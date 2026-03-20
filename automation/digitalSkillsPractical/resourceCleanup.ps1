<#
.VERSION    1.0.1
.AUTHOR     Chris Langford
.COPYRIGHT  (c) 2026 Chris Langford. All rights reserved.
.TAGS       Azure Automation, PowerShell Runbook, DevOps
.DESCRIPTION This PowerShell script is designed to clean up Azure resource groups in a subscription. It retrieves all resource groups, checks for a specific exclusion tag, and deletes those that do not have the exclusion tag. The script supports a dry run mode for testing and sends a summary of the cleanup operation to a Microsoft Teams channel via a webhook.
.SYNOPSIS    Clean up Azure resource groups based on tag exclusion.
.PARAMETER   cleanupEnabled     Flag to enable or disable the cleanup operation.
.PARAMETER   ExcludeTagName     The name of the tag used to exclude resource groups from deletion.
.PARAMETER   ExcludeTagValue    The value of the tag used to exclude resource groups from deletion.
.PARAMETER   teamsWebhookUrl    The Microsoft Teams webhook URL to send the cleanup summary (optional, can also be set via an Automation Variable).
.PARAMETER   DryRun             Flag to indicate whether to perform a dry run (no actual deletions) or to execute the cleanup.
.RuntimeEnvironment PowerShell-7.2
.NOTES
    LASTEDIT: 20-03-2026
#>

param(
    [Parameter(Mandatory=$true)]
    [ValidateNotNull()]
    [bool] $cleanupEnabled,

    [Parameter(Mandatory = $false)]
    [string] $ExcludeTagName = "Delete",

    [Parameter(Mandatory = $false)]
    [string] $ExcludeTagValue = "DoNotDelete",

    [Parameter(Mandatory=$false)]
    [ValidatePattern('^https://.*')]
    [string] $teamsWebhookUrl,

    [Parameter(Mandatory = $true)]
    [bool] $DryRun = $true
)

#–– Preferences ––
$ErrorActionPreference = 'Stop'

#–– Teams webhook from Automation Variable if not provided ––
if (-not $teamsWebhookUrl) {
    try { 
        $teamsWebhookUrl = Get-AutomationVariable -Name 'TeamsWebhookUrlWeeklyCleanup' 
    }
    catch { 
        Write-Verbose "No Teams webhook URL provided or found." 
    }
}

#–– Authenticate ––
try {
    Connect-AzAccount -Identity
    Write-Information "Azure authentication succeeded." -Tags Authentication
}
catch { Write-Error "Authentication failed: $_"; throw }

# Get current Azure subscription name
$subscriptionName = (Get-AzContext).Subscription.Name
$subscriptionId = (Get-AzContext).Subscription.Id
Write-Information "Current Azure subscription: $subscriptionName ($subscriptionId)" -Tags Subscription  

#–– Exit if cleanup not enabled ––
if (-not $cleanupEnabled) {
    Write-Information "cleanupEnabled flag is False. No resources will be removed." -Tags CleanupRun
    #Stop-Transcript
    return
}else{
    Write-Output "Starting cleanup for subscription: $subscriptionName." -Tags CleanupRun
}

# Retrieve all resource groups
$resourceGroups = Get-AzResourceGroup

$planned = @()
$deleted = @()
$skipped = @()

foreach ($rg in $resourceGroups) {

    $rgName = $rg.ResourceGroupName
    $tags = $rg.Tags

    $exclude = $false

    if ($ExcludeTagName -and $ExcludeTagValue) {
        if ($tags.ContainsKey($ExcludeTagName) -and $tags[$ExcludeTagName] -eq $ExcludeTagValue) {
            $exclude = $true
        }
    }

    if ($exclude) {
        Write-Output "Skipping RG '$rgName' due to tag exclusion."
        $skipped += $rgName
        continue
    }

    # Add to planned list
    $planned += $rgName

    if ($DryRun) {
        Write-Output "DryRun: Would delete RG: $rgName"
        continue
    }

    # Actual deletion
    Write-Output "Deleting RG: $rgName"
    try {
        Remove-AzResourceGroup -Name $rgName -Force -AsJob
        $deleted += $rgName
    }
    catch {
        Write-Error "Failed to delete RG $rgName. $_"
    }
}

if (-not $DryRun) {
    Write-Output "Waiting for deletion jobs to complete..."
    Get-Job | Wait-Job
}

# Build Teams Adaptive Card
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
                        text = "Azure Subscription Cleanup Summary for $subscriptionName subscription."
                        weight = "Bolder"
                        size = "Large"
                    },
                    @{
                        type = "TextBlock"
                        text = "Subscription: $SubscriptionId"
                        wrap = $true
                    },
                    @{
                        type = "TextBlock"
                        text = "**Dry Run Mode:** $DryRun"
                        wrap = $true
                    },
                    @{
                        type = "TextBlock"
                        text = "**Planned Deletions:**"
                        wrap = $true
                    },
                    @{
                        type = "TextBlock"
                        text = ($(if ($planned.Count -gt 0) { $planned -join ", " } else { "None" }))
                        wrap = $true
                    },
                    @{
                        type = "TextBlock"
                        text = "**Actual Deletions:**"
                        wrap = $true
                    },
                    @{
                        type = "TextBlock"
                        text = ($(if ($deleted.Count -gt 0) { $deleted -join ", " } else { "None (Dry Run or no deletions)" }))
                        wrap = $true
                    },
                    @{
                        type = "TextBlock"
                        text = "**Skipped (Tag Exclusion):**"
                        wrap = $true
                    },
                    @{
                        type = "TextBlock"
                        text = ($(if ($skipped.Count -gt 0) { $skipped -join ", " } else { "None" }))
                        wrap = $true
                    }
                )
            }
        }
    )
}

# Send to Teams
Invoke-RestMethod -Method Post -Uri $TeamsWebhookUrl -Body ($card | ConvertTo-Json -Depth 10) -ContentType 'application/json'

Write-Output "Cleanup complete. Summary sent to Teams."