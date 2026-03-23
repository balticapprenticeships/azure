<#
.VERSION    1.1.1
.AUTHOR     Chris Langford
.COPYRIGHT  (c) 2026 Chris Langford. All rights reserved.
.TAGS       Azure Automation, PowerShell Runbook, DevOps
.SYNOPSIS   Drops, Downgrades, and Deletes SQL databases and sends Teams notifications.
.DESCRIPTION
    This Azure Automation Runbook performs bulk management of Azure SQL databases based on configurable criteria. 
    It can automatically downgrade non-Basic databases to Basic edition, delete Basic databases, or delete databases 
    based on specific tag values. The runbook includes safeguards to prevent mass deletions and sends a summary report 
    to a Microsoft Teams channel via webhook.
.PARAMETER  cleanupEnabled - Master switch to enable or disable all cleanup actions.
.PARAMETER  DowngradeToBasic - If true, downgrades non-Basic databases to Basic edition.
.PARAMETER  DeleteBasicDatabases - If true, deletes databases currently in Basic edition.
.PARAMETER  DeleteTagName - Name of the tag to check for deletion criteria.
.PARAMETER  DeleteTagValue - Value of the tag that triggers deletion when matched.
.PARAMETER  ExcludeTagPatterns - Array of wildcard patterns for tag keys that should exclude databases from any action.
.PARAMETER  DatabaseNamePattern - Wildcard pattern that database names must match to be considered for any action.
.PARAMETER  teamsWebhookUrl - Optional Microsoft Teams webhook URL for sending the summary report. If not provided, it will attempt to retrieve from an Automation Variable.
.PARAMETER  WhatIf - If true, simulates the actions without making any changes. Set to false to perform actual operations.
.RuntimeEnvironment PowerShell-7.2

.NOTES
    LASTEDIT: 18-03-2026
#>

param(
    [Parameter(Mandatory=$true)]
    [ValidateNotNull()]
    [bool] $cleanupEnabled,

    [Parameter(Mandatory=$false)]
    [ValidateNotNullOrEmpty()]
    [bool] $DowngradeToBasic = $false,

    [Parameter(Mandatory=$false)]
    [ValidateNotNullOrEmpty()]
    [bool] $DeleteBasicDatabases = $false,

    [Parameter(Mandatory=$false)]
    [ValidateNotNullOrEmpty()]
    [string] $DeleteTagName = "",

    [Parameter(Mandatory=$false)]
    [ValidateNotNullOrEmpty()]
    [string] $DeleteTagValue = "",

    [Parameter(Mandatory=$false)]
    [ValidateNotNullOrEmpty()]
    [string[]] $ExcludeTagPatterns = @("DoNotDelete*", "DoNotModify*"),

    [Parameter(Mandatory=$false)]
    [ValidateNotNullOrEmpty()]
    [string] $DatabaseNamePattern = "*Database*",

    [Parameter(Mandatory=$false)]
    [ValidatePattern('^https://.*')]
    [string] $teamsWebhookUrl,

    [Parameter(Mandatory=$true)]
    [ValidateNotNull()]
    [bool] $WhatIf = $true
)

#–– Preferences ––
$ErrorActionPreference = 'Stop'
$WarningPreference     = 'Continue'
$VerbosePreference     = 'SilentlyContinue'
$InformationPreference = 'Continue'

#–– Teams webhook from Automation Variable if not provided ––
if (-not $teamsWebhookUrl) {
    try { 
        $teamsWebhookUrl = Get-AutomationVariable -Name 'TeamWebhookUrlSwDRwWeeklyCleanup' 
    }
    catch { 
        Write-Verbose "No Teams webhook URL provided or found." 
    }
}

# ------------------------------------------------
# Time Tracking (UTC)
# ------------------------------------------------
$runStartTimeUtc = Get-Date
$ukTimeZone = [System.TimeZoneInfo]::FindSystemTimeZoneById("GMT Standard Time")

# ------------------------------------------------
# Authenticate
# ------------------------------------------------
try {
    Connect-AzAccount -Identity
    Write-Information "Azure authentication succeeded." -Tags Authentication
}
catch { Write-Error "Authentication failed: $_"; Stop-Transcript; throw }

# Get current Azure subscription name
$subscriptionId = (Get-AzContext).Subscription.Id
$subscriptionName = (Get-AzSubscription).Subscription.Name

#–– Exit if cleanup not enabled ––
if (-not $cleanupEnabled) {
    Write-Information "cleanupEnabled flag is False. No resources will be removed." -Tags CleanupRun
    Stop-Transcript
    return
}

Write-Output "Scanning subscription using Resource Graph..."

# ------------------------------------------------
# Resource Graph Query
# ------------------------------------------------

$query = @"
Resources
| where type == 'microsoft.sql/servers/databases'
| where subscriptionId == '$subscriptionId'
| where name != 'master'
| where name contains '$DatabaseNamePattern'
| project name, resourceGroup, subscriptionId, tags, sku, id
"@

Write-Output "Querying Azure Resource Graph"

$databases = Search-AzGraph -Query $query -First 5000

$totalDatabases = $databases.Count

Write-Output "Matching databases discovered: $totalDatabases"

# ------------------------------------------------
# Automatic Self-Throttling
# ------------------------------------------------

if ($totalDatabases -lt 50) { $ThrottleLimit = 5 }
elseif ($totalDatabases -lt 200) { $ThrottleLimit = 10 }
elseif ($totalDatabases -lt 1000) { $ThrottleLimit = 20 }
else { $ThrottleLimit = 30 }

Write-Output "Parallel throttle limit: $ThrottleLimit"

# ------------------------------------------------
# Concurrent collections
# ------------------------------------------------

$results = [System.Collections.Concurrent.ConcurrentBag[object]]::new()
$errorCounter = [System.Collections.Concurrent.ConcurrentBag[object]]::new()

# ------------------------------------------------
# Parallel Processing
# ------------------------------------------------

$databases | ForEach-Object -Parallel {

    param(
        $DeleteTagName,
        $DeleteTagValue,
        $DowngradeToBasic,
        $DeleteBasicDatabases,
        $ExcludeTagPatterns,
        $DatabaseNamePattern,
        $WhatIf,
        $results,
        $errorCounter
    )

    $db = $_
    $server = ($db.id -split "/")[8]

    $action = "Skipped"
    $reason = ""
    $errorMessage = ""

    try {

        # ------------------------------------------------
        # DATABASE NAME VALIDATION
        # ------------------------------------------------

        if ($db.name -notlike $DatabaseNamePattern) {

            $reason = "Name does not match required pattern"

            $results.Add([PSCustomObject]@{
                Database = $db.name
                Server = $server
                Action = $action
                Reason = $reason
                ErrorMessage = $errorMessage
            })

            return
        }

        # ------------------------------------------------
        # TAG EXCLUSION RULES
        # ------------------------------------------------

        $tags = $db.tags

        if ($tags) {

            foreach ($pattern in $ExcludeTagPatterns) {

                foreach ($key in $tags.Keys) {

                    if ($key -like $pattern) {

                        $reason = "Excluded by tag pattern"

                        $results.Add([PSCustomObject]@{
                            Database = $db.name
                            Server = $server
                            Action = $action
                            Reason = $reason
                            ErrorMessage = $errorMessage
                        })

                        return
                    }

                }

            }

        }

        $edition = $db.sku.name

        # ------------------------------------------------
        # DELETE BY TAG
        # ------------------------------------------------

        if ($DeleteTagName) {

            if ($tags.ContainsKey($DeleteTagName) -and $tags[$DeleteTagName] -eq $DeleteTagValue) {

                if (-not $WhatIf) {

                    Remove-AzSqlDatabase `
                        -ResourceGroupName $db.resourceGroup `
                        -ServerName $server `
                        -DatabaseName $db.name `
                        -Force

                }

                $action = "Deleted"
            }

        }

        # ------------------------------------------------
        # DELETE BASIC DATABASES
        # ------------------------------------------------

        elseif ($DeleteBasicDatabases -and $edition -eq "Basic") {

            if (-not $WhatIf) {

                Remove-AzSqlDatabase `
                    -ResourceGroupName $db.resourceGroup `
                    -ServerName $server `
                    -DatabaseName $db.name `
                    -Force

            }

            $action = "Deleted"
        }

        # ------------------------------------------------
        # DOWNGRADE DATABASES
        # ------------------------------------------------

        elseif ($DowngradeToBasic -and $edition -ne "Basic") {

            if (-not $WhatIf) {

                Set-AzSqlDatabase `
                    -ResourceGroupName $db.resourceGroup `
                    -ServerName $server `
                    -DatabaseName $db.name `
                    -Edition Basic

            }

            $action = "Downgraded"
        }

        else {

            $reason = "No matching rule"

        }

    }
    catch {

        $action = "Error"
        $errorMessage = $_.Exception.Message
        $errorCounter.Add($errorMessage)

    }

    $results.Add([PSCustomObject]@{
        Database = $db.name
        Server = $server
        Action = $action
        Reason = $reason
        ErrorMessage = $errorMessage
    })

} -ThrottleLimit $ThrottleLimit -ArgumentList `
$DeleteTagName,
$DeleteTagValue,
$DowngradeToBasic,
$DeleteBasicDatabases,
$ExcludeTagPatterns,
$DatabaseNamePattern,
$WhatIf,
$results,
$errorCounter


# ------------------------------------------------
# Results Summary
# ------------------------------------------------

$deleted = ($results | Where-Object Action -eq "Deleted").Count
$downgraded = ($results | Where-Object Action -eq "Downgraded").Count
$skipped = ($results | Where-Object Action -eq "Skipped").Count
$errors = $results | Where-Object Action -eq "Error"

$runEndTime = Get-Date
$duration = $runEndTime - $runStartTime

$runStartString = $runStartTime.ToString("dd-mm-yyyy HH:mm:ss")
$runEndString = $runEndTime.ToString("dd-mm-yyyy HH:mm:ss")
$durationString = "{0:hh\:mm\:ss}" -f $duration

# ------------------------------------------------
# Catastrophic Deletion Safeguard
# ------------------------------------------------

if ($deleted -gt 50 -or $deleted -gt ($totalDatabases * 0.2)) {

    Write-Warning "Deletion safety threshold exceeded — aborting."

    $deleted = 0
}

# ------------------------------------------------
# Time Conversion (UK)
# ------------------------------------------------
$runEndTimeUtc = Get-Date

$runStartUK = [System.TimeZoneInfo]::ConvertTimeFromUtc($runStartTimeUtc, $ukTimeZone)
$runEndUK = [System.TimeZoneInfo]::ConvertTimeFromUtc($runEndTimeUtc, $ukTimeZone)

$duration = $runEndTimeUtc - $runStartTimeUtc

$runStartString = $runStartUK.ToString("dd-MM-yyyy HH:mm:ss")
$runEndString = $runEndUK.ToString("dd-MM-yyyy HH:mm:ss")
$durationString = "{0:hh\:mm\:ss}" -f $duration

# -----------------------------
# Teams Adaptive Card
# -----------------------------
if ($teamsWebhookUrl) {

    # Error Formatting
    $errorText = ""
    if ($errors.Count -gt 0) {
        $errorText = ($errors | Select-Object -First 10 | ForEach-Object {
            "$($_.Database): $($_.ErrorMessage)"
        }) -join "`n"
    }

    # Adaptive Teams Card (Structured)
    $card = @{
        type = "message"
        attachments = @(
            @{
                contentType = "application/vnd.microsoft.card.adaptive"
                content = @{
                    type = "AdaptiveCard"
                    version = "1.4"
                    body = @(
                        @{
                            type = "TextBlock"
                            size = "Large"
                            weight = "Bolder"
                            text = "Azure SQL Database management Runbook Report for subscription $subscriptionName"
                        },
                        # Run Info
                    @{
                        type="TextBlock"
                        text="Run Information"
                        weight="Bolder"
                    },
                    @{
                        type="FactSet"
                        facts=@(
                            @{title="Start (UK)"; value=$runStartString},
                            @{title="End (UK)"; value=$runEndString},
                            @{title="Duration"; value=$durationString}
                        )
                    },

                    # Actions
                    @{
                        type="TextBlock"
                        text="Actions Summary"
                        weight="Bolder"
                    },
                    @{
                        type="FactSet"
                        facts=@(
                            @{title="Matching DBs"; value="$totalDatabases"},
                            @{title="Deleted"; value="$deleted"},
                            @{title="Downgraded"; value="$downgraded"},
                            @{title="Skipped"; value="$skipped"},
                            @{title="Errors"; value="$($errors.Count)"}
                        )
                    },

                    # Errors
                    @{
                        type="TextBlock"
                        text="Top Errors"
                        weight="Bolder"
                    },
                    @{
                        type="TextBlock"
                        text=$errorText
                        wrap=$true
                    }
                    )
                }
            }
        )
    } | ConvertTo-Json -Depth 10

    Invoke-RestMethod `
        -Uri $TeamsWebhookUrl `
        -Method Post `
        -ContentType "application/json" `
        -Body $card

}