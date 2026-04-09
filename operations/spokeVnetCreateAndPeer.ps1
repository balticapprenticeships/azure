<#
.version 1.0
.AUTHOR Chris Langford
.SYNOPSIS
    This script automates the creation of spoke virtual networks in each resource group of a subscription, assigns them CIDR blocks from a defined range, and peers them with a central firewall VNet. It also tags the VNets and applies a resource lock to prevent accidental deletion.
.DESCRIPTION
    The script connects to Azure using a Managed Identity, iterates through resource groups (with optional exclusion patterns), creates a VNet in each RG if it doesn't exist, assigns CIDR blocks (with optional persistence in a storage table), tags the VNets, applies a "DoNotDelete" lock, and peers them with a central firewall VNet in another subscription.
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
.PARAMETER CidrStoreAccountName
    The name of the storage account to use for CIDR persistence. Default is "cidrstoresa".
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

#>
param(
    [Parameter(Mandatory=$false)]
    [string]$FirewallSubscriptionId = "c4790cb5-6d79-4f3b-914e-3307eb65c9d3",

    [Parameter(Mandatory=$false)]
    [string]$FirewallVnetName = "FirewallRg-vnet",

    [Parameter(Mandatory=$false)]
    [string]$FirewallVnetResourceGroup = "FirewallRg",

    [hashtable]$Tags = @{Cleanup="Disabled"},

    [int]$VnetPrefixLength = 24,

    [int]$SubnetPrefixLength = 26,

    [Parameter(Mandatory=$false)]
    [string]$CidrStoreAccountName = "cidrstoresa",
    [Parameter(Mandatory=$false)]
    [string]$CidrStoreTableName = "CidrAllocation",

    [string[]]$ExcludeRgPattern = @("OMSrg$", "NetworkWatcherRG", "DefaultResourceGroup-"),

    [bool]$DryRun = $true
)

# ----------------------------
# Connect to Azure
# ----------------------------
$context = Connect-AzAccount -Identity | Select-Object -First 1
$spokeSubId = $context.Subscription.Id
Set-AzContext -SubscriptionId $spokeSubId
Write-Output "Spoke Subscription: $spokeSubId"

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
    $rgForStorage = Get-AzStorageAccount | Where-Object {$_.StorageAccountName -eq $CidrStoreAccountName} | Select-Object -First 1
    $ctx = $rgForStorage.Context
    $cidrTable = Get-AzTable -Name $CidrStoreTableName -Context $ctx
}

# ----------------------------
# Automatic global /16 allocation
# ----------------------------
function Get-NextFreeBaseCidr {
    param(
        [string[]]$ExistingCidrs,
        [int]$StartOctet = 1,
        [int]$MaxOctet = 255
    )

    for ($i = $StartOctet; $i -le $MaxOctet; $i++) {
        $candidate = "10.$i.0.0/16"
        if ($ExistingCidrs -notcontains $candidate) { return $candidate }
    }
    throw "No available /16 CIDR blocks remaining in 10.1.0.0/16 - 10.255.0.0/16"
}

function Get-BaseCidrForSubscription {
    param([string]$SubscriptionId)

    if ($cidrStoreEnabled) {
        # Load all assigned BaseCidrs
        $assignedCidrs = @()
        $rows = Get-AzTableRow -Table $cidrTable -PartitionKey "CIDR"
        foreach ($r in $rows) { $assignedCidrs += $r.BaseCidr }

        # Check if subscription already has BaseCidr
        $entry = $rows | Where-Object {$_.RowKey -eq $SubscriptionId}
        if ($entry) { return $entry.BaseCidr }

        # Otherwise assign next free /16
        $nextCidr = Get-NextFreeBaseCidr -ExistingCidrs $assignedCidrs
        if (-not $DryRun) {
            Add-AzTableRow -Table $cidrTable -PartitionKey "CIDR" -RowKey $SubscriptionId -Properties @{BaseCidr=$nextCidr;NextIndex=0}
        }
        return $nextCidr
    } else {
        return "10.1.0.0/16"
    }
}

function Get-NextSubnetCidr {
    param([string]$SubscriptionId, [int]$PrefixLength=24)

    $baseCidr = Get-BaseCidrForSubscription -SubscriptionId $SubscriptionId
    if ($cidrStoreEnabled -and -not $DryRun) {
        $entry = Get-AzTableRow -Table $cidrTable -PartitionKey "CIDR" -RowKey $SubscriptionId
        $index = $entry.NextIndex
        $subnets = Get-Subnets -BaseCidr $baseCidr -NewPrefix $PrefixLength
        if ($index -ge $subnets.Count) { throw "CIDR exhausted in base $baseCidr" }
        $nextSubnet = $subnets[$index]
        $entry.NextIndex = $index + 1
        Update-AzTableRow -Table $cidrTable -Row $entry
        return $nextSubnet
    } else {
        $subnets = Get-Subnets -BaseCidr $baseCidr -NewPrefix $PrefixLength
        return $subnets[0]
    }
}

# ----------------------------
# Filter resource groups
# ----------------------------
$rgs = Get-AzResourceGroup | Where-Object {
    $exclude = $false
    foreach ($pattern in $ExcludeRgPattern) {
        if ($_.ResourceGroupName -match $pattern) { $exclude = $true; break }
    }
    -not $exclude
}

# ----------------------------
# VNet creation loop
# ----------------------------
foreach ($rg in $rgs) {
    $vnetName = "$($rg.ResourceGroupName.ToLower())-vnet"
    $vnet = Get-AzVirtualNetwork -ResourceGroupName $rg.ResourceGroupName -Name $vnetName -ErrorAction SilentlyContinue

    if (-not $vnet) {
        $cidr = Get-NextSubnetCidr -SubscriptionId $spokeSubId -PrefixLength $VnetPrefixLength
        Write-Output "[CREATE] $vnetName → $cidr"

        if (-not $DryRun) {
            $subnetCidr = (Get-Subnets -BaseCidr $cidr -NewPrefix $SubnetPrefixLength)[0]
            $subnet = New-AzVirtualNetworkSubnetConfig -Name "default" -AddressPrefix $subnetCidr
            $vnet = New-AzVirtualNetwork -Name $vnetName -ResourceGroupName $rg.ResourceGroupName -Location $rg.Location -AddressPrefix $cidr -Subnet $subnet -Tag $Tags
        }
    } else {
        Write-Output "[EXISTS] $vnetName"
    }

    # Tag merge
    if (-not $DryRun -and $vnet) {
        $merged = @{}
        if ($vnet.Tags) { $merged = $vnet.Tags.Clone() }
        foreach ($k in $Tags.Keys) { $merged[$k] = $Tags[$k] }
        Set-AzVirtualNetwork -VirtualNetwork $vnet -Tag $merged
    }

    # Resource lock
    if (-not $DryRun -and $vnet) {
        $lock = Get-AzResourceLock -ResourceName $vnet.Name -ResourceGroupName $rg.ResourceGroupName -ResourceType "Microsoft.Network/virtualNetworks" -ErrorAction SilentlyContinue
        if (-not $lock) {
            New-AzResourceLock -LockName "DoNotDelete-VNET" -LockLevel CanNotDelete -ResourceName $vnet.Name -ResourceGroupName $rg.ResourceGroupName -ResourceType "Microsoft.Network/virtualNetworks"
        }
    }

    # Firewall peering
    if ($vnet) {
        Select-AzSubscription -SubscriptionId $FirewallSubscriptionId
        $fwVnet = Get-AzVirtualNetwork -Name $FirewallVnetName -ResourceGroupName $FirewallVnetResourceGroup
        Select-AzSubscription -SubscriptionId $spokeSubId

        $peer = Get-AzVirtualNetworkPeering -VirtualNetworkName $vnet.Name -ResourceGroupName $rg.ResourceGroupName -Name "$($vnet.Name)-to-fw" -ErrorAction SilentlyContinue
        if (-not $peer) {
            Write-Output "[PEER] $($vnet.Name) → firewall"

            if (-not $DryRun) {
                Add-AzVirtualNetworkPeering -Name "$($vnet.Name)-to-fw" -VirtualNetwork $vnet -RemoteVirtualNetworkId $fwVnet.Id -AllowForwardedTraffic -UseRemoteGateways:$true

                Select-AzSubscription -SubscriptionId $FirewallSubscriptionId
                Add-AzVirtualNetworkPeering -Name "fw-to-$($vnet.Name)" -VirtualNetwork $fwVnet -RemoteVirtualNetworkId $vnet.Id -AllowForwardedTraffic -AllowGatewayTransit
                Select-AzSubscription -SubscriptionId $spokeSubId
            }
        }
    }
}

Write-Output "Runbook complete."