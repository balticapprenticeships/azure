<#
.version 3.1.18
.AUTHOR Chris Langford
.SYNOPSIS
    This script automates the creation of spoke virtual networks in each resource group of a subscription, assigns them CIDR blocks from a defined range, and peers them with a central firewall VNet. It also tags the VNets and applies a resource lock to prevent accidental deletion.
.DESCRIPTION
    The script connects to Azure using a Managed Identity, iterates through resource groups (with optional exclusion patterns), creates a VNet and network security group in each RG if the VNet doesn't exist, assigns CIDR blocks (with optional persistence in a storage table), tags the VNets, applies a "DoNotDelete" lock, and peers them with a central firewall VNet in another subscription.
.PARAMETER SubscriptionId
    The subscription ID where the spoke VNets will be created. If not provided, it will attempt to read from an Automation Variable named 'SubscriptionId'.
.PARAMETER WebhookData
    The data received from the Event Grid webhook.
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
    [object] $WebhookData,

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

    [Parameter(Mandatory=$false)]
    [ValidatePattern('^https://.*')]
    [string] $teamsWebhookUrl,

    [bool]$DryRun = $true
)

Import-Module Az.Storage -ErrorAction Stop
Import-Module AzTable -ErrorAction Stop

# ----------------------------
# Parse Event Grid webhook payload
# ----------------------------
if ($WebhookData) {
    try {
        $eventGridEvents = ConvertFrom-Json -InputObject $WebhookData.RequestBody
    }
    catch {
        throw "Failed to parse WebhookData.RequestBody as JSON: $_"
    }

    # Event Grid always delivers an array, even for a single event
    $rgEvent = $eventGridEvents | Select-Object -First 1

    if (-not $rgEvent) {
        throw "WebhookData.RequestBody did not contain any events."
    }

    Write-Output "Triggered by Event Grid event: $($rgEvent.eventType) / subject: $($rgEvent.subject)"

    # Defense in depth - confirm this really is a resource-group write success,
    # in case the Event Grid subscription filter is ever loosened or misconfigured.
    if ($rgEvent.data.operationName -ne "Microsoft.Resources/subscriptions/resourceGroups/write" `
        -or $rgEvent.data.status -ne "Succeeded") {
        Write-Output "Event is not a successful resource group write. Exiting without action."
        return
    }

    # Pull the subscription ID out of the event subject/topic if not explicitly supplied
    if (-not $SubscriptionId -and $rgEvent.topic -match '/subscriptions/([0-9a-fA-F-]{36})') {
        $SubscriptionId = $Matches[1]
    }
}

# ----------------------------
# Connect to Azure
# ----------------------------
try {
    Clear-AzContext -Scope Process -Force -ErrorAction SilentlyContinue

    # Resolve subscription first
    if (-not $subscriptionId) {
        if (Get-Command Get-AutomationVariable -ErrorAction SilentlyContinue) {
            $subscriptionId = Get-AutomationVariable -Name 'SubscriptionId'
        }
        else {
            throw "SubscriptionId was not supplied and Get-AutomationVariable is not available in this run context. Pass the SubscriptionId parameter, or run in an Azure Automation runtime that exposes automation asset cmdlets."
        }
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

# Teams webhook URL can be provided as a parameter or retrieved from an Automation Variable.
if (-not $teamsWebhookUrl) {
    try {
        $teamsWebhookUrl = Get-AutomationVariable -Name 'TeamsWebhookUrlSpokeCreateAndPeer'
    }
    catch {
        Write-Verbose "No Teams webhook URL provided or found."
    }
}

function Send-TeamsRunbookCard {
    param(
        [Parameter(Mandatory=$true)]
        [string]$teamsWebhookUrl,
        [Parameter(Mandatory=$true)]
        [object[]]$Results,
        [Parameter(Mandatory=$true)]
        [string]$SubscriptionName,
        [Parameter(Mandatory=$true)]
        [string]$SubscriptionId,
        [Parameter(Mandatory=$true)]
        [bool]$DryRun
    )

    if ([string]::IsNullOrWhiteSpace($teamsWebhookUrl)) {
        return
    }

    $created = @($Results | Where-Object { $_.VNetState -eq "Created" }).Count
    $existing = @($Results | Where-Object { $_.VNetState -eq "Exists" }).Count
    $dryRunCount = @($Results | Where-Object { $_.DryRun }).Count
    $lockIssues = @($Results | Where-Object { $_.LockState -in @("Skipped", "Failed") -or $_.NsgLockState -in @("Skipped", "Failed", "NotFound") }).Count
    $peeringIssues = @($Results | Where-Object { $_.PeeringState -in @("SkippedOverlap", "Failed") }).Count

    $resultContainers = @(
        $Results | Select-Object -First 15 | ForEach-Object {
            $subnetText = if ($_.SubnetCidr) { "$($_.SubnetName) $($_.SubnetCidr)" } else { "n/a" }
            @{
                type = "Container"
                separator = $true
                items = @(
                    @{
                        type = "TextBlock"
                        weight = "Bolder"
                        text = "$($_.ResourceGroup) / $($_.VNetName)"
                        wrap = $true
                    },
                    @{
                        type = "FactSet"
                        facts = @(
                            @{ title = "Location"; value = "$($_.Location)" },
                            @{ title = "VNet CIDR"; value = "$($_.VNetCidr)" },
                            @{ title = "Subnet"; value = $subnetText },
                            @{ title = "NSG"; value = "$($_.NsgName)" },
                            @{ title = "VNet"; value = "$($_.VNetState)" },
                            @{ title = "VNet Lock"; value = "$($_.LockState)" },
                            @{ title = "NSG Lock"; value = "$($_.NsgLockState)" },
                            @{ title = "Peering"; value = "$($_.PeeringState)" }
                        )
                    }
                )
            }
        }
    )

    if ($Results.Count -gt 15) {
        $resultContainers += @{
            type = "TextBlock"
            isSubtle = $true
            wrap = $true
            text = "Showing first 15 of $($Results.Count) resource groups. See runbook output for the full result set."
        }
    }

    $payload = @{
        type = "message"
        attachments = @(
            @{
                contentType = "application/vnd.microsoft.card.adaptive"
                contentUrl = $null
                content = @{
                    '$schema' = "http://adaptivecards.io/schemas/adaptive-card.json"
                    type = "AdaptiveCard"
                    version = "1.4"
                    body = @(
                        @{
                            type = "TextBlock"
                            size = "Large"
                            weight = "Bolder"
                            text = "Spoke VNet Runbook Complete"
                            wrap = $true
                        },
                        @{
                            type = "FactSet"
                            facts = @(
                                @{ title = "Subscription"; value = "$SubscriptionName ($SubscriptionId)" },
                                @{ title = "Dry run"; value = "$DryRun" },
                                @{ title = "Resource groups"; value = "$($Results.Count)" },
                                @{ title = "Created"; value = "$created" },
                                @{ title = "Existing"; value = "$existing" },
                                @{ title = "Dry-run items"; value = "$dryRunCount" },
                                @{ title = "Lock issues"; value = "$lockIssues" },
                                @{ title = "Peering issues"; value = "$peeringIssues" }
                            )
                        }
                    ) + $resultContainers
                }
            }
        )
    }

    try {
        Invoke-RestMethod `
            -Method Post `
            -Uri $teamsWebhookUrl `
            -ContentType "application/json" `
            -Body ($payload | ConvertTo-Json -Depth 30) | Out-Null
    }
    catch {
        Write-Warning "Failed to send Teams Adaptive Card: $_"
    }
}

# ----------------------------
# Subscription Helpers
# ----------------------------
function Invoke-InSubscription {
    param(
        [Parameter(Mandatory=$true)]
        [string]$TargetSubscriptionId,
        [Parameter(Mandatory=$true)]
        [scriptblock]$ScriptBlock
    )

    $previousSubscriptionId = (Get-AzContext).Subscription.Id
    try {
        if ($previousSubscriptionId -ne $TargetSubscriptionId) {
            Select-AzSubscription -SubscriptionId $TargetSubscriptionId -ErrorAction Stop | Out-Null
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
    Invoke-InSubscription -TargetSubscriptionId $spokeSubId -ScriptBlock $ScriptBlock
}

function Invoke-InCidrStoreSubscription {
    param([Parameter(Mandatory=$true)][scriptblock]$ScriptBlock)
    Invoke-InSubscription -TargetSubscriptionId $CidrStoreSubscriptionId -ScriptBlock $ScriptBlock
}

function Invoke-InFirewallSubscription {
    param([Parameter(Mandatory=$true)][scriptblock]$ScriptBlock)
    Invoke-InSubscription -TargetSubscriptionId $FirewallSubscriptionId -ScriptBlock $ScriptBlock
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

function Invoke-CidrTableOperation {
    param(
        [Parameter(Mandatory=$true)]
        [string]$OperationName,
        [Parameter(Mandatory=$true)]
        [scriptblock]$ScriptBlock
    )

    try {
        & $ScriptBlock
    }
    catch {
        $statusCode = $null
        $exception = $_.Exception
        while ($exception) {
            if ($exception.RequestInformation -and $exception.RequestInformation.HttpStatusCode) {
                $statusCode = $exception.RequestInformation.HttpStatusCode
                break
            }
            $exception = $exception.InnerException
        }

        throw "CIDR table operation '$OperationName' failed. HTTP status: $statusCode. Original error: $($_.Exception.Message)"
    }
}

function Convert-CidrTableEntityToObject {
    param(
        [Parameter(Mandatory=$true)]
        [Microsoft.Azure.Cosmos.Table.DynamicTableEntity]$Entity
    )

    $row = [ordered]@{
        PartitionKey = $Entity.PartitionKey
        RowKey = $Entity.RowKey
        Timestamp = $Entity.Timestamp
        Etag = $Entity.ETag
        TableTimestamp = $Entity.Timestamp
    }

    foreach ($propertyName in $Entity.Properties.Keys) {
        $row[$propertyName] = $Entity.Properties[$propertyName].PropertyAsObject
    }

    [pscustomobject]$row
}

function Get-CidrTableRows {
    param(
        [Parameter(Mandatory=$true)]
        [string]$PartitionKey,
        [string]$RowKey
    )

    Invoke-CidrTableOperation -OperationName "Read row(s) $PartitionKey/$RowKey" -ScriptBlock {
        $query = [Microsoft.Azure.Cosmos.Table.TableQuery[Microsoft.Azure.Cosmos.Table.DynamicTableEntity]]::new()
        $partitionFilter = [Microsoft.Azure.Cosmos.Table.TableQuery]::GenerateFilterCondition(
            "PartitionKey",
            [Microsoft.Azure.Cosmos.Table.QueryComparisons]::Equal,
            $PartitionKey
        )

        if ([string]::IsNullOrWhiteSpace($RowKey)) {
            $query.FilterString = $partitionFilter
        }
        else {
            $rowFilter = [Microsoft.Azure.Cosmos.Table.TableQuery]::GenerateFilterCondition(
                "RowKey",
                [Microsoft.Azure.Cosmos.Table.QueryComparisons]::Equal,
                $RowKey
            )
            $query.FilterString = [Microsoft.Azure.Cosmos.Table.TableQuery]::CombineFilters(
                $partitionFilter,
                [Microsoft.Azure.Cosmos.Table.TableOperators]::And,
                $rowFilter
            )
        }

        $token = [Microsoft.Azure.Cosmos.Table.TableContinuationToken]$null
        do {
            $segment = $cidrTable.ExecuteQuerySegmented($query, $token, $null, $null)
            $token = $segment.ContinuationToken
            $segment.Results |
                ForEach-Object { Convert-CidrTableEntityToObject -Entity $_ }
        } while ($token)
    }
}

function Remove-CidrTableRow {
    param(
        [Parameter(Mandatory=$true)]
        [string]$PartitionKey,
        [Parameter(Mandatory=$true)]
        [string]$RowKey
    )

    Invoke-CidrTableOperation -OperationName "Remove row $PartitionKey/$RowKey" -ScriptBlock {
        $query = [Microsoft.Azure.Cosmos.Table.TableQuery[Microsoft.Azure.Cosmos.Table.DynamicTableEntity]]::new()
        $partitionFilter = [Microsoft.Azure.Cosmos.Table.TableQuery]::GenerateFilterCondition(
            "PartitionKey",
            [Microsoft.Azure.Cosmos.Table.QueryComparisons]::Equal,
            $PartitionKey
        )
        $rowFilter = [Microsoft.Azure.Cosmos.Table.TableQuery]::GenerateFilterCondition(
            "RowKey",
            [Microsoft.Azure.Cosmos.Table.QueryComparisons]::Equal,
            $RowKey
        )
        $query.FilterString = [Microsoft.Azure.Cosmos.Table.TableQuery]::CombineFilters(
            $partitionFilter,
            [Microsoft.Azure.Cosmos.Table.TableOperators]::And,
            $rowFilter
        )

        $segment = $cidrTable.ExecuteQuerySegmented(
            $query,
            [Microsoft.Azure.Cosmos.Table.TableContinuationToken]$null,
            $null,
            $null
        )
        $entity = $segment.Results | Select-Object -First 1
        if ($entity) {
            $cidrTable.Execute([Microsoft.Azure.Cosmos.Table.TableOperation]::Delete($entity)) | Out-Null
        }
    }
}

function Get-CidrAllocationRows {
    Get-CidrTableRows -PartitionKey "CIDR"
}

function Get-CidrVnetAllocationRows {
    param([string]$SubscriptionId)

    $allocationPrefix = "$SubscriptionId|"

    Get-CidrTableRows -PartitionKey "CIDR_ALLOCATIONS" |
        Where-Object RowKey -like "$allocationPrefix*"
}

function Get-CidrAllocatorState {
    Get-CidrTableRows -PartitionKey "CIDR_STATE" -RowKey "GLOBAL" |
        Select-Object -First 1
}

function Get-CidrSubscriptionAllocation {
    param([string]$SubscriptionId)

    Get-CidrTableRows -PartitionKey "CIDR" -RowKey $SubscriptionId |
        Select-Object -First 1
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

    Get-CidrTableRows -PartitionKey "CIDR_ALLOCATIONS" -RowKey $rowKey |
        Select-Object -First 1
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
            Remove-CidrTableRow `
                -PartitionKey "CIDR_ALLOCATIONS" `
                -RowKey $allocation.RowKey
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
        $Row,
        [Parameter(Mandatory=$true)]
        [string]$PartitionKey,
        [Parameter(Mandatory=$true)]
        [string]$RowKey
    )

    if ([string]::IsNullOrWhiteSpace($PartitionKey) -or [string]::IsNullOrWhiteSpace($RowKey)) {
        throw "Cannot update CIDR table row because PartitionKey or RowKey is empty."
    }

    $updatedEntity = New-Object `
        -TypeName "Microsoft.Azure.Cosmos.Table.DynamicTableEntity" `
        -ArgumentList $PartitionKey, $RowKey

    foreach ($prop in $Row.psobject.Properties) {
        if ($prop.Name -notin @("PartitionKey", "RowKey", "Timestamp", "Etag", "TableTimestamp")) {
            if ($prop.Value -is [Microsoft.Azure.Cosmos.Table.EntityProperty]) {
                $updatedEntity.Properties.Add($prop.Name, $prop.Value)
            }
            elseif ($null -ne $prop.Value) {
                $updatedEntity.Properties.Add(
                    $prop.Name,
                    (New-Object -TypeName "Microsoft.Azure.Cosmos.Table.EntityProperty" -ArgumentList $prop.Value)
                )
            }
        }
    }

    if ($Row.psobject.Properties.Name -contains "Etag" -and $Row.Etag) {
        $updatedEntity.ETag = $Row.Etag
    }

    if ($Row.psobject.Properties.Name -contains "TableTimestamp" -and $Row.TableTimestamp) {
        $updatedEntity.Timestamp = $Row.TableTimestamp
    }

    try {
        $Table.Execute([Microsoft.Azure.Cosmos.Table.TableOperation]::InsertOrReplace($updatedEntity)) | Out-Null
    }
    catch {
        $statusCode = $null
        $exception = $_.Exception
        while ($exception) {
            if ($exception.RequestInformation -and $exception.RequestInformation.HttpStatusCode) {
                $statusCode = $exception.RequestInformation.HttpStatusCode
                break
            }
            $exception = $exception.InnerException
        }

        $tableName = if ($Table.Name) { $Table.Name } else { $CidrStoreTableName }
        throw "Failed to update CIDR table row '$PartitionKey/$RowKey' in table '$tableName'. HTTP status: $statusCode. Original error: $($_.Exception.Message)"
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

function Convert-IPv4ToUInt32 {
    param([Parameter(Mandatory=$true)][string]$IPAddress)

    $bytes = [System.Net.IPAddress]::Parse($IPAddress).GetAddressBytes()
    [Array]::Reverse($bytes)
    [BitConverter]::ToUInt32($bytes, 0)
}

function Test-CidrOverlap {
    param(
        [Parameter(Mandatory=$true)]
        [string]$CidrA,
        [Parameter(Mandatory=$true)]
        [string]$CidrB
    )

    $aParts = $CidrA -split "/"
    $bParts = $CidrB -split "/"

    $aStart = Convert-IPv4ToUInt32 -IPAddress $aParts[0]
    $bStart = Convert-IPv4ToUInt32 -IPAddress $bParts[0]

    $aSize = [uint64]1 -shl (32 - [int]$aParts[1])
    $bSize = [uint64]1 -shl (32 - [int]$bParts[1])

    $aEnd = [uint64]$aStart + $aSize - 1
    $bEnd = [uint64]$bStart + $bSize - 1

    return ([uint64]$aStart -le $bEnd -and [uint64]$bStart -le $aEnd)
}

function Test-VnetAddressSpaceOverlap {
    param(
        [Parameter(Mandatory=$true)]
        $VnetA,
        [Parameter(Mandatory=$true)]
        $VnetB
    )

    foreach ($prefixA in $VnetA.AddressSpace.AddressPrefixes) {
        foreach ($prefixB in $VnetB.AddressSpace.AddressPrefixes) {
            if (Test-CidrOverlap -CidrA $prefixA -CidrB $prefixB) {
                return $true
            }
        }
    }

    return $false
}

# ----------------------------
# CIDR persistence
# ----------------------------
$cidrStoreEnabled = ($CidrStoreAccountName -and $CidrStoreTableName)
if ($cidrStoreEnabled) {
    $cidrTable = Invoke-InCidrStoreSubscription {
        $rgForStorage = Get-AzStorageAccount -ResourceGroupName $StorageAccountResourceGroup -Name $CidrStoreAccountName
        if (-not $rgForStorage) {
            throw "CIDR storage account '$CidrStoreAccountName' was not found in subscription '$CidrStoreSubscriptionId'."
        }

        $tableEndpoint = $rgForStorage.PrimaryEndpoints.Table
        if ([string]::IsNullOrWhiteSpace($tableEndpoint)) {
            throw "CIDR storage account '$CidrStoreAccountName' does not expose a Table service endpoint. Account kind: '$($rgForStorage.Kind)'. SKU: '$($rgForStorage.Sku.Name)'. Use a general-purpose storage account that supports Azure Table Storage."
        }

        if ($rgForStorage.EnableHierarchicalNamespace) {
            throw "CIDR storage account '$CidrStoreAccountName' has hierarchical namespace enabled. Azure Table Storage is not supported on ADLS Gen2 hierarchical namespace accounts. Use a separate general-purpose StorageV2 account without hierarchical namespace enabled for CIDR table storage."
        }

        $storageKey = (
            Get-AzStorageAccountKey `
                -ResourceGroupName $StorageAccountResourceGroup `
                -Name $CidrStoreAccountName `
                -ErrorAction Stop `
                -WarningAction SilentlyContinue
        )[0].Value

        $credentials = New-Object `
            -TypeName "Microsoft.Azure.Cosmos.Table.StorageCredentials" `
            -ArgumentList $CidrStoreAccountName, $storageKey

        $tableClient = New-Object `
            -TypeName "Microsoft.Azure.Cosmos.Table.CloudTableClient" `
            -ArgumentList ([Uri]$tableEndpoint), $credentials

        $cloudTable = $tableClient.GetTableReference($CidrStoreTableName)

        try {
            $cloudTable.CreateIfNotExists() | Out-Null
        }
        catch {
            throw "CIDR storage table '$CidrStoreTableName' could not be created or verified at '$($cloudTable.Uri)'. ARM table endpoint: '$tableEndpoint'. Account kind: '$($rgForStorage.Kind)'. SKU: '$($rgForStorage.Sku.Name)'. Original error: $($_.Exception.Message)"
        }

        $cloudTable
    }

    if (-not $cidrTable) {
        throw "CIDR table initialization returned null for table '$CidrStoreTableName' in storage account '$CidrStoreAccountName'."
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

            $state = [pscustomobject]@{
                NextBaseOctet = $nextBaseOctet
            }

            Invoke-InCidrStoreSubscription {
                Update-CidrTableRowWithEtag `
                    -Table $cidrTable `
                    -Row $state `
                    -PartitionKey "CIDR_STATE" `
                    -RowKey "GLOBAL"
            }
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
                -Row $state `
                -PartitionKey "CIDR_STATE" `
                -RowKey "GLOBAL"

            Update-CidrTableRowWithEtag `
                -Table $cidrTable `
                -Row ([pscustomobject]@{
                    BaseCidr = $nextCidr
                    NextIndex = 0
                }) `
                -PartitionKey "CIDR" `
                -RowKey $SubscriptionId
        }

        [pscustomobject]@{
            BaseCidr = $nextCidr
            NextIndex = 0
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
                -Row $entry `
                -PartitionKey "CIDR" `
                -RowKey $SubscriptionId

            Update-CidrTableRowWithEtag `
                -Table $cidrTable `
                -Row ([pscustomobject]@{
                    SubscriptionId = $SubscriptionId
                    ResourceGroupName = $ResourceGroupName
                    VnetName = $VnetName
                    BaseCidr = $baseCidr
                    VnetCidr = $nextSubnet
                }) `
                -PartitionKey "CIDR_ALLOCATIONS" `
                -RowKey (Get-CidrVnetAllocationRowKey -SubscriptionId $SubscriptionId -ResourceGroupName $ResourceGroupName -VnetName $VnetName)
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
$runResults = @()

foreach ($rg in $rgs) {
    $vnetName = "$($rg.ResourceGroupName.ToLower())-vnet"
    $cidr = $null
    $subnetName = "default"
    $subnetCidr = $null
    $nsgName = "$($rg.ResourceGroupName)-nsg"
    $vnetState = "Unknown"
    $lockState = if ($DryRun) { "DryRun" } else { "NotChecked" }
    $nsgLockState = if ($DryRun) { "DryRun" } else { "NotChecked" }
    $peeringState = if ($DryRun) { "DryRun" } else { "Exists" }

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

        $subnetCidr = (Get-Subnets -BaseCidr $cidr -NewPrefix $SubnetPrefixLength)[0]
        $vnetState = if ($DryRun) { "WouldCreate" } else { "Created" }

        Write-Output "[CREATE] $vnetName -> $cidr"

        if (-not $DryRun) {
            $nsgCreated = $false

            try {
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
        $cidr = @($vnet.AddressSpace.AddressPrefixes) -join ", "
        $defaultSubnet = @($vnet.Subnets | Where-Object { $_.Name -eq $subnetName } | Select-Object -First 1)
        if (-not $defaultSubnet) {
            $defaultSubnet = @($vnet.Subnets | Select-Object -First 1)
        }
        if ($defaultSubnet) {
            $subnetName = $defaultSubnet[0].Name
            $subnetCidr = @($defaultSubnet[0].AddressPrefix) -join ", "
            if ($defaultSubnet[0].NetworkSecurityGroup -and $defaultSubnet[0].NetworkSecurityGroup.Id) {
                $nsgName = ($defaultSubnet[0].NetworkSecurityGroup.Id -split "/")[-1]
            }
        }
        $vnetState = "Exists"
        Write-Output "[EXISTS] $vnetName"
    }

    # Tag merge
    if (-not $DryRun -and $vnet) {
        $merged = @{}
        if ($vnet.Tag) { $merged = $vnet.Tag.Clone() }
        elseif ($vnet.Tags) { $merged = $vnet.Tags.Clone() }
        foreach ($k in $Tags.Keys) { $merged[$k] = $Tags[$k] }
        Invoke-InSpokeSubscription {
            Update-AzTag -ResourceId $vnet.Id -Tag $merged -Operation Merge -ErrorAction Stop | Out-Null
        }
    }

    # Resource lock
    if (-not $DryRun -and $vnet) {
        $lock = Invoke-InSpokeSubscription {
            Get-AzResourceLock -ResourceName $vnet.Name -ResourceGroupName $rg.ResourceGroupName -ResourceType "Microsoft.Network/virtualNetworks" -ErrorAction SilentlyContinue
        }
        if (-not $lock) {
            try {
                Invoke-InSpokeSubscription {
                    New-AzResourceLock -LockName "DoNotDelete-VNET" -LockLevel CanNotDelete -ResourceName $vnet.Name -ResourceGroupName $rg.ResourceGroupName -ResourceType "Microsoft.Network/virtualNetworks" -Force -ErrorAction Stop | Out-Null
                }
                $lockState = "Created"
            }
            catch {
                if ($_.Exception.Message -match 'AuthorizationFailed|Microsoft.Authorization/locks/write') {
                    Write-Warning "Skipping resource lock for '$($vnet.Name)' because the managed identity does not have Microsoft.Authorization/locks/write at the VNet scope."
                    $lockState = "Skipped"
                }
                else {
                    $lockState = "Failed"
                    throw
                }
            }
        }
        else {
            $lockState = "Exists"
        }
    }

    # NSG resource lock
    if (-not $DryRun -and $nsgName) {
        $nsgForLock = Invoke-InSpokeSubscription {
            Get-AzNetworkSecurityGroup -Name $nsgName -ResourceGroupName $rg.ResourceGroupName -ErrorAction SilentlyContinue
        }

        if ($nsgForLock) {
            $nsgLock = Invoke-InSpokeSubscription {
                Get-AzResourceLock -ResourceName $nsgForLock.Name -ResourceGroupName $rg.ResourceGroupName -ResourceType "Microsoft.Network/networkSecurityGroups" -ErrorAction SilentlyContinue
            }

            if (-not $nsgLock) {
                try {
                    Invoke-InSpokeSubscription {
                        New-AzResourceLock -LockName "DoNotDelete-NSG" -LockLevel CanNotDelete -ResourceName $nsgForLock.Name -ResourceGroupName $rg.ResourceGroupName -ResourceType "Microsoft.Network/networkSecurityGroups" -Force -ErrorAction Stop | Out-Null
                    }
                    $nsgLockState = "Created"
                }
                catch {
                    if ($_.Exception.Message -match 'AuthorizationFailed|Microsoft.Authorization/locks/write') {
                        Write-Warning "Skipping resource lock for '$($nsgForLock.Name)' because the managed identity does not have Microsoft.Authorization/locks/write at the NSG scope."
                        $nsgLockState = "Skipped"
                    }
                    else {
                        $nsgLockState = "Failed"
                        throw
                    }
                }
            }
            else {
                $nsgLockState = "Exists"
            }
        }
        else {
            $nsgLockState = "NotFound"
            Write-Warning "Skipping NSG resource lock for '$nsgName' because the network security group was not found in resource group '$($rg.ResourceGroupName)'."
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

        $fwPeer = Invoke-InFirewallSubscription {
            Get-AzVirtualNetworkPeering -VirtualNetworkName $fwVnet.Name -ResourceGroupName $FirewallVnetResourceGroup -Name "fw-to-$($vnet.Name)" -ErrorAction SilentlyContinue
        }

        if (-not $peer -or -not $fwPeer) {
            Write-Output "[PEER] $($vnet.Name) -> firewall"
            $peeringState = if ($DryRun) { "DryRun" } else { "Pending" }

            if (-not $DryRun) {
                if (Test-VnetAddressSpaceOverlap -VnetA $vnet -VnetB $fwVnet) {
                    Write-Warning "Skipping peering for '$($vnet.Name)' because its address space overlaps with firewall VNet '$($fwVnet.Name)'."
                    $peeringState = "SkippedOverlap"
                }
                else {
                    try {
                        if (-not $peer) {
                            Invoke-InSpokeSubscription {
                                Add-AzVirtualNetworkPeering -Name "$($vnet.Name)-to-fw" -VirtualNetwork $vnet -RemoteVirtualNetworkId $fwVnet.Id -AllowForwardedTraffic -ErrorAction Stop | Out-Null
                            }
                        }

                        if (-not $fwPeer) {
                            Invoke-InFirewallSubscription {
                                Add-AzVirtualNetworkPeering -Name "fw-to-$($vnet.Name)" -VirtualNetwork $fwVnet -RemoteVirtualNetworkId $vnet.Id -AllowForwardedTraffic -ErrorAction Stop | Out-Null
                            }
                        }
                        $peeringState = "Created"
                    }
                    catch {
                        Write-Warning "Failed to peer '$($vnet.Name)' with firewall VNet '$($fwVnet.Name)': $_"
                        $peeringState = "Failed"
                    }
                }
            }
        }
    }

    $runResults += [pscustomobject]@{
        ResourceGroup = $rg.ResourceGroupName
        Location = $rg.Location
        VNetName = $vnetName
        VNetCidr = $cidr
        SubnetName = $subnetName
        SubnetCidr = $subnetCidr
        NsgName = $nsgName
        VNetState = $vnetState
        LockState = $lockState
        NsgLockState = $nsgLockState
        PeeringState = $peeringState
        DryRun = $DryRun
    }
}

if ($teamsWebhookUrl) {
    Send-TeamsRunbookCard `
        -teamsWebhookUrl $teamsWebhookUrl `
        #-WebhookUrl $teamsWebhookUrl `
        -Results $runResults `
        -SubscriptionName $context.Subscription.Name `
        -SubscriptionId $spokeSubId `
        -DryRun $DryRun
}

Write-Output "Runbook complete."
