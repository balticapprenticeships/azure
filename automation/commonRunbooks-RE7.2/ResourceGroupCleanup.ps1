<#
.VERSION    6.0.1
.AUTHOR     Chris Langford
.COPYRIGHT  (c) 2026 Chris Langford. All rights reserved.
.TAGS       Azure Automation, PowerShell Runbook, DevOps
.SYNOPSIS   Cleans up Azure VMs tagged Cleanup=Enabled with advanced logging and Teams notifications (VM-only).
.DESCRIPTION Identifies Azure VMs tagged with Cleanup=Enabled and removes them along with dependencies. Supports dry-run, per-RG grouping, and rich Teams adaptive card reporting.
.PARAMETER cleanupEnabled
    Boolean flag to enable actual cleanup. Set to False for testing/logging.
.PARAMETER teamsWebhookUrl
    Optional Teams webhook URL. Falls back to Automation Variable 'TeamsWebhookUrlWeeklyCleanup' if not provided.
.PARAMETER ParallelMode
    If True, VM deletions run in parallel using ThrottleLimit.
.PARAMETER ThrottleLimit
    Max concurrent VM deletions when ParallelMode is True. Default is 5.
.PARAMETER VMDeletionSettleTimeout
    Seconds to wait for all VMs to settle before reporting. Default 300.
.PARAMETER WhatIf
    Boolean dry-run flag. Default True. Prevents actual deletion when True.
.NOTES
    - Requires Azure PowerShell module (Az)
    - Run with appropriate permissions to delete VMs and manage resources
    - Edit parameters to configure execution mode and Teams integration
    LASTEDIT: 15.04.2026
#>

param(
    [Parameter(Mandatory=$true)]
    [ValidateNotNull()]
    [bool] $cleanupEnabled,

    [Parameter(Mandatory=$false)]
    [ValidatePattern('^[0-9a-fA-F-]{36}$')]
    [string] $SubscriptionId,

    [Parameter(Mandatory=$false)]
    [ValidatePattern('^https://.*')]
    [string] $teamsWebhookUrl,

    [Parameter(Mandatory=$true)]
    [ValidateNotNull()]
    [bool] $ParallelMode = $false,

    [Parameter(Mandatory=$false)]
    [ValidateRange(1, 20)]
    [int] $ThrottleLimit = 5,

    [Parameter(Mandatory=$false)]
    [int] $VMDeletionSettleTimeout = 300,

    [Parameter(Mandatory=$false)]
    [bool] $WhatIf = $true
)

#–– Preferences ––
$ErrorActionPreference = 'Stop'
$WarningPreference     = 'Continue'
$VerbosePreference     = 'SilentlyContinue'
$InformationPreference = 'Continue'

function Format-LondonTime { param([datetime]$dt)
    $tz = [System.TimeZoneInfo]::FindSystemTimeZoneById("GMT Standard Time")
    [System.TimeZoneInfo]::ConvertTime($dt, $tz).ToString("dd/MM/yyyy HH:mm:ss")
}

function Get-LondonTime { param([datetime]$dt)
    $tz = [System.TimeZoneInfo]::FindSystemTimeZoneById("GMT Standard Time")
    [System.TimeZoneInfo]::ConvertTime($dt, $tz)
}

if (-not $teamsWebhookUrl) {
    try { $teamsWebhookUrl = Get-AutomationVariable -Name 'TeamsWebhookUrlDailyCleanup' } catch {Write-Verbose "No Teams webhook URL provided or found."}
}

#–– Start Transcript ––
$transcriptTime = (Get-LondonTime (Get-Date)).ToString("ddMMyyyy_HHmmss")
$transcript = Join-Path $env:TEMP "DailyCleanupRun_$transcriptTime.txt"
Start-Transcript -Path $transcript -Force

$global:cleanupResults = @{
    StartTime      = Get-Date
    StartTimeStr   = Format-LondonTime (Get-Date)
    EndTime        = $null
    EndTimeStr     = $null
    Duration       = $null
    VMsTargeted    = 0
    VMsRemoved     = 0
    SkippedVMs     = @()
    FailedVMs      = @()
    Errors         = 0
    VMsRemovedRGs  = @()
    SkippedVMsRGs  = @()
    FailedVMsRGs   = @()
}

#–– Authenticate and select subscription ––
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

    Write-Output "Runbook executing in subscription: $($context.Subscription.Name) ($subscriptionId)"
}
catch {
    Write-Error "Authentication or subscription selection failed: $_"
    throw
}

# Get current Azure subscription name
$subscriptionName = (Get-AzContext).Subscription.Name

#–– Confirmation Guard ––
if (-not $cleanupEnabled -or $WhatIf) {
    Write-Warning "Runbook is in safe mode. To perform actual cleanup, set -cleanupEnabled \$true and -WhatIf \$false."
    Stop-Transcript
    return
}

function Invoke-WithRetry {
    param([scriptblock]$ScriptBlock,[int]$MaxRetries=3)
    for ($i=1; $i -le $MaxRetries; $i++) {
        try { & $ScriptBlock; return $true }
        catch {
            if ($i -eq $MaxRetries) { return $false }
            Start-Sleep -Seconds (5 * $i)
        }
    }
}

function Wait-ForVMNicDetach {
    param($ResourceGroupName,$VMName)
    for ($i=0; $i -lt 12; $i++) {
        $nics = Get-AzNetworkInterface -ResourceGroupName $ResourceGroupName | Where-Object { $_.VirtualMachine -and $_.VirtualMachine.Id -like "*$VMName" }
        if (-not $nics) { return $true }
        Start-Sleep 5
    }
    return $false
}

function Remove-BootDiagnostics { param($VM)
    try {
        $uri = $VM.DiagnosticsProfile.BootDiagnostics.StorageUri
        if (-not $uri) { return }
        $storageName = [regex]::Match($uri, 'https[s]?://(.+?)\\.').Groups[1].Value
        $sa = Get-AzStorageAccount -Name $storageName
        if (-not $WhatIf) {
            Remove-AzStorageContainer -Name "bootdiagnostics-*" -Context $sa.Context -Force -ErrorAction Ignore
        }
    } catch {}
}

function Remove-VMAndDependencies { param($VM)
    try {
        if ($WhatIf) {
            Write-Information "[WhatIf] Would remove VM '$($VM.Name)' in RG '$($VM.ResourceGroupName)'"
            $global:cleanupResults.SkippedVMs += $VM.Name
            $global:cleanupResults.SkippedVMsRGs += "$($VM.Name) (RG: $($VM.ResourceGroupName))"
            return
        }

        Remove-BootDiagnostics -VM $VM

        $nics = Get-AzNetworkInterface -ResourceGroupName $VM.ResourceGroupName | Where-Object { $_.VirtualMachine -and $_.VirtualMachine.Id -eq $VM.Id }
        foreach ($nic in $nics) {
            Invoke-WithRetry { Remove-AzNetworkInterface -Name $nic.Name -ResourceGroupName $VM.ResourceGroupName -Force }
        }

        Remove-AzVM -Name $VM.Name -ResourceGroupName $VM.ResourceGroupName -Force
        Wait-ForVMNicDetach -ResourceGroupName $VM.ResourceGroupName -VMName $VM.Name

        $osDisk = Get-AzDisk -ResourceGroupName $VM.ResourceGroupName -Name $VM.StorageProfile.OsDisk.Name -ErrorAction SilentlyContinue
        if ($osDisk -and -not $osDisk.ManagedBy) {
            Remove-AzDisk -ResourceGroupName $VM.ResourceGroupName -Name $osDisk.Name -Force
        }

        $global:cleanupResults.VMsRemoved++
        $global:cleanupResults.VMsRemovedRGs += "$($VM.Name) (RG: $($VM.ResourceGroupName))"
    }
    catch {
        $global:cleanupResults.FailedVMs += $VM.Name
        $global:cleanupResults.FailedVMsRGs += "$($VM.Name) (RG: $($VM.ResourceGroupName))"
        $global:cleanupResults.Errors++
    }
}

$vmList = Get-AzVM | Where-Object { $_.Tags -and $_.Tags['Cleanup'] -ieq 'Enabled' }
$global:cleanupResults.VMsTargeted = $vmList.Count

if ($ParallelMode -and -not $WhatIf) {
    $vmList | ForEach-Object -Parallel {
        Remove-VMAndDependencies -VM $_
    } -ThrottleLimit $ThrottleLimit
} else {
    foreach ($vm in $vmList) { Remove-VMAndDependencies -VM $vm }
}

$global:cleanupResults.EndTime  = Get-Date
$global:cleanupResults.EndTimeStr = Format-LondonTime $global:cleanupResults.EndTime
$global:cleanupResults.Duration = [math]::Round((New-TimeSpan -Start $global:cleanupResults.StartTime -End $global:cleanupResults.EndTime).TotalMinutes, 2)

Stop-Transcript

#–– Teams Adaptive Card (VM-only, grouped by RG) ––
if ($teamsWebhookUrl) {

    $resourcesByRG = @{}

    function Add-VMToRG {
        param($rgName, $status, $vmName)
        if (-not $resourcesByRG.ContainsKey($rgName)) {
            $resourcesByRG[$rgName] = @{
                Removed = @()
                Skipped = @()
                Failed  = @()
            }
        }
        $resourcesByRG[$rgName][$status] += $vmName
    }

    # Populate RG grouping
    foreach ($entry in $global:cleanupResults.VMsRemovedRGs) {
        if ($entry -match '\(RG: (.+?)\)$') {
            $rg = $matches[1]
            $name = $entry -replace " \(RG: .+\)$", ""
            Add-VMToRG -rgName $rg -status 'Removed' -vmName $name
        }
    }

    foreach ($entry in $global:cleanupResults.SkippedVMsRGs) {
        if ($entry -match '\(RG: (.+?)\)$') {
            $rg = $matches[1]
            $name = $entry -replace " \(RG: .+\)$", ""
            Add-VMToRG -rgName $rg -status 'Skipped' -vmName $name
        }
    }

    foreach ($entry in $global:cleanupResults.FailedVMsRGs) {
        if ($entry -match '\(RG: (.+?)\)$') {
            $rg = $matches[1]
            $name = $entry -replace " \(RG: .+\)$", ""
            Add-VMToRG -rgName $rg -status 'Failed' -vmName $name
        }
    }

    function Add-CollapsibleSection {
        param($title, $items, $color="Default")
        if ($items.Count -gt 0) {
            $itemList = $items | ForEach-Object { @{ type="TextBlock"; text=$_; wrap=$true; spacing="None" } }
            $toggleId = ($title -replace '[^0-9a-zA-Z]', '') + "_" + ([guid]::NewGuid().ToString('N'))
            return @{
                type="Container"
                items=@(
                    @{ type="ActionSet"; actions=@(@{ type="Action.ToggleVisibility"; title=$title; target=@(@{ elementId=$toggleId }) }) },
                    @{ type="Container"; id=$toggleId; isVisible=$false; items=$itemList; style=$color }
                )
            }
        }
        return $null
    }

    # Card body
    $cardBody = @(
        @{ type="TextBlock"; text="Azure VM Cleanup Report for ($subscriptionName)"; weight="Bolder"; size="Large" },
        @{ type="TextBlock"; text="Runbook Mode: $(if ($WhatIf) { 'Safe Mode / WhatIf' } else { 'Actual Cleanup' })"; wrap=$true },
        @{ type="FactSet"; facts=@(
            @{ title="Start:"; value=$global:cleanupResults.StartTimeStr },
            @{ title="End:"; value=$global:cleanupResults.EndTimeStr },
            @{ title="Duration:"; value="$($global:cleanupResults.Duration) min" },
            @{ title="VMs Targeted:"; value="$($global:cleanupResults.VMsTargeted)" },
            @{ title="Removed:"; value="$($global:cleanupResults.VMsRemoved)" },
            @{ title="Errors:"; value="$($global:cleanupResults.Errors)" }
        )}
    )

    # Add collapsible sections per resource group
    foreach ($rg in $resourcesByRG.Keys | Sort-Object) {
        $rgData = $resourcesByRG[$rg]

        $removedCount = $rgData.Removed.Count
        $skippedCount = $rgData.Skipped.Count
        $failedCount  = $rgData.Failed.Count

        $rgColor = if ($failedCount -gt 0) { "Attention" } elseif ($skippedCount -gt 0) { "Warning" } else { "Good" }

        $rgTitle = "Resource Group: $rg (✅$removedCount | ⚠️$skippedCount | ❌$failedCount)"

        $rgItems = @()
        foreach ($vm in $rgData.Removed) { $rgItems += "✅ $vm" }
        foreach ($vm in $rgData.Skipped) { $rgItems += "⚠️ [WhatIf] $vm" }
        foreach ($vm in $rgData.Failed)  { $rgItems += "❌ $vm" }

        $section = Add-CollapsibleSection -title $rgTitle -items $rgItems -color $rgColor
        if ($section) { $cardBody += $section }
    }

    # Send Adaptive Card
    $payload = @{
        type = "message"
        attachments = @(@{
            contentType = "application/vnd.microsoft.card.adaptive"
            content = @{ type="AdaptiveCard"; version="1.5"; body=$cardBody; msteams=@{ width="Full" } }
        })
    } | ConvertTo-Json -Depth 50

    Invoke-RestMethod -Uri $teamsWebhookUrl -Method Post -Body $payload -ContentType 'application/json'
}