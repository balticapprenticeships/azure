<#
.version 1.0.0
.AUTHOR Chris Langford
.SYNOPSIS
    This script automates the creation of spoke virtual networks in each resource group of a subscription, assigns them CIDR blocks from a defined range, and peers them with a central firewall VNet. It also tags the VNets and applies a resource lock to prevent accidental deletion.
.DESCRIPTION
    The script connects to Azure using a Managed Identity, iterates through resource groups (with optional exclusion patterns), creates a VNet in each RG if it doesn't exist, assigns CIDR blocks (with optional persistence in a storage table), tags the VNets, applies a "DoNotDelete" lock, and peers them with a central firewall VNet in another subscription.
.PARAMETER SubscriptionId
    The subscription ID where the spoke VNets will be created. If not provided, it will attempt to read from an Automation Variable named 'SubscriptionId'.
.PARAMETER FirewallSubscriptionId
    The subscription ID where the central firewall VNet is located.
.PARAMETER FirewallVnetName
    The name of the central firewall VNet to peer with. Default is "FirewallRg-vnet".
.PARAMETER FirewallVnetResourceGroup
    The resource group of the central firewall VNet. Default is "FirewallRg".
.PARAMETER Tags
    A hashtable of tags to apply to each created VNet. Default is @{Cleanup="Disabled"}.
.PARAMETER VnetPrefixLength
    The prefix length for the spoke VNets. Default is 24.
.PARAMETER SubnetPrefixLength
    The prefix length for the subnets within each spoke VNet. Default is 26.
.PARAMETER StorageAccountResourceGroup
    The resource group where the CIDR storage account is located. Default is "NetworkAutomationRg".
.PARAMETER CidrStoreAccountName
    The name of the storage account to use for CIDR persistence. Default is "cidrstoresa".
.PARAMETER CidrStoreSubscriptionId
    The subscription ID where the CIDR storage account is located. Defaults to FirewallSubscriptionId.
.PARAMETER CidrStoreTableName
    The name of the table in the storage account to use for CIDR persistence. Default is "CidrAllocation".
.PARAMETER ExcludeRgPattern
    An array of patterns to exclude resource groups from processing. Default is @("OMSrg$", "NetworkWatcherRG", "DefaultResourceGroup-").
.PARAMETER DryRun
    A boolean indicating whether to perform a dry run (preview changes without applying them). Default is $true.

.NOTES
    - Requires Azure PowerShell module (Az)
    - Run with appropriate permissions to create VNets, assign roles, and manage resources
    - Edit the parameters section to specify your environment details and preferences.
.RuntimeEnvironment PowerShell-7.4
#>
param(

    [Parameter(Mandatory=$false)]
    [ValidatePattern('^[0-9a-fA-F-]{36}$')]
    [string] $SubscriptionId,

    [Parameter(Mandatory=$false)]
    [string]$FirewallSubscriptionId = "c4790cb5-6d79-4f3b-914e-3307eb65c9d3",

    [Parameter(Mandatory=$false)]
    [string]$FirewallVnetName = "FirewallRg-vnet",

    [Parameter(Mandatory=$false)]
    [string]$FirewallVnetResourceGroup = "FirewallRg",

    [hashtable]$Tags = @{Cleanup="Disabled"},

    [int]$VnetPrefixLength = 24,

    [int]$SubnetPrefixLength = 26,

    [string]$StorageAccountResourceGroup = "NetworkAutomationRg",
    [Parameter(Mandatory=$false)]
    [string]$CidrStoreAccountName = "cidrstoresa",
    [Parameter(Mandatory=$false)]
    [ValidatePattern('^[0-9a-fA-F-]{36}$')]
    [string]$CidrStoreSubscriptionId,
    [Parameter(Mandatory=$false)]
    [string]$CidrStoreTableName = "CidrAllocation",

    [string[]]$ExcludeRgPattern = @("OMSrg$", "NetworkWatcherRG", "DefaultResourceGroup-"),

    [bool]$DryRun = $true
)

Import-Module Az.Storage -ErrorAction Stop
Import-Module AzTable -ErrorAction Stop

# ----------------------------
# Connect to Azure
# ----------------------------
try {
    Clear-AzContext -Scope Process -Force -ErrorAction SilentlyContinue

    # Resolve subscription first
    if (-not $subscriptionId) {
        $subscriptionId = Get-AutomationVariable -Name 'SubscriptionId'
    }

    if (-not $subscriptionId) {
        throw "SubscriptionId is required."
    }

    $subscriptionId = $subscriptionId.Trim()

    # 🔥 Bind subscription at login
    Connect-AzAccount -Identity -Subscription $subscriptionId

    $context = Get-AzContext

    if ($context.Subscription.Id -ne $subscriptionId) {
        throw "Context mismatch after login."
    }

    Write-Output "Spoke Subscription: $($context.Subscription.Name) ($subscriptionId)"
}
catch {
    Write-Error "Authentication or subscription selection failed: $_"
    throw
}

$spokeSubId = (Get-AzContext).Subscription.Id
if (-not $CidrStoreSubscriptionId) {
    $CidrStoreSubscriptionId = $FirewallSubscriptionId
}

# ----------------------------
# Subscription Helpers
# ----------------------------
function Invoke-InSubscription {
    param(
        [Parameter(Mandatory=$true)]
        [string]$SubscriptionId,
        [Parameter(Mandatory=$true)]
        [scriptblock]$ScriptBlock
    )

    $previousSubscriptionId = (Get-AzContext).Subscription.Id
    try {
        if ($previousSubscriptionId -ne $SubscriptionId) {
            Select-AzSubscription -SubscriptionId $SubscriptionId -ErrorAction Stop | Out-Null
        }

        & $ScriptBlock
    }
    finally {
        $currentSubscriptionId = (Get-AzContext).Subscription.Id
        if ($previousSubscriptionId -and $currentSubscriptionId -ne $previousSubscriptionId) {
            Select-AzSubscription -SubscriptionId $previousSubscriptionId -ErrorAction Stop | Out-Null
        }
    }
}

function Invoke-InSpokeSubscription {
    param([Parameter(Mandatory=$true)][scriptblock]$ScriptBlock)
    Invoke-InSubscription -SubscriptionId $spokeSubId -ScriptBlock $ScriptBlock
}

function Invoke-InCidrStoreSubscription {
    param([Parameter(Mandatory=$true)][scriptblock]$ScriptBlock)
    Invoke-InSubscription -SubscriptionId $CidrStoreSubscriptionId -ScriptBlock $ScriptBlock
}

function Invoke-InFirewallSubscription {
    param([Parameter(Mandatory=$true)][scriptblock]$ScriptBlock)
    Invoke-InSubscription -SubscriptionId $FirewallSubscriptionId -ScriptBlock $ScriptBlock
}

# ----------------------------
# Cidr Helpers
# ----------------------------
function Get-CidrLockBlob {
    param(
        [string]$StorageAccountName,
        [string]$ContainerName = "cidr-locks",
        [string]$BlobName = "cidr-allocation.lock"
    )

    Invoke-InCidrStoreSubscription {

        $ctx = New-AzStorageContext `
            -StorageAccountName $StorageAccountName `
            -UseConnectedAccount

        $container = Get-AzStorageContainer `
            -Name $ContainerName `
            -Context $ctx `
            -ErrorAction SilentlyContinue

        if (-not $container) {
            $container = New-AzStorageContainer `
                -Name $ContainerName `
                -Context $ctx
        }

        $blob = Get-AzStorageBlob `
            -Container $ContainerName `
            -Blob $BlobName `
            -Context $ctx `
            -ErrorAction SilentlyContinue

        if (-not $blob) {

            $tmp = Join-Path $env:TEMP "cidr-lock.txt"
            "lock" | Out-File $tmp

            Set-AzStorageBlobContent `
                -Container $ContainerName `
                -File $tmp `
                -Blob $BlobName `
                -Context $ctx `
                -Force | Out-Null
        }

        return @{
            Context = $ctx
            Container = $ContainerName
            Blob = $BlobName
        }
    }
}

function Request-CidrLease {

    param(
        [string]$StorageAccountName,
        [int]$RetrySeconds = 5,
        [int]$MaxRetries = 24
    )

    $lockBlob = Get-CidrLockBlob `
        -StorageAccountName $StorageAccountName

    for ($i = 0; $i -lt $MaxRetries; $i++) {

        try {

            $lease = New-AzStorageBlobLease `
                -Container $lockBlob.Container `
                -Blob $lockBlob.Blob `
                -Context $lockBlob.Context `
                -LeaseAction Acquire `
                -LeaseDuration 60 `
                -ErrorAction Stop

            return @{
                LeaseId = $lease.LeaseId
                Context = $lockBlob.Context
                Container = $lockBlob.Container
                Blob = $lockBlob.Blob
            }
        }
        catch {

            Write-Output "CIDR lease busy. Waiting..."

            Start-Sleep -Seconds $RetrySeconds
        }
    }

    throw "Unable to acquire CIDR allocation lease."
}

function Unlock-CidrLease {

    param(
        [Parameter(Mandatory)]
        $Lease
    )

    try {

        Remove-AzStorageBlobLease `
            -Container $Lease.Container `
            -Blob $Lease.Blob `
            -Context $Lease.Context `
            -LeaseId $Lease.LeaseId `
            -ErrorAction Stop | Out-Null
    }
    catch {

        Write-Warning "Failed to release CIDR lease: $_"
    }
}

# ----------------------------
# CIDR helpers
# ----------------------------
function Get-Subnets {
    param([string]$BaseCidr, [int]$NewPrefix)
    $base = ($BaseCidr -split "/")[0]
    $basePrefix = [int]($BaseCidr -split "/")[1]

    $baseBytes = [System.Net.IPAddress]::Parse($base).GetAddressBytes()
    [Array]::Reverse($baseBytes)
    $baseInt = [BitConverter]::ToUInt32($baseBytes,0)

    $count = 1 -shl ($NewPrefix - $basePrefix)
    $step = 1 -shl (32 - $NewPrefix)

    $subnets = @()
    for ($i = 0; $i -lt $count; $i++) {
        $next = $baseInt + ($i * $step)
        if ($next -gt [uint32]::MaxValue) { break }
        $bytes = [BitConverter]::GetBytes([uint32]$next)
        [Array]::Reverse($bytes)
        $ip = [System.Net.IPAddress]::new($bytes).ToString()
        $subnets += "$ip/$NewPrefix"
    }
    return $subnets
}

# ----------------------------
# CIDR persistence (optional)
# ----------------------------
$cidrStoreEnabled = ($CidrStoreAccountName -and $CidrStoreTableName)
if ($cidrStoreEnabled) {
    $cidrTable = Invoke-InCidrStoreSubscription {
        $rgForStorage = Get-AzStorageAccount -ResourceGroupName $StorageAccountResourceGroup -Name $CidrStoreAccountName
        if (-not $rgForStorage) {
            throw "CIDR storage account '$CidrStoreAccountName' was not found in subscription '$CidrStoreSubscriptionId'."
        }

        $ctx = New-AzStorageContext -StorageAccountName $CidrStoreAccountName -UseConnectedAccount
        $storageTable = Get-AzStorageTable -Name $CidrStoreTableName -Context $ctx -ErrorAction Stop
        if (-not $storageTable) {
            throw "CIDR storage table '$CidrStoreTableName' was not found in storage account '$CidrStoreAccountName'."
        }

        $storageTable.CloudTable
    }
}

# ----------------------------
# Automatic global /16 allocation
# ----------------------------
function Get-NextFreeBaseCidr {
    param(
        [string[]]$ExistingCidrs,
        [int]$StartOctet = 2,
        [int]$MaxOctet = 255
    )

    for ($i = $StartOctet; $i -le $MaxOctet; $i++) {
        $candidate = "10.$i.0.0/16"
        if ($ExistingCidrs -notcontains $candidate) { return $candidate }
    }
    throw "No available /16 CIDR blocks remaining in 10.2.0.0/16 - 10.255.0.0/16"
}

function Get-BaseCidrForSubscription {

    param([string]$SubscriptionId)

    $rows = Invoke-InCidrStoreSubscription {
        Get-AzTableRow -Table $cidrTable -PartitionKey "CIDR"
    }

    $entry = $rows |
        Where-Object RowKey -eq $SubscriptionId

    if ($entry) {
        return $entry.BaseCidr
    }

    return $null
}

function Get-OrCreateSubscriptionAllocation {

    param(
        [string]$SubscriptionId
    )

    $rows = Invoke-InCidrStoreSubscription {

        Get-AzTableRow -Table $cidrTable -PartitionKey "CIDR"
    }

    $entry = $rows | Where-Object RowKey -eq $SubscriptionId

    if ($entry) {
        return $entry
    }

    $assignedCidrs = @(
        $rows | Select-Object -ExpandProperty BaseCidr
    )

    $nextCidr = Get-NextFreeBaseCidr -ExistingCidrs $assignedCidrs

    Invoke-InCidrStoreSubscription {

        Add-AzTableRow `
            -Table $cidrTable `
            -PartitionKey "CIDR" `
            -RowKey $SubscriptionId `
            -Properties @{
                BaseCidr = $nextCidr
                NextIndex = 0
            } | Out-Null
    }

    return Invoke-InCidrStoreSubscription {

        Get-AzTableRow `
            -Table $cidrTable `
            -PartitionKey "CIDR" `
            -RowKey $SubscriptionId
    }
}

function Get-NextSubnetCidr {

    param(
        [string]$SubscriptionId,
        [int]$PrefixLength = 24
    )

    if (-not $cidrStoreEnabled) {

        $subnets = Get-Subnets -BaseCidr "10.1.0.0/16" -NewPrefix $PrefixLength

        return $subnets[0]
    }

    $lease = Request-CidrLease -StorageAccountName $CidrStoreAccountName

    try {

        $entry = Get-OrCreateSubscriptionAllocation -SubscriptionId $SubscriptionId

        $baseCidr = $entry.BaseCidr

        $index = [int]$entry.NextIndex

        $subnets = Get-Subnets -BaseCidr $baseCidr -NewPrefix $PrefixLength

        if ($index -ge $subnets.Count) {
            throw "CIDR exhausted in $baseCidr"
        }

        $nextSubnet = $subnets[$index]

        $entry.NextIndex = $index + 1

        Invoke-InCidrStoreSubscription {

            Update-AzTableRow -Table $cidrTable -Row $entry | Out-Null
        }

        return $nextSubnet
    }
    finally {

        Unlock-CidrLease -Lease $lease
    }
}

# ----------------------------
# Filter resource groups
# ----------------------------
$rgs = Invoke-InSpokeSubscription {
    Get-AzResourceGroup | Where-Object {
        $exclude = $false
        foreach ($pattern in $ExcludeRgPattern) {
            if ($_.ResourceGroupName -match $pattern) { $exclude = $true; break }
        }
        -not $exclude
    }
}

# ----------------------------
# VNet creation loop
# ----------------------------
foreach ($rg in $rgs) {
    $vnetName = "$($rg.ResourceGroupName.ToLower())-vnet"
    $vnet = Invoke-InSpokeSubscription {
        Get-AzVirtualNetwork -ResourceGroupName $rg.ResourceGroupName -Name $vnetName -ErrorAction SilentlyContinue
    }

    if (-not $vnet) {
        $cidr = Get-NextSubnetCidr -SubscriptionId $spokeSubId -PrefixLength $VnetPrefixLength
        Write-Output "[CREATE] $vnetName → $cidr"

        if (-not $DryRun) {
            $subnetCidr = (Get-Subnets -BaseCidr $cidr -NewPrefix $SubnetPrefixLength)[0]
            $subnet = New-AzVirtualNetworkSubnetConfig -Name "default" -AddressPrefix $subnetCidr
            $vnet = Invoke-InSpokeSubscription {
                New-AzVirtualNetwork -Name $vnetName -ResourceGroupName $rg.ResourceGroupName -Location $rg.Location -AddressPrefix $cidr -Subnet $subnet -Tag $Tags
            }
        }
    } else {
        Write-Output "[EXISTS] $vnetName"
    }

    # Tag merge
    if (-not $DryRun -and $vnet) {
        $merged = @{}
        if ($vnet.Tags) { $merged = $vnet.Tags.Clone() }
        foreach ($k in $Tags.Keys) { $merged[$k] = $Tags[$k] }
        Invoke-InSpokeSubscription {
            Set-AzVirtualNetwork -VirtualNetwork $vnet -Tag $merged | Out-Null
        }
    }

    # Resource lock
    if (-not $DryRun -and $vnet) {
        $lock = Invoke-InSpokeSubscription {
            Get-AzResourceLock -ResourceName $vnet.Name -ResourceGroupName $rg.ResourceGroupName -ResourceType "Microsoft.Network/virtualNetworks" -ErrorAction SilentlyContinue
        }
        if (-not $lock) {
            Invoke-InSpokeSubscription {
                New-AzResourceLock -LockName "DoNotDelete-VNET" -LockLevel CanNotDelete -ResourceName $vnet.Name -ResourceGroupName $rg.ResourceGroupName -ResourceType "Microsoft.Network/virtualNetworks" | Out-Null
            }
        }
    }

    # Firewall peering
    if ($vnet) {
        $fwVnet = Invoke-InFirewallSubscription {
            Get-AzVirtualNetwork -Name $FirewallVnetName -ResourceGroupName $FirewallVnetResourceGroup
        }

        $peer = Invoke-InSpokeSubscription {
            Get-AzVirtualNetworkPeering -VirtualNetworkName $vnet.Name -ResourceGroupName $rg.ResourceGroupName -Name "$($vnet.Name)-to-fw" -ErrorAction SilentlyContinue
        }
        if (-not $peer) {
            Write-Output "[PEER] $($vnet.Name) → firewall"

            if (-not $DryRun) {
                Invoke-InSpokeSubscription {
                    Add-AzVirtualNetworkPeering -Name "$($vnet.Name)-to-fw" -VirtualNetwork $vnet -RemoteVirtualNetworkId $fwVnet.Id -AllowForwardedTraffic -UseRemoteGateways:$true | Out-Null
                }

                Invoke-InFirewallSubscription {
                    Add-AzVirtualNetworkPeering -Name "fw-to-$($vnet.Name)" -VirtualNetwork $fwVnet -RemoteVirtualNetworkId $vnet.Id -AllowForwardedTraffic -AllowGatewayTransit | Out-Null
                }
            }
        }
    }
}

Write-Output "Runbook complete."
