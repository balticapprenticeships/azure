<#
.VERSION    5.0.0
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
.PARAMETER NICWaitTimeout
    Seconds to wait for NICs to detach before VM deletion. Default 300.
.PARAMETER VMDeletionSettleTimeout
    Seconds to wait for all VMs to settle before reporting. Default 300.
.PARAMETER WhatIf
    Boolean dry-run flag. Default True. Prevents actual deletion when True.
.NOTES
    - Requires Azure PowerShell module (Az)
    - Run with appropriate permissions to delete VMs and manage resources
    - Edit parameters to configure execution mode and Teams integration
    LASTEDIT: 07.04.2026
#>

param(
    [Parameter(Mandatory=$true)]
    [bool] $cleanupEnabled,

    [Parameter(Mandatory=$false)]
    [ValidatePattern('^https://.*')]
    [string] $teamsWebhookUrl,

    [Parameter(Mandatory=$true)]
    [bool] $ParallelMode = $false,

    [Parameter(Mandatory=$false)]
    [ValidateRange(1,20)]
    [int] $ThrottleLimit = 5,

    [Parameter(Mandatory=$false)]
    [int] $NICWaitTimeout = 300,

    [Parameter(Mandatory=$false)]
    [int] $VMDeletionSettleTimeout = 300,

    [Parameter(Mandatory=$false)]
    [bool] $WhatIf = $true
)

#–– Confirmation Guard ––
if (-not ($cleanupEnabled -and ($WhatIf -eq $false))) {
    Write-Warning "Cleanup guard triggered: actual deletions will NOT run."
    Write-Warning "You must set -cleanupEnabled \$true AND -WhatIf \$false to perform VM cleanup."
}

#–– Preferences ––
$ErrorActionPreference = 'Stop'
$WarningPreference     = 'Continue'
$VerbosePreference     = 'SilentlyContinue'
$InformationPreference = 'Continue'

#–– Time helpers ––
function Format-LondonTime { param([datetime]$dt)
    $tzLondon = [System.TimeZoneInfo]::FindSystemTimeZoneById("GMT Standard Time")
    [System.TimeZoneInfo]::ConvertTime($dt, $tzLondon).ToString("dd/MM/yyyy HH:mm:ss")
}

function Get-LondonTime { 
    param([datetime]$dt)
    $tzLondon = [System.TimeZoneInfo]::FindSystemTimeZoneById("GMT Standard Time")
    [System.TimeZoneInfo]::ConvertTime($dt, $tzLondon)
}

#–– Teams webhook from Automation Variable if not provided ––
if (-not $teamsWebhookUrl) {
    try { 
        $teamsWebhookUrl = Get-AutomationVariable -Name 'TeamsWebhookUrlWeeklyCleanup' 
    } catch { Write-Verbose "No Teams webhook URL provided or found." }
}

#–– Start Transcript ––
$transcriptTime = (Get-LondonTime (Get-Date)).ToString("ddMMyyyy_HHmmss")
$transcript = Join-Path $env:TEMP "CleanupRun_$transcriptTime.txt"
Start-Transcript -Path $transcript -Force

#–– Logging execution mode ––
Write-Information "Execution Mode: $(if ($ParallelMode) {"Parallel (ThrottleLimit=$ThrottleLimit)"} else {"Sequential"})" -Tags CleanupRun

#–– Global cleanup results ––
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
}

Write-Information "Cleanup run started at $($global:cleanupResults.StartTimeStr)" -Tags CleanupRun

#–– Authenticate ––
try { Connect-AzAccount -Identity; Write-Information "Azure authentication succeeded." -Tags Authentication }
catch { Write-Error "Authentication failed: $_"; Stop-Transcript; throw }

$subscriptionName = (Get-AzContext).Subscription.Name

#–– Dry-run / exit guard ––
if (-not $cleanupEnabled) {
    Write-Information "cleanupEnabled flag is False. No VMs will be removed."
    Stop-Transcript; return
}

#–– Retry wrapper ––
function Invoke-WithRetry {
    param([scriptblock]$ScriptBlock, [int]$MaxRetries=3, [int]$InitialDelaySeconds=10, [string]$OperationName="Operation")
    $attempt=1; $delay=$InitialDelaySeconds
    while ($attempt -le $MaxRetries) {
        try { Write-Information "[$OperationName] Attempt $attempt/$MaxRetries"; & $ScriptBlock; return $true }
        catch { 
            Write-Warning "[$OperationName] failed on attempt ${attempt}: $($_.Exception.Message)"
            if ($attempt -eq $MaxRetries) { Write-Warning "[$OperationName] exhausted retries"; return $false }
            Start-Sleep -Seconds $delay; $attempt++; $delay = [Math]::Min($delay*2,60)
        }
    }
}

#–– Wait for NIC detach ––
function Wait-ForVMNicDetach {
    param([string]$ResourceGroupName,[string]$VMName,[int]$TimeoutSeconds=60,[int]$PollIntervalSeconds=5)
    $elapsed=0
    while ($elapsed -lt $TimeoutSeconds) {
        $nics = Get-AzNetworkInterface -ResourceGroupName $ResourceGroupName -ErrorAction SilentlyContinue |
                Where-Object { $_.VirtualMachine -and $_.VirtualMachine.Id -like "*$VMName" }
        if (-not $nics -or $nics.Count -eq 0) { Write-Information "VM '$VMName' detached from NICs."; return $true }
        Write-Information "Waiting for VM '$VMName' to detach from $($nics.Count) NIC(s)..."; Start-Sleep -Seconds $PollIntervalSeconds; $elapsed += $PollIntervalSeconds
    }
    Write-Warning "Timeout waiting for VM '$VMName' to detach from NICs."; return $false
}

#–– Boot Diagnostics cleanup ––
function Remove-BootDiagnostics { param($VM)
    try {
        $uri = $VM.DiagnosticsProfile.BootDiagnostics.StorageUri
        if (-not $uri) { return }
        $storageName = [regex]::Match($uri,'https[s]?://(.+?)\.').Groups[1].Value
        $cleanName = ($VM.Name -replace '[^0-9a-zA-Z]','').ToLower()
        $shortName = $cleanName.Substring(0,[Math]::Min(9,$cleanName.Length))
        $sanitizedId = ($VM.Id -replace '[^0-9a-zA-Z]','').ToLower()
        $container = "bootdiagnostics-$shortName-$sanitizedId"
        $sa = Get-AzStorageAccount -Name $storageName -ErrorAction Stop
        $ctx = $sa.Context
        if (-not $WhatIf) { Remove-AzStorageContainer -Name $container -Context $ctx -Force -ErrorAction Ignore }
        Write-Information "Boot diagnostics cleaned for VM '$($VM.Name)'." -Tags Diagnostics
    }
    catch { Write-Warning "Failed to remove boot diagnostics for '$($VM.Name)': $_"; $global:cleanupResults.FailedVMs += "$($VM.Name) (RG: $($VM.ResourceGroupName))"; $global:cleanupResults.Errors++ }
}

#–– VM + Dependencies cleanup ––
function Remove-VMAndDependencies { param($VM)
    Write-Information "Processing VM '$($VM.Name)' in RG '$($VM.ResourceGroupName)' (WhatIf=$WhatIf)."

    if ($WhatIf) {
        Write-Information "[Dry-Run] Would remove VM and dependencies: $($VM.Name)"
        $global:cleanupResults.SkippedVMs += "$($VM.Name) (RG: $($VM.ResourceGroupName))"
        return
    }

    try {
        Remove-BootDiagnostics -VM $VM

        # Remove NICs
        $nics = Get-AzNetworkInterface -ResourceGroupName $VM.ResourceGroupName -ErrorAction SilentlyContinue | Where-Object { $_.VirtualMachine -and $_.VirtualMachine.Id -eq $VM.Id }
        foreach ($nic in $nics) {
            $deleteNicScript = { param($nicName,$rgName) Remove-AzNetworkInterface -Name $nicName -ResourceGroupName $rgName -Force -ErrorAction Stop }
            $success = Invoke-WithRetry -OperationName "Delete NIC $($nic.Name)" -ScriptBlock { & $deleteNicScript $using:nic.Name $using:VM.ResourceGroupName }
            if (-not $success) { $global:cleanupResults.FailedVMs += "$($VM.Name) - NIC:$($nic.Name)"; $global:cleanupResults.Errors++ }
        }

        Remove-AzVM -Name $VM.Name -ResourceGroupName $VM.ResourceGroupName -Force
        Wait-ForVMNicDetach -ResourceGroupName $VM.ResourceGroupName -VMName $VM.Name -TimeoutSeconds 90

        # Remove OS disk
        $osDisk = Get-AzDisk -ResourceGroupName $VM.ResourceGroupName -Name $VM.StorageProfile.OsDisk.Name -ErrorAction SilentlyContinue
        if ($osDisk -and -not $osDisk.ManagedBy) { Remove-AzDisk -ResourceGroupName $VM.ResourceGroupName -Name $osDisk.Name -Force -ErrorAction SilentlyContinue }

        $global:cleanupResults.VMsRemoved++ 
        $global:cleanupResults.VMsRemovedRGs += $VM.ResourceGroupName
    }
    catch { Write-Warning "Failed VM cleanup: $($_.Exception.Message)"; $global:cleanupResults.FailedVMs += "$($VM.Name) (RG: $($VM.ResourceGroupName))"; $global:cleanupResults.Errors++ }
}

#–– VM Cleanup Execution ––
$vmList = Get-AzVM | Where-Object { $_.Tags -and $_.Tags['Cleanup'] -ieq 'Enabled' }
$global:cleanupResults.VMsTargeted = $vmList.Count

if ($vmList) {
    if ($ParallelMode) {
        $removeVMScript = (Get-Item -Path Function:\Remove-VMAndDependencies).ScriptBlock
        $vmList | ForEach-Object -Parallel { param($vm,$removeVMScript) Set-Item -Path Function:\Remove-VMAndDependencies -Value $removeVMScript; Remove-VMAndDependencies -VM $vm } -ArgumentList $using:removeVMScript -ThrottleLimit $ThrottleLimit
    } else { foreach ($vm in $vmList) { Remove-VMAndDependencies -VM $vm } }
} else { Write-Information "No VMs found with Cleanup=Enabled tag." -Tags VM }

#–– Wait for all VMs to settle ––
$elapsed = 0
while ($elapsed -lt $VMDeletionSettleTimeout) {
    $remaining = Get-AzVM | Where-Object { $_.Tags -and $_.Tags['Cleanup'] -ieq 'Enabled' }
    if (-not $remaining -or $remaining.Count -eq 0) { break }
    Write-Information "Waiting for $($remaining.Count) VMs to be removed..."
    Start-Sleep -Seconds 15; $elapsed += 15
}

#–– Wrap-up ––
$global:cleanupResults.EndTime = Get-Date
$global:cleanupResults.EndTimeStr = Format-LondonTime $global:cleanupResults.EndTime
$global:cleanupResults.Duration = [math]::Round((New-TimeSpan -Start $global:cleanupResults.StartTime -End $global:cleanupResults.EndTime).TotalMinutes,2)
Write-Information "Cleanup completed at $($global:cleanupResults.EndTimeStr) (Duration: $($global:cleanupResults.Duration) min)" -Tags CleanupRun

Stop-Transcript

#–– Teams Adaptive Card ––
if ($teamsWebhookUrl) {

    $resourcesByRG = @{}

    function Add-ResourceToRG { param($rgName,$type,$status,$item)
        if (-not $resourcesByRG.ContainsKey($rgName)) { $resourcesByRG[$rgName] = @{ VMs=@{Removed=@();Skipped=@();Failed=@()} } }
        $resourcesByRG[$rgName][$type][$status] += $item
    }

    foreach ($vm in $global:cleanupResults.VMsRemovedRGs) { Add-ResourceToRG -rgName $vm -type 'VMs' -status 'Removed' -item $vm }
    foreach ($vm in $global:cleanupResults.SkippedVMs) { if ($vm -match '\(RG: (.+?)\)$') { Add-ResourceToRG -rgName $matches[1] -type 'VMs' -status 'Skipped' -item $vm } }
    foreach ($vm in $global:cleanupResults.FailedVMs) { if ($vm -match '\(RG: (.+?)\)$') { Add-ResourceToRG -rgName $matches[1] -type 'VMs' -status 'Failed' -item $vm } }

    function Add-CollapsibleSection { param($title,$items,$color="Default")
        if ($items.Count -gt 0) {
            $itemList = $items | ForEach-Object { @{ type="TextBlock"; text="• $_"; wrap=$true; spacing="None" } }
            $toggleId = ($title -replace '[^0-9a-zA-Z]','') + "_toggle_$([guid]::NewGuid().ToString('N'))"
            return @{ type="Container"; items=@(@{ type="ActionSet"; actions=@(@{ type="Action.ToggleVisibility"; title=$title; target=@(@{ elementId=$toggleId }) }) }, @{ type="Container"; id=$toggleId; isVisible=$false; items=$itemList; style=$color }) }
        }
        return $null
    }

    $cardBody=@(@{ type="TextBlock"; text="Azure VM Cleanup Report for subscription $subscriptionName"; weight="Bolder"; size="Large" })
    foreach ($rg in $resourcesByRG.Keys | Sort-Object) {
        $rgData = $resourcesByRG[$rg]
        $removedCount = $rgData.VMs.Removed.Count
        $skippedCount = $rgData.VMs.Skipped.Count
        $failedCount  = $rgData.VMs.Failed.Count
        $rgColor = if ($failedCount -gt 0) {"Attention"} elseif ($skippedCount -gt 0) {"Warning"} else {"Good"}
        $rgTitle = "Resource Group: $rg (✅$removedCount | ⚠️$skippedCount | ❌$failedCount)"
        $rgSectionItems=@()
        foreach ($status in @('Removed','Skipped','Failed')) { $emoji = switch ($status) {"Removed"{"✅"}"Skipped"{"⚠️"}"Failed"{"❌"}}; foreach ($item in $rgData.VMs[$status]) { $rgSectionItems += "$emoji VM: $item" } }
        if ($rgSectionItems.Count -gt 0) { $cardBody += Add-CollapsibleSection -title $rgTitle -items $rgSectionItems -color $rgColor }
    }

    $payload=@{ type="message"; attachments=@(@{ contentType="application/vnd.microsoft.card.adaptive"; content=@{ type="AdaptiveCard"; version="1.5"; body=$cardBody; msteams=@{ width="Full" } }}) } | ConvertTo-Json -Depth 50 -Compress

    try { Invoke-RestMethod -Uri $teamsWebhookUrl -Method Post -Body $payload -ContentType 'application/json'; Write-Information "Teams notification sent." -Tags Teams }
    catch { Write-Warning "Failed to send Teams notification: $_" }
}