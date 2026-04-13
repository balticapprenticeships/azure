<#
.VERSION    2.4.0
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
    LASTEDIT    13.04.2026
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
    [ValidatePattern('^[0-9a-fA-F-]{36}$')]
    [string] $SubscriptionId,

    [Parameter(Mandatory=$false)]
    [ValidatePattern('^https://.*')]
    [string] $teamsWebhookUrl,

    [Parameter(Mandatory = $false)]
    [int]$GlobalTimeoutSeconds = 3600,

    # Idempotency lock tag
    [Parameter(Mandatory = $false)]
    [string]$LockTagName = "AutomationLock",

    [Parameter(Mandatory = $false)]
    [int]$LockExpiryMinutes = 30,

    [Parameter(Mandatory = $false)]
    [bool]$WhatIf =$false
)

# Runtime validation
Write-Output "PSVersion: $($PSVersionTable.PSVersion)"

# Throttle protection: cap parallelism to reduce ARM throttling risk
$ThrottleLimit = [math]::Min($ThrottleLimit, 5)

# Global deadline for per-VM cancellation
$RunbookDeadline  = (Get-Date).AddSeconds($GlobalTimeoutSeconds)

# Teams Webhook URL can be passed as a parameter or stored as an Automation Variable
if (-not $teamsWebhookUrl) {
    try { 
        $teamsWebhookUrl = Get-AutomationVariable -Name 'TeamsWebhookUrlDailyStopStart' 
    }
    catch { 
        Write-Verbose "No Teams webhook URL provided or found." 
    }
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

$subscriptionName = (Get-AzContext).Subscription.Name

# Get VMs and filter by tag
$vms = Get-AzVM -Status
$filteredVMs = $vms | Where-Object {
    $_.Tags.ContainsKey($TagName) -and $_.Tags[$TagName] -eq $TagValue
}

# Parallel execution returning structured objects
$results = $filteredVMs | ForEach-Object -Parallel {
    function Invoke-WithRetry {
        param (
            [scriptblock]$ScriptBlock,
            [int]$MaxRetries
        )

        for ($i = 0; $i -le $MaxRetries; $i++) {
            try {
                return & $ScriptBlock
            } catch {
                if ($i -eq $MaxRetries) { throw }
                Start-Sleep -Seconds ([math]::Min(60, [math]::Pow(2, $i) + (Get-Random -Minimum 1 -Maximum 5)))
            }
        }
    }

    function Wait-ForVMState {
        param (
            [string]$ResourceGroup,
            [string]$VMName,
            [string]$DesiredState,
            [int]$TimeoutSeconds,
            [int]$PollIntervalSeconds,
            [datetime]$Deadline
        )

        $elapsed = 0
        while ($elapsed -lt $TimeoutSeconds) {
            if ((Get-Date) -gt $Deadline) { return $false }

            $vmStatus = Get-AzVM -ResourceGroupName $ResourceGroup -Name $VMName -Status -ErrorAction Stop
            $state = ($vmStatus.Statuses | Where-Object Code -like "PowerState/*").DisplayStatus
            if ($state -eq $DesiredState) { return $true }

            Start-Sleep -Seconds $PollIntervalSeconds
            $elapsed += $PollIntervalSeconds
        }
        return $false
    }


    $vm = $_
    $vmName = $vm.Name
    $rg = $vm.ResourceGroupName
    $vmId = $vm.Id

    # Per-VM cancellation: skip work if global deadline exceeded
    if ((Get-Date) -gt $using:RunbookDeadline) {
        return [PSCustomObject]@{
            VMName        = $vmName
            ResourceGroup = $rg
            Message       = "Runbook global timeout exceeded — VM skipped"
            ResultType    = "Skipped"
        }
    }

    # Determine current state (snapshot from initial Get-AzVM -Status)
    $currentState = ($vm.Statuses | Where-Object { $_.Code -like "PowerState/*" }).DisplayStatus

    # If WhatIf, do not lock—just report intent
    if ($using:WhatIf) {
        if ($using:Action -eq "Start") {
            $msg = if ($currentState -eq "VM running") { "$vmName ($rg) already running" } else { "$vmName ($rg) would start" }
        } else {
            $msg = if ($currentState -eq "VM deallocated") { "$vmName ($rg) already stopped" } else { "$vmName ($rg) would stop" }
        }

        return [PSCustomObject]@{
            VMName        = $vmName
            ResourceGroup = $rg
            Message       = $msg
            ResultType    = if ($msg -like "*already*") { "Skipped" } else { "WhatIf" }
        }
    }

    # ----- Idempotency with auto-expiring lock tag -----
    # Re-read tags from Azure to avoid stale $vm.Tags
    try {
        $res = Get-AzResource -ResourceId $vmId -ErrorAction Stop
        $tags = $res.Tags
    } catch {
        return [PSCustomObject]@{
            VMName        = $vmName
            ResourceGroup = $rg
            Message       = "$vmName ($rg) error reading tags: $($_.Exception.Message)"
            ResultType    = "Failed"
        }
    }

    $lockExists  = $false
    $lockExpired = $false

    if ($tags -and $tags.ContainsKey($using:LockTagName)) {
        $lockExists = $true

        $lockTime = $null
        if ([datetime]::TryParse($tags[$using:LockTagName], [ref]$lockTime)) {
            $age = (Get-Date).ToUniversalTime() - $lockTime.ToUniversalTime()
            if ($age -gt [TimeSpan]::FromMinutes($using:LockExpiryMinutes)) {
                $lockExpired = $true
            }
        } else {
            # Unparsable lock value—treat as stale so it doesn't block forever
            $lockExpired = $true
        }
    }

    if ($lockExists -and -not $lockExpired) {
        return [PSCustomObject]@{
            VMName        = $vmName
            ResourceGroup = $rg
            Message       = "$vmName ($rg) is locked by another run (lock active) — skipped"
            ResultType    = "Skipped"
        }
    }

    # Acquire/overwrite lock (UTC ISO-8601)
    $lockAcquired = $false
    $lockValue = (Get-Date).ToUniversalTime().ToString("o")

    try {
        Update-AzTag -ResourceId $vmId -Tag @{ ($using:LockTagName) = $lockValue } -Operation Merge -ErrorAction Stop | Out-Null
        $lockAcquired = $true

        # Small jitter to spread ARM calls a bit
        Start-Sleep -Milliseconds (Get-Random -Minimum 50 -Maximum 250)

        if ($using:Action -eq "Start") {

            if ($currentState -eq "VM running") {
                return [PSCustomObject]@{
                    VMName        = $vmName
                    ResourceGroup = $rg
                    Message       = "$vmName ($rg) already running"
                    ResultType    = "Skipped"
                }
            }

            Invoke-WithRetry {
                Start-AzVM -ResourceGroupName $rg -Name $vmName -NoWait -ErrorAction Stop | Out-Null
            } $using:MaxRetries

            $ok = Wait-ForVMState `
                $rg `
                $vmName `
                "VM running" `
                $using:TimeoutSeconds `
                $using:PollIntervalSeconds `
                $using:RunbookDeadline

            return [PSCustomObject]@{
                VMName        = $vmName
                ResourceGroup = $rg
                Message       = if ($ok) { "$vmName ($rg) started successfully" } else { "$vmName ($rg) timeout waiting for running state" }
                ResultType    = if ($ok) { "Success" } else { "Failed" }
            }
        }

        if ($using:Action -eq "Stop") {

            if ($currentState -eq "VM deallocated") {
                return [PSCustomObject]@{
                    VMName        = $vmName
                    ResourceGroup = $rg
                    Message       = "$vmName ($rg) already stopped"
                    ResultType    = "Skipped"
                }
            }

            Invoke-WithRetry {
                Stop-AzVM -ResourceGroupName $rg -Name $vmName -Force -NoWait -ErrorAction Stop | Out-Null
            } $using:MaxRetries

            $ok = Wait-ForVMState `
                $rg `
                $vmName `
                "VM deallocated" `
                $using:TimeoutSeconds `
                $using:PollIntervalSeconds `
                $using:RunbookDeadline

            return [PSCustomObject]@{
                VMName        = $vmName
                ResourceGroup = $rg
                Message       = if ($ok) { "$vmName ($rg) stopped successfully" } else { "$vmName ($rg) timeout waiting for stopped state" }
                ResultType    = if ($ok) { "Success" } else { "Failed" }
            }
        }

        return [PSCustomObject]@{
            VMName        = $vmName
            ResourceGroup = $rg
            Message       = "$vmName ($rg) unknown action: $($using:Action)"
            ResultType    = "Failed"
        }

    } catch {
        return [PSCustomObject]@{
            VMName        = $vmName
            ResourceGroup = $rg
            Message       = "$vmName ($rg) error: $($_.Exception.Message)"
            ResultType    = "Failed"
        }
    } finally {
        if ($lockAcquired) {
            try {
                Update-AzTag -ResourceId $vmId -Tag @{ ($using:LockTagName) = "" } -Operation Delete -ErrorAction Stop | Out-Null
            } catch {
                Write-Output "WARN: Failed to remove lock tag from $vmName ($rg): $($_.Exception.Message)"
            }
        }
    }

} -ThrottleLimit $ThrottleLimit

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
        @{ title="Execution Time"; value="$(Get-Date -Format 'dd-MM-yyy HH:mm:ss')" }
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
            content=@{ type="AdaptiveCard"; version="1.5"; body=$cardBody; msteams=@{ width="Full" } }
        }
    )
}

Invoke-RestMethod -Method Post -Uri $teamsWebhookUrl -Body ($card | ConvertTo-Json -Depth 10) -ContentType "application/json"

# Output structured results
[PSCustomObject]@{
    Success = $successObjs | ForEach-Object { $_.Message }
    Skipped = $skippedObjs | ForEach-Object { $_.Message }
    Failed  = $failedObjs  | ForEach-Object { $_.Message }
    WhatIf  = $whatIfObjs  | ForEach-Object { $_.Message }
}