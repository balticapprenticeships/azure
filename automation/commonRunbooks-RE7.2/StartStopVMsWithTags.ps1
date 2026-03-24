<#
.VERSION    2.1.0
.AUTHOR     Chris Langford
.COPYRIGHT  (c) 2026 Chris Langford. All rights reserved.
.TAGS       Azure Automation, PowerShell Runbook, DevOps
.DESCRIPTION This PowerShell script is designed to start or stop Azure virtual machines based on specified tags. It authenticates using a managed identity, retrieves VMs with the given tags, and performs the requested action in parallel for efficiency.
.SYNOPSIS    Start or stop Azure virtual machines based on tags.
.PARAMETER   Action      The action to perform: "Start" or "Stop".
.PARAMETER   TagName     The name of the tag to filter VMs (optional).
.PARAMETER   TagValue    The value of the tag to filter VMs (optional).
.PARAMETER   DryRun       If set, the script will only simulate actions without making changes.
.PARAMETER   TeamsWebhookUrl The URL of the Microsoft Teams webhook to send the report to (optional).
,Parameter   ThrottleLimit The maximum number of parallel operations to run (default: 5).
.Parameter   TimeoutSeconds The maximum time to wait for each VM to reach the desired state (default: 600 seconds).
.Parameter   PollIntervalSeconds The interval between status checks for each VM (default: 15 seconds).
.Parameter   MaxRetries The maximum number of retries for transient errors (default: 3).
.RuntimeEnvironment PowerShell-7.2
.NOTES
    LASTEDIT    24.03.2026
#>

param (
    [Parameter(Mandatory = $true)]
    [string]$TagName,

    [Parameter(Mandatory = $true)]
    [string]$TagValue,

    [Parameter(Mandatory = $true)]
    [ValidateSet("Start","Stop")]
    [string]$Action,

    [Parameter(Mandatory = $false)]
    [int]$ThrottleLimit = 10,

    [Parameter(Mandatory = $false)]
    [int]$TimeoutSeconds = 600,

    [Parameter(Mandatory = $false)]
    [int]$PollIntervalSeconds = 15,

    [Parameter(Mandatory = $false)]
    [int]$MaxRetries = 3,

    [Parameter(Mandatory=$false)]
    [ValidatePattern('^https://.*')]
    [string] $teamsWebhookUrl,

    [Parameter(Mandatory = $false)]
    [switch]$WhatIf
)

# Convert portal string input to boolean
if ($PSBoundParameters.ContainsKey('WhatIf')) {
    $WhatIf = [bool]::Parse($WhatIf.ToString())
} else {
    $WhatIf = $false
}

# Teams Webhook URL can be passed as a parameter or stored as an Automation Variable
if (-not $teamsWebhookUrl) {
    try { 
        $teamsWebhookUrl = Get-AutomationVariable -Name 'TeamsWebhookUrlDailyStopStart' 
    }
    catch { 
        Write-Verbose "No Teams webhook URL provided or found." 
    }
}

# Authenticate with Managed Identity
try {
    Connect-AzAccount -Identity
    Write-Information "Azure authentication succeeded." -Tags Authentication
}
catch { Write-Error "Authentication failed: $_"; throw }

$subscriptionName = (Get-AzContext).Subscription.Name

# Get VMs and filter by tag
$vms = Get-AzVM -Status
$filteredVMs = $vms | Where-Object {
    $_.Tags.ContainsKey($TagName) -and $_.Tags[$TagName] -eq $TagValue
}

# Retry helper
function Invoke-WithRetry {
    param ([scriptblock]$ScriptBlock, [int]$MaxRetries)
    for ($i=0; $i -le $MaxRetries; $i++) {
        try { return & $ScriptBlock }
        catch {
            if ($i -eq $MaxRetries) { throw $_ }
            Start-Sleep -Seconds ([math]::Pow(2,$i))
        }
    }
}

# Wait for VM desired state
function Wait-ForVMState {
    param ([string]$ResourceGroup, [string]$VMName, [string]$DesiredState, [int]$TimeoutSeconds, [int]$PollIntervalSeconds)
    $elapsed = 0
    while ($elapsed -lt $TimeoutSeconds) {
        $vmStatus = Get-AzVM -ResourceGroupName $ResourceGroup -Name $VMName -Status
        $state = ($vmStatus.Statuses | Where-Object { $_.Code -like "PowerState/*" }).DisplayStatus
        if ($state -eq $DesiredState) { return $true }
        Start-Sleep -Seconds $PollIntervalSeconds
        $elapsed += $PollIntervalSeconds
    }
    return $false
}

# Parallel execution returning structured objects
$results = $filteredVMs | ForEach-Object -Parallel {
    param($vm,$Action,$TimeoutSeconds,$PollIntervalSeconds,$MaxRetries,$WhatIf)

    $vmName = $vm.Name
    $rg = $vm.ResourceGroupName
    $currentState = ($vm.Statuses | Where-Object { $_.Code -like "PowerState/*" }).DisplayStatus

    try {
        if ($Action -eq "Start") {
            if ($currentState -eq "VM running") { return [PSCustomObject]@{ VMName=$vmName; ResourceGroup=$rg; Message="$vmName ($rg) already running"; ResultType="Skipped" } }
            if ($WhatIf) { return [PSCustomObject]@{ VMName=$vmName; ResourceGroup=$rg; Message="$vmName ($rg) would start"; ResultType="WhatIf" } }

            Invoke-WithRetry { Start-AzVM -ResourceGroupName $rg -Name $vmName -NoWait } -MaxRetries $MaxRetries
            $ok = Wait-ForVMState -ResourceGroup $rg -VMName $vmName -DesiredState "VM running" -TimeoutSeconds $TimeoutSeconds -PollIntervalSeconds $PollIntervalSeconds
            if ($ok) { return [PSCustomObject]@{ VMName=$vmName; ResourceGroup=$rg; Message="$vmName ($rg) started successfully"; ResultType="Success" } }
            else { return [PSCustomObject]@{ VMName=$vmName; ResourceGroup=$rg; Message="$vmName ($rg) timeout waiting for running state"; ResultType="Failed" } }
        }
        elseif ($Action -eq "Stop") {
            if ($currentState -eq "VM deallocated") { return [PSCustomObject]@{ VMName=$vmName; ResourceGroup=$rg; Message="$vmName ($rg) already stopped"; ResultType="Skipped" } }
            if ($WhatIf) { return [PSCustomObject]@{ VMName=$vmName; ResourceGroup=$rg; Message="$vmName ($rg) would stop"; ResultType="WhatIf" } }

            Invoke-WithRetry { Stop-AzVM -ResourceGroupName $rg -Name $vmName -Force -NoWait } -MaxRetries $MaxRetries
            $ok = Wait-ForVMState -ResourceGroup $rg -VMName $vmName -DesiredState "VM deallocated" -TimeoutSeconds $TimeoutSeconds -PollIntervalSeconds $PollIntervalSeconds
            if ($ok) { return [PSCustomObject]@{ VMName=$vmName; ResourceGroup=$rg; Message="$vmName ($rg) stopped successfully"; ResultType="Success" } }
            else { return [PSCustomObject]@{ VMName=$vmName; ResourceGroup=$rg; Message="$vmName ($rg) timeout waiting for stopped state"; ResultType="Failed" } }
        }
    } catch {
        return [PSCustomObject]@{ VMName=$vmName; ResourceGroup=$rg; Message="$vmName ($rg) error: $($_.Exception.Message)"; ResultType="Failed" }
    }
} -ThrottleLimit $ThrottleLimit -ArgumentList $Action,$TimeoutSeconds,$PollIntervalSeconds,$MaxRetries,$WhatIf

# Helper to group VMs by Resource Group
function Group-VMsByRG {
    param ($vmObjects)
    $grouped = @{}
    foreach ($vm in $vmObjects) {
        $rg = $vm.ResourceGroup
        if (-not $grouped.ContainsKey($rg)) { $grouped[$rg] = @() }
        $grouped[$rg] += $vm
    }
    return $grouped
}

# Build collapsible sections by RG
function New-CollapsibleSectionByRG {
    param ($title,$vmObjects,$color,$maxVisiblePerRG=5)
    if ($vmObjects.Count -eq 0) { return @() }

    $sections = @()
    $grouped = Group-VMsByRG $vmObjects
    foreach ($rg in $grouped.Keys) {
        $items = $grouped[$rg] | ForEach-Object { $_.Message }
        $visibleItems = $items[0..([math]::Min($maxVisiblePerRG-1,$items.Count-1))]
        $extraCount = $items.Count - $visibleItems.Count
        $text = ($visibleItems -join "`n")
        if ($extraCount -gt 0) { $text += "`n... and $extraCount more" }
        $sections += @{ type="TextBlock"; text="$rg ($title)"; weight="Bolder"; color=$color; size="Medium" }
        $sections += @{ type="TextBlock"; text=$text; wrap=$true }
    }
    return $sections
}

# Aggregate results by ResultType
$successObjs = $results | Where-Object { $_.ResultType -eq "Success" }
$failedObjs  = $results | Where-Object { $_.ResultType -eq "Failed" }
$skippedObjs = $results | Where-Object { $_.ResultType -eq "Skipped" }
$whatIfObjs  = $results | Where-Object { $_.ResultType -eq "WhatIf" }

# Build card body
$cardBody = @(
    @{ type="TextBlock"; size="Large"; weight="Bolder"; text="Azure VM Automated Stop/Start Report for the $subscriptionName Subscription" },
    @{ type="TextBlock"; text="Action: $Action | Tag: $TagName = $TagValue | WhatIf: $WhatIf | Parallel: $ThrottleLimit"; wrap=$true },
    @{ type="FactSet"; facts=@(
        @{ title="Success"; value="$($successObjs.Count)" },
        @{ title="Skipped"; value="$($skippedObjs.Count)" },
        @{ title="Failed"; value="$($failedObjs.Count)" },
        @{ title="WhatIf"; value="$($whatIfObjs.Count)" },
        @{ title="Execution Time"; value="$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" }
    )}
)

# Add RG-grouped collapsible sections
$cardBody += New-CollapsibleSectionByRG "✅ Success" $successObjs "Good"
$cardBody += New-CollapsibleSectionByRG "⚠️ Skipped" $skippedObjs "Warning"
$cardBody += New-CollapsibleSectionByRG "❌ Failed" $failedObjs "Attention"
$cardBody += New-CollapsibleSectionByRG "🔍 WhatIf Results" $whatIfObjs "Accent"

# Send Teams card
$card = @{
    type="message"
    attachments=@(
        @{
            contentType="application/vnd.microsoft.card.adaptive"
            content=@{ type="AdaptiveCard"; version="1.4"; body=$cardBody }
        }
    )
}

Invoke-RestMethod -Method Post -Uri $TeamsWebhookUrl -Body ($card | ConvertTo-Json -Depth 10) -ContentType "application/json"

# Output structured results
[PSCustomObject]@{
    Success = $successObjs | ForEach-Object { $_.Message }
    Skipped = $skippedObjs | ForEach-Object { $_.Message }
    Failed  = $failedObjs  | ForEach-Object { $_.Message }
    WhatIf  = $whatIfObjs  | ForEach-Object { $_.Message }
}