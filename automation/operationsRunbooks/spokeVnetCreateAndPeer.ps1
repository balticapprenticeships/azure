<#
.version 3.1.0
.AUTHOR Chris Langford
.SYNOPSIS
    This script automates the creation of spoke virtual networks in each resource group of a subscription, assigns them CIDR blocks from a defined range, and peers them with a central firewall VNet. It also tags the VNets and applies a resource lock to prevent accidental deletion.
.DESCRIPTION
    The script connects to Azure using a Managed Identity, iterates through resource groups (with optional exclusion patterns), creates a VNet and network security group in each RG if the VNet doesn't exist, assigns CIDR blocks (with optional persistence in a storage table), tags the VNets, applies a "DoNotDelete" lock, and peers them with a central firewall VNet in another subscription.
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
.PARAMETER BaseCidr
    The base CIDR block to allocate from. Default is "10.0.0.0/16".
.PARAMETER CidrStoreEnabled
    A boolean indicating whether to use a storage account for CIDR persistence. Default is $false (automatic in-memory allocation). If enabled, the script will store CIDR allocations in an Azure Table for durability and concurrency control across multiple runs or instances.
.PARAMETER StorageAccountResourceGroup
    The resource group where the CIDR storage account is located. Default is "NetworkAutomationRg".
.PARAMETER CidrStoreAccountName
    The name of the storage account to use for CIDR persistence. Default is "cidrstoresa".S
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


    [string]$FirewallSubscriptionId = "c4790cb5-6d79-4f3b-914e-3307eb65c9d3",
    [string]$FirewallVnetName = "FirewallRg-vnet",
    [string]$FirewallVnetResourceGroup = "FirewallRg",

    [hashtable]$Tags = @{Cleanup="Disabled"},

    [int]$VnetPrefixLength = 24,

    [int]$SubnetPrefixLength = 26,

    [string]$StorageAccountResourceGroup = "NetworkAutomationRg",
    [string]$CidrStoreAccountName = "cidrstoresa",
    [Parameter(Mandatory=$false)]
    [ValidatePattern('^[0-9a-fA-F-]{36}$')]
    [string]$CidrStoreSubscriptionId,
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

    # Bind subscription at login
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
# Table concurrency helpers
# ----------------------------
function Test-CidrConcurrencyConflict {
    param(
        [Parameter(Mandatory=$true)]
        [System.Management.Automation.ErrorRecord]$ErrorRecord
    )

    $exception = $ErrorRecord.Exception
    while ($exception) {
        $statusCode = $exception.RequestInformation.HttpStatusCode
        if ($statusCode -in 409, 412) {
            return $true
        }
        $exception = $exception.InnerException
    }

    if ($ErrorRecord.Exception.Message -match '\b(409|412)\b|conflict|precondition') {
        return $true
    }

    return $false
}

function Invoke-CidrConcurrencyRetry {
    param(
        [Parameter(Mandatory=$true)]
        [scriptblock]$ScriptBlock,
        [int]$RetrySeconds = 5,
        [int]$MaxRetries = 24
    )

    for ($i = 0; $i -lt $MaxRetries; $i++) {
        try {
            return & $ScriptBlock
        }
        catch {
            if (-not (Test-CidrConcurrencyConflict -ErrorRecord $_)) {
                throw
            }

            Write-Output "CIDR allocation changed concurrently. Retrying..."
            Start-Sleep -Seconds $RetrySeconds
        }
    }

    throw "Unable to update CIDR allocation after $MaxRetries optimistic concurrency retries."
}

function Get-CidrAllocationRows {
    Invoke-InCidrStoreSubscription {
        Get-AzTableRow -Table $cidrTable -PartitionKey "CIDR"
    }
}

function Get-CidrVnetAllocationRows {
    param([string]$SubscriptionId)

    $allocationPrefix = "$SubscriptionId|"

    Invoke-InCidrStoreSubscription {
        Get-AzTableRow -Table $cidrTable -PartitionKey "CIDR_ALLOCATIONS"
    } | Where-Object RowKey -like "$allocationPrefix*"
}

function Get-CidrAllocatorState {
    Invoke-InCidrStoreSubscription {
        Get-AzTableRow `
            -Table $cidrTable `
            -PartitionKey "CIDR_STATE" `
            -RowKey "GLOBAL"
    }
}

function Get-CidrSubscriptionAllocation {
    param([string]$SubscriptionId)

    Invoke-InCidrStoreSubscription {
        Get-AzTableRow `
            -Table $cidrTable `
            -PartitionKey "CIDR" `
            -RowKey $SubscriptionId
    }
}

function Get-CidrVnetAllocationRowKey {
    param(
        [string]$SubscriptionId,
        [string]$ResourceGroupName,
        [string]$VnetName
    )

    return "$SubscriptionId|$ResourceGroupName|$VnetName"
}

function Get-CidrVnetAllocation {
    param(
        [string]$SubscriptionId,
        [string]$ResourceGroupName,
        [string]$VnetName
    )

    $rowKey = Get-CidrVnetAllocationRowKey `
        -SubscriptionId $SubscriptionId `
        -ResourceGroupName $ResourceGroupName `
        -VnetName $VnetName

    Invoke-InCidrStoreSubscription {
        Get-AzTableRow `
            -Table $cidrTable `
            -PartitionKey "CIDR_ALLOCATIONS" `
            -RowKey $rowKey
    }
}

function Remove-CidrVnetAllocation {
    param(
        [string]$SubscriptionId,
        [string]$ResourceGroupName,
        [string]$VnetName
    )

    try {
        $allocation = Get-CidrVnetAllocation `
            -SubscriptionId $SubscriptionId `
            -ResourceGroupName $ResourceGroupName `
            -VnetName $VnetName

        if ($allocation) {
            Invoke-InCidrStoreSubscription {
                Remove-AzTableRow `
                    -Table $cidrTable `
                    -entity $allocation `
                    -ErrorAction Stop | Out-Null
            }
        }
    }
    catch {
        Write-Warning "Failed to remove CIDR allocation for '$VnetName': $_"
    }
}

function Update-CidrTableRowWithEtag {
    param(
        [Parameter(Mandatory=$true)]
        $Table,
        [Parameter(Mandatory=$true)]
        $Row
    )

    $updatedEntity = New-Object `
        -TypeName "Microsoft.Azure.Cosmos.Table.DynamicTableEntity" `
        -ArgumentList $Row.PartitionKey, $Row.RowKey

    foreach ($prop in $Row.psobject.Properties) {
        if ($prop.Name -notin @("PartitionKey", "RowKey", "Timestamp", "Etag", "TableTimestamp")) {
            $updatedEntity.Properties.Add($prop.Name, $prop.Value)
        }
    }

    $updatedEntity.ETag = $Row.Etag
    $updatedEntity.Timestamp = $Row.TableTimestamp

    $Table.Execute([Microsoft.Azure.Cosmos.Table.TableOperation]::Replace($updatedEntity)) | Out-Null
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

function Get-FirstFreeSubnetCidr {
    param(
        [string]$BaseCidr,
        [int]$PrefixLength,
        [string[]]$UsedCidrs
    )

    $subnets = Get-Subnets -BaseCidr $BaseCidr -NewPrefix $PrefixLength

    foreach ($subnet in $subnets) {
        if ($UsedCidrs -notcontains $subnet) {
            return $subnet
        }
    }

    throw "CIDR exhausted in $BaseCidr"
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

$cidrDryRunAllocations = @{}

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

    $rows = Get-CidrAllocationRows

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

    $entry = Get-CidrSubscriptionAllocation -SubscriptionId $SubscriptionId

    if ($entry) {
        return $entry
    }

    Invoke-CidrConcurrencyRetry -ScriptBlock {
        $rows = Get-CidrAllocationRows

        $entry = $rows | Where-Object RowKey -eq $SubscriptionId

        if ($entry) {
            return $entry
        }

        $assignedCidrs = @(
            $rows | Select-Object -ExpandProperty BaseCidr
        )

        $state = Get-CidrAllocatorState

        if (-not $state) {
            $nextBaseOctet = 2
            $assignedOctets = @(
                $assignedCidrs |
                    Where-Object { $_ -match '^10\.(\d+)\.0\.0/16$' } |
                    ForEach-Object { [int]$Matches[1] }
            )

            if ($assignedOctets.Count -gt 0) {
                $nextBaseOctet = (($assignedOctets | Measure-Object -Maximum).Maximum + 1)
            }

            Invoke-InCidrStoreSubscription {
                Add-AzTableRow `
                    -Table $cidrTable `
                    -PartitionKey "CIDR_STATE" `
                    -RowKey "GLOBAL" `
                    -property @{
                        NextBaseOctet = $nextBaseOctet
                    } `
                    -ErrorAction Stop | Out-Null
            }

            $state = Get-CidrAllocatorState
        }

        $candidateOctet = [int]$state.NextBaseOctet
        do {
            if ($candidateOctet -gt 255) {
                throw "No available /16 CIDR blocks remaining in 10.2.0.0/16 - 10.255.0.0/16"
            }

            $nextCidr = "10.$candidateOctet.0.0/16"
            $candidateOctet++
        } while ($assignedCidrs -contains $nextCidr)

        $state.NextBaseOctet = $candidateOctet

        Invoke-InCidrStoreSubscription {
            Update-CidrTableRowWithEtag `
                -Table $cidrTable `
                -Row $state

            Add-AzTableRow `
                -Table $cidrTable `
                -PartitionKey "CIDR" `
                -RowKey $SubscriptionId `
                -property @{
                    BaseCidr = $nextCidr
                    NextIndex = 0
                } `
                -ErrorAction Stop | Out-Null

            Get-AzTableRow `
                -Table $cidrTable `
                -PartitionKey "CIDR" `
                -RowKey $SubscriptionId
        }
    }
}

function Get-NextSubnetCidr {

    param(
        [string]$SubscriptionId,
        [string]$ResourceGroupName,
        [string]$VnetName,
        [int]$PrefixLength = 24,
        [switch]$Preview,
        [string[]]$ExistingVnetCidrs = @()
    )

    if (-not $cidrStoreEnabled) {

        $subnets = Get-Subnets -BaseCidr "10.1.0.0/16" -NewPrefix $PrefixLength

        return $subnets[0]
    }

    if ($Preview) {
        $allocationKey = Get-CidrVnetAllocationRowKey `
            -SubscriptionId $SubscriptionId `
            -ResourceGroupName $ResourceGroupName `
            -VnetName $VnetName

        if ($cidrDryRunAllocations.ContainsKey($allocationKey)) {
            return $cidrDryRunAllocations[$allocationKey].VnetCidr
        }

        $existingAllocation = Get-CidrVnetAllocation `
            -SubscriptionId $SubscriptionId `
            -ResourceGroupName $ResourceGroupName `
            -VnetName $VnetName

        if ($existingAllocation) {
            $cidrDryRunAllocations[$allocationKey] = [pscustomobject]@{
                BaseCidr = $existingAllocation.BaseCidr
                VnetCidr = $existingAllocation.VnetCidr
            }

            return $existingAllocation.VnetCidr
        }

        $subscriptionPreviewKey = "$SubscriptionId|SUBSCRIPTION"
        if (-not $cidrDryRunAllocations.ContainsKey($subscriptionPreviewKey)) {
            $entry = Get-CidrSubscriptionAllocation -SubscriptionId $SubscriptionId

            if ($entry) {
                $cidrDryRunAllocations[$subscriptionPreviewKey] = [pscustomobject]@{
                    BaseCidr = $entry.BaseCidr
                    NextIndex = [int]$entry.NextIndex
                }
            }
            else {
                $rows = Get-CidrAllocationRows
                $assignedCidrs = @(
                    $rows | Select-Object -ExpandProperty BaseCidr
                )

                $assignedCidrs += @(
                    $cidrDryRunAllocations.Values | Select-Object -ExpandProperty BaseCidr
                )

                $state = Get-CidrAllocatorState
                if ($state) {
                    $candidateOctet = [int]$state.NextBaseOctet
                }
                else {
                    $candidateOctet = 2
                    $assignedOctets = @(
                        $assignedCidrs |
                            Where-Object { $_ -match '^10\.(\d+)\.0\.0/16$' } |
                            ForEach-Object { [int]$Matches[1] }
                    )

                    if ($assignedOctets.Count -gt 0) {
                        $candidateOctet = (($assignedOctets | Measure-Object -Maximum).Maximum + 1)
                    }
                }

                do {
                    if ($candidateOctet -gt 255) {
                        throw "No available /16 CIDR blocks remaining in 10.2.0.0/16 - 10.255.0.0/16"
                    }

                    $baseCidr = "10.$candidateOctet.0.0/16"
                    $candidateOctet++
                } while ($assignedCidrs -contains $baseCidr)

                $cidrDryRunAllocations[$subscriptionPreviewKey] = [pscustomobject]@{
                    BaseCidr = $baseCidr
                    NextIndex = 0
                }
            }
        }

        $previewAllocation = $cidrDryRunAllocations[$subscriptionPreviewKey]
        $allocationRows = Get-CidrVnetAllocationRows -SubscriptionId $SubscriptionId
        $usedCidrs = @(
            $allocationRows | Select-Object -ExpandProperty VnetCidr
        )

        $usedCidrs += @(
            $ExistingVnetCidrs | Where-Object { $_ -in (Get-Subnets -BaseCidr $previewAllocation.BaseCidr -NewPrefix $PrefixLength) }
        )

        $usedCidrs += @(
            $cidrDryRunAllocations.Values |
                Where-Object { $_.PSObject.Properties.Name -contains "VnetCidr" } |
                Select-Object -ExpandProperty VnetCidr
        )

        $nextSubnet = Get-FirstFreeSubnetCidr `
            -BaseCidr $previewAllocation.BaseCidr `
            -PrefixLength $PrefixLength `
            -UsedCidrs $usedCidrs

        $cidrDryRunAllocations[$allocationKey] = [pscustomobject]@{
            BaseCidr = $previewAllocation.BaseCidr
            VnetCidr = $nextSubnet
        }

        return $nextSubnet
    }

    Invoke-CidrConcurrencyRetry -ScriptBlock {
        $existingAllocation = Get-CidrVnetAllocation `
            -SubscriptionId $SubscriptionId `
            -ResourceGroupName $ResourceGroupName `
            -VnetName $VnetName

        if ($existingAllocation) {
            return $existingAllocation.VnetCidr
        }

        $entry = Get-OrCreateSubscriptionAllocation -SubscriptionId $SubscriptionId

        $baseCidr = $entry.BaseCidr

        $allocationRows = Get-CidrVnetAllocationRows -SubscriptionId $SubscriptionId
        $subnets = Get-Subnets -BaseCidr $baseCidr -NewPrefix $PrefixLength

        $usedCidrs = @(
            $allocationRows | Select-Object -ExpandProperty VnetCidr
        )

        $usedCidrs += @(
            $ExistingVnetCidrs | Where-Object { $_ -in $subnets }
        )

        $nextSubnet = Get-FirstFreeSubnetCidr `
            -BaseCidr $baseCidr `
            -PrefixLength $PrefixLength `
            -UsedCidrs $usedCidrs

        $entry.NextIndex = ([array]::IndexOf($subnets, $nextSubnet) + 1)

        Invoke-InCidrStoreSubscription {

            Update-CidrTableRowWithEtag `
                -Table $cidrTable `
                -Row $entry

            Add-AzTableRow `
                -Table $cidrTable `
                -PartitionKey "CIDR_ALLOCATIONS" `
                -RowKey (Get-CidrVnetAllocationRowKey -SubscriptionId $SubscriptionId -ResourceGroupName $ResourceGroupName -VnetName $VnetName) `
                -property @{
                    SubscriptionId = $SubscriptionId
                    ResourceGroupName = $ResourceGroupName
                    VnetName = $VnetName
                    BaseCidr = $baseCidr
                    VnetCidr = $nextSubnet
                } `
                -ErrorAction Stop | Out-Null
        }

        return $nextSubnet
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

$existingVnetCidrs = @(
    Invoke-InSpokeSubscription {
        Get-AzVirtualNetwork | ForEach-Object {
            $_.AddressSpace.AddressPrefixes
        }
    }
)

# ----------------------------
# VNet creation loop
# ----------------------------
foreach ($rg in $rgs) {
    $vnetName = "$($rg.ResourceGroupName.ToLower())-vnet"
    $vnet = Invoke-InSpokeSubscription {
        Get-AzVirtualNetwork -ResourceGroupName $rg.ResourceGroupName -Name $vnetName -ErrorAction SilentlyContinue
    }

    if (-not $vnet) {
        $cidr = Get-NextSubnetCidr `
            -SubscriptionId $spokeSubId `
            -ResourceGroupName $rg.ResourceGroupName `
            -VnetName $vnetName `
            -PrefixLength $VnetPrefixLength `
            -Preview:$DryRun `
            -ExistingVnetCidrs $existingVnetCidrs

        Write-Output "[CREATE] $vnetName -> $cidr"

        if (-not $DryRun) {
            $nsgName = "$($rg.Location)-$($rg.ResourceGroupName)-nsg"
            $nsgCreated = $false

            try {
                $subnetCidr = (Get-Subnets -BaseCidr $cidr -NewPrefix $SubnetPrefixLength)[0]

                $rdpRule = New-AzNetworkSecurityRuleConfig `
                    -Name "Allow-RDP-Internet" `
                    -Description "Allow inbound RDP from the internet." `
                    -Access Allow `
                    -Protocol Tcp `
                    -Direction Inbound `
                    -Priority 1000 `
                    -SourceAddressPrefix Internet `
                    -SourcePortRange "*" `
                    -DestinationAddressPrefix "*" `
                    -DestinationPortRange 3389

                $nsg = Invoke-InSpokeSubscription {
                    New-AzNetworkSecurityGroup `
                        -Name $nsgName `
                        -ResourceGroupName $rg.ResourceGroupName `
                        -Location $rg.Location `
                        -SecurityRules $rdpRule `
                        -Tag $Tags
                }
                $nsgCreated = $true

                $subnet = New-AzVirtualNetworkSubnetConfig `
                    -Name "default" `
                    -AddressPrefix $subnetCidr `
                    -NetworkSecurityGroup $nsg

                $vnet = Invoke-InSpokeSubscription {
                    New-AzVirtualNetwork -Name $vnetName -ResourceGroupName $rg.ResourceGroupName -Location $rg.Location -AddressPrefix $cidr -Subnet $subnet -Tag $Tags
                }

                $existingVnetCidrs += $cidr
            }
            catch {
                Remove-CidrVnetAllocation `
                    -SubscriptionId $spokeSubId `
                    -ResourceGroupName $rg.ResourceGroupName `
                    -VnetName $vnetName

                if ($nsgCreated) {
                    try {
                        Invoke-InSpokeSubscription {
                            Remove-AzNetworkSecurityGroup `
                                -Name $nsgName `
                                -ResourceGroupName $rg.ResourceGroupName `
                                -Force `
                                -ErrorAction Stop | Out-Null
                        }
                    }
                    catch {
                        Write-Warning "Failed to remove network security group '$nsgName' after VNet creation failed: $_"
                    }
                }

                throw
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
            Write-Output "[PEER] $($vnet.Name) -> firewall"

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
