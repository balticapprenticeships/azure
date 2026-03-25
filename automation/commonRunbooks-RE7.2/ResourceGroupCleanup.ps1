<#
.VERSION    4.4.4
.AUTHOR     Chris Langford
.COPYRIGHT  (c) 2026 Chris Langford. All rights reserved.
.TAGS       Azure Automation, PowerShell Runbook, DevOps
.SYNOPSIS   Cleans up Azure resources tagged Cleanup=Enabled, with advanced logging and Teams notifications.
,DESCRIPTION This runbook identifies Azure VMs, NSGs, and VNets tagged with Cleanup=Enabled and attempts to remove them along with their dependencies. It includes robust error handling, retry logic, and sends a detailed summary to Microsoft Teams via webhook.
.PARAMETER cleanupEnabled
    A boolean flag to enable or disable actual cleanup. Set to False for testing/logging without deletion.
.PARAMETER teamsWebhookUrl
    Optional Microsoft Teams webhook URL for posting cleanup summaries. If not provided, it will attempt to retrieve from an Automation Variable named 'TeamWebhookUrlWeeklyCleanup'.
.PARAMETER ParallelMode
    If set to True, VM deletions will be processed in parallel with a throttle limit defined by ThrottleLimit parameter. NSG and VNet cleanup will still be processed sequentially to ensure safe dependency handling.
.PARAMETER ThrottleLimit
    When ParallelMode is enabled, this parameter controls how many VM deletions run concurrently. Default is 5.
.RuntimeEnvironment PowerShell-7.2
.NOTES
    LASTEDIT: 25-03-2026
#>

param(
    [Parameter(Mandatory=$true)]
    [ValidateNotNull()]
    [bool] $cleanupEnabled,

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
    [int] $NICWaitTimeout = 300,

    [Parameter(Mandatory=$false)]
    [int] $VMDeletionSettleTimeout = 300
)

#–– Preferences ––
$ErrorActionPreference = 'Stop'
$WarningPreference     = 'Continue'
$VerbosePreference     = 'SilentlyContinue'
$InformationPreference = 'Continue'

#–– Time helpers ––

# Runtime validation
Write-Output "PSVersion: $($PSVersionTable.PSVersion)"
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
    }
    catch { 
        Write-Verbose "No Teams webhook URL provided or found." 
    }
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
    SkippedNSGs    = @()
    FailedVMs      = @()
    SkippedVNets   = @()
    DependencyVNets= @()
    FailedNSGs     = @()
    Errors         = 0

    VMsRemovedRGs  = @()
    NSGsRemovedRGs = @()
    VNetsRemovedRGs= @()
}

Write-Information "Cleanup run started at $($global:cleanupResults.StartTimeStr)" -Tags CleanupRun

#–– Authenticate ––
try {
    Connect-AzAccount -Identity
    Write-Information "Azure authentication succeeded." -Tags Authentication
}
catch { Write-Error "Authentication failed: $_"; Stop-Transcript; throw }

# Get current Azure subscription name
$subscriptionName = (Get-AzContext).Subscription.Name

#–– Exit if cleanup not enabled ––
if (-not $cleanupEnabled) {
    Write-Information "cleanupEnabled flag is False. No resources will be removed." -Tags CleanupRun
    Stop-Transcript
    return
}

#–– Retry wrapper ––
function Invoke-WithRetry {
    param(
        [Parameter(Mandatory)]
        [scriptblock] $ScriptBlock,

        [int] $MaxRetries = 3,
        [int] $InitialDelaySeconds = 10,
        [string] $OperationName = "Operation"
    )

    $attempt = 1
    $delay = $InitialDelaySeconds

    while ($attempt -le $MaxRetries) {
        try {
            Write-Information "[$OperationName] Attempt $attempt of $MaxRetries." -Tags Retry
            & $ScriptBlock
            Write-Information "[$OperationName] succeeded on attempt $attempt." -Tags Retry
            return $true
        }
        catch {
            Write-Warning "[$OperationName] failed on attempt ${attempt}: $($_.Exception.Message)"

            if ($attempt -eq $MaxRetries) {
                Write-Warning "[$OperationName] exhausted all retries."
                return $false
            }

            Start-Sleep -Seconds $delay
            $attempt++
            $delay = [Math]::Min($delay * 2, 60)
        }
    }
}

#–– Wait helpers ––
function Wait-ForNoNICs {
    param(
        [string] $ResourceGroupName,
        [int] $TimeoutSeconds = $NICWaitTimeout,
        [int] $PollIntervalSeconds = 15
    )
    $elapsed = 0
    while ($elapsed -lt $TimeoutSeconds) {
        $nics = Get-AzNetworkInterface -ResourceGroupName $ResourceGroupName -ErrorAction SilentlyContinue
        if (-not $nics -or $nics.Count -eq 0) {
            Write-Information "No NICs in RG '$ResourceGroupName'." -Tags Wait
            return $true
        }

        # --- Enhanced logging: show why NICs remain ---
        Write-Warning "Waiting: $($nics.Count) NIC(s) remain in RG '$ResourceGroupName'. Logging details..."
        foreach ($nic in $nics) {
            $attachedVm = if ($nic.VirtualMachine) { $nic.VirtualMachine.Id } else { '<none>' }
            $provState  = $nic.ProvisioningState
            $ipConfigs  = ($nic.IpConfigurations | ForEach-Object { $_.Name + ':' + ($_.PrivateIpAddress -or '<no-ip>') }) -join '; '
            $lbPools    = ($nic.IpConfigurations | ForEach-Object { ($_.LoadBalancerBackendAddressPools | ForEach-Object { $_.Id }) -join ',' }) -join '; '
            Write-Information "NIC: $($nic.Name) | ProvisioningState: $provState | AttachedVM: $attachedVm | IPs: $ipConfigs | LBPools: $lbPools" -Tags Wait
        }

        Start-Sleep -Seconds $PollIntervalSeconds
        $elapsed += $PollIntervalSeconds
    }
    Write-Warning "Timeout waiting for NICs in RG '$ResourceGroupName'."
    return $false
}

function Wait-ForNoSubnetsInUse {
    param(
        [string] $ResourceGroupName,
        [string] $VNetName,
        [int] $TimeoutSeconds = 600,
        [int] $PollIntervalSeconds = 15
    )
    $elapsed = 0
    while ($elapsed -lt $TimeoutSeconds) {
        $vnet = Get-AzVirtualNetwork -ResourceGroupName $ResourceGroupName -Name $VNetName -ErrorAction Stop
        $reasons = @()
        $nics = Get-AzNetworkInterface -ResourceGroupName $ResourceGroupName -ErrorAction SilentlyContinue
        if ($vnet.Subnets) {
            foreach ($sub in $vnet.Subnets) {
                if (($nics | Where-Object { $_.IpConfigurations.Subnet.Id -eq $sub.Id }).Count -gt 0) { $reasons += "Subnet '$($sub.Name)' has NICs" }
                if ($sub.Delegations -and $sub.Delegations.Count -gt 0) { $reasons += "Subnet '$($sub.Name)' has delegations" }
            }
        }
        if (Get-AzPrivateEndpoint -ResourceGroupName $ResourceGroupName -ErrorAction SilentlyContinue |
            Where-Object { $_.Subnet.Id -like "$($vnet.Id)/*" }) { $reasons += "Private Endpoints exist" }
        if (Get-AzBastion -ResourceGroupName $ResourceGroupName -ErrorAction SilentlyContinue) { $reasons += "Bastion exists" }
        if (Get-AzFirewall -ResourceGroupName $ResourceGroupName -ErrorAction SilentlyContinue) { $reasons += "Firewall exists" }
        if (Get-AzVirtualNetworkGateway -ResourceGroupName $ResourceGroupName -ErrorAction SilentlyContinue) { $reasons += "Gateway exists" }

        if ($reasons.Count -eq 0) {
            Write-Information "VNet '$VNetName' has no dependencies." -Tags Wait
            return $true
        }

        Write-Information "Waiting on VNet '$VNetName': $($reasons -join '; ')" -Tags Wait
        Start-Sleep -Seconds $PollIntervalSeconds
        $elapsed += $PollIntervalSeconds
    }
    Write-Warning "Timeout waiting for subnet dependencies on VNet '$VNetName'."
    return $false
}

function Wait-ForVMNicDetach {
    param(
        [string] $ResourceGroupName,
        [string] $VMName,
        [int] $TimeoutSeconds = 60,
        [int] $PollIntervalSeconds = 5
    )
    $elapsed = 0
    while ($elapsed -lt $TimeoutSeconds) {
        $nics = Get-AzNetworkInterface -ResourceGroupName $ResourceGroupName -ErrorAction SilentlyContinue |
                Where-Object { $_.VirtualMachine -and $_.VirtualMachine.Id -like "*$VMName" }
        if (-not $nics -or $nics.Count -eq 0) {
            Write-Information "VM '$VMName' detached from NICs."
            return $true
        }
        Write-Information "Waiting for VM '$VMName' to detach from $($nics.Count) NIC(s)..." -Tags Wait
        Start-Sleep -Seconds $PollIntervalSeconds
        $elapsed += $PollIntervalSeconds
    }
    Write-Warning "Timeout waiting for VM '$VMName' to detach from NICs."
    return $false
}

#–– VM + Boot Diagnostics Cleanup ––
function Remove-BootDiagnostics { param($VM)
    try {
        $uri = $VM.DiagnosticsProfile.BootDiagnostics.StorageUri
        if (-not $uri) { return }
        $storageName = [regex]::Match($uri, 'https[s]?://(.+?)\.').Groups[1].Value
        $cleanName   = ($VM.Name -replace '[^0-9a-zA-Z]', '').ToLower()
        $shortName   = $cleanName.Substring(0, [Math]::Min(9, $cleanName.Length))
        $sanitizedId = ($VM.Id -replace '[^0-9a-zA-Z]', '').ToLower()
        $container   = "bootdiagnostics-$shortName-$sanitizedId"
        $sa          = Get-AzStorageAccount -Name $storageName -ErrorAction Stop
        $ctx         = $sa.Context
        Remove-AzStorageContainer -Name $container -Context $ctx -Force -ErrorAction Ignore
        Write-Information "Boot diagnostics cleaned for VM '$($VM.Name)'." -Tags Diagnostics
    }
    catch { 
        Write-Warning "Failed to remove boot diagnostics for '$($VM.Name)': $_"
        $global:cleanupResults.FailedVMs += $VM.Name
        $global:cleanupResults.Errors++ 
    }
}

function Remove-VMAndDependencies { param($VM)
    try {
        Write-Information "Cleaning VM '$($VM.Name)' in RG '$($VM.ResourceGroupName)'." -Tags VM

        # 1. Boot diagnostic
        Remove-BootDiagnostics -VM $VM

        # 2. Network interfaces - enhanced: retry-backed deletion
        $nics = Get-AzNetworkInterface -ResourceGroupName $VM.ResourceGroupName -ErrorAction SilentlyContinue | Where-Object { $_.VirtualMachine -and $_.VirtualMachine.Id -eq $VM.Id }
        foreach ($nic in $nics) {
            Write-Information "Attempting to remove NIC '$($nic.Name)' for VM '$($VM.Name)'."
            $deleteNicScript = {
                param($nicName, $rgName)
                Remove-AzNetworkInterface -Name $nicName -ResourceGroupName $rgName -Force -ErrorAction Stop
            }
            $success = Invoke-WithRetry -OperationName "Delete NIC $($nic.Name)" -MaxRetries 4 -InitialDelaySeconds 10 -ScriptBlock { & $deleteNicScript $using:nic.Name $using:VM.ResourceGroupName }
            if (-not $success) {
                Write-Warning "Failed to delete NIC '$($nic.Name)' after retries."
                $global:cleanupResults.FailedVMs += "$($VM.Name) - NIC:$($nic.Name)"
                $global:cleanupResults.Errors++
            }
        }

        # 3. VM itself
        Write-Information "Removing VM '$($VM.Name)'."
        Remove-AzVM -Name $VM.Name -ResourceGroupName $VM.ResourceGroupName -Force

        # Wait briefly for platform detach before attempting disk/NIC cleanup
        Wait-ForVMNicDetach -ResourceGroupName $VM.ResourceGroupName -VMName $VM.Name -TimeoutSeconds 90

        # 4. OS Disk (only if not managed by another resource)
        $osDiskName = $VM.StorageProfile.OsDisk.Name
        $osDisk = Get-AzDisk -ResourceGroupName $VM.ResourceGroupName -Name $osDiskName -ErrorAction SilentlyContinue
        if ($osDisk -and -not $osDisk.ManagedBy) {
            Write-Information "Removing OS Disk '$osDiskName' for VM '$($VM.Name)'." 
            Remove-AzDisk -ResourceGroupName $VM.ResourceGroupName -Name $osDiskName -Force -ErrorAction SilentlyContinue 
        }

        Write-Information "VM '$($VM.Name)' and dependencies removed successfully."
        $global:cleanupResults.VMsRemoved++
        $global:cleanupResults.VMsRemovedRGs += $VM.ResourceGroupName
    }
    catch { 
        Write-Warning "Error cleaning VM '$($VM.Name)': $_"
        $global:cleanupResults.FailedVMs += $VM.Name
        $global:cleanupResults.Errors++ }
}

#–– NSG cleanup ––
function Remove-NSGs {
    $nsgs = Get-AzNetworkSecurityGroup | Where-Object { $_.Tags -and $_.Tags['Cleanup'] -ieq 'Enabled' }
    foreach ($nsg in $nsgs) {
        try {
            $nics = Get-AzNetworkInterface -ResourceGroupName $nsg.ResourceGroupName | Where-Object { $_.NetworkSecurityGroup -and $_.NetworkSecurityGroup.Id -eq $nsg.Id }
            foreach ($nic in $nics) { Invoke-WithRetry -OperationName "Detach NSG from NIC $($nic.Name)" -ScriptBlock { $nic.NetworkSecurityGroup = $null; Set-AzNetworkInterface -NetworkInterface $nic -ErrorAction Stop } }
            $vnets = Get-AzVirtualNetwork -ResourceGroupName $nsg.ResourceGroupName
            foreach ($vnet in $vnets) {
                $changed = $false
                foreach ($sub in $vnet.Subnets) {
                    if ($sub.NetworkSecurityGroup -and $sub.NetworkSecurityGroup.Id -eq $nsg.Id) { $sub.NetworkSecurityGroup = $null; $changed = $true }
                }
                if ($changed) { Set-AzVirtualNetwork -VirtualNetwork $vnet }
            }
            Start-Sleep -Seconds 15
            Invoke-WithRetry -OperationName "Delete NSG $($nsg.Name)" -ScriptBlock { Remove-AzNetworkSecurityGroup -Name $nsg.Name -ResourceGroupName $nsg.ResourceGroupName -Force -ErrorAction Stop }
            $global:cleanupResults.NSGsRemovedRGs += "$($nsg.Name) (RG: $($nsg.ResourceGroupName))"
        }
        catch { 
            Write-Warning "Failed NSG '$($nsg.Name)': $($_.Exception.Message)"
            $global:cleanupResults.FailedNSGs += "$($nsg.Name) — $($_.Exception.Message)"
            $global:cleanupResults.Errors++ 
        }
    }
}

#–– Safe Network Cleanup ––
function Invoke-NetworkCleanupSafely {

    # Determine RGs based on tagged resources, not parallel state
    $resourceGroups = Get-AzResource |
        Where-Object { $_.Tags -and $_.Tags['Cleanup'] -ieq 'Enabled' } |
        Select-Object -ExpandProperty ResourceGroupName -Unique

    foreach ($rg in $resourceGroups) {
        try {
            Write-Information "Starting network cleanup for RG '$rg'." -Tags Network

            if (-not (Wait-ForNoNICs -ResourceGroupName $rg -TimeoutSeconds $NICWaitTimeout)) {
                Write-Warning "Skipping NSG/VNet cleanup for RG '$rg' due to NIC timeout."
                $global:cleanupResults.Errors++
                continue
            }

            # ---- NSGs ----
            Remove-NSGs

            # ---- VNets ----
            $vnets = Get-AzVirtualNetwork -ResourceGroupName $rg |
                    Where-Object { $_.Tags -and $_.Tags['Cleanup'] -ieq 'Enabled' }

            foreach ($vnet in $vnets) {

                if (-not (Wait-ForNoSubnetsInUse -ResourceGroupName $rg -VNetName $vnet.Name)) {
                    $msg = "$($vnet.Name) (RG: $rg) - Timeout waiting for dependencies"
                    Write-Warning $msg
                    $global:cleanupResults.DependencyVNets += $msg
                    $global:cleanupResults.Errors++
                    continue
                }

                $success = Invoke-WithRetry -OperationName "Delete VNet $($vnet.Name)" -MaxRetries 5 -InitialDelaySeconds 15 -ScriptBlock {
                    Remove-AzVirtualNetwork -Name $vnet.Name -ResourceGroupName $rg -Force -ErrorAction Stop
                }

                if ($success) {
                    $global:cleanupResults.VNetsRemovedRGs += "$($vnet.Name) (RG: $rg)"
                }
                else {
                    $msg = "$($vnet.Name) (RG: $rg) - Delete failed after retries"
                    $global:cleanupResults.SkippedVNets += $msg
                    $global:cleanupResults.Errors++
                }
            }
        }
        catch {
            Write-Warning "Network cleanup failed for RG '$rg': $($_.Exception.Message)"
            $global:cleanupResults.Errors++
        }
    }
}

#–– VM Cleanup Execution ––
$vmList = Get-AzVM | Where-Object { $_.Tags -and $_.Tags['Cleanup'] -ieq 'Enabled' }
$global:cleanupResults.VMsTargeted = $vmList.Count

if ($vmList) {

    if ($ParallelMode) {

        $removeVMScript   = (Get-Item -Path Function:\Remove-VMAndDependencies).ScriptBlock
        $removeBootScript = (Get-Item -Path Function:\Remove-BootDiagnostics).ScriptBlock

        $vmList | ForEach-Object -Parallel {
            param($vm, $removeVMScript, $removeBootScript)

            Set-Item -Path Function:\Remove-BootDiagnostics -Value $removeBootScript
            Set-Item -Path Function:\Remove-VMAndDependencies -Value $removeVMScript

            Remove-VMAndDependencies -VM $vm

        } -ArgumentList $using:removeVMScript, $using:removeBootScript -ThrottleLimit $ThrottleLimit
    }
    else {
        foreach ($vm in $vmList) {
            Remove-VMAndDependencies -VM $vm
        }
    }
}
else {
    Write-Information "No VMs found with Cleanup=Enabled tag." -Tags VM
}

#–– Ensure network cleanup waits for VM deletions to settle ––
function Wait-ForAllTargetVMsGone {
    param([int] $TimeoutSeconds = $VMDeletionSettleTimeout, [int] $PollIntervalSeconds = 15)
    $elapsed = 0
    while ($elapsed -lt $TimeoutSeconds) {
        $remaining = Get-AzVM | Where-Object { $_.Tags -and $_.Tags['Cleanup'] -ieq 'Enabled' }
        if (-not $remaining -or $remaining.Count -eq 0) { return $true }
        Write-Information "Waiting for $($remaining.Count) targeted VM(s) to be removed before network cleanup..."
        Start-Sleep -Seconds $PollIntervalSeconds
        $elapsed += $PollIntervalSeconds
    }
    Write-Warning "Timeout waiting for targeted VMs to be removed; proceeding with network cleanup."
    return $false
}

# Wait for VMs to settle before network cleanup
Wait-ForAllTargetVMsGone -TimeoutSeconds $VMDeletionSettleTimeout

#–– Safe NSG + VNet Cleanup ––
try {
    Invoke-NetworkCleanupSafely
}
catch {
    Write-Warning "Network cleanup failed unexpectedly: $($_.Exception.Message)"
    $global:cleanupResults.Errors++
}

#–– Wrap-up ––
$global:cleanupResults.EndTime  = Get-Date
$global:cleanupResults.EndTimeStr = Format-LondonTime $global:cleanupResults.EndTime
$global:cleanupResults.Duration = [math]::Round((New-TimeSpan -Start $global:cleanupResults.StartTime -End $global:cleanupResults.EndTime).TotalMinutes, 2)
Write-Information "Cleanup completed at $($global:cleanupResults.EndTimeStr) (Duration: $($global:cleanupResults.Duration) min)" -Tags CleanupRun

Stop-Transcript

#–– Teams Notification with RG Summary Counts, Collapsible Sections, and Color Coding ––
if ($teamsWebhookUrl) {

    $resourcesByRG = @{}
    $dependencyIssuesByRG = @{}

    function Add-ResourceToRG {
        param($rgName, $type, $status, $item, $isDependencyIssue=$false)
        if (-not $resourcesByRG.ContainsKey($rgName)) {
            $resourcesByRG[$rgName] = @{
                VMs   = @{ Removed=@(); Skipped=@(); Failed=@() }
                NSGs  = @{ Removed=@(); Skipped=@(); Failed=@() }
                VNets = @{ Removed=@(); Skipped=@(); Failed=@() }
            }
            $dependencyIssuesByRG[$rgName] = @()
        }
        $resourcesByRG[$rgName][$type][$status] += $item
        if ($isDependencyIssue -and $status -eq 'Failed') {
            $dependencyIssuesByRG[$rgName] += $item
        }
    }

    # Populate RG dictionary
    foreach ($entry in @(
        @{List=$global:cleanupResults.VMsRemovedRGs; Type='VMs'; Status='Removed'},
        @{List=$global:cleanupResults.FailedVMs;    Type='VMs'; Status='Failed'},
        @{List=$global:cleanupResults.SkippedVMs;   Type='VMs'; Status='Skipped'},
        @{List=$global:cleanupResults.NSGsRemovedRGs; Type='NSGs'; Status='Removed'},
        @{List=$global:cleanupResults.FailedNSGs;    Type='NSGs'; Status='Failed'},
        @{List=$global:cleanupResults.VNetsRemovedRGs; Type='VNets'; Status='Removed'},
        @{List=$global:cleanupResults.SkippedVNets;   Type='VNets'; Status='Skipped'},
        @{List=$global:cleanupResults.DependencyVNets; Type='VNets'; Status='Failed'; IsDependencyIssue=$true}
    )) {
        foreach ($item in $entry.List) {
            if ($item -match '\(RG: (.+?)\)$') {
                $rgName = $matches[1]
                $name = $item -replace " \(RG: .+\)$", ""
                $isDep = $entry.PSObject.Properties.Match('IsDependencyIssue').Count -gt 0 -and $entry.IsDependencyIssue
                Add-ResourceToRG -rgName $rgName -type $entry.Type -status $entry.Status -item $name -isDependencyIssue $isDep
            }
        }
    }

    # Collapsible section function
    function Add-CollapsibleSection {
        param($title, $items, $color="Default")
        if ($items.Count -gt 0) {
            $itemList = $items | ForEach-Object { @{ type="TextBlock"; text="• $_"; wrap=$true; spacing="None" } }
            $toggleId = ($title -replace '[^0-9a-zA-Z]', '') + "_toggle_$([guid]::NewGuid().ToString('N'))"
            return @{
                type="Container";
                items=@(
                    @{ type="ActionSet"; actions=@(@{ type="Action.ToggleVisibility"; title=$title; target=@(@{ elementId=$toggleId }) }) },
                    @{ type="Container"; id=$toggleId; isVisible=$false; items=$itemList; style=$color }
                )
            }
        }
        return $null
    }

    # Adaptive Card body
    $cardBody = @(
        @{ type="TextBlock"; text="**Azure Cleanup Run Report for subscription $subscriptionName**"; weight="Bolder"; size="Large" },
        @{ type="TextBlock"; text="Execution Mode: $(if ($ParallelMode){ "Parallel (ThrottleLimit=$ThrottleLimit)" }else{"Sequential"})"; weight="Bolder"; size="Small"; wrap=$true },
        @{ type="FactSet"; facts=@(
            @{ title="Start:"; value=$global:cleanupResults.StartTimeStr },
            @{ title="End:"; value=$global:cleanupResults.EndTimeStr },
            @{ title="Duration:"; value="$($global:cleanupResults.Duration) min" },
            @{ title="VMs targeted:"; value="$($global:cleanupResults.VMsTargeted)" },
            @{ title="Errors:"; value="$($global:cleanupResults.Errors)" }
        )}
    )

    # Build RG-specific sections with inline summary and color coding
    foreach ($rg in $resourcesByRG.Keys | Sort-Object) {
        $rgData = $resourcesByRG[$rg]

        # Compute summary counts
        $removedCount = ($rgData.VMs.Removed.Count + $rgData.NSGs.Removed.Count + $rgData.VNets.Removed.Count)
        $skippedCount = ($rgData.VMs.Skipped.Count + $rgData.NSGs.Skipped.Count + $rgData.VNets.Skipped.Count)
        $failedCount  = ($rgData.VMs.Failed.Count + $rgData.NSGs.Failed.Count + $rgData.VNets.Failed.Count)

        # Determine RG color
        $rgColor = if ($failedCount -gt 0) { "Attention" } elseif ($skippedCount -gt 0) { "Warning" } else { "Good" }

        # RG header with inline counts
        $rgTitle = "Resource Group: $rg (✅$removedCount | ⚠️$skippedCount | ❌$failedCount)"

        $rgSectionItems = @()

        # Dependency Issues
        $depIssues = $dependencyIssuesByRG[$rg]
        foreach ($issue in $depIssues) {
            $rgSectionItems += "❌ Dependency Issue: $issue"
        }

        # VMs, NSGs, VNets
        foreach ($type in @('VMs','NSGs','VNets')) {
            foreach ($status in @('Removed','Skipped','Failed')) {
                $items = $rgData[$type][$status]
                $emoji = switch ($status) { "Removed" {"✅"} "Skipped" {"⚠️"} "Failed" {"❌"} }
                foreach ($item in $items) {
                    $rgSectionItems += "$emoji $($type): $($item)"
                }
            }
        }

        if ($rgSectionItems.Count -gt 0) {
            $cardBody += Add-CollapsibleSection -title $rgTitle -items $rgSectionItems -color $rgColor
        }
    }

    # Build JSON payload
    $payload = @{
        type       = "message"
        attachments= @(@{
            contentType="application/vnd.microsoft.card.adaptive"
            content=@{ type="AdaptiveCard"; version="1.5"; body=$cardBody; msteams=@{ width="Full" } }
        })
    } | ConvertTo-Json -Depth 50 -Compress

    # Send Teams notification
    try {
        Invoke-RestMethod -Uri $teamsWebhookUrl -Method Post -Body $payload -ContentType 'application/json'
        Write-Information "Teams notification sent successfully at $(Format-LondonTime (Get-Date))." -Tags Teams
    }
    catch {
        Write-Warning "Failed to send Teams notification at $(Format-LondonTime (Get-Date)): $_"
    }
}
#–– End of Script ––