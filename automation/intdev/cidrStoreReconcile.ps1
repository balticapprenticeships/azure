<#
.version 1.1.0
.AUTHOR Chris Langford
.SYNOPSIS
    Reconciles the CIDR store table against Azure by removing allocation entries whose resource groups no longer exist.
.DESCRIPTION
    This runbook is the housekeeping counterpart to spokeVnetCreateAndPeer.ps1. It reads every
    per-VNet allocation row from the CIDR store table (PartitionKey "CIDR_ALLOCATIONS"), resolves the
    subscription and resource group each row refers to, and checks whether that resource group still
    exists in Azure. Rows pointing at resource groups that have been deleted are removed from the
    table so their CIDR blocks return to the free pool.

    Safety behaviour:
      - A subscription the managed identity cannot reach is reported as "Inaccessible" and none of
        its rows are touched. An access problem must never be mistaken for a deleted resource group.
      - Rows whose RowKey cannot be parsed into subscription/resource group/VNet are reported and
        left in place for manual review.
      - The per-subscription base CIDR row (PartitionKey "CIDR") is only reclaimed when
        -RemoveEmptySubscriptionAllocations is set, the subscription is reachable, and no allocation
        rows remain for it.
      - DryRun defaults to $true so the first run is always a report.

    A Microsoft Teams Adaptive Card summarising the reconciliation is sent when a webhook URL is
    available.
.PARAMETER SubscriptionId
    Optional filter. When supplied, only allocation rows belonging to these subscription IDs are
    reconciled. When omitted, every subscription referenced in the table is reconciled.
.PARAMETER StorageAccountResourceGroup
    The resource group where the CIDR storage account is located. Default is "NetworkAutomationRg".
.PARAMETER CidrStoreAccountName
    The name of the storage account holding the CIDR table. Default is "cidrstoresa".
.PARAMETER CidrStoreSubscriptionId
    The subscription ID where the CIDR storage account is located.
.PARAMETER CidrStoreTableName
    The name of the CIDR table. Default is "CidrAllocation".
.PARAMETER RemoveEmptySubscriptionAllocations
    When $true, a subscription's base /16 reservation (PartitionKey "CIDR") is removed once the
    subscription is reachable and has no remaining allocation rows. Default is $false.
.PARAMETER teamsWebhookUrl
    The Microsoft Teams webhook URL for the summary card. Falls back to the Automation Variable
    'TeamsWebhookUrlCidrStoreReconcile'.
.PARAMETER DryRun
    When $true (the default) nothing is deleted; the runbook only reports what it would remove.
.NOTES
    - Requires the Az and AzTable modules.
    - The managed identity needs Reader on every subscription referenced in the table, and
      Storage Account Key Operator (or Contributor) on the CIDR storage account.
.RuntimeEnvironment PowerShell-7.4
#>
param(
    [Parameter(Mandatory=$false)]
    [string[]] $SubscriptionId,

    [string] $StorageAccountResourceGroup = "NetworkAutomationRg",
    [string] $CidrStoreAccountName = "cidrstoresa",

    [Parameter(Mandatory=$false)]
    [ValidatePattern('^[0-9a-fA-F-]{36}$')]
    [string] $CidrStoreSubscriptionId = "c4790cb5-6d79-4f3b-914e-3307eb65c9d3",

    [string] $CidrStoreTableName = "CidrAllocation",

    [Parameter(Mandatory=$false)]
    $RemoveEmptySubscriptionAllocations = $false,

    [Parameter(Mandatory=$false)]
    [ValidatePattern('^https://.*')]
    [string] $teamsWebhookUrl,

    [Parameter(Mandatory=$false)]
    $DryRun = $true
)

Import-Module Az.Storage -ErrorAction Stop
Import-Module AzTable -ErrorAction Stop

$ErrorActionPreference = 'Stop'

# ----------------------------
# Coerce switch-like parameters to real booleans
# ----------------------------
# Azure Automation does not parse parameters out of a webhook's JSON body, and the portal's
# "Start runbook" blade hands every value over as a string. A strict [bool] parameter type rejects
# "true"/"false", so these are left untyped above and normalized here instead.
function ConvertTo-RunbookBoolean {
    param($Value)

    if ($Value -is [string]) {
        if ([string]::IsNullOrWhiteSpace($Value)) { return $false }
        return [System.Convert]::ToBoolean($Value.Trim())
    }

    return [bool]$Value
}

$DryRun = ConvertTo-RunbookBoolean -Value $DryRun
$RemoveEmptySubscriptionAllocations = ConvertTo-RunbookBoolean -Value $RemoveEmptySubscriptionAllocations

# ----------------------------
# Connect to Azure
# ----------------------------
try {
    Clear-AzContext -Scope Process -Force -ErrorAction SilentlyContinue

    Connect-AzAccount -Identity -Subscription $CidrStoreSubscriptionId | Out-Null

    $context = Get-AzContext

    if ($context.Subscription.Id -ne $CidrStoreSubscriptionId) {
        throw "Context mismatch after login. Expected '$CidrStoreSubscriptionId' but got '$($context.Subscription.Id)'."
    }

    Write-Output "CIDR store subscription: $($context.Subscription.Name) ($CidrStoreSubscriptionId)"
}
catch {
    Write-Error "Authentication or subscription selection failed: $_"
    throw
}

if (-not $teamsWebhookUrl) {
    try {
        $teamsWebhookUrl = Get-AutomationVariable -Name 'TeamsWebhookUrlCidrStoreReconcile'
    }
    catch {
        Write-Verbose "No Teams webhook URL provided or found."
    }
}

# ----------------------------
# Subscription helpers
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

function Invoke-InCidrStoreSubscription {
    param([Parameter(Mandatory=$true)][scriptblock]$ScriptBlock)
    Invoke-InSubscription -TargetSubscriptionId $CidrStoreSubscriptionId -ScriptBlock $ScriptBlock
}

# ----------------------------
# Table helpers
# ----------------------------
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

function Get-CidrAllocationEntryDetail {
    param(
        [Parameter(Mandatory=$true)]
        $Row
    )

    # Prefer the explicit columns written by spokeVnetCreateAndPeer.ps1 and only fall back to
    # splitting the composite RowKey ("<subscriptionId>|<resourceGroup>|<vnetName>") for rows
    # written by older versions of that runbook.
    $subId = $Row.SubscriptionId
    $rgName = $Row.ResourceGroupName
    $vnetName = $Row.VnetName

    if (-not $subId -or -not $rgName) {
        $parts = $Row.RowKey -split '\|'
        if ($parts.Count -ge 3) {
            if (-not $subId) { $subId = $parts[0] }
            if (-not $rgName) { $rgName = $parts[1] }
            if (-not $vnetName) { $vnetName = $parts[2] }
        }
    }

    [pscustomobject]@{
        SubscriptionId = $subId
        ResourceGroupName = $rgName
        VnetName = $vnetName
        VnetCidr = $Row.VnetCidr
        BaseCidr = $Row.BaseCidr
        RowKey = $Row.RowKey
    }
}

# ----------------------------
# Teams card
# ----------------------------
function New-CollapsibleSection {
    <#
        Builds a collapsible Adaptive Card section: a clickable header row plus a body container that
        starts hidden. Clicking the header fires Action.ToggleVisibility against three element ids at
        once - the body and the two "Show"/"Hide" labels - so the label always reflects the state.

        Returns the two elements as an array. Call it wrapped in @(...) so an empty section (no items)
        appends nothing rather than a stray $null.
    #>
    param(
        [Parameter(Mandatory=$true)]
        [string]$Id,
        [Parameter(Mandatory=$true)]
        [string]$Title,
        [Parameter(Mandatory=$false)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]]$Items,
        [bool]$Expanded = $false
    )

    if (-not $Items -or $Items.Count -eq 0) {
        return @()
    }

    $bodyId = "$Id-body"
    $showId = "$Id-show"
    $hideId = "$Id-hide"

    $toggle = @{
        type = "Action.ToggleVisibility"
        targetElements = @($bodyId, $showId, $hideId)
    }

    $header = @{
        type = "Container"
        separator = $true
        selectAction = $toggle
        items = @(
            @{
                type = "ColumnSet"
                columns = @(
                    @{
                        type = "Column"
                        width = "stretch"
                        items = @(
                            @{
                                type = "TextBlock"
                                text = $Title
                                weight = "Bolder"
                                wrap = $true
                            }
                        )
                    },
                    @{
                        type = "Column"
                        width = "auto"
                        items = @(
                            @{
                                type = "TextBlock"
                                id = $showId
                                text = "Show"
                                color = "Accent"
                                isVisible = (-not $Expanded)
                            },
                            @{
                                type = "TextBlock"
                                id = $hideId
                                text = "Hide"
                                color = "Accent"
                                isVisible = $Expanded
                            }
                        )
                    }
                )
            }
        )
    }

    $body = @{
        type = "Container"
        id = $bodyId
        isVisible = $Expanded
        items = $Items
    }

    return @($header, $body)
}

function Limit-CardText {
    # A single very long detail string - a stack-flavoured storage exception, say - can breach the
    # card size limit on its own, which no row cap would rescue. Truncate at the source.
    param(
        [AllowNull()]
        [string]$Text,
        [int]$MaxLength = 300
    )

    if ([string]::IsNullOrEmpty($Text)) { return "" }
    if ($Text.Length -le $MaxLength) { return $Text }

    return $Text.Substring(0, $MaxLength - 3) + "..."
}

function ConvertTo-CidrRowCardItem {
    param(
        [Parameter(Mandatory=$false)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]]$Rows,
        [int]$Limit = 25
    )

    if (-not $Rows -or $Rows.Count -eq 0) {
        return @()
    }

    # Teams rejects cards over ~28 KB, so cap each section rather than letting a large sweep
    # silently produce a card that never renders.
    $items = @(
        $Rows | Select-Object -First $Limit | ForEach-Object {
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
                            @{ title = "Subscription"; value = "$($_.SubscriptionName)" },
                            @{ title = "VNet CIDR"; value = "$($_.VnetCidr)" },
                            @{ title = "Partition"; value = "$($_.PartitionKey)" },
                            @{ title = "Action"; value = "$($_.Action)" },
                            @{ title = "Detail"; value = (Limit-CardText -Text "$($_.Detail)") }
                        )
                    }
                )
            }
        }
    )

    if ($Rows.Count -gt $Limit) {
        $items += @{
            type = "TextBlock"
            isSubtle = $true
            wrap = $true
            text = "Showing first $Limit of $($Rows.Count). See the runbook output for the full set."
        }
    }

    return $items
}

function Send-TeamsRunbookCard {
    param(
        [Parameter(Mandatory=$true)]
        [string]$teamsWebhookUrl,
        [Parameter(Mandatory=$true)]
        [AllowEmptyCollection()]
        [object[]]$Results,
        [Parameter(Mandatory=$true)]
        [bool]$DryRun,
        [Parameter(Mandatory=$true)]
        [int]$RowsScanned,
        [Parameter(Mandatory=$true)]
        [AllowEmptyCollection()]
        [object[]]$SubscriptionSummary
    )

    if ([string]::IsNullOrWhiteSpace($teamsWebhookUrl)) {
        return
    }

    $removed = @($Results | Where-Object { $_.Action -eq "Removed" }).Count
    $wouldRemove = @($Results | Where-Object { $_.Action -eq "WouldRemove" }).Count
    $retained = @($Results | Where-Object { $_.Action -eq "Retained" }).Count
    $skipped = @($Results | Where-Object { $_.Action -in @("SkippedInaccessible", "SkippedUnparsable") }).Count
    $failed = @($Results | Where-Object { $_.Action -eq "Failed" }).Count

    # A healthy sweep is all "Retained", so the detail is grouped by outcome and collapsed by
    # default - except failures, which are expanded so they cannot be missed.
    $orphanRows = @($Results | Where-Object { $_.Action -in @("Removed", "WouldRemove") })
    $skippedRows = @($Results | Where-Object { $_.Action -in @("SkippedInaccessible", "SkippedUnparsable") })
    $failedRows = @($Results | Where-Object { $_.Action -eq "Failed" })

    $orphanTitle = if ($DryRun) { "Orphaned rows to remove" } else { "Rows removed" }

    $buildPayload = {
        param([int]$Limit)

        $resultContainers = @()

        $resultContainers += @(
            New-CollapsibleSection `
                -Id "failed" `
                -Title "Failures ($($failedRows.Count))" `
                -Items @(ConvertTo-CidrRowCardItem -Rows $failedRows -Limit $Limit) `
                -Expanded $true
        )

        $resultContainers += @(
            New-CollapsibleSection `
                -Id "orphans" `
                -Title "$orphanTitle ($($orphanRows.Count))" `
                -Items @(ConvertTo-CidrRowCardItem -Rows $orphanRows -Limit $Limit)
        )

        $resultContainers += @(
            New-CollapsibleSection `
                -Id "skipped" `
                -Title "Skipped ($($skippedRows.Count))" `
                -Items @(ConvertTo-CidrRowCardItem -Rows $skippedRows -Limit $Limit)
        )

        $subscriptionItems = @()
        if ($SubscriptionSummary.Count -gt 0) {
            $subscriptionFacts = @(
                $SubscriptionSummary | Select-Object -First $Limit | ForEach-Object {
                    @{ title = "$($_.SubscriptionName)"; value = "$($_.Status) - $($_.RowCount) row(s)" }
                }
            )

            $subscriptionItems = @(@{ type = "FactSet"; facts = $subscriptionFacts })

            if ($SubscriptionSummary.Count -gt $Limit) {
                $subscriptionItems += @{
                    type = "TextBlock"
                    isSubtle = $true
                    wrap = $true
                    text = "Showing first $Limit of $($SubscriptionSummary.Count) subscriptions."
                }
            }
        }

        $resultContainers += @(
            New-CollapsibleSection `
                -Id "subscriptions" `
                -Title "Subscriptions scanned ($($SubscriptionSummary.Count))" `
                -Items $subscriptionItems
        )

        @{
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
                                text = "CIDR Store Reconciliation Complete"
                                wrap = $true
                            },
                            @{
                                type = "FactSet"
                                facts = @(
                                    @{ title = "Table"; value = "$CidrStoreAccountName/$CidrStoreTableName" },
                                    @{ title = "Dry run"; value = "$DryRun" },
                                    @{ title = "Rows scanned"; value = "$RowsScanned" },
                                    @{ title = "Removed"; value = "$removed" },
                                    @{ title = "Would remove"; value = "$wouldRemove" },
                                    @{ title = "Retained"; value = "$retained" },
                                    @{ title = "Skipped"; value = "$skipped" },
                                    @{ title = "Failed"; value = "$failed" }
                                )
                            }
                        ) + $resultContainers
                    }
                }
            )
        }
    }

    # Teams rejects cards over 28 KB outright. A fixed per-section row cap cannot hold that line -
    # three full sections of long resource group names and verbose error text will breach it - so
    # build the card and shrink the cap until it fits, keeping a margin for the Teams envelope.
    $maxCardBytes = 26624
    $json = $null

    foreach ($limit in @(25, 15, 10, 5, 2, 1)) {
        $json = (& $buildPayload $limit) | ConvertTo-Json -Depth 30 -Compress
        $cardBytes = [System.Text.Encoding]::UTF8.GetByteCount($json)

        if ($cardBytes -le $maxCardBytes) {
            Write-Verbose "Teams card built at $cardBytes bytes with a per-section limit of $limit."
            break
        }

        Write-Verbose "Teams card was $cardBytes bytes at a per-section limit of $limit. Shrinking."
    }

    try {
        Invoke-RestMethod `
            -Method Post `
            -Uri $teamsWebhookUrl `
            -ContentType "application/json" `
            -Body $json | Out-Null
    }
    catch {
        Write-Warning "Failed to send Teams Adaptive Card: $_"
    }
}

# ----------------------------
# Open the CIDR table
# ----------------------------
$cidrTable = Invoke-InCidrStoreSubscription {
    $storageAccount = Get-AzStorageAccount -ResourceGroupName $StorageAccountResourceGroup -Name $CidrStoreAccountName -ErrorAction SilentlyContinue
    if (-not $storageAccount) {
        throw "CIDR storage account '$CidrStoreAccountName' was not found in subscription '$CidrStoreSubscriptionId'."
    }

    $tableEndpoint = $storageAccount.PrimaryEndpoints.Table
    if ([string]::IsNullOrWhiteSpace($tableEndpoint)) {
        throw "CIDR storage account '$CidrStoreAccountName' does not expose a Table service endpoint. Account kind: '$($storageAccount.Kind)'. SKU: '$($storageAccount.Sku.Name)'."
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

    if (-not $cloudTable.Exists()) {
        throw "CIDR storage table '$CidrStoreTableName' does not exist at '$($cloudTable.Uri)'. Nothing to reconcile."
    }

    $cloudTable
}

if (-not $cidrTable) {
    throw "CIDR table initialization returned null for table '$CidrStoreTableName' in storage account '$CidrStoreAccountName'."
}

# ----------------------------
# Load allocation rows
# ----------------------------
$allocationRows = @(Invoke-InCidrStoreSubscription { Get-CidrTableRows -PartitionKey "CIDR_ALLOCATIONS" })

Write-Output "Loaded $($allocationRows.Count) allocation row(s) from '$CidrStoreTableName'."

$entries = @($allocationRows | ForEach-Object { Get-CidrAllocationEntryDetail -Row $_ })

$subscriptionFilter = @()
if ($SubscriptionId) {
    $subscriptionFilter = @($SubscriptionId | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $entries = @($entries | Where-Object { $_.SubscriptionId -in $subscriptionFilter })
    Write-Output "Filtered to $($entries.Count) row(s) across $($subscriptionFilter.Count) requested subscription(s)."
}

# ----------------------------
# Resolve resource groups per subscription
# ----------------------------
# One Get-AzResourceGroup call per subscription rather than one per row, cached so a subscription
# with hundreds of allocation rows is still a single ARM round trip.
$subscriptionState = @{}

$referencedSubscriptionIds = @(
    $entries |
        Where-Object { $_.SubscriptionId } |
        Select-Object -ExpandProperty SubscriptionId -Unique
)

foreach ($subId in $referencedSubscriptionIds) {
    $state = [pscustomobject]@{
        SubscriptionId = $subId
        SubscriptionName = $subId
        Accessible = $false
        ResourceGroups = @{}
        Status = "Unknown"
        RowCount = 0
    }

    try {
        $subscription = Get-AzSubscription -SubscriptionId $subId -ErrorAction Stop
        $state.SubscriptionName = $subscription.Name

        if ($subscription.State -ne "Enabled") {
            # A disabled subscription still holds its resource groups but will not answer ARM
            # queries reliably. Treat it as inaccessible rather than risk reclaiming a live CIDR.
            $state.Status = "NotEnabled ($($subscription.State))"
            Write-Warning "Subscription '$($subscription.Name)' ($subId) is in state '$($subscription.State)'. Its rows will be left untouched."
        }
        else {
            $rgNames = Invoke-InSubscription -TargetSubscriptionId $subId -ScriptBlock {
                Get-AzResourceGroup -ErrorAction Stop | Select-Object -ExpandProperty ResourceGroupName
            }

            $lookup = @{}
            foreach ($name in @($rgNames)) {
                $lookup[$name.ToLowerInvariant()] = $true
            }

            $state.ResourceGroups = $lookup
            $state.Accessible = $true
            $state.Status = "Accessible"

            Write-Output "Subscription '$($state.SubscriptionName)' ($subId): $($lookup.Count) resource group(s) found."
        }
    }
    catch {
        $state.Status = "Inaccessible"
        Write-Warning "Could not enumerate resource groups in subscription '$subId': $($_.Exception.Message). Its rows will be left untouched."
    }

    $subscriptionState[$subId] = $state
}

# ----------------------------
# Reconcile
# ----------------------------
$runResults = @()

foreach ($entry in $entries) {
    $subId = $entry.SubscriptionId
    $rgName = $entry.ResourceGroupName

    if (-not $subId -or -not $rgName) {
        Write-Warning "Row '$($entry.RowKey)' could not be parsed into a subscription and resource group. Leaving it in place."
        $runResults += [pscustomobject]@{
            SubscriptionId = $subId
            SubscriptionName = "$subId"
            ResourceGroup = "$rgName"
            VNetName = "$($entry.VnetName)"
            VnetCidr = "$($entry.VnetCidr)"
            PartitionKey = "CIDR_ALLOCATIONS"
            RowKey = $entry.RowKey
            Action = "SkippedUnparsable"
            Detail = "RowKey is not in the expected '<subscriptionId>|<resourceGroup>|<vnetName>' form."
            DryRun = $DryRun
        }
        continue
    }

    $state = $subscriptionState[$subId]
    $state.RowCount++

    if (-not $state.Accessible) {
        $runResults += [pscustomobject]@{
            SubscriptionId = $subId
            SubscriptionName = $state.SubscriptionName
            ResourceGroup = $rgName
            VNetName = "$($entry.VnetName)"
            VnetCidr = "$($entry.VnetCidr)"
            PartitionKey = "CIDR_ALLOCATIONS"
            RowKey = $entry.RowKey
            Action = "SkippedInaccessible"
            Detail = "Subscription status: $($state.Status)."
            DryRun = $DryRun
        }
        continue
    }

    if ($state.ResourceGroups.ContainsKey($rgName.ToLowerInvariant())) {
        $runResults += [pscustomobject]@{
            SubscriptionId = $subId
            SubscriptionName = $state.SubscriptionName
            ResourceGroup = $rgName
            VNetName = "$($entry.VnetName)"
            VnetCidr = "$($entry.VnetCidr)"
            PartitionKey = "CIDR_ALLOCATIONS"
            RowKey = $entry.RowKey
            Action = "Retained"
            Detail = "Resource group still exists."
            DryRun = $DryRun
        }
        continue
    }

    Write-Output "[ORPHAN] $subId / $rgName / $($entry.VnetName) -> $($entry.VnetCidr)"

    if ($DryRun) {
        $runResults += [pscustomobject]@{
            SubscriptionId = $subId
            SubscriptionName = $state.SubscriptionName
            ResourceGroup = $rgName
            VNetName = "$($entry.VnetName)"
            VnetCidr = "$($entry.VnetCidr)"
            PartitionKey = "CIDR_ALLOCATIONS"
            RowKey = $entry.RowKey
            Action = "WouldRemove"
            Detail = "Resource group no longer exists."
            DryRun = $DryRun
        }
        continue
    }

    try {
        $rowKeyToRemove = $entry.RowKey
        Invoke-InCidrStoreSubscription {
            Remove-CidrTableRow -PartitionKey "CIDR_ALLOCATIONS" -RowKey $rowKeyToRemove
        }

        Write-Output "[REMOVED] CIDR_ALLOCATIONS/$rowKeyToRemove"

        $runResults += [pscustomobject]@{
            SubscriptionId = $subId
            SubscriptionName = $state.SubscriptionName
            ResourceGroup = $rgName
            VNetName = "$($entry.VnetName)"
            VnetCidr = "$($entry.VnetCidr)"
            PartitionKey = "CIDR_ALLOCATIONS"
            RowKey = $entry.RowKey
            Action = "Removed"
            Detail = "Resource group no longer exists."
            DryRun = $DryRun
        }
    }
    catch {
        Write-Warning "Failed to remove row 'CIDR_ALLOCATIONS/$($entry.RowKey)': $_"
        $runResults += [pscustomobject]@{
            SubscriptionId = $subId
            SubscriptionName = $state.SubscriptionName
            ResourceGroup = $rgName
            VNetName = "$($entry.VnetName)"
            VnetCidr = "$($entry.VnetCidr)"
            PartitionKey = "CIDR_ALLOCATIONS"
            RowKey = $entry.RowKey
            Action = "Failed"
            Detail = "$($_.Exception.Message)"
            DryRun = $DryRun
        }
    }
}

# ----------------------------
# Optionally reclaim empty per-subscription base CIDR reservations
# ----------------------------
if ($RemoveEmptySubscriptionAllocations) {
    $subscriptionRows = @(Invoke-InCidrStoreSubscription { Get-CidrTableRows -PartitionKey "CIDR" })

    foreach ($subscriptionRow in $subscriptionRows) {
        $subId = $subscriptionRow.RowKey

        if ($subscriptionFilter.Count -gt 0 -and $subId -notin $subscriptionFilter) {
            continue
        }

        $state = $subscriptionState[$subId]

        # A subscription with no allocation rows in this run was never verified against ARM, so its
        # reservation is left alone - the /16 is cheap, a wrongly reissued one is not.
        if (-not $state -or -not $state.Accessible) {
            Write-Output "Skipping base CIDR reclaim for '$subId' because the subscription was not verified this run."
            continue
        }

        $remaining = @(
            $runResults |
                Where-Object { $_.SubscriptionId -eq $subId -and $_.Action -in @("Retained", "SkippedInaccessible", "Failed") }
        ).Count

        if ($remaining -gt 0) {
            continue
        }

        Write-Output "[EMPTY] Subscription '$($state.SubscriptionName)' ($subId) has no remaining allocations. Base CIDR: $($subscriptionRow.BaseCidr)"

        if ($DryRun) {
            $runResults += [pscustomobject]@{
                SubscriptionId = $subId
                SubscriptionName = $state.SubscriptionName
                ResourceGroup = "(subscription reservation)"
                VNetName = ""
                VnetCidr = "$($subscriptionRow.BaseCidr)"
                PartitionKey = "CIDR"
                RowKey = $subId
                Action = "WouldRemove"
                Detail = "No allocations remain for this subscription."
                DryRun = $DryRun
            }
            continue
        }

        try {
            $subscriptionRowKey = $subId
            Invoke-InCidrStoreSubscription {
                Remove-CidrTableRow -PartitionKey "CIDR" -RowKey $subscriptionRowKey
            }

            $runResults += [pscustomobject]@{
                SubscriptionId = $subId
                SubscriptionName = $state.SubscriptionName
                ResourceGroup = "(subscription reservation)"
                VNetName = ""
                VnetCidr = "$($subscriptionRow.BaseCidr)"
                PartitionKey = "CIDR"
                RowKey = $subId
                Action = "Removed"
                Detail = "No allocations remain for this subscription."
                DryRun = $DryRun
            }
        }
        catch {
            Write-Warning "Failed to remove base CIDR row 'CIDR/$subId': $_"
            $runResults += [pscustomobject]@{
                SubscriptionId = $subId
                SubscriptionName = $state.SubscriptionName
                ResourceGroup = "(subscription reservation)"
                VNetName = ""
                VnetCidr = "$($subscriptionRow.BaseCidr)"
                PartitionKey = "CIDR"
                RowKey = $subId
                Action = "Failed"
                Detail = "$($_.Exception.Message)"
                DryRun = $DryRun
            }
        }
    }
}

# ----------------------------
# Report
# ----------------------------
$runResults | Sort-Object Action, SubscriptionName, ResourceGroup | Format-Table -AutoSize | Out-String | Write-Output

$subscriptionSummary = @(
    $subscriptionState.Values |
        Sort-Object SubscriptionName |
        ForEach-Object {
            [pscustomobject]@{
                SubscriptionId = $_.SubscriptionId
                SubscriptionName = $_.SubscriptionName
                Status = $_.Status
                RowCount = $_.RowCount
            }
        }
)

if ($teamsWebhookUrl) {
    Send-TeamsRunbookCard `
        -teamsWebhookUrl $teamsWebhookUrl `
        -Results $runResults `
        -DryRun $DryRun `
        -RowsScanned $entries.Count `
        -SubscriptionSummary $subscriptionSummary
}

Write-Output "Runbook complete."
