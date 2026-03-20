<#
.VERSION    1.0.0
.AUTHOR     Chris Langford
.COPYRIGHT  (c) 2026 Chris Langford. All rights reserved.
.TAGS       Azure Automation, PowerShell Runbook, DevOps
.DESCRIPTION This PowerShell script is designed to start or stop Azure virtual machines based on specified tags. It authenticates using a managed identity, retrieves VMs with the given tags, and performs the requested action in parallel for efficiency.
.SYNOPSIS    Start or stop Azure virtual machines based on tags.
.PARAMETER   Action      The action to perform: "Start" or "Stop".
.PARAMETER   TagName     The name of the tag to filter VMs (optional).
.PARAMETER   TagValue    The value of the tag to filter VMs (optional).
.RuntimeEnvironment PowerShell-7.2
.NOTES
    LASTEDIT    20.03.2026
#>

param (
    [Parameter(Mandatory = $true)]
    [ValidateSet("Start", "Stop")]
    [string] $Action,

    [Parameter(Mandatory = $false)]
    [string] $TagName,

    [Parameter(Mandatory = $false)]
    [string] $TagValue,

    [Parameter(Mandatory = $false)]
    [bool] $DryRun = $false,

    [Parameter(Mandatory=$false)]
    [ValidatePattern('^https://.*')]
    [string] $teamsWebhookUrl
)

# ---------------------- CONFIGURATION ----------------------
$MaxRetries = 3
$ThrottleLimit = 5
$RetryDelaySeconds = 10

#–– Teams webhook from Automation Variable if not provided ––
if (-not $teamsWebhookUrl) {
    try { 
        $teamsWebhookUrl = Get-AutomationVariable -Name 'TeamsWebhookUrlDailyStopStart' 
    }
    catch { 
        Write-Verbose "No Teams webhook URL provided or found." 
    }
}

# ---------------------- AUTH ----------------------
try {
    Connect-AzAccount -Identity
    Write-Information "Azure authentication succeeded." -Tags Authentication
}
catch { Write-Error "Authentication failed: $_"; Stop-Transcript; throw }

# Get current Azure subscription name
$subscriptionName = (Get-AzContext).Subscription.Name

# ---------------------- GET VMs ----------------------
Write-Output "`nRetrieving VMs with the tag $TagName."

if ($TagName) {
    $instances = Get-AzResource -TagName $TagName -TagValue $TagValue -ResourceType "Microsoft.Compute/virtualMachines"
}
else {
    $instances = Get-AzResource -ResourceType "Microsoft.Compute/virtualMachines"
}

if (-not $instances) {
    Write-Output "No VMs found with the tag $TagName."
    return
}

$vmStatusList = foreach ($instance in $instances) {
    $vm = Get-AzVM -ResourceGroupName $instance.ResourceGroupName -Name $instance.Name -Status
    $powerState = ($vm.Statuses.Code[1] -replace "PowerState/", "")

    [PSCustomObject]@{
        ResourceGroup = $instance.ResourceGroupName
        Name          = $instance.Name
        State         = $powerState
    }
}

$vmStatusList | Format-Table -AutoSize

$runningVMs = $vmStatusList | Where-Object { $_.State -in @("running", "starting") }
$stoppedVMs = $vmStatusList | Where-Object { $_.State -in @("deallocated", "deallocating") }

# ---------------------- RETRYABLE ACTION ----------------------
function Invoke-RetryVMAction {
    param (
        [string] $Action,
        [object] $VM,
        [bool]   $DryRun
    )

    if ($DryRun) {
        return [PSCustomObject]@{
            ResourceGroup = $VM.ResourceGroup
            Name          = $VM.Name
            Attempt       = 0
            Success       = $true
            DryRun        = $true
            Error         = $null
            Timestamp     = Get-Date
        }
    }

    for ($i = 1; $i -le $MaxRetries; $i++) {
        try {
            if ($Action -eq "Stop") {
                Stop-AzVM -ResourceGroupName $VM.ResourceGroup -Name $VM.Name -Force -ErrorAction Stop
            }
            elseif ($Action -eq "Start") {
                Start-AzVM -ResourceGroupName $VM.ResourceGroup -Name $VM.Name -ErrorAction Stop
            }

            return [PSCustomObject]@{
                ResourceGroup = $VM.ResourceGroup
                Name          = $VM.Name
                Attempt       = $i
                Success       = $true
                DryRun        = $false
                Error         = $null
                Timestamp     = Get-Date
            }
        }
        catch {
            if ($i -eq $MaxRetries) {
                return [PSCustomObject]@{
                    ResourceGroup = $VM.ResourceGroup
                    Name          = $VM.Name
                    Attempt       = $i
                    Success       = $false
                    DryRun        = $false
                    Error         = $_.Exception.Message
                    Timestamp     = Get-Date
                }
            }

            Start-Sleep -Seconds $RetryDelaySeconds
        }
    }
}

# ---------------------- PARALLEL EXECUTION ----------------------
function Invoke-Parallel {
    param (
        [array] $VMList,
        [string] $Action,
        [bool]   $DryRun
    )

    $jobs = @()

    foreach ($vm in $VMList) {
        while ((Get-Job -State "Running").Count -ge $ThrottleLimit) {
            Start-Sleep -Seconds 2
        }

        $jobs += Start-Job -ScriptBlock {
            param($vm, $Action, $DryRun)
            Invoke-RetryVMAction -Action $Action -VM $vm -DryRun $DryRun
        } -ArgumentList $vm, $Action, $DryRun
    }

    Write-Output "Waiting for jobs..."
    $results = Receive-Job -Job $jobs -Wait -AutoRemoveJob
    return $results
}

# ---------------------- EXECUTE ----------------------
if ($Action -eq "Stop") {
    $targetVMs = $runningVMs
}
else {
    $targetVMs = $stoppedVMs
}

if (-not $targetVMs) {
    Write-Output "No VMs match the required state."
    return
}

$results = Invoke-Parallel -VMList $targetVMs -Action $Action -DryRun $DryRun
$results | Format-Table -AutoSize

# ---------------------- TEAMS ADAPTIVE CARD ----------------------
$successCount = ($results | Where-Object { $_.Success }).Count
$failCount    = ($results | Where-Object { -not $_.Success }).Count

# Build detailed VM rows
$vmRows = @()

foreach ($r in $results) {
    $vmRows += @{
        type = "ColumnSet"
        columns = @(
            @{ type="Column"; width="stretch"; items=@(@{ type="TextBlock"; text=$r.Name }) },
            @{ type="Column"; width="stretch"; items=@(@{ type="TextBlock"; text=$r.ResourceGroup }) },
            @{ type="Column"; width="auto";    items=@(@{ type="TextBlock"; text=$Action }) },
            @{ type="Column"; width="auto";    items=@(@{ type="TextBlock"; text=($(if ($r.Success) {"Success"} else {"Fail"})) }) },
            @{ type="Column"; width="auto";    items=@(@{ type="TextBlock"; text=$r.Attempt }) },
            @{ type="Column"; width="stretch"; items=@(@{ type="TextBlock"; text=($r.Error ?? "") }) }
        )
    }
}

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
                        text = "Azure VM Automated Stop/Start Report for the $subscriptionName Subscription"
                    },
                    @{
                        type = "TextBlock"
                        text = "$(if ($DryRun) { '**DRY RUN - NO CHANGES MADE TO THE ($subscriptionName) SUBSCRIPTION**' } else { 'Execution Summary' })"
                        wrap = $true
                    },
                    @{
                        type = "FactSet"
                        facts = @(
                            @{ title = "Action:"; value = $Action },
                            @{ title = "Successful:"; value = "$successCount" },
                            @{ title = "Failed:"; value = "$failCount" },
                            @{ title = "Timestamp:"; value = (Get-Date).ToString("u") }
                        )
                    },
                    @{
                        type = "TextBlock"
                        text = "Per-VM Details"
                        weight = "Bolder"
                        spacing = "Medium"
                    }
                ) + $vmRows
            }
        }
    )
}

Invoke-RestMethod -Uri $TeamsWebhookUrl -Method Post -Body ($card | ConvertTo-Json -Depth 20)