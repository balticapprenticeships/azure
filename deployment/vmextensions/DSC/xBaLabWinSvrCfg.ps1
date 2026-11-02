################################################################
# Script to configure Windows lab environment using DSC        #
# Author: Chris Langford                                       #
# Version: 7.0.1                                               #
################################################################

Configuration xBaICTSupC1LabCfg {
    [CmdletBinding()]

    Param (
        
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.PSCredential]
        [System.Management.Automation.Credential()]
        $Credential
    )

    Import-DscResource -ModuleName xPSDesiredStateConfiguration

    $features = @("Hyper-V", "RSAT-Hyper-V-Tools", "Hyper-V-Tools", "Hyper-V-PowerShell")

    Node localhost {

        LocalConfigurationManager {
            RebootNodeIfNeeded = $true
        }

        # This resource block create a local user
        xUser "CreateUserAccount" {
            Ensure = "Present"
            Username = Split-Path -Path $Credential.Username -Leaf
            Password = $Credential
            FullName = "Baltic Apprentice"
            Description = "Baltic Apprentice"
            PasswordNeverExpires = $true
            PasswordChangeRequired = $false
            PasswordChangeNotAllowed = $true
        }

        # This resource block adds user to a spacific group
        xGroup "AddToRemoteDesktopUserGroup"
        {
            GroupName = "Remote Desktop Users"
            Ensure = "Present"
            MembersToInclude = Split-Path -Path $Credential.Username -Leaf
            DependsOn = "[xUser]CreateUserAccount"
        }

        # This resource block adds user to a spacific group
        xGroup "AddToHyperVAdministratorGroup"
        {
            GroupName = "Hyper-V Administrators"
            Ensure = "Present"
            MembersToInclude = Split-Path -Path $Credential.Username -Leaf
            DependsOn = "[xUser]CreateUserAccount"
        }

        # This resource block ensures that a Windows Features (Roles) is present
        xWindowsFeatureSet "AddHyperVFeatures"
        {
            Name = $features
            Ensure = "Present"
            IncludeAllSubFeature = $true
        }

        # This resource block ensures that the file is executed
        xScript "SetDefaultVirtualHardDiskLocation"
        {
            SetScript = { 
                Set-VMHost -VirtualHardDiskPath "C:\Users\Public\Documents\Hyper-V\Virtual hard disks"
            }
            TestScript = { $false }
            GetScript = { 
                # Do Nothing
            }
            DependsOn = "[xWindowsFeatureSet]AddHyperVFeatures"
        }

        # This resource block ensures that the file is executed
        xScript "RunvSwitchForNestedVms"
        {
            SetScript = { 
                New-VMSwitch -SwitchName "vSwitch" -SwitchType Private
            }
            TestScript = { $false }
            GetScript = { 
                # Do Nothing
            }
            DependsOn = "[xWindowsFeatureSet]AddHyperVFeatures"
        }

        xScript "RunCreateVms"
        {
            SetScript = { 
                New-VM -Name "Server01" -MemoryStartupBytes 1GB -Generation 2 -BootDevice VHD -VHDPath "C:\Users\Public\Documents\Hyper-V\Virtual hard disks\SupportITArchitecture-P1\Server01.vhdx" -SwitchName "vSwitch"
                New-VM -Name "AsimLaptop" -MemoryStartupBytes 1GB -Generation 1 -BootDevice VHD -VHDPath "C:\Users\Public\Documents\Hyper-V\Virtual hard disks\SupportITArchitecture-P1\AsimLaptop.vhdx" -SwitchName "vSwitch"
                New-VM -Name "ApprenticeLaptop" -MemoryStartupBytes 2GB -Generation 1 -BootDevice VHD -VHDPath "C:\Users\Public\Documents\Hyper-V\Virtual hard disks\SupportITArchitecture-P1\ApprenticeLaptop.vhdx" -SwitchName "vSwitch"
                New-VM -Name "CallumPC" -MemoryStartupBytes 1GB -Generation 1 -BootDevice VHD -VHDPath "C:\Users\Public\Documents\Hyper-V\Virtual hard disks\SupportITArchitecture-P1\CallumPC.vhdx" -SwitchName "vSwitch"
                New-VM -Name "KiaraLaptop" -MemoryStartupBytes 1GB -Generation 1 -BootDevice VHD -VHDPath "C:\Users\Public\Documents\Hyper-V\Virtual hard disks\SupportITArchitecture-P1\KiaraLaptop.vhdx" -SwitchName "vSwitch"
                New-VM -Name "MariaPC" -MemoryStartupBytes 1GB -Generation 1 -BootDevice VHD -VHDPath "C:\Users\Public\Documents\Hyper-V\Virtual hard disks\SupportITArchitecture-P1\MariaPC.vhdx" -SwitchName "vSwitch"
            }
            TestScript = { $false }
            GetScript = {  
                # Do Nothing
            }
            DependsOn = "[xWindowsFeatureSet]AddHyperVFeatures"
        }

        # This resource block ensures that the file or command is executed
        xScript "SetRdpTimeZone"
        {
            SetScript = {
                New-ItemProperty -ErrorAction SilentlyContinue -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services" -Name "fEnableTimeZoneRedirection" -Value "1" -PropertyType DWORD -Force
            }
            TestScript = { $false }
            GetScript = { 
                # Do Nothing
            }
        }

        # This resource block sets Performance Options -> Visual Effects to
        # "Adjust for best performance" for every user: the Default profile (so any
        # account created later inherits it), every profile already on disk, and any
        # hive that is currently loaded. These are per-user (HKCU) settings, so there
        # is no single machine-wide value to set.
        xScript "SetVisualEffectsBestPerformance"
        {
            SetScript = {
                $ErrorActionPreference = "Stop"

                function Set-VisualEffects {
                    param ([string] $HiveRoot)

                    # The values Windows writes itself when "Adjust for best performance"
                    # is picked. Declared in here so the function does not rely on
                    # variables in the caller's scope.
                    $dwordValues = @{
                        "Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects" = @{ VisualFXSetting = 2 }
                        "Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"      = @{ ListviewAlphaSelect = 0; ListviewShadow = 0; TaskbarAnimations = 0; IconsOnly = 1 }
                        "Software\Microsoft\Windows\DWM"                                   = @{ EnableAeroPeek = 0; AlwaysHibernateThumbnails = 0 }
                    }

                    $stringValues = @{
                        "Control Panel\Desktop"               = @{ DragFullWindows = "0"; FontSmoothing = "0" }
                        "Control Panel\Desktop\WindowMetrics" = @{ MinAnimate = "0" }
                    }

                    $binaryValues = @{
                        "Control Panel\Desktop" = @{ UserPreferencesMask = [byte[]](0x90, 0x12, 0x03, 0x80, 0x10, 0x00, 0x00, 0x00) }
                    }

                    foreach ($set in @(
                        @{ Values = $dwordValues;  Type = "DWord"  },
                        @{ Values = $stringValues; Type = "String" },
                        @{ Values = $binaryValues; Type = "Binary" }
                    )) {
                        foreach ($subKey in $set.Values.Keys) {
                            $keyPath = Join-Path -Path $HiveRoot -ChildPath $subKey
                            if (-not (Test-Path -Path $keyPath)) {
                                New-Item -Path $keyPath -Force | Out-Null
                            }
                            foreach ($name in $set.Values[$subKey].Keys) {
                                New-ItemProperty -Path $keyPath -Name $name -Value $set.Values[$subKey][$name] -PropertyType $set.Type -Force | Out-Null
                            }
                        }
                    }
                }

                # Hives of real users that are already loaded. The S-1-5-21-* filter
                # deliberately skips the built-in service accounts (S-1-5-18/19/20) and
                # .DEFAULT, which is an alias for LocalSystem rather than the Default
                # profile and so has no bearing on accounts created later.
                $loadedSids = @(Get-ChildItem -Path "Registry::HKEY_USERS" |
                    Where-Object { $_.PSChildName -like "S-1-5-21-*" -and $_.PSChildName -notlike "*_Classes" } |
                    Select-Object -ExpandProperty PSChildName)

                foreach ($sid in $loadedSids) {
                    Set-VisualEffects -HiveRoot "Registry::HKEY_USERS\$sid"
                }

                # Profiles on disk whose hive is not loaded, plus the Default profile.
                # The value under ProfileList is ProfileImagePath, not ProfilePath. The
                # SID filter runs before it is read, so entries that do not carry it are
                # never touched, and GetValue is used in place of property access: DSC
                # runs these script blocks under Set-StrictMode, where reading a property
                # that does not exist is a terminating error rather than $null.
                $targets = @(Get-ChildItem -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList" |
                    Where-Object { $_.PSChildName -like "S-1-5-21-*" -and $_.PSChildName -notin $loadedSids } |
                    ForEach-Object {
                        $profilePath = $_.GetValue("ProfileImagePath")
                        if ($profilePath) {
                            [pscustomobject]@{ Sid = $_.PSChildName; Path = $profilePath }
                        }
                    })

                $targets += [pscustomobject]@{ Sid = "DefaultUser"; Path = "$env:SystemDrive\Users\Default" }

                foreach ($target in $targets) {
                    $hiveFile = Join-Path -Path $target.Path -ChildPath "NTUSER.DAT"
                    # SilentlyContinue because an unreachable or orphaned profile path
                    # raises access denied, which would be terminating under Stop
                    if (-not (Test-Path -LiteralPath $hiveFile -ErrorAction SilentlyContinue)) { continue }

                    $mountName = "DSC_$($target.Sid)"
                    & reg.exe load "HKU\$mountName" $hiveFile | Out-Null
                    if ($LASTEXITCODE -ne 0) { continue }

                    try {
                        Set-VisualEffects -HiveRoot "Registry::HKEY_USERS\$mountName"
                    }
                    finally {
                        [GC]::Collect()
                        [GC]::WaitForPendingFinalizers()
                        & reg.exe unload "HKU\$mountName" | Out-Null
                    }
                }
            }

            TestScript = {
                # In desired state when VisualFXSetting is 2 for every real user hive and
                # every profile on disk, including the Default profile. Values are read
                # with GetValue rather than Get-ItemProperty because DSC runs these script
                # blocks under Set-StrictMode, where reading a property that does not
                # exist is a terminating error that -ErrorAction cannot suppress.
                function Get-VisualFXSetting {
                    param ([string] $HiveRoot)

                    $key = Get-Item -Path "$HiveRoot\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects" -ErrorAction SilentlyContinue
                    if ($null -eq $key) { return $null }
                    return $key.GetValue("VisualFXSetting")
                }

                # Must use the same SID filter as SetScript, or the hives SetScript
                # deliberately skips would keep this test returning $false for ever
                $loadedSids = @(Get-ChildItem -Path "Registry::HKEY_USERS" -ErrorAction SilentlyContinue |
                    Where-Object { $_.PSChildName -like "S-1-5-21-*" -and $_.PSChildName -notlike "*_Classes" } |
                    Select-Object -ExpandProperty PSChildName)

                foreach ($sid in $loadedSids) {
                    if ((Get-VisualFXSetting -HiveRoot "Registry::HKEY_USERS\$sid") -ne 2) { return $false }
                }

                $targets = @(Get-ChildItem -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList" -ErrorAction SilentlyContinue |
                    Where-Object { $_.PSChildName -like "S-1-5-21-*" -and $_.PSChildName -notin $loadedSids } |
                    ForEach-Object {
                        $profilePath = $_.GetValue("ProfileImagePath")
                        if ($profilePath) {
                            [pscustomobject]@{ Sid = $_.PSChildName; Path = $profilePath }
                        }
                    })

                $targets += [pscustomobject]@{ Sid = "DefaultUser"; Path = "$env:SystemDrive\Users\Default" }

                foreach ($target in $targets) {
                    $hiveFile = Join-Path -Path $target.Path -ChildPath "NTUSER.DAT"
                    # SilentlyContinue because an unreachable or orphaned profile path
                    # raises access denied, which would be terminating under Stop
                    if (-not (Test-Path -LiteralPath $hiveFile -ErrorAction SilentlyContinue)) { continue }

                    $mountName = "DSCTest_$($target.Sid)"
                    & reg.exe load "HKU\$mountName" $hiveFile | Out-Null

                    # A hive that cannot be mounted is skipped rather than reported as
                    # non-compliant: SetScript skips it too, so returning $false here
                    # would put the LCM into a Set on every consistency check for ever
                    if ($LASTEXITCODE -ne 0) { continue }

                    try {
                        if ((Get-VisualFXSetting -HiveRoot "Registry::HKEY_USERS\$mountName") -ne 2) { return $false }
                    }
                    finally {
                        [GC]::Collect()
                        [GC]::WaitForPendingFinalizers()
                        & reg.exe unload "HKU\$mountName" | Out-Null
                    }
                }

                return $true
            }

            GetScript = {
                $hiveFile = "$env:SystemDrive\Users\Default\NTUSER.DAT"
                $result = "Unknown"

                & reg.exe load "HKU\DSCGet_DefaultUser" $hiveFile | Out-Null
                if ($LASTEXITCODE -eq 0) {
                    try {
                        $key = Get-Item -Path "Registry::HKEY_USERS\DSCGet_DefaultUser\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects" -ErrorAction SilentlyContinue
                        if ($null -eq $key) {
                            $result = "Default profile VisualFXSetting is not set"
                        }
                        else {
                            $result = "Default profile VisualFXSetting = $($key.GetValue('VisualFXSetting'))"
                        }
                    }
                    finally {
                        [GC]::Collect()
                        [GC]::WaitForPendingFinalizers()
                        & reg.exe unload "HKU\DSCGet_DefaultUser" | Out-Null
                    }
                }

                return @{ Result = $result }
            }
        }
        
        # This resource block ensures that the file or command is executed
        xScript "RemoveArtifacts"
        {
            SetScript = {
                Remove-Item "C:\workflow-artifacts\*" -Recurse -Force
                Remove-Item "C:\workflow-artifacts" -Force
                Remove-Item "C:\workflow-artifacts.zip" -Force
                Remove-Item "C:\*_buildlog.log" -Force
            }
            TestScript = { $false }
            GetScript = { 
                # Do Nothing
            }
        }
    }
    
}

Configuration xBaICTSupC2LabCfg {
    [CmdletBinding()]

    Param (
        
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.PSCredential]
        [System.Management.Automation.Credential()]
        $Credential
    )

    Import-DscResource -ModuleName xPSDesiredStateConfiguration

    $features = @("Hyper-V", "RSAT-Hyper-V-Tools", "Hyper-V-Tools", "Hyper-V-PowerShell")

    Node localhost {

        LocalConfigurationManager {
            RebootNodeIfNeeded = $true
        }

        # This resource block create a local user
        xUser "CreateUserAccount" {
            Ensure = "Present"
            Username = Split-Path -Path $Credential.Username -Leaf
            Password = $Credential
            FullName = "Baltic Apprentice"
            Description = "Baltic Apprentice"
            PasswordNeverExpires = $true
            PasswordChangeRequired = $false
            PasswordChangeNotAllowed = $true
        }

        # This resource block adds user to a spacific group
        xGroup "AddToRemoteDesktopUserGroup"
        {
            GroupName = "Remote Desktop Users"
            Ensure = "Present"
            MembersToInclude = Split-Path -Path $Credential.Username -Leaf
            DependsOn = "[xUser]CreateUserAccount"
        }

        # This resource block adds user to a spacific group
        xGroup "AddToHyperVAdministratorGroup"
        {
            GroupName = "Hyper-V Administrators"
            Ensure = "Present"
            MembersToInclude = Split-Path -Path $Credential.Username -Leaf
            DependsOn = "[xUser]CreateUserAccount"
        }

        # This resource block ensures that a Windows Features (Roles) is present
        xWindowsFeatureSet "AddHyperVFeatures"
        {
            Name = $features
            Ensure = "Present"
            IncludeAllSubFeature = $true
        }
        
        # This resource block ensure that Enhanced Session mode is set to true in Hyper-V
        xscript "SetHyperVEnhancedSessionMode"
        {
            SetScript = {
                Set-VMHost -EnableEnhancedSessionMode $true
            }
            TestScript = { $false }
            GetScript = {
                # Do nothing
            }
            DependsOn = "[xWindowsFeatureSet]AddHyperVFeatures"
        }

        # This resource block ensures that the VM is built
        xScript "RunCreateVMs"
        {
            SetScript = {
                New-VM -Name "Windows 10 Client" -MemoryStartupBytes 1GB -Generation 1 -BootDevice VHD -VHDPath "C:\Users\Public\Documents\Hyper-V\Virtual hard disks\ITTshootToolTechniques\Windows 10 Client.vhdx"
                
            }
            TestScript = { $false }
            GetScript = {  
                # Do Nothing
            }
            DependsOn = "[xWindowsFeatureSet]AddHyperVFeatures"
        }

        # This resource block ensures that the VM is built
        xScript "AddDataVHD"
        {
            SetScript = {
                Add-VMHardDiskDrive -VMName "Windows 10 Client" -ControllerType IDE -ControllerNumber 0 -Path "C:\Users\Public\Documents\Hyper-V\Virtual hard disks\ITTshootToolTechniques\Windows 10 Client Data.vhdx"
                
            }
            TestScript = { $false }
            GetScript = {  
                # Do Nothing
            }
            DependsOn = "[xScript]RunCreateVMs"
        }

        # This resource block ensures that the file or command is executed
        xScript "SetRdpTimeZone"
        {
            SetScript = {
                New-ItemProperty -ErrorAction SilentlyContinue -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services" -Name "fEnableTimeZoneRedirection" -Value "1" -PropertyType DWORD -Force
            }
            TestScript = { $false }
            GetScript = { 
                # Do Nothing
            }
        }

        # This resource block sets Performance Options -> Visual Effects to
        # "Adjust for best performance" for every user: the Default profile (so any
        # account created later inherits it), every profile already on disk, and any
        # hive that is currently loaded. These are per-user (HKCU) settings, so there
        # is no single machine-wide value to set.
        xScript "SetVisualEffectsBestPerformance"
        {
            SetScript = {
                $ErrorActionPreference = "Stop"

                function Set-VisualEffects {
                    param ([string] $HiveRoot)

                    # The values Windows writes itself when "Adjust for best performance"
                    # is picked. Declared in here so the function does not rely on
                    # variables in the caller's scope.
                    $dwordValues = @{
                        "Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects" = @{ VisualFXSetting = 2 }
                        "Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"      = @{ ListviewAlphaSelect = 0; ListviewShadow = 0; TaskbarAnimations = 0; IconsOnly = 1 }
                        "Software\Microsoft\Windows\DWM"                                   = @{ EnableAeroPeek = 0; AlwaysHibernateThumbnails = 0 }
                    }

                    $stringValues = @{
                        "Control Panel\Desktop"               = @{ DragFullWindows = "0"; FontSmoothing = "0" }
                        "Control Panel\Desktop\WindowMetrics" = @{ MinAnimate = "0" }
                    }

                    $binaryValues = @{
                        "Control Panel\Desktop" = @{ UserPreferencesMask = [byte[]](0x90, 0x12, 0x03, 0x80, 0x10, 0x00, 0x00, 0x00) }
                    }

                    foreach ($set in @(
                        @{ Values = $dwordValues;  Type = "DWord"  },
                        @{ Values = $stringValues; Type = "String" },
                        @{ Values = $binaryValues; Type = "Binary" }
                    )) {
                        foreach ($subKey in $set.Values.Keys) {
                            $keyPath = Join-Path -Path $HiveRoot -ChildPath $subKey
                            if (-not (Test-Path -Path $keyPath)) {
                                New-Item -Path $keyPath -Force | Out-Null
                            }
                            foreach ($name in $set.Values[$subKey].Keys) {
                                New-ItemProperty -Path $keyPath -Name $name -Value $set.Values[$subKey][$name] -PropertyType $set.Type -Force | Out-Null
                            }
                        }
                    }
                }

                # Hives of real users that are already loaded. The S-1-5-21-* filter
                # deliberately skips the built-in service accounts (S-1-5-18/19/20) and
                # .DEFAULT, which is an alias for LocalSystem rather than the Default
                # profile and so has no bearing on accounts created later.
                $loadedSids = @(Get-ChildItem -Path "Registry::HKEY_USERS" |
                    Where-Object { $_.PSChildName -like "S-1-5-21-*" -and $_.PSChildName -notlike "*_Classes" } |
                    Select-Object -ExpandProperty PSChildName)

                foreach ($sid in $loadedSids) {
                    Set-VisualEffects -HiveRoot "Registry::HKEY_USERS\$sid"
                }

                # Profiles on disk whose hive is not loaded, plus the Default profile.
                # The value under ProfileList is ProfileImagePath, not ProfilePath. The
                # SID filter runs before it is read, so entries that do not carry it are
                # never touched, and GetValue is used in place of property access: DSC
                # runs these script blocks under Set-StrictMode, where reading a property
                # that does not exist is a terminating error rather than $null.
                $targets = @(Get-ChildItem -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList" |
                    Where-Object { $_.PSChildName -like "S-1-5-21-*" -and $_.PSChildName -notin $loadedSids } |
                    ForEach-Object {
                        $profilePath = $_.GetValue("ProfileImagePath")
                        if ($profilePath) {
                            [pscustomobject]@{ Sid = $_.PSChildName; Path = $profilePath }
                        }
                    })

                $targets += [pscustomobject]@{ Sid = "DefaultUser"; Path = "$env:SystemDrive\Users\Default" }

                foreach ($target in $targets) {
                    $hiveFile = Join-Path -Path $target.Path -ChildPath "NTUSER.DAT"
                    # SilentlyContinue because an unreachable or orphaned profile path
                    # raises access denied, which would be terminating under Stop
                    if (-not (Test-Path -LiteralPath $hiveFile -ErrorAction SilentlyContinue)) { continue }

                    $mountName = "DSC_$($target.Sid)"
                    & reg.exe load "HKU\$mountName" $hiveFile | Out-Null
                    if ($LASTEXITCODE -ne 0) { continue }

                    try {
                        Set-VisualEffects -HiveRoot "Registry::HKEY_USERS\$mountName"
                    }
                    finally {
                        [GC]::Collect()
                        [GC]::WaitForPendingFinalizers()
                        & reg.exe unload "HKU\$mountName" | Out-Null
                    }
                }
            }

            TestScript = {
                # In desired state when VisualFXSetting is 2 for every real user hive and
                # every profile on disk, including the Default profile. Values are read
                # with GetValue rather than Get-ItemProperty because DSC runs these script
                # blocks under Set-StrictMode, where reading a property that does not
                # exist is a terminating error that -ErrorAction cannot suppress.
                function Get-VisualFXSetting {
                    param ([string] $HiveRoot)

                    $key = Get-Item -Path "$HiveRoot\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects" -ErrorAction SilentlyContinue
                    if ($null -eq $key) { return $null }
                    return $key.GetValue("VisualFXSetting")
                }

                # Must use the same SID filter as SetScript, or the hives SetScript
                # deliberately skips would keep this test returning $false for ever
                $loadedSids = @(Get-ChildItem -Path "Registry::HKEY_USERS" -ErrorAction SilentlyContinue |
                    Where-Object { $_.PSChildName -like "S-1-5-21-*" -and $_.PSChildName -notlike "*_Classes" } |
                    Select-Object -ExpandProperty PSChildName)

                foreach ($sid in $loadedSids) {
                    if ((Get-VisualFXSetting -HiveRoot "Registry::HKEY_USERS\$sid") -ne 2) { return $false }
                }

                $targets = @(Get-ChildItem -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList" -ErrorAction SilentlyContinue |
                    Where-Object { $_.PSChildName -like "S-1-5-21-*" -and $_.PSChildName -notin $loadedSids } |
                    ForEach-Object {
                        $profilePath = $_.GetValue("ProfileImagePath")
                        if ($profilePath) {
                            [pscustomobject]@{ Sid = $_.PSChildName; Path = $profilePath }
                        }
                    })

                $targets += [pscustomobject]@{ Sid = "DefaultUser"; Path = "$env:SystemDrive\Users\Default" }

                foreach ($target in $targets) {
                    $hiveFile = Join-Path -Path $target.Path -ChildPath "NTUSER.DAT"
                    # SilentlyContinue because an unreachable or orphaned profile path
                    # raises access denied, which would be terminating under Stop
                    if (-not (Test-Path -LiteralPath $hiveFile -ErrorAction SilentlyContinue)) { continue }

                    $mountName = "DSCTest_$($target.Sid)"
                    & reg.exe load "HKU\$mountName" $hiveFile | Out-Null

                    # A hive that cannot be mounted is skipped rather than reported as
                    # non-compliant: SetScript skips it too, so returning $false here
                    # would put the LCM into a Set on every consistency check for ever
                    if ($LASTEXITCODE -ne 0) { continue }

                    try {
                        if ((Get-VisualFXSetting -HiveRoot "Registry::HKEY_USERS\$mountName") -ne 2) { return $false }
                    }
                    finally {
                        [GC]::Collect()
                        [GC]::WaitForPendingFinalizers()
                        & reg.exe unload "HKU\$mountName" | Out-Null
                    }
                }

                return $true
            }

            GetScript = {
                $hiveFile = "$env:SystemDrive\Users\Default\NTUSER.DAT"
                $result = "Unknown"

                & reg.exe load "HKU\DSCGet_DefaultUser" $hiveFile | Out-Null
                if ($LASTEXITCODE -eq 0) {
                    try {
                        $key = Get-Item -Path "Registry::HKEY_USERS\DSCGet_DefaultUser\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects" -ErrorAction SilentlyContinue
                        if ($null -eq $key) {
                            $result = "Default profile VisualFXSetting is not set"
                        }
                        else {
                            $result = "Default profile VisualFXSetting = $($key.GetValue('VisualFXSetting'))"
                        }
                    }
                    finally {
                        [GC]::Collect()
                        [GC]::WaitForPendingFinalizers()
                        & reg.exe unload "HKU\DSCGet_DefaultUser" | Out-Null
                    }
                }

                return @{ Result = $result }
            }
        }
        
        # This resource block ensures that the file or command is executed
        xScript "RemoveArtifacts"
        {
            SetScript = {
                Remove-Item "C:\workflow-artifacts\*" -Recurse -Force
                Remove-Item "C:\workflow-artifacts" -Force
                Remove-Item "C:\workflow-artifacts.zip" -Force
                Remove-Item "C:\*_buildlog.log" -Force
                Remove-Item "C:\ISOs\*" -Recurse -Force
                Remove-Item "C:\ISOs" -Force
            }
            TestScript = { $false }
            GetScript = { 
                # Do Nothing
            }
        }
    }
    
}

Configuration xBaICTSupC3LabCfg {
    [CmdletBinding()]

    Param (
        
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.PSCredential]
        [System.Management.Automation.Credential()]
        $Credential
    )

    Import-DscResource -ModuleName xPSDesiredStateConfiguration

    $features = @("Hyper-V", "RSAT-Hyper-V-Tools", "Hyper-V-Tools", "Hyper-V-PowerShell")

    Node localhost {

        LocalConfigurationManager {
            RebootNodeIfNeeded = $true
        }

        # This resource block create a local user
        xUser "CreateUserAccount" {
            Ensure = "Present"
            Username = Split-Path -Path $Credential.Username -Leaf
            Password = $Credential
            FullName = "Baltic Apprentice"
            Description = "Baltic Apprentice"
            PasswordNeverExpires = $true
            PasswordChangeRequired = $false
            PasswordChangeNotAllowed = $true
        }

        # This resource block adds user to a spacific group
        xGroup "AddToRemoteDesktopUserGroup"
        {
            GroupName = "Remote Desktop Users"
            Ensure = "Present"
            MembersToInclude = Split-Path -Path $Credential.Username -Leaf
            DependsOn = "[xUser]CreateUserAccount"
        }

        # This resource block adds user to a spacific group
        xGroup "AddToHyperVAdministratorGroup"
        {
            GroupName = "Hyper-V Administrators"
            Ensure = "Present"
            MembersToInclude = Split-Path -Path $Credential.Username -Leaf
            DependsOn = "[xUser]CreateUserAccount"
        }

        # This resource block ensures that a Windows Features (Roles) is present
        xWindowsFeatureSet "AddHyperVFeatures"
        {
            Name = $features
            Ensure = "Present"
            IncludeAllSubFeature = $true
        }

        # This resource block ensures that the file is executed
        xScript "SetDefaultVirtualHardDiskLocation"
        {
            SetScript = { 
                Set-VMHost -VirtualHardDiskPath "C:\Users\Public\Documents\Hyper-V\Virtual hard disks"
            }
            TestScript = { $false }
            GetScript = { 
                # Do Nothing
            }
            DependsOn = "[xWindowsFeatureSet]AddHyperVFeatures"
        }

        # This resource block ensures that the file is executed
        xScript "RunvSwitchForNestedVms"
        {
            SetScript = { 
                New-VMSwitch -SwitchName "vSwitch" -SwitchType Private
            }
            TestScript = { $false }
            GetScript = { 
                # Do Nothing
            }
            DependsOn = "[xWindowsFeatureSet]AddHyperVFeatures"
        }

        # This resource block ensures that the file is executed
        xScript "RunvSwitchForNat"
        {
            SetScript = { 
                New-VMSwitch -SwitchName "Int-vSwitch" -SwitchType Internal
                New-NetIPAddress -InterfaceAlias "vEthernet (Int-vSwitch)" -IPAddress 172.16.20.254 -PrefixLength 24
                New-NetNat -Name "Nat-VM" -InternalIPInterfaceAddressPrefix 172.16.20.0/24
            }
            TestScript = { $false }
            GetScript = { 
                # Do Nothing
            }
            DependsOn = "[xWindowsFeatureSet]AddHyperVFeatures"
        }

        # This resource block ensure that Enhanced Session mode is set to true in Hyper-V
        xscript "SetHyperVEnhancedSessionMode"
        {
            SetScript = {
                Set-VMHost -EnableEnhancedSessionMode $true
            }
            TestScript = { $false }
            GetScript = {
                # Do nothing
            }
            DependsOn = "[xWindowsFeatureSet]AddHyperVFeatures"
        }

        # This resource block ensures that the file or command is executed
        xScript "SetRdpTimeZone"
        {
            SetScript = {
                New-ItemProperty -ErrorAction SilentlyContinue -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services" -Name "fEnableTimeZoneRedirection" -Value "1" -PropertyType DWORD -Force
            }
            TestScript = { $false }
            GetScript = { 
                # Do Nothing
            }
        }

        # This resource block sets Performance Options -> Visual Effects to
        # "Adjust for best performance" for every user: the Default profile (so any
        # account created later inherits it), every profile already on disk, and any
        # hive that is currently loaded. These are per-user (HKCU) settings, so there
        # is no single machine-wide value to set.
        xScript "SetVisualEffectsBestPerformance"
        {
            SetScript = {
                $ErrorActionPreference = "Stop"

                function Set-VisualEffects {
                    param ([string] $HiveRoot)

                    # The values Windows writes itself when "Adjust for best performance"
                    # is picked. Declared in here so the function does not rely on
                    # variables in the caller's scope.
                    $dwordValues = @{
                        "Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects" = @{ VisualFXSetting = 2 }
                        "Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"      = @{ ListviewAlphaSelect = 0; ListviewShadow = 0; TaskbarAnimations = 0; IconsOnly = 1 }
                        "Software\Microsoft\Windows\DWM"                                   = @{ EnableAeroPeek = 0; AlwaysHibernateThumbnails = 0 }
                    }

                    $stringValues = @{
                        "Control Panel\Desktop"               = @{ DragFullWindows = "0"; FontSmoothing = "0" }
                        "Control Panel\Desktop\WindowMetrics" = @{ MinAnimate = "0" }
                    }

                    $binaryValues = @{
                        "Control Panel\Desktop" = @{ UserPreferencesMask = [byte[]](0x90, 0x12, 0x03, 0x80, 0x10, 0x00, 0x00, 0x00) }
                    }

                    foreach ($set in @(
                        @{ Values = $dwordValues;  Type = "DWord"  },
                        @{ Values = $stringValues; Type = "String" },
                        @{ Values = $binaryValues; Type = "Binary" }
                    )) {
                        foreach ($subKey in $set.Values.Keys) {
                            $keyPath = Join-Path -Path $HiveRoot -ChildPath $subKey
                            if (-not (Test-Path -Path $keyPath)) {
                                New-Item -Path $keyPath -Force | Out-Null
                            }
                            foreach ($name in $set.Values[$subKey].Keys) {
                                New-ItemProperty -Path $keyPath -Name $name -Value $set.Values[$subKey][$name] -PropertyType $set.Type -Force | Out-Null
                            }
                        }
                    }
                }

                # Hives of real users that are already loaded. The S-1-5-21-* filter
                # deliberately skips the built-in service accounts (S-1-5-18/19/20) and
                # .DEFAULT, which is an alias for LocalSystem rather than the Default
                # profile and so has no bearing on accounts created later.
                $loadedSids = @(Get-ChildItem -Path "Registry::HKEY_USERS" |
                    Where-Object { $_.PSChildName -like "S-1-5-21-*" -and $_.PSChildName -notlike "*_Classes" } |
                    Select-Object -ExpandProperty PSChildName)

                foreach ($sid in $loadedSids) {
                    Set-VisualEffects -HiveRoot "Registry::HKEY_USERS\$sid"
                }

                # Profiles on disk whose hive is not loaded, plus the Default profile.
                # The value under ProfileList is ProfileImagePath, not ProfilePath. The
                # SID filter runs before it is read, so entries that do not carry it are
                # never touched, and GetValue is used in place of property access: DSC
                # runs these script blocks under Set-StrictMode, where reading a property
                # that does not exist is a terminating error rather than $null.
                $targets = @(Get-ChildItem -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList" |
                    Where-Object { $_.PSChildName -like "S-1-5-21-*" -and $_.PSChildName -notin $loadedSids } |
                    ForEach-Object {
                        $profilePath = $_.GetValue("ProfileImagePath")
                        if ($profilePath) {
                            [pscustomobject]@{ Sid = $_.PSChildName; Path = $profilePath }
                        }
                    })

                $targets += [pscustomobject]@{ Sid = "DefaultUser"; Path = "$env:SystemDrive\Users\Default" }

                foreach ($target in $targets) {
                    $hiveFile = Join-Path -Path $target.Path -ChildPath "NTUSER.DAT"
                    # SilentlyContinue because an unreachable or orphaned profile path
                    # raises access denied, which would be terminating under Stop
                    if (-not (Test-Path -LiteralPath $hiveFile -ErrorAction SilentlyContinue)) { continue }

                    $mountName = "DSC_$($target.Sid)"
                    & reg.exe load "HKU\$mountName" $hiveFile | Out-Null
                    if ($LASTEXITCODE -ne 0) { continue }

                    try {
                        Set-VisualEffects -HiveRoot "Registry::HKEY_USERS\$mountName"
                    }
                    finally {
                        [GC]::Collect()
                        [GC]::WaitForPendingFinalizers()
                        & reg.exe unload "HKU\$mountName" | Out-Null
                    }
                }
            }

            TestScript = {
                # In desired state when VisualFXSetting is 2 for every real user hive and
                # every profile on disk, including the Default profile. Values are read
                # with GetValue rather than Get-ItemProperty because DSC runs these script
                # blocks under Set-StrictMode, where reading a property that does not
                # exist is a terminating error that -ErrorAction cannot suppress.
                function Get-VisualFXSetting {
                    param ([string] $HiveRoot)

                    $key = Get-Item -Path "$HiveRoot\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects" -ErrorAction SilentlyContinue
                    if ($null -eq $key) { return $null }
                    return $key.GetValue("VisualFXSetting")
                }

                # Must use the same SID filter as SetScript, or the hives SetScript
                # deliberately skips would keep this test returning $false for ever
                $loadedSids = @(Get-ChildItem -Path "Registry::HKEY_USERS" -ErrorAction SilentlyContinue |
                    Where-Object { $_.PSChildName -like "S-1-5-21-*" -and $_.PSChildName -notlike "*_Classes" } |
                    Select-Object -ExpandProperty PSChildName)

                foreach ($sid in $loadedSids) {
                    if ((Get-VisualFXSetting -HiveRoot "Registry::HKEY_USERS\$sid") -ne 2) { return $false }
                }

                $targets = @(Get-ChildItem -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList" -ErrorAction SilentlyContinue |
                    Where-Object { $_.PSChildName -like "S-1-5-21-*" -and $_.PSChildName -notin $loadedSids } |
                    ForEach-Object {
                        $profilePath = $_.GetValue("ProfileImagePath")
                        if ($profilePath) {
                            [pscustomobject]@{ Sid = $_.PSChildName; Path = $profilePath }
                        }
                    })

                $targets += [pscustomobject]@{ Sid = "DefaultUser"; Path = "$env:SystemDrive\Users\Default" }

                foreach ($target in $targets) {
                    $hiveFile = Join-Path -Path $target.Path -ChildPath "NTUSER.DAT"
                    # SilentlyContinue because an unreachable or orphaned profile path
                    # raises access denied, which would be terminating under Stop
                    if (-not (Test-Path -LiteralPath $hiveFile -ErrorAction SilentlyContinue)) { continue }

                    $mountName = "DSCTest_$($target.Sid)"
                    & reg.exe load "HKU\$mountName" $hiveFile | Out-Null

                    # A hive that cannot be mounted is skipped rather than reported as
                    # non-compliant: SetScript skips it too, so returning $false here
                    # would put the LCM into a Set on every consistency check for ever
                    if ($LASTEXITCODE -ne 0) { continue }

                    try {
                        if ((Get-VisualFXSetting -HiveRoot "Registry::HKEY_USERS\$mountName") -ne 2) { return $false }
                    }
                    finally {
                        [GC]::Collect()
                        [GC]::WaitForPendingFinalizers()
                        & reg.exe unload "HKU\$mountName" | Out-Null
                    }
                }

                return $true
            }

            GetScript = {
                $hiveFile = "$env:SystemDrive\Users\Default\NTUSER.DAT"
                $result = "Unknown"

                & reg.exe load "HKU\DSCGet_DefaultUser" $hiveFile | Out-Null
                if ($LASTEXITCODE -eq 0) {
                    try {
                        $key = Get-Item -Path "Registry::HKEY_USERS\DSCGet_DefaultUser\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects" -ErrorAction SilentlyContinue
                        if ($null -eq $key) {
                            $result = "Default profile VisualFXSetting is not set"
                        }
                        else {
                            $result = "Default profile VisualFXSetting = $($key.GetValue('VisualFXSetting'))"
                        }
                    }
                    finally {
                        [GC]::Collect()
                        [GC]::WaitForPendingFinalizers()
                        & reg.exe unload "HKU\DSCGet_DefaultUser" | Out-Null
                    }
                }

                return @{ Result = $result }
            }
        }

        # This resource block ensures that the file or command is executed
        xScript "RemoveArtifacts"
        {
            SetScript = {
                Remove-Item "C:\workflow-artifacts\*" -Recurse -Force
                Remove-Item "C:\workflow-artifacts" -Force
                Remove-Item "C:\workflow-artifacts.zip" -Force
                Remove-Item "C:\*_buildlog.log" -Force
            }
            TestScript = { $false }
            GetScript = { 
                # Do Nothing
            }
        }
    }
    
}

Configuration xBaICTSupC4LabCfg {
    [CmdletBinding()]

    Param (
        
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.PSCredential]
        [System.Management.Automation.Credential()]
        $Credential
    )

    Import-DscResource -ModuleName xPSDesiredStateConfiguration

    $features = @("Hyper-V", "RSAT-Hyper-V-Tools", "Hyper-V-Tools", "Hyper-V-PowerShell")

    Node localhost {

        LocalConfigurationManager {
            RebootNodeIfNeeded = $true
        }

        # This resource block create a local user
        xUser "CreateUserAccount" {
            Ensure = "Present"
            Username = Split-Path -Path $Credential.Username -Leaf
            Password = $Credential
            FullName = "Baltic Apprentice"
            Description = "Baltic Apprentice"
            PasswordNeverExpires = $true
            PasswordChangeRequired = $false
            PasswordChangeNotAllowed = $true
        }

        # This resource block adds user to a spacific group
        xGroup "AddToRemoteDesktopUserGroup"
        {
            GroupName = "Remote Desktop Users"
            Ensure = "Present"
            MembersToInclude = Split-Path -Path $Credential.Username -Leaf
            DependsOn = "[xUser]CreateUserAccount"
        }

        # This resource block adds user to a spacific group
        xGroup "AddToHyperVAdministratorGroup"
        {
            GroupName = "Hyper-V Administrators"
            Ensure = "Present"
            MembersToInclude = Split-Path -Path $Credential.Username -Leaf
            DependsOn = "[xUser]CreateUserAccount"
        }

        # This resource block ensures that a Windows Features (Roles) is present
        xWindowsFeatureSet "AddHyperVFeatures"
        {
            Name = $features
            Ensure = "Present"
            IncludeAllSubFeature = $true
        }

        # This resource block ensures that the file is executed
        xScript "SetDefaultVirtualHardDiskLocation"
        {
            SetScript = { 
                Set-VMHost -VirtualHardDiskPath "C:\Users\Public\Documents\Hyper-V\Virtual hard disks"
            }
            TestScript = { $false }
            GetScript = { 
                # Do Nothing
            }
            DependsOn = "[xWindowsFeatureSet]AddHyperVFeatures"
        }

        # This resource block ensures that the file is executed
        xScript "RunvSwitchForNestedVms"
        {
            SetScript = { 
                New-VMSwitch -SwitchName "vSwitch" -SwitchType Private
            }
            TestScript = { $false }
            GetScript = { 
                # Do Nothing
            }
            DependsOn = "[xWindowsFeatureSet]AddHyperVFeatures"
        }

        # This resource block ensures that the file is executed
        xScript "RunvSwitchForNat"
        {
            SetScript = { 
                New-VMSwitch -SwitchName "Int-vSwitch" -SwitchType Internal
                New-NetIPAddress -InterfaceAlias "vEthernet (Int-vSwitch)" -IPAddress 172.16.20.254 -PrefixLength 24
                New-NetNat -Name "Nat-VM" -InternalIPInterfaceAddressPrefix 172.16.20.0/24
            }
            TestScript = { $false }
            GetScript = { 
                # Do Nothing
            }
            DependsOn = "[xWindowsFeatureSet]AddHyperVFeatures"
        }

        # This resource block ensure that Enhanced Session mode is set to true in Hyper-V
        xscript "SetHyperVEnhancedSessionMode"
        {
            SetScript = {
                Set-VMHost -EnableEnhancedSessionMode $true
            }
            TestScript = { $false }
            GetScript = {
                # Do nothing
            }
            DependsOn = "[xWindowsFeatureSet]AddHyperVFeatures"
        }

        # This resource block ensures that the file or command is executed
        xScript "SetRdpTimeZone"
        {
            SetScript = {
                New-ItemProperty -ErrorAction SilentlyContinue -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services" -Name "fEnableTimeZoneRedirection" -Value "1" -PropertyType DWORD -Force
            }
            TestScript = { $false }
            GetScript = { 
                # Do Nothing
            }
        }

        # This resource block sets Performance Options -> Visual Effects to
        # "Adjust for best performance" for every user: the Default profile (so any
        # account created later inherits it), every profile already on disk, and any
        # hive that is currently loaded. These are per-user (HKCU) settings, so there
        # is no single machine-wide value to set.
        xScript "SetVisualEffectsBestPerformance"
        {
            SetScript = {
                $ErrorActionPreference = "Stop"

                function Set-VisualEffects {
                    param ([string] $HiveRoot)

                    # The values Windows writes itself when "Adjust for best performance"
                    # is picked. Declared in here so the function does not rely on
                    # variables in the caller's scope.
                    $dwordValues = @{
                        "Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects" = @{ VisualFXSetting = 2 }
                        "Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"      = @{ ListviewAlphaSelect = 0; ListviewShadow = 0; TaskbarAnimations = 0; IconsOnly = 1 }
                        "Software\Microsoft\Windows\DWM"                                   = @{ EnableAeroPeek = 0; AlwaysHibernateThumbnails = 0 }
                    }

                    $stringValues = @{
                        "Control Panel\Desktop"               = @{ DragFullWindows = "0"; FontSmoothing = "0" }
                        "Control Panel\Desktop\WindowMetrics" = @{ MinAnimate = "0" }
                    }

                    $binaryValues = @{
                        "Control Panel\Desktop" = @{ UserPreferencesMask = [byte[]](0x90, 0x12, 0x03, 0x80, 0x10, 0x00, 0x00, 0x00) }
                    }

                    foreach ($set in @(
                        @{ Values = $dwordValues;  Type = "DWord"  },
                        @{ Values = $stringValues; Type = "String" },
                        @{ Values = $binaryValues; Type = "Binary" }
                    )) {
                        foreach ($subKey in $set.Values.Keys) {
                            $keyPath = Join-Path -Path $HiveRoot -ChildPath $subKey
                            if (-not (Test-Path -Path $keyPath)) {
                                New-Item -Path $keyPath -Force | Out-Null
                            }
                            foreach ($name in $set.Values[$subKey].Keys) {
                                New-ItemProperty -Path $keyPath -Name $name -Value $set.Values[$subKey][$name] -PropertyType $set.Type -Force | Out-Null
                            }
                        }
                    }
                }

                # Hives of real users that are already loaded. The S-1-5-21-* filter
                # deliberately skips the built-in service accounts (S-1-5-18/19/20) and
                # .DEFAULT, which is an alias for LocalSystem rather than the Default
                # profile and so has no bearing on accounts created later.
                $loadedSids = @(Get-ChildItem -Path "Registry::HKEY_USERS" |
                    Where-Object { $_.PSChildName -like "S-1-5-21-*" -and $_.PSChildName -notlike "*_Classes" } |
                    Select-Object -ExpandProperty PSChildName)

                foreach ($sid in $loadedSids) {
                    Set-VisualEffects -HiveRoot "Registry::HKEY_USERS\$sid"
                }

                # Profiles on disk whose hive is not loaded, plus the Default profile.
                # The value under ProfileList is ProfileImagePath, not ProfilePath. The
                # SID filter runs before it is read, so entries that do not carry it are
                # never touched, and GetValue is used in place of property access: DSC
                # runs these script blocks under Set-StrictMode, where reading a property
                # that does not exist is a terminating error rather than $null.
                $targets = @(Get-ChildItem -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList" |
                    Where-Object { $_.PSChildName -like "S-1-5-21-*" -and $_.PSChildName -notin $loadedSids } |
                    ForEach-Object {
                        $profilePath = $_.GetValue("ProfileImagePath")
                        if ($profilePath) {
                            [pscustomobject]@{ Sid = $_.PSChildName; Path = $profilePath }
                        }
                    })

                $targets += [pscustomobject]@{ Sid = "DefaultUser"; Path = "$env:SystemDrive\Users\Default" }

                foreach ($target in $targets) {
                    $hiveFile = Join-Path -Path $target.Path -ChildPath "NTUSER.DAT"
                    # SilentlyContinue because an unreachable or orphaned profile path
                    # raises access denied, which would be terminating under Stop
                    if (-not (Test-Path -LiteralPath $hiveFile -ErrorAction SilentlyContinue)) { continue }

                    $mountName = "DSC_$($target.Sid)"
                    & reg.exe load "HKU\$mountName" $hiveFile | Out-Null
                    if ($LASTEXITCODE -ne 0) { continue }

                    try {
                        Set-VisualEffects -HiveRoot "Registry::HKEY_USERS\$mountName"
                    }
                    finally {
                        [GC]::Collect()
                        [GC]::WaitForPendingFinalizers()
                        & reg.exe unload "HKU\$mountName" | Out-Null
                    }
                }
            }

            TestScript = {
                # In desired state when VisualFXSetting is 2 for every real user hive and
                # every profile on disk, including the Default profile. Values are read
                # with GetValue rather than Get-ItemProperty because DSC runs these script
                # blocks under Set-StrictMode, where reading a property that does not
                # exist is a terminating error that -ErrorAction cannot suppress.
                function Get-VisualFXSetting {
                    param ([string] $HiveRoot)

                    $key = Get-Item -Path "$HiveRoot\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects" -ErrorAction SilentlyContinue
                    if ($null -eq $key) { return $null }
                    return $key.GetValue("VisualFXSetting")
                }

                # Must use the same SID filter as SetScript, or the hives SetScript
                # deliberately skips would keep this test returning $false for ever
                $loadedSids = @(Get-ChildItem -Path "Registry::HKEY_USERS" -ErrorAction SilentlyContinue |
                    Where-Object { $_.PSChildName -like "S-1-5-21-*" -and $_.PSChildName -notlike "*_Classes" } |
                    Select-Object -ExpandProperty PSChildName)

                foreach ($sid in $loadedSids) {
                    if ((Get-VisualFXSetting -HiveRoot "Registry::HKEY_USERS\$sid") -ne 2) { return $false }
                }

                $targets = @(Get-ChildItem -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList" -ErrorAction SilentlyContinue |
                    Where-Object { $_.PSChildName -like "S-1-5-21-*" -and $_.PSChildName -notin $loadedSids } |
                    ForEach-Object {
                        $profilePath = $_.GetValue("ProfileImagePath")
                        if ($profilePath) {
                            [pscustomobject]@{ Sid = $_.PSChildName; Path = $profilePath }
                        }
                    })

                $targets += [pscustomobject]@{ Sid = "DefaultUser"; Path = "$env:SystemDrive\Users\Default" }

                foreach ($target in $targets) {
                    $hiveFile = Join-Path -Path $target.Path -ChildPath "NTUSER.DAT"
                    # SilentlyContinue because an unreachable or orphaned profile path
                    # raises access denied, which would be terminating under Stop
                    if (-not (Test-Path -LiteralPath $hiveFile -ErrorAction SilentlyContinue)) { continue }

                    $mountName = "DSCTest_$($target.Sid)"
                    & reg.exe load "HKU\$mountName" $hiveFile | Out-Null

                    # A hive that cannot be mounted is skipped rather than reported as
                    # non-compliant: SetScript skips it too, so returning $false here
                    # would put the LCM into a Set on every consistency check for ever
                    if ($LASTEXITCODE -ne 0) { continue }

                    try {
                        if ((Get-VisualFXSetting -HiveRoot "Registry::HKEY_USERS\$mountName") -ne 2) { return $false }
                    }
                    finally {
                        [GC]::Collect()
                        [GC]::WaitForPendingFinalizers()
                        & reg.exe unload "HKU\$mountName" | Out-Null
                    }
                }

                return $true
            }

            GetScript = {
                $hiveFile = "$env:SystemDrive\Users\Default\NTUSER.DAT"
                $result = "Unknown"

                & reg.exe load "HKU\DSCGet_DefaultUser" $hiveFile | Out-Null
                if ($LASTEXITCODE -eq 0) {
                    try {
                        $key = Get-Item -Path "Registry::HKEY_USERS\DSCGet_DefaultUser\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects" -ErrorAction SilentlyContinue
                        if ($null -eq $key) {
                            $result = "Default profile VisualFXSetting is not set"
                        }
                        else {
                            $result = "Default profile VisualFXSetting = $($key.GetValue('VisualFXSetting'))"
                        }
                    }
                    finally {
                        [GC]::Collect()
                        [GC]::WaitForPendingFinalizers()
                        & reg.exe unload "HKU\DSCGet_DefaultUser" | Out-Null
                    }
                }

                return @{ Result = $result }
            }
        }

        # This resource block ensures that the file or command is executed
        xScript "RemoveArtifacts"
        {
            SetScript = {
                Remove-Item "C:\workflow-artifacts\*" -Recurse -Force
                Remove-Item "C:\workflow-artifacts" -Force
                Remove-Item "C:\workflow-artifacts.zip" -Force
                Remove-Item "C:\*_buildlog.log" -Force
            }
            TestScript = { $false }
            GetScript = { 
                # Do Nothing
            }
        }
    }
    
}

Configuration xBaICTSupC6LabCfg {
    [CmdletBinding()]

    Param (
        
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.PSCredential]
        [System.Management.Automation.Credential()]
        $Credential
    )

    Import-DscResource -ModuleName xPSDesiredStateConfiguration

    $features = @("Hyper-V", "RSAT-Hyper-V-Tools", "Hyper-V-Tools", "Hyper-V-PowerShell")

    Node localhost {

        LocalConfigurationManager {
            RebootNodeIfNeeded = $true
        }

        # This resource block create a local user
        xUser "CreateUserAccount" {
            Ensure = "Present"
            Username = Split-Path -Path $Credential.Username -Leaf
            Password = $Credential
            FullName = "Baltic Apprentice"
            Description = "Baltic Apprentice"
            PasswordNeverExpires = $true
            PasswordChangeRequired = $false
            PasswordChangeNotAllowed = $true
        }

        # This resource block adds user to a spacific group
        xGroup "AddToRemoteDesktopUserGroup"
        {
            GroupName = "Remote Desktop Users"
            Ensure = "Present"
            MembersToInclude = Split-Path -Path $Credential.Username -Leaf
            DependsOn = "[xUser]CreateUserAccount"
        }

        # This resource block adds user to a spacific group
        xGroup "AddToHyperVAdministratorGroup"
        {
            GroupName = "Hyper-V Administrators"
            Ensure = "Present"
            MembersToInclude = Split-Path -Path $Credential.Username -Leaf
            DependsOn = "[xUser]CreateUserAccount"
        }

        # This resource block ensures that a Windows Features (Roles) is present
        xWindowsFeatureSet "AddHyperVFeatures"
        {
            Name = $features
            Ensure = "Present"
            IncludeAllSubFeature = $true
        }

        # This resource block ensures that the file is executed
        xScript "SetDefaultVirtualHardDiskLocation"
        {
            SetScript = { 
                Set-VMHost -VirtualHardDiskPath "C:\Users\Public\Documents\Hyper-V\Virtual hard disks"
            }
            TestScript = { $false }
            GetScript = { 
                # Do Nothing
            }
            DependsOn = "[xWindowsFeatureSet]AddHyperVFeatures"
        }

        # This resource block ensures that the file is executed
        xScript "RunvSwitchForNestedVms"
        {
            SetScript = { 
                New-VMSwitch -SwitchName "vSwitch" -SwitchType Private
            }
            TestScript = { $false }
            GetScript = { 
                # Do Nothing
            }
            DependsOn = "[xWindowsFeatureSet]AddHyperVFeatures"
        }

        # This resource block ensures that the file is executed
        xScript "RunvSwitchForNat"
        {
            SetScript = { 
                New-VMSwitch -SwitchName "Int-vSwitch" -SwitchType Internal
                New-NetIPAddress -InterfaceAlias "vEthernet (Int-vSwitch)" -IPAddress 172.16.20.254 -PrefixLength 24
                New-NetNat -Name "Nat-VM" -InternalIPInterfaceAddressPrefix 172.16.20.0/24
            }
            TestScript = { $false }
            GetScript = { 
                # Do Nothing
            }
            DependsOn = "[xWindowsFeatureSet]AddHyperVFeatures"
        }

        # This resource block ensure that Enhanced Session mode is set to true in Hyper-V
        xscript "SetHyperVEnhancedSessionMode"
        {
            SetScript = {
                Set-VMHost -EnableEnhancedSessionMode $true
            }
            TestScript = { $false }
            GetScript = {
                # Do nothing
            }
            DependsOn = "[xWindowsFeatureSet]AddHyperVFeatures"
        }

        # This resource block ensures that the file or command is executed
        xScript "SetRdpTimeZone"
        {
            SetScript = {
                New-ItemProperty -ErrorAction SilentlyContinue -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services" -Name "fEnableTimeZoneRedirection" -Value "1" -PropertyType DWORD -Force
            }
            TestScript = { $false }
            GetScript = { 
                # Do Nothing
            }
        }

        # This resource block sets Performance Options -> Visual Effects to
        # "Adjust for best performance" for every user: the Default profile (so any
        # account created later inherits it), every profile already on disk, and any
        # hive that is currently loaded. These are per-user (HKCU) settings, so there
        # is no single machine-wide value to set.
        xScript "SetVisualEffectsBestPerformance"
        {
            SetScript = {
                $ErrorActionPreference = "Stop"

                function Set-VisualEffects {
                    param ([string] $HiveRoot)

                    # The values Windows writes itself when "Adjust for best performance"
                    # is picked. Declared in here so the function does not rely on
                    # variables in the caller's scope.
                    $dwordValues = @{
                        "Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects" = @{ VisualFXSetting = 2 }
                        "Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"      = @{ ListviewAlphaSelect = 0; ListviewShadow = 0; TaskbarAnimations = 0; IconsOnly = 1 }
                        "Software\Microsoft\Windows\DWM"                                   = @{ EnableAeroPeek = 0; AlwaysHibernateThumbnails = 0 }
                    }

                    $stringValues = @{
                        "Control Panel\Desktop"               = @{ DragFullWindows = "0"; FontSmoothing = "0" }
                        "Control Panel\Desktop\WindowMetrics" = @{ MinAnimate = "0" }
                    }

                    $binaryValues = @{
                        "Control Panel\Desktop" = @{ UserPreferencesMask = [byte[]](0x90, 0x12, 0x03, 0x80, 0x10, 0x00, 0x00, 0x00) }
                    }

                    foreach ($set in @(
                        @{ Values = $dwordValues;  Type = "DWord"  },
                        @{ Values = $stringValues; Type = "String" },
                        @{ Values = $binaryValues; Type = "Binary" }
                    )) {
                        foreach ($subKey in $set.Values.Keys) {
                            $keyPath = Join-Path -Path $HiveRoot -ChildPath $subKey
                            if (-not (Test-Path -Path $keyPath)) {
                                New-Item -Path $keyPath -Force | Out-Null
                            }
                            foreach ($name in $set.Values[$subKey].Keys) {
                                New-ItemProperty -Path $keyPath -Name $name -Value $set.Values[$subKey][$name] -PropertyType $set.Type -Force | Out-Null
                            }
                        }
                    }
                }

                # Hives of real users that are already loaded. The S-1-5-21-* filter
                # deliberately skips the built-in service accounts (S-1-5-18/19/20) and
                # .DEFAULT, which is an alias for LocalSystem rather than the Default
                # profile and so has no bearing on accounts created later.
                $loadedSids = @(Get-ChildItem -Path "Registry::HKEY_USERS" |
                    Where-Object { $_.PSChildName -like "S-1-5-21-*" -and $_.PSChildName -notlike "*_Classes" } |
                    Select-Object -ExpandProperty PSChildName)

                foreach ($sid in $loadedSids) {
                    Set-VisualEffects -HiveRoot "Registry::HKEY_USERS\$sid"
                }

                # Profiles on disk whose hive is not loaded, plus the Default profile.
                # The value under ProfileList is ProfileImagePath, not ProfilePath. The
                # SID filter runs before it is read, so entries that do not carry it are
                # never touched, and GetValue is used in place of property access: DSC
                # runs these script blocks under Set-StrictMode, where reading a property
                # that does not exist is a terminating error rather than $null.
                $targets = @(Get-ChildItem -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList" |
                    Where-Object { $_.PSChildName -like "S-1-5-21-*" -and $_.PSChildName -notin $loadedSids } |
                    ForEach-Object {
                        $profilePath = $_.GetValue("ProfileImagePath")
                        if ($profilePath) {
                            [pscustomobject]@{ Sid = $_.PSChildName; Path = $profilePath }
                        }
                    })

                $targets += [pscustomobject]@{ Sid = "DefaultUser"; Path = "$env:SystemDrive\Users\Default" }

                foreach ($target in $targets) {
                    $hiveFile = Join-Path -Path $target.Path -ChildPath "NTUSER.DAT"
                    # SilentlyContinue because an unreachable or orphaned profile path
                    # raises access denied, which would be terminating under Stop
                    if (-not (Test-Path -LiteralPath $hiveFile -ErrorAction SilentlyContinue)) { continue }

                    $mountName = "DSC_$($target.Sid)"
                    & reg.exe load "HKU\$mountName" $hiveFile | Out-Null
                    if ($LASTEXITCODE -ne 0) { continue }

                    try {
                        Set-VisualEffects -HiveRoot "Registry::HKEY_USERS\$mountName"
                    }
                    finally {
                        [GC]::Collect()
                        [GC]::WaitForPendingFinalizers()
                        & reg.exe unload "HKU\$mountName" | Out-Null
                    }
                }
            }

            TestScript = {
                # In desired state when VisualFXSetting is 2 for every real user hive and
                # every profile on disk, including the Default profile. Values are read
                # with GetValue rather than Get-ItemProperty because DSC runs these script
                # blocks under Set-StrictMode, where reading a property that does not
                # exist is a terminating error that -ErrorAction cannot suppress.
                function Get-VisualFXSetting {
                    param ([string] $HiveRoot)

                    $key = Get-Item -Path "$HiveRoot\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects" -ErrorAction SilentlyContinue
                    if ($null -eq $key) { return $null }
                    return $key.GetValue("VisualFXSetting")
                }

                # Must use the same SID filter as SetScript, or the hives SetScript
                # deliberately skips would keep this test returning $false for ever
                $loadedSids = @(Get-ChildItem -Path "Registry::HKEY_USERS" -ErrorAction SilentlyContinue |
                    Where-Object { $_.PSChildName -like "S-1-5-21-*" -and $_.PSChildName -notlike "*_Classes" } |
                    Select-Object -ExpandProperty PSChildName)

                foreach ($sid in $loadedSids) {
                    if ((Get-VisualFXSetting -HiveRoot "Registry::HKEY_USERS\$sid") -ne 2) { return $false }
                }

                $targets = @(Get-ChildItem -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList" -ErrorAction SilentlyContinue |
                    Where-Object { $_.PSChildName -like "S-1-5-21-*" -and $_.PSChildName -notin $loadedSids } |
                    ForEach-Object {
                        $profilePath = $_.GetValue("ProfileImagePath")
                        if ($profilePath) {
                            [pscustomobject]@{ Sid = $_.PSChildName; Path = $profilePath }
                        }
                    })

                $targets += [pscustomobject]@{ Sid = "DefaultUser"; Path = "$env:SystemDrive\Users\Default" }

                foreach ($target in $targets) {
                    $hiveFile = Join-Path -Path $target.Path -ChildPath "NTUSER.DAT"
                    # SilentlyContinue because an unreachable or orphaned profile path
                    # raises access denied, which would be terminating under Stop
                    if (-not (Test-Path -LiteralPath $hiveFile -ErrorAction SilentlyContinue)) { continue }

                    $mountName = "DSCTest_$($target.Sid)"
                    & reg.exe load "HKU\$mountName" $hiveFile | Out-Null

                    # A hive that cannot be mounted is skipped rather than reported as
                    # non-compliant: SetScript skips it too, so returning $false here
                    # would put the LCM into a Set on every consistency check for ever
                    if ($LASTEXITCODE -ne 0) { continue }

                    try {
                        if ((Get-VisualFXSetting -HiveRoot "Registry::HKEY_USERS\$mountName") -ne 2) { return $false }
                    }
                    finally {
                        [GC]::Collect()
                        [GC]::WaitForPendingFinalizers()
                        & reg.exe unload "HKU\$mountName" | Out-Null
                    }
                }

                return $true
            }

            GetScript = {
                $hiveFile = "$env:SystemDrive\Users\Default\NTUSER.DAT"
                $result = "Unknown"

                & reg.exe load "HKU\DSCGet_DefaultUser" $hiveFile | Out-Null
                if ($LASTEXITCODE -eq 0) {
                    try {
                        $key = Get-Item -Path "Registry::HKEY_USERS\DSCGet_DefaultUser\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects" -ErrorAction SilentlyContinue
                        if ($null -eq $key) {
                            $result = "Default profile VisualFXSetting is not set"
                        }
                        else {
                            $result = "Default profile VisualFXSetting = $($key.GetValue('VisualFXSetting'))"
                        }
                    }
                    finally {
                        [GC]::Collect()
                        [GC]::WaitForPendingFinalizers()
                        & reg.exe unload "HKU\DSCGet_DefaultUser" | Out-Null
                    }
                }

                return @{ Result = $result }
            }
        }

        # This resource block ensures that the file or command is executed
        xScript "RemoveArtifacts"
        {
            SetScript = {
                Remove-Item "C:\workflow-artifacts\*" -Recurse -Force
                Remove-Item "C:\workflow-artifacts" -Force
                Remove-Item "C:\workflow-artifacts.zip" -Force
                Remove-Item "C:\*_buildlog.log" -Force
            }
            TestScript = { $false }
            GetScript = { 
                # Do Nothing
            }
        }
    }
    
}

Configuration xBaICTNetEPALabCfg {
    [CmdletBinding()]

    Param (
        
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.PSCredential]
        [System.Management.Automation.Credential()]
        $Credential
    )

    Import-DscResource -ModuleName xPSDesiredStateConfiguration

    Node localhost {

        LocalConfigurationManager {
            RebootNodeIfNeeded = $true
        }

        # This resource block create a local user
        xUser "CreateUserAccount" {
            Ensure = "Present"
            Username = Split-Path -Path $Credential.Username -Leaf
            Password = $Credential
            FullName = "Baltic Apprentice"
            Description = "Baltic Apprentice"
            PasswordNeverExpires = $true
            PasswordChangeRequired = $false
            PasswordChangeNotAllowed = $true
        }

        # This resource block adds user to a spacific group
        xGroup "AddToRemoteDesktopUserGroup"
        {
            GroupName = "Remote Desktop Users"
            Ensure = "Present"
            MembersToInclude = Split-Path -Path $Credential.Username -Leaf
            DependsOn = "[xUser]CreateUserAccount"
        }

        # This resource block adds user to a spacific group
        xGroup "AddToHyperVAdministratorGroup"
        {
            GroupName = "Hyper-V Administrators"
            Ensure = "Present"
            MembersToInclude = Split-Path -Path $Credential.Username -Leaf
            DependsOn = "[xUser]CreateUserAccount"
        }

        # This resource block ensures that the file or command is executed
        xScript "SetRdpTimeZone"
        {
            SetScript = {
                New-ItemProperty -ErrorAction SilentlyContinue -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services" -Name "fEnableTimeZoneRedirection" -Value "1" -PropertyType DWORD -Force
            }
            TestScript = { $false }
            GetScript = { 
                # Do Nothing
            }
        }

        # This resource block sets Performance Options -> Visual Effects to
        # "Adjust for best performance" for every user: the Default profile (so any
        # account created later inherits it), every profile already on disk, and any
        # hive that is currently loaded. These are per-user (HKCU) settings, so there
        # is no single machine-wide value to set.
        xScript "SetVisualEffectsBestPerformance"
        {
            SetScript = {
                $ErrorActionPreference = "Stop"

                function Set-VisualEffects {
                    param ([string] $HiveRoot)

                    # The values Windows writes itself when "Adjust for best performance"
                    # is picked. Declared in here so the function does not rely on
                    # variables in the caller's scope.
                    $dwordValues = @{
                        "Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects" = @{ VisualFXSetting = 2 }
                        "Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"      = @{ ListviewAlphaSelect = 0; ListviewShadow = 0; TaskbarAnimations = 0; IconsOnly = 1 }
                        "Software\Microsoft\Windows\DWM"                                   = @{ EnableAeroPeek = 0; AlwaysHibernateThumbnails = 0 }
                    }

                    $stringValues = @{
                        "Control Panel\Desktop"               = @{ DragFullWindows = "0"; FontSmoothing = "0" }
                        "Control Panel\Desktop\WindowMetrics" = @{ MinAnimate = "0" }
                    }

                    $binaryValues = @{
                        "Control Panel\Desktop" = @{ UserPreferencesMask = [byte[]](0x90, 0x12, 0x03, 0x80, 0x10, 0x00, 0x00, 0x00) }
                    }

                    foreach ($set in @(
                        @{ Values = $dwordValues;  Type = "DWord"  },
                        @{ Values = $stringValues; Type = "String" },
                        @{ Values = $binaryValues; Type = "Binary" }
                    )) {
                        foreach ($subKey in $set.Values.Keys) {
                            $keyPath = Join-Path -Path $HiveRoot -ChildPath $subKey
                            if (-not (Test-Path -Path $keyPath)) {
                                New-Item -Path $keyPath -Force | Out-Null
                            }
                            foreach ($name in $set.Values[$subKey].Keys) {
                                New-ItemProperty -Path $keyPath -Name $name -Value $set.Values[$subKey][$name] -PropertyType $set.Type -Force | Out-Null
                            }
                        }
                    }
                }

                # Hives of real users that are already loaded. The S-1-5-21-* filter
                # deliberately skips the built-in service accounts (S-1-5-18/19/20) and
                # .DEFAULT, which is an alias for LocalSystem rather than the Default
                # profile and so has no bearing on accounts created later.
                $loadedSids = @(Get-ChildItem -Path "Registry::HKEY_USERS" |
                    Where-Object { $_.PSChildName -like "S-1-5-21-*" -and $_.PSChildName -notlike "*_Classes" } |
                    Select-Object -ExpandProperty PSChildName)

                foreach ($sid in $loadedSids) {
                    Set-VisualEffects -HiveRoot "Registry::HKEY_USERS\$sid"
                }

                # Profiles on disk whose hive is not loaded, plus the Default profile.
                # The value under ProfileList is ProfileImagePath, not ProfilePath. The
                # SID filter runs before it is read, so entries that do not carry it are
                # never touched, and GetValue is used in place of property access: DSC
                # runs these script blocks under Set-StrictMode, where reading a property
                # that does not exist is a terminating error rather than $null.
                $targets = @(Get-ChildItem -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList" |
                    Where-Object { $_.PSChildName -like "S-1-5-21-*" -and $_.PSChildName -notin $loadedSids } |
                    ForEach-Object {
                        $profilePath = $_.GetValue("ProfileImagePath")
                        if ($profilePath) {
                            [pscustomobject]@{ Sid = $_.PSChildName; Path = $profilePath }
                        }
                    })

                $targets += [pscustomobject]@{ Sid = "DefaultUser"; Path = "$env:SystemDrive\Users\Default" }

                foreach ($target in $targets) {
                    $hiveFile = Join-Path -Path $target.Path -ChildPath "NTUSER.DAT"
                    # SilentlyContinue because an unreachable or orphaned profile path
                    # raises access denied, which would be terminating under Stop
                    if (-not (Test-Path -LiteralPath $hiveFile -ErrorAction SilentlyContinue)) { continue }

                    $mountName = "DSC_$($target.Sid)"
                    & reg.exe load "HKU\$mountName" $hiveFile | Out-Null
                    if ($LASTEXITCODE -ne 0) { continue }

                    try {
                        Set-VisualEffects -HiveRoot "Registry::HKEY_USERS\$mountName"
                    }
                    finally {
                        [GC]::Collect()
                        [GC]::WaitForPendingFinalizers()
                        & reg.exe unload "HKU\$mountName" | Out-Null
                    }
                }
            }

            TestScript = {
                # In desired state when VisualFXSetting is 2 for every real user hive and
                # every profile on disk, including the Default profile. Values are read
                # with GetValue rather than Get-ItemProperty because DSC runs these script
                # blocks under Set-StrictMode, where reading a property that does not
                # exist is a terminating error that -ErrorAction cannot suppress.
                function Get-VisualFXSetting {
                    param ([string] $HiveRoot)

                    $key = Get-Item -Path "$HiveRoot\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects" -ErrorAction SilentlyContinue
                    if ($null -eq $key) { return $null }
                    return $key.GetValue("VisualFXSetting")
                }

                # Must use the same SID filter as SetScript, or the hives SetScript
                # deliberately skips would keep this test returning $false for ever
                $loadedSids = @(Get-ChildItem -Path "Registry::HKEY_USERS" -ErrorAction SilentlyContinue |
                    Where-Object { $_.PSChildName -like "S-1-5-21-*" -and $_.PSChildName -notlike "*_Classes" } |
                    Select-Object -ExpandProperty PSChildName)

                foreach ($sid in $loadedSids) {
                    if ((Get-VisualFXSetting -HiveRoot "Registry::HKEY_USERS\$sid") -ne 2) { return $false }
                }

                $targets = @(Get-ChildItem -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList" -ErrorAction SilentlyContinue |
                    Where-Object { $_.PSChildName -like "S-1-5-21-*" -and $_.PSChildName -notin $loadedSids } |
                    ForEach-Object {
                        $profilePath = $_.GetValue("ProfileImagePath")
                        if ($profilePath) {
                            [pscustomobject]@{ Sid = $_.PSChildName; Path = $profilePath }
                        }
                    })

                $targets += [pscustomobject]@{ Sid = "DefaultUser"; Path = "$env:SystemDrive\Users\Default" }

                foreach ($target in $targets) {
                    $hiveFile = Join-Path -Path $target.Path -ChildPath "NTUSER.DAT"
                    # SilentlyContinue because an unreachable or orphaned profile path
                    # raises access denied, which would be terminating under Stop
                    if (-not (Test-Path -LiteralPath $hiveFile -ErrorAction SilentlyContinue)) { continue }

                    $mountName = "DSCTest_$($target.Sid)"
                    & reg.exe load "HKU\$mountName" $hiveFile | Out-Null

                    # A hive that cannot be mounted is skipped rather than reported as
                    # non-compliant: SetScript skips it too, so returning $false here
                    # would put the LCM into a Set on every consistency check for ever
                    if ($LASTEXITCODE -ne 0) { continue }

                    try {
                        if ((Get-VisualFXSetting -HiveRoot "Registry::HKEY_USERS\$mountName") -ne 2) { return $false }
                    }
                    finally {
                        [GC]::Collect()
                        [GC]::WaitForPendingFinalizers()
                        & reg.exe unload "HKU\$mountName" | Out-Null
                    }
                }

                return $true
            }

            GetScript = {
                $hiveFile = "$env:SystemDrive\Users\Default\NTUSER.DAT"
                $result = "Unknown"

                & reg.exe load "HKU\DSCGet_DefaultUser" $hiveFile | Out-Null
                if ($LASTEXITCODE -eq 0) {
                    try {
                        $key = Get-Item -Path "Registry::HKEY_USERS\DSCGet_DefaultUser\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects" -ErrorAction SilentlyContinue
                        if ($null -eq $key) {
                            $result = "Default profile VisualFXSetting is not set"
                        }
                        else {
                            $result = "Default profile VisualFXSetting = $($key.GetValue('VisualFXSetting'))"
                        }
                    }
                    finally {
                        [GC]::Collect()
                        [GC]::WaitForPendingFinalizers()
                        & reg.exe unload "HKU\DSCGet_DefaultUser" | Out-Null
                    }
                }

                return @{ Result = $result }
            }
        }

        # This resource block ensures that the file or command is executed
        xScript "RemoveArtifacts"
        {
            SetScript = {
                Remove-Item "C:\workflow-artifacts\*" -Recurse -Force
                Remove-Item "C:\workflow-artifacts" -Force
                Remove-Item "C:\workflow-artifacts.zip" -Force
                Remove-Item "C:\*_buildlog.log" -Force
            }
            TestScript = { $false }
            GetScript = { 
                # Do Nothing
            }
        }
    }
    
}

Configuration xBaICTSupMstrLabCfg {
    [CmdletBinding()]

    Param (
        
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.PSCredential]
        [System.Management.Automation.Credential()]
        $Credential
    )

    Import-DscResource -ModuleName xPSDesiredStateConfiguration

    $features = @("Hyper-V", "RSAT-Hyper-V-Tools", "Hyper-V-Tools", "Hyper-V-PowerShell")

    Node localhost {

        LocalConfigurationManager {
            RebootNodeIfNeeded = $true
        }

        # This resource block create a local user
        xUser "CreateUserAccount" {
            Ensure = "Present"
            Username = Split-Path -Path $Credential.Username -Leaf
            Password = $Credential
            FullName = "Baltic Apprentice"
            Description = "Baltic Apprentice"
            PasswordNeverExpires = $true
            PasswordChangeRequired = $false
            PasswordChangeNotAllowed = $true
        }

        # This resource block adds user to a spacific group
        xGroup "AddToRemoteDesktopUserGroup"
        {
            GroupName = "Remote Desktop Users"
            Ensure = "Present"
            MembersToInclude = Split-Path -Path $Credential.Username -Leaf
            DependsOn = "[xUser]CreateUserAccount"
        }

        # This resource block adds user to a spacific group
        xGroup "AddToHyperVAdministratorGroup"
        {
            GroupName = "Hyper-V Administrators"
            Ensure = "Present"
            MembersToInclude = Split-Path -Path $Credential.Username -Leaf
            DependsOn = "[xUser]CreateUserAccount"
        }

        # This resource block ensures that a Windows Features (Roles) is present
        xWindowsFeatureSet "AddHyperVFeatures"
        {
            Name = $features
            Ensure = "Present"
            IncludeAllSubFeature = $true
        }

        # This resource block ensures that the file is executed
        xScript "SetDefaultVirtualHardDiskLocation"
        {
            SetScript = { 
                Set-VMHost -VirtualHardDiskPath "C:\Users\Public\Documents\Hyper-V\Virtual hard disks"
            }
            TestScript = { $false }
            GetScript = { 
                # Do Nothing
            }
            DependsOn = "[xWindowsFeatureSet]AddHyperVFeatures"
        }

        # This resource block ensures that the file is executed
        xScript "RunvSwitchForNestedVms"
        {
            SetScript = { 
                New-VMSwitch -SwitchName "Int-vSwitch" -SwitchType Private
            }
            TestScript = { $false }
            GetScript = { 
                # Do Nothing
            }
            DependsOn = "[xWindowsFeatureSet]AddHyperVFeatures"
        }

        # This resource block ensures that the file is executed
        xScript "RunvSwitchForNat"
        {
            SetScript = { 
                New-VMSwitch -SwitchName "Int-vSwitch" -SwitchType Internal
                New-NetIPAddress -InterfaceAlias "vEthernet (Int-vSwitch)" -IPAddress 172.16.20.254 -PrefixLength 24
                New-NetNat -Name "Nat-VM" -InternalIPInterfaceAddressPrefix 172.16.20.0/24
            }
            TestScript = { $false }
            GetScript = { 
                # Do Nothing
            }
            DependsOn = "[xWindowsFeatureSet]AddHyperVFeatures"
        }

        # This resource block ensure that Enhanced Session mode is set to true in Hyper-V
        xscript "SetHyperVEnhancedSessionMode"
        {
            SetScript = {
                Set-VMHost -EnableEnhancedSessionMode $true
            }
            TestScript = { $false }
            GetScript = {
                # Do nothing
            }
            DependsOn = "[xWindowsFeatureSet]AddHyperVFeatures"
        }

        # This resource block ensures that the file or command is executed
        xScript "SetRdpTimeZone"
        {
            SetScript = {
                New-ItemProperty -ErrorAction SilentlyContinue -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services" -Name "fEnableTimeZoneRedirection" -Value "1" -PropertyType DWORD -Force
            }
            TestScript = { $false }
            GetScript = { 
                # Do Nothing
            }
        }

        # This resource block sets Performance Options -> Visual Effects to
        # "Adjust for best performance" for every user: the Default profile (so any
        # account created later inherits it), every profile already on disk, and any
        # hive that is currently loaded. These are per-user (HKCU) settings, so there
        # is no single machine-wide value to set.
        xScript "SetVisualEffectsBestPerformance"
        {
            SetScript = {
                $ErrorActionPreference = "Stop"

                function Set-VisualEffects {
                    param ([string] $HiveRoot)

                    # The values Windows writes itself when "Adjust for best performance"
                    # is picked. Declared in here so the function does not rely on
                    # variables in the caller's scope.
                    $dwordValues = @{
                        "Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects" = @{ VisualFXSetting = 2 }
                        "Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"      = @{ ListviewAlphaSelect = 0; ListviewShadow = 0; TaskbarAnimations = 0; IconsOnly = 1 }
                        "Software\Microsoft\Windows\DWM"                                   = @{ EnableAeroPeek = 0; AlwaysHibernateThumbnails = 0 }
                    }

                    $stringValues = @{
                        "Control Panel\Desktop"               = @{ DragFullWindows = "0"; FontSmoothing = "0" }
                        "Control Panel\Desktop\WindowMetrics" = @{ MinAnimate = "0" }
                    }

                    $binaryValues = @{
                        "Control Panel\Desktop" = @{ UserPreferencesMask = [byte[]](0x90, 0x12, 0x03, 0x80, 0x10, 0x00, 0x00, 0x00) }
                    }

                    foreach ($set in @(
                        @{ Values = $dwordValues;  Type = "DWord"  },
                        @{ Values = $stringValues; Type = "String" },
                        @{ Values = $binaryValues; Type = "Binary" }
                    )) {
                        foreach ($subKey in $set.Values.Keys) {
                            $keyPath = Join-Path -Path $HiveRoot -ChildPath $subKey
                            if (-not (Test-Path -Path $keyPath)) {
                                New-Item -Path $keyPath -Force | Out-Null
                            }
                            foreach ($name in $set.Values[$subKey].Keys) {
                                New-ItemProperty -Path $keyPath -Name $name -Value $set.Values[$subKey][$name] -PropertyType $set.Type -Force | Out-Null
                            }
                        }
                    }
                }

                # Hives of real users that are already loaded. The S-1-5-21-* filter
                # deliberately skips the built-in service accounts (S-1-5-18/19/20) and
                # .DEFAULT, which is an alias for LocalSystem rather than the Default
                # profile and so has no bearing on accounts created later.
                $loadedSids = @(Get-ChildItem -Path "Registry::HKEY_USERS" |
                    Where-Object { $_.PSChildName -like "S-1-5-21-*" -and $_.PSChildName -notlike "*_Classes" } |
                    Select-Object -ExpandProperty PSChildName)

                foreach ($sid in $loadedSids) {
                    Set-VisualEffects -HiveRoot "Registry::HKEY_USERS\$sid"
                }

                # Profiles on disk whose hive is not loaded, plus the Default profile.
                # The value under ProfileList is ProfileImagePath, not ProfilePath. The
                # SID filter runs before it is read, so entries that do not carry it are
                # never touched, and GetValue is used in place of property access: DSC
                # runs these script blocks under Set-StrictMode, where reading a property
                # that does not exist is a terminating error rather than $null.
                $targets = @(Get-ChildItem -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList" |
                    Where-Object { $_.PSChildName -like "S-1-5-21-*" -and $_.PSChildName -notin $loadedSids } |
                    ForEach-Object {
                        $profilePath = $_.GetValue("ProfileImagePath")
                        if ($profilePath) {
                            [pscustomobject]@{ Sid = $_.PSChildName; Path = $profilePath }
                        }
                    })

                $targets += [pscustomobject]@{ Sid = "DefaultUser"; Path = "$env:SystemDrive\Users\Default" }

                foreach ($target in $targets) {
                    $hiveFile = Join-Path -Path $target.Path -ChildPath "NTUSER.DAT"
                    # SilentlyContinue because an unreachable or orphaned profile path
                    # raises access denied, which would be terminating under Stop
                    if (-not (Test-Path -LiteralPath $hiveFile -ErrorAction SilentlyContinue)) { continue }

                    $mountName = "DSC_$($target.Sid)"
                    & reg.exe load "HKU\$mountName" $hiveFile | Out-Null
                    if ($LASTEXITCODE -ne 0) { continue }

                    try {
                        Set-VisualEffects -HiveRoot "Registry::HKEY_USERS\$mountName"
                    }
                    finally {
                        [GC]::Collect()
                        [GC]::WaitForPendingFinalizers()
                        & reg.exe unload "HKU\$mountName" | Out-Null
                    }
                }
            }

            TestScript = {
                # In desired state when VisualFXSetting is 2 for every real user hive and
                # every profile on disk, including the Default profile. Values are read
                # with GetValue rather than Get-ItemProperty because DSC runs these script
                # blocks under Set-StrictMode, where reading a property that does not
                # exist is a terminating error that -ErrorAction cannot suppress.
                function Get-VisualFXSetting {
                    param ([string] $HiveRoot)

                    $key = Get-Item -Path "$HiveRoot\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects" -ErrorAction SilentlyContinue
                    if ($null -eq $key) { return $null }
                    return $key.GetValue("VisualFXSetting")
                }

                # Must use the same SID filter as SetScript, or the hives SetScript
                # deliberately skips would keep this test returning $false for ever
                $loadedSids = @(Get-ChildItem -Path "Registry::HKEY_USERS" -ErrorAction SilentlyContinue |
                    Where-Object { $_.PSChildName -like "S-1-5-21-*" -and $_.PSChildName -notlike "*_Classes" } |
                    Select-Object -ExpandProperty PSChildName)

                foreach ($sid in $loadedSids) {
                    if ((Get-VisualFXSetting -HiveRoot "Registry::HKEY_USERS\$sid") -ne 2) { return $false }
                }

                $targets = @(Get-ChildItem -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList" -ErrorAction SilentlyContinue |
                    Where-Object { $_.PSChildName -like "S-1-5-21-*" -and $_.PSChildName -notin $loadedSids } |
                    ForEach-Object {
                        $profilePath = $_.GetValue("ProfileImagePath")
                        if ($profilePath) {
                            [pscustomobject]@{ Sid = $_.PSChildName; Path = $profilePath }
                        }
                    })

                $targets += [pscustomobject]@{ Sid = "DefaultUser"; Path = "$env:SystemDrive\Users\Default" }

                foreach ($target in $targets) {
                    $hiveFile = Join-Path -Path $target.Path -ChildPath "NTUSER.DAT"
                    # SilentlyContinue because an unreachable or orphaned profile path
                    # raises access denied, which would be terminating under Stop
                    if (-not (Test-Path -LiteralPath $hiveFile -ErrorAction SilentlyContinue)) { continue }

                    $mountName = "DSCTest_$($target.Sid)"
                    & reg.exe load "HKU\$mountName" $hiveFile | Out-Null

                    # A hive that cannot be mounted is skipped rather than reported as
                    # non-compliant: SetScript skips it too, so returning $false here
                    # would put the LCM into a Set on every consistency check for ever
                    if ($LASTEXITCODE -ne 0) { continue }

                    try {
                        if ((Get-VisualFXSetting -HiveRoot "Registry::HKEY_USERS\$mountName") -ne 2) { return $false }
                    }
                    finally {
                        [GC]::Collect()
                        [GC]::WaitForPendingFinalizers()
                        & reg.exe unload "HKU\$mountName" | Out-Null
                    }
                }

                return $true
            }

            GetScript = {
                $hiveFile = "$env:SystemDrive\Users\Default\NTUSER.DAT"
                $result = "Unknown"

                & reg.exe load "HKU\DSCGet_DefaultUser" $hiveFile | Out-Null
                if ($LASTEXITCODE -eq 0) {
                    try {
                        $key = Get-Item -Path "Registry::HKEY_USERS\DSCGet_DefaultUser\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects" -ErrorAction SilentlyContinue
                        if ($null -eq $key) {
                            $result = "Default profile VisualFXSetting is not set"
                        }
                        else {
                            $result = "Default profile VisualFXSetting = $($key.GetValue('VisualFXSetting'))"
                        }
                    }
                    finally {
                        [GC]::Collect()
                        [GC]::WaitForPendingFinalizers()
                        & reg.exe unload "HKU\DSCGet_DefaultUser" | Out-Null
                    }
                }

                return @{ Result = $result }
            }
        }

        # This resource block ensures that the file or command is executed
        xScript "RemoveArtifacts"
        {
            SetScript = {
                Remove-Item "C:\workflow-artifacts\*" -Recurse -Force
                Remove-Item "C:\workflow-artifacts" -Force
                Remove-Item "C:\workflow-artifacts.zip" -Force
                Remove-Item "C:\*_buildlog.log" -Force
            }
            TestScript = { $false }
            GetScript = { 
                # Do Nothing
            }
        }
    }
    
}

Configuration xBaL4NetEngC4LabCfg {
    [CmdletBinding()]

    Param (
        
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.PSCredential]
        [System.Management.Automation.Credential()]
        $Credential
    )

    Import-DscResource -ModuleName xPSDesiredStateConfiguration

    $features = @("Hyper-V", "RSAT-Hyper-V-Tools", "Hyper-V-Tools", "Hyper-V-PowerShell")

    Node localhost {

        LocalConfigurationManager {
            RebootNodeIfNeeded = $true
        }

        # This resource block create a local user
        xUser "CreateUserAccount" {
            Ensure = "Present"
            Username = Split-Path -Path $Credential.Username -Leaf
            Password = $Credential
            FullName = "Baltic Apprentice"
            Description = "Baltic Apprentice"
            PasswordNeverExpires = $true
            PasswordChangeRequired = $false
            PasswordChangeNotAllowed = $true
        }

        # This resource block adds user to a spacific group
        xGroup "AddToRemoteDesktopUserGroup"
        {
            GroupName = "Remote Desktop Users"
            Ensure = "Present"
            MembersToInclude = Split-Path -Path $Credential.Username -Leaf
            DependsOn = "[xUser]CreateUserAccount"
        }

        # This resource block adds user to a spacific group
        xGroup "AddToHyperVAdministratorGroup"
        {
            GroupName = "Hyper-V Administrators"
            Ensure = "Present"
            MembersToInclude = Split-Path -Path $Credential.Username -Leaf
            DependsOn = "[xUser]CreateUserAccount"
        }

        # This resource block ensures that a Windows Features (Roles) is present
        xWindowsFeatureSet "AddHyperVFeatures"
        {
            Name = $features
            Ensure = "Present"
            IncludeAllSubFeature = $true
        }

        # This resource block ensures that the file is executed
        xScript "SetDefaultVirtualHardDiskLocation"
        {
            SetScript = { 
                Set-VMHost -VirtualHardDiskPath "C:\Users\Public\Documents\Hyper-V\Virtual hard disks"
            }
            TestScript = { $false }
            GetScript = { 
                # Do Nothing
            }
            DependsOn = "[xWindowsFeatureSet]AddHyperVFeatures"
        }

        # This resource block ensures that the file is executed
        xScript "RunvSwitchForNat"
        {
            SetScript = { 
                New-VMSwitch -SwitchName "WAN" -SwitchType Internal
                New-NetIPAddress -InterfaceAlias "vEthernet (WAN)" -IPAddress 172.16.20.254 -PrefixLength 24
                New-NetNat -Name "Nat-VM" -InternalIPInterfaceAddressPrefix 172.16.20.0/24
            }
            TestScript = { $false }
            GetScript = { 
                # Do Nothing
            }
            DependsOn = "[xWindowsFeatureSet]AddHyperVFeatures"
        }

        # This resource block ensures that the file is executed
        xScript "RunvSwitchForNestedVms"
        {
            SetScript = { 
                New-VMSwitch -SwitchName "LAN" -SwitchType Private
                New-VMSwitch -SwitchName "LAN2" -SwitchType Private

            }
            TestScript = { $false }
            GetScript = { 
                # Do Nothing
            }
            DependsOn = "[xWindowsFeatureSet]AddHyperVFeatures"
        }

        # This resource block ensure that Enhanced Session mode is set to true in Hyper-V
        xscript "SetHyperVEnhancedSessionMode"
        {
            SetScript = {
                Set-VMHost -EnableEnhancedSessionMode $true
            }
            TestScript = { $false }
            GetScript = {
                # Do nothing
            }
            DependsOn = "[xWindowsFeatureSet]AddHyperVFeatures"
        }

        xScript "RunCreateVms"
        {
            SetScript = { 
                New-VM -Name "pfSense" -MemoryStartupBytes 1GB -Generation 1 -BootDevice VHD -VHDPath "C:\Users\Public\Documents\Hyper-V\Virtual hard disks\L4NetEngC4\pfsense.vhdx" -SwitchName "WAN"
                Add-VMNetworkAdapter -VMName "pfSense" -SwitchName "LAN"
                Add-VMNetworkAdapter -VMName "pfSense" -SwitchName "LAN2"
                New-VM -Name "ManagementServer" -MemoryStartupBytes 2GB -Generation 2 -BootDevice VHD -VHDPath "C:\Users\Public\Documents\Hyper-V\Virtual hard disks\L4NetEngC4\WinSvr22.vhdx" -SwitchName "LAN"
                Add-VMHardDiskDrive -VMName "ManagementServer" -Path "C:\Users\Public\Documents\Hyper-V\Virtual hard disks\L4NetEngC4\Data01.vhdx"
                New-VM -Name "Client1" -MemoryStartupBytes 1GB -Generation 1 -BootDevice VHD -VHDPath "C:\Users\Public\Documents\Hyper-V\Virtual hard disks\L4NetEngC4\Win10-Client01.vhdx" -SwitchName "LAN"
                
            }
            TestScript = { $false }
            GetScript = {  
                # Do Nothing
            }
            DependsOn = "[xWindowsFeatureSet]AddHyperVFeatures"
        }

        # This resource block ensures that the file or command is executed
        xScript "SetRdpTimeZone"
        {
            SetScript = {
                New-ItemProperty -ErrorAction SilentlyContinue -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services" -Name "fEnableTimeZoneRedirection" -Value "1" -PropertyType DWORD -Force
            }
            TestScript = { $false }
            GetScript = { 
                # Do Nothing
            }
        }

        # This resource block sets Performance Options -> Visual Effects to
        # "Adjust for best performance" for every user: the Default profile (so any
        # account created later inherits it), every profile already on disk, and any
        # hive that is currently loaded. These are per-user (HKCU) settings, so there
        # is no single machine-wide value to set.
        xScript "SetVisualEffectsBestPerformance"
        {
            SetScript = {
                $ErrorActionPreference = "Stop"

                function Set-VisualEffects {
                    param ([string] $HiveRoot)

                    # The values Windows writes itself when "Adjust for best performance"
                    # is picked. Declared in here so the function does not rely on
                    # variables in the caller's scope.
                    $dwordValues = @{
                        "Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects" = @{ VisualFXSetting = 2 }
                        "Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"      = @{ ListviewAlphaSelect = 0; ListviewShadow = 0; TaskbarAnimations = 0; IconsOnly = 1 }
                        "Software\Microsoft\Windows\DWM"                                   = @{ EnableAeroPeek = 0; AlwaysHibernateThumbnails = 0 }
                    }

                    $stringValues = @{
                        "Control Panel\Desktop"               = @{ DragFullWindows = "0"; FontSmoothing = "0" }
                        "Control Panel\Desktop\WindowMetrics" = @{ MinAnimate = "0" }
                    }

                    $binaryValues = @{
                        "Control Panel\Desktop" = @{ UserPreferencesMask = [byte[]](0x90, 0x12, 0x03, 0x80, 0x10, 0x00, 0x00, 0x00) }
                    }

                    foreach ($set in @(
                        @{ Values = $dwordValues;  Type = "DWord"  },
                        @{ Values = $stringValues; Type = "String" },
                        @{ Values = $binaryValues; Type = "Binary" }
                    )) {
                        foreach ($subKey in $set.Values.Keys) {
                            $keyPath = Join-Path -Path $HiveRoot -ChildPath $subKey
                            if (-not (Test-Path -Path $keyPath)) {
                                New-Item -Path $keyPath -Force | Out-Null
                            }
                            foreach ($name in $set.Values[$subKey].Keys) {
                                New-ItemProperty -Path $keyPath -Name $name -Value $set.Values[$subKey][$name] -PropertyType $set.Type -Force | Out-Null
                            }
                        }
                    }
                }

                # Hives of real users that are already loaded. The S-1-5-21-* filter
                # deliberately skips the built-in service accounts (S-1-5-18/19/20) and
                # .DEFAULT, which is an alias for LocalSystem rather than the Default
                # profile and so has no bearing on accounts created later.
                $loadedSids = @(Get-ChildItem -Path "Registry::HKEY_USERS" |
                    Where-Object { $_.PSChildName -like "S-1-5-21-*" -and $_.PSChildName -notlike "*_Classes" } |
                    Select-Object -ExpandProperty PSChildName)

                foreach ($sid in $loadedSids) {
                    Set-VisualEffects -HiveRoot "Registry::HKEY_USERS\$sid"
                }

                # Profiles on disk whose hive is not loaded, plus the Default profile.
                # The value under ProfileList is ProfileImagePath, not ProfilePath. The
                # SID filter runs before it is read, so entries that do not carry it are
                # never touched, and GetValue is used in place of property access: DSC
                # runs these script blocks under Set-StrictMode, where reading a property
                # that does not exist is a terminating error rather than $null.
                $targets = @(Get-ChildItem -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList" |
                    Where-Object { $_.PSChildName -like "S-1-5-21-*" -and $_.PSChildName -notin $loadedSids } |
                    ForEach-Object {
                        $profilePath = $_.GetValue("ProfileImagePath")
                        if ($profilePath) {
                            [pscustomobject]@{ Sid = $_.PSChildName; Path = $profilePath }
                        }
                    })

                $targets += [pscustomobject]@{ Sid = "DefaultUser"; Path = "$env:SystemDrive\Users\Default" }

                foreach ($target in $targets) {
                    $hiveFile = Join-Path -Path $target.Path -ChildPath "NTUSER.DAT"
                    # SilentlyContinue because an unreachable or orphaned profile path
                    # raises access denied, which would be terminating under Stop
                    if (-not (Test-Path -LiteralPath $hiveFile -ErrorAction SilentlyContinue)) { continue }

                    $mountName = "DSC_$($target.Sid)"
                    & reg.exe load "HKU\$mountName" $hiveFile | Out-Null
                    if ($LASTEXITCODE -ne 0) { continue }

                    try {
                        Set-VisualEffects -HiveRoot "Registry::HKEY_USERS\$mountName"
                    }
                    finally {
                        [GC]::Collect()
                        [GC]::WaitForPendingFinalizers()
                        & reg.exe unload "HKU\$mountName" | Out-Null
                    }
                }
            }

            TestScript = {
                # In desired state when VisualFXSetting is 2 for every real user hive and
                # every profile on disk, including the Default profile. Values are read
                # with GetValue rather than Get-ItemProperty because DSC runs these script
                # blocks under Set-StrictMode, where reading a property that does not
                # exist is a terminating error that -ErrorAction cannot suppress.
                function Get-VisualFXSetting {
                    param ([string] $HiveRoot)

                    $key = Get-Item -Path "$HiveRoot\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects" -ErrorAction SilentlyContinue
                    if ($null -eq $key) { return $null }
                    return $key.GetValue("VisualFXSetting")
                }

                # Must use the same SID filter as SetScript, or the hives SetScript
                # deliberately skips would keep this test returning $false for ever
                $loadedSids = @(Get-ChildItem -Path "Registry::HKEY_USERS" -ErrorAction SilentlyContinue |
                    Where-Object { $_.PSChildName -like "S-1-5-21-*" -and $_.PSChildName -notlike "*_Classes" } |
                    Select-Object -ExpandProperty PSChildName)

                foreach ($sid in $loadedSids) {
                    if ((Get-VisualFXSetting -HiveRoot "Registry::HKEY_USERS\$sid") -ne 2) { return $false }
                }

                $targets = @(Get-ChildItem -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList" -ErrorAction SilentlyContinue |
                    Where-Object { $_.PSChildName -like "S-1-5-21-*" -and $_.PSChildName -notin $loadedSids } |
                    ForEach-Object {
                        $profilePath = $_.GetValue("ProfileImagePath")
                        if ($profilePath) {
                            [pscustomobject]@{ Sid = $_.PSChildName; Path = $profilePath }
                        }
                    })

                $targets += [pscustomobject]@{ Sid = "DefaultUser"; Path = "$env:SystemDrive\Users\Default" }

                foreach ($target in $targets) {
                    $hiveFile = Join-Path -Path $target.Path -ChildPath "NTUSER.DAT"
                    # SilentlyContinue because an unreachable or orphaned profile path
                    # raises access denied, which would be terminating under Stop
                    if (-not (Test-Path -LiteralPath $hiveFile -ErrorAction SilentlyContinue)) { continue }

                    $mountName = "DSCTest_$($target.Sid)"
                    & reg.exe load "HKU\$mountName" $hiveFile | Out-Null

                    # A hive that cannot be mounted is skipped rather than reported as
                    # non-compliant: SetScript skips it too, so returning $false here
                    # would put the LCM into a Set on every consistency check for ever
                    if ($LASTEXITCODE -ne 0) { continue }

                    try {
                        if ((Get-VisualFXSetting -HiveRoot "Registry::HKEY_USERS\$mountName") -ne 2) { return $false }
                    }
                    finally {
                        [GC]::Collect()
                        [GC]::WaitForPendingFinalizers()
                        & reg.exe unload "HKU\$mountName" | Out-Null
                    }
                }

                return $true
            }

            GetScript = {
                $hiveFile = "$env:SystemDrive\Users\Default\NTUSER.DAT"
                $result = "Unknown"

                & reg.exe load "HKU\DSCGet_DefaultUser" $hiveFile | Out-Null
                if ($LASTEXITCODE -eq 0) {
                    try {
                        $key = Get-Item -Path "Registry::HKEY_USERS\DSCGet_DefaultUser\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects" -ErrorAction SilentlyContinue
                        if ($null -eq $key) {
                            $result = "Default profile VisualFXSetting is not set"
                        }
                        else {
                            $result = "Default profile VisualFXSetting = $($key.GetValue('VisualFXSetting'))"
                        }
                    }
                    finally {
                        [GC]::Collect()
                        [GC]::WaitForPendingFinalizers()
                        & reg.exe unload "HKU\DSCGet_DefaultUser" | Out-Null
                    }
                }

                return @{ Result = $result }
            }
        }

        # This resource block ensures that the file or command is executed
        xScript "RemoveArtifacts"
        {
            SetScript = {
                Remove-Item "C:\workflow-artifacts\*" -Recurse -Force
                Remove-Item "C:\workflow-artifacts" -Force
                Remove-Item "C:\workflow-artifacts.zip" -Force
                Remove-Item "C:\*_buildlog.log" -Force
            }
            TestScript = { $false }
            GetScript = { 
                # Do Nothing
            }
        }
    }
    
}

Configuration xBaL4NetEngC5LabCfg {
    [CmdletBinding()]

    Param (
        
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.PSCredential]
        [System.Management.Automation.Credential()]
        $Credential
    )

    Import-DscResource -ModuleName xPSDesiredStateConfiguration

    $features = @("Hyper-V", "RSAT-Hyper-V-Tools", "Hyper-V-Tools", "Hyper-V-PowerShell")

    Node localhost {

        LocalConfigurationManager {
            RebootNodeIfNeeded = $true
        }

        # This resource block create a local user
        xUser "CreateUserAccount" {
            Ensure = "Present"
            Username = Split-Path -Path $Credential.Username -Leaf
            Password = $Credential
            FullName = "Baltic Apprentice"
            Description = "Baltic Apprentice"
            PasswordNeverExpires = $true
            PasswordChangeRequired = $false
            PasswordChangeNotAllowed = $true
        }

        # This resource block adds user to a spacific group
        xGroup "AddToRemoteDesktopUserGroup"
        {
            GroupName = "Remote Desktop Users"
            Ensure = "Present"
            MembersToInclude = Split-Path -Path $Credential.Username -Leaf
            DependsOn = "[xUser]CreateUserAccount"
        }

        # This resource block adds user to a spacific group
        xGroup "AddToHyperVAdministratorGroup"
        {
            GroupName = "Hyper-V Administrators"
            Ensure = "Present"
            MembersToInclude = Split-Path -Path $Credential.Username -Leaf
            DependsOn = "[xUser]CreateUserAccount"
        }

        # This resource block ensures that a Windows Features (Roles) is present
        xWindowsFeatureSet "AddHyperVFeatures"
        {
            Name = $features
            Ensure = "Present"
            IncludeAllSubFeature = $true
        }

        # This resource block ensure that Enhanced Session mode is set to true in Hyper-V
        xscript "SetHyperVEnhancedSessionMode"
        {
            SetScript = {
                Set-VMHost -EnableEnhancedSessionMode $true
            }
            TestScript = { $false }
            GetScript = {
                # Do nothing
            }
            DependsOn = "[xWindowsFeatureSet]AddHyperVFeatures"
        }

        # This resource block sets Performance Options -> Visual Effects to
        # "Adjust for best performance" for every user: the Default profile (so any
        # account created later inherits it), every profile already on disk, and any
        # hive that is currently loaded. These are per-user (HKCU) settings, so there
        # is no single machine-wide value to set.
        xScript "SetVisualEffectsBestPerformance"
        {
            SetScript = {
                $ErrorActionPreference = "Stop"

                function Set-VisualEffects {
                    param ([string] $HiveRoot)

                    # The values Windows writes itself when "Adjust for best performance"
                    # is picked. Declared in here so the function does not rely on
                    # variables in the caller's scope.
                    $dwordValues = @{
                        "Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects" = @{ VisualFXSetting = 2 }
                        "Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"      = @{ ListviewAlphaSelect = 0; ListviewShadow = 0; TaskbarAnimations = 0; IconsOnly = 1 }
                        "Software\Microsoft\Windows\DWM"                                   = @{ EnableAeroPeek = 0; AlwaysHibernateThumbnails = 0 }
                    }

                    $stringValues = @{
                        "Control Panel\Desktop"               = @{ DragFullWindows = "0"; FontSmoothing = "0" }
                        "Control Panel\Desktop\WindowMetrics" = @{ MinAnimate = "0" }
                    }

                    $binaryValues = @{
                        "Control Panel\Desktop" = @{ UserPreferencesMask = [byte[]](0x90, 0x12, 0x03, 0x80, 0x10, 0x00, 0x00, 0x00) }
                    }

                    foreach ($set in @(
                        @{ Values = $dwordValues;  Type = "DWord"  },
                        @{ Values = $stringValues; Type = "String" },
                        @{ Values = $binaryValues; Type = "Binary" }
                    )) {
                        foreach ($subKey in $set.Values.Keys) {
                            $keyPath = Join-Path -Path $HiveRoot -ChildPath $subKey
                            if (-not (Test-Path -Path $keyPath)) {
                                New-Item -Path $keyPath -Force | Out-Null
                            }
                            foreach ($name in $set.Values[$subKey].Keys) {
                                New-ItemProperty -Path $keyPath -Name $name -Value $set.Values[$subKey][$name] -PropertyType $set.Type -Force | Out-Null
                            }
                        }
                    }
                }

                # Hives of real users that are already loaded. The S-1-5-21-* filter
                # deliberately skips the built-in service accounts (S-1-5-18/19/20) and
                # .DEFAULT, which is an alias for LocalSystem rather than the Default
                # profile and so has no bearing on accounts created later.
                $loadedSids = @(Get-ChildItem -Path "Registry::HKEY_USERS" |
                    Where-Object { $_.PSChildName -like "S-1-5-21-*" -and $_.PSChildName -notlike "*_Classes" } |
                    Select-Object -ExpandProperty PSChildName)

                foreach ($sid in $loadedSids) {
                    Set-VisualEffects -HiveRoot "Registry::HKEY_USERS\$sid"
                }

                # Profiles on disk whose hive is not loaded, plus the Default profile.
                # The value under ProfileList is ProfileImagePath, not ProfilePath. The
                # SID filter runs before it is read, so entries that do not carry it are
                # never touched, and GetValue is used in place of property access: DSC
                # runs these script blocks under Set-StrictMode, where reading a property
                # that does not exist is a terminating error rather than $null.
                $targets = @(Get-ChildItem -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList" |
                    Where-Object { $_.PSChildName -like "S-1-5-21-*" -and $_.PSChildName -notin $loadedSids } |
                    ForEach-Object {
                        $profilePath = $_.GetValue("ProfileImagePath")
                        if ($profilePath) {
                            [pscustomobject]@{ Sid = $_.PSChildName; Path = $profilePath }
                        }
                    })

                $targets += [pscustomobject]@{ Sid = "DefaultUser"; Path = "$env:SystemDrive\Users\Default" }

                foreach ($target in $targets) {
                    $hiveFile = Join-Path -Path $target.Path -ChildPath "NTUSER.DAT"
                    # SilentlyContinue because an unreachable or orphaned profile path
                    # raises access denied, which would be terminating under Stop
                    if (-not (Test-Path -LiteralPath $hiveFile -ErrorAction SilentlyContinue)) { continue }

                    $mountName = "DSC_$($target.Sid)"
                    & reg.exe load "HKU\$mountName" $hiveFile | Out-Null
                    if ($LASTEXITCODE -ne 0) { continue }

                    try {
                        Set-VisualEffects -HiveRoot "Registry::HKEY_USERS\$mountName"
                    }
                    finally {
                        [GC]::Collect()
                        [GC]::WaitForPendingFinalizers()
                        & reg.exe unload "HKU\$mountName" | Out-Null
                    }
                }
            }

            TestScript = {
                # In desired state when VisualFXSetting is 2 for every real user hive and
                # every profile on disk, including the Default profile. Values are read
                # with GetValue rather than Get-ItemProperty because DSC runs these script
                # blocks under Set-StrictMode, where reading a property that does not
                # exist is a terminating error that -ErrorAction cannot suppress.
                function Get-VisualFXSetting {
                    param ([string] $HiveRoot)

                    $key = Get-Item -Path "$HiveRoot\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects" -ErrorAction SilentlyContinue
                    if ($null -eq $key) { return $null }
                    return $key.GetValue("VisualFXSetting")
                }

                # Must use the same SID filter as SetScript, or the hives SetScript
                # deliberately skips would keep this test returning $false for ever
                $loadedSids = @(Get-ChildItem -Path "Registry::HKEY_USERS" -ErrorAction SilentlyContinue |
                    Where-Object { $_.PSChildName -like "S-1-5-21-*" -and $_.PSChildName -notlike "*_Classes" } |
                    Select-Object -ExpandProperty PSChildName)

                foreach ($sid in $loadedSids) {
                    if ((Get-VisualFXSetting -HiveRoot "Registry::HKEY_USERS\$sid") -ne 2) { return $false }
                }

                $targets = @(Get-ChildItem -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList" -ErrorAction SilentlyContinue |
                    Where-Object { $_.PSChildName -like "S-1-5-21-*" -and $_.PSChildName -notin $loadedSids } |
                    ForEach-Object {
                        $profilePath = $_.GetValue("ProfileImagePath")
                        if ($profilePath) {
                            [pscustomobject]@{ Sid = $_.PSChildName; Path = $profilePath }
                        }
                    })

                $targets += [pscustomobject]@{ Sid = "DefaultUser"; Path = "$env:SystemDrive\Users\Default" }

                foreach ($target in $targets) {
                    $hiveFile = Join-Path -Path $target.Path -ChildPath "NTUSER.DAT"
                    # SilentlyContinue because an unreachable or orphaned profile path
                    # raises access denied, which would be terminating under Stop
                    if (-not (Test-Path -LiteralPath $hiveFile -ErrorAction SilentlyContinue)) { continue }

                    $mountName = "DSCTest_$($target.Sid)"
                    & reg.exe load "HKU\$mountName" $hiveFile | Out-Null

                    # A hive that cannot be mounted is skipped rather than reported as
                    # non-compliant: SetScript skips it too, so returning $false here
                    # would put the LCM into a Set on every consistency check for ever
                    if ($LASTEXITCODE -ne 0) { continue }

                    try {
                        if ((Get-VisualFXSetting -HiveRoot "Registry::HKEY_USERS\$mountName") -ne 2) { return $false }
                    }
                    finally {
                        [GC]::Collect()
                        [GC]::WaitForPendingFinalizers()
                        & reg.exe unload "HKU\$mountName" | Out-Null
                    }
                }

                return $true
            }

            GetScript = {
                $hiveFile = "$env:SystemDrive\Users\Default\NTUSER.DAT"
                $result = "Unknown"

                & reg.exe load "HKU\DSCGet_DefaultUser" $hiveFile | Out-Null
                if ($LASTEXITCODE -eq 0) {
                    try {
                        $key = Get-Item -Path "Registry::HKEY_USERS\DSCGet_DefaultUser\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects" -ErrorAction SilentlyContinue
                        if ($null -eq $key) {
                            $result = "Default profile VisualFXSetting is not set"
                        }
                        else {
                            $result = "Default profile VisualFXSetting = $($key.GetValue('VisualFXSetting'))"
                        }
                    }
                    finally {
                        [GC]::Collect()
                        [GC]::WaitForPendingFinalizers()
                        & reg.exe unload "HKU\DSCGet_DefaultUser" | Out-Null
                    }
                }

                return @{ Result = $result }
            }
        }

        # This resource block ensures that the file or command is executed
        xScript "RemoveArtifacts"
        {
            SetScript = {
                Remove-Item "C:\workflow-artifacts\*" -Recurse -Force
                Remove-Item "C:\workflow-artifacts" -Force
                Remove-Item "C:\workflow-artifacts.zip" -Force
                Remove-Item "C:\*_buildlog.log" -Force
            }
            TestScript = { $false }
            GetScript = { 
                # Do Nothing
            }
        }
    }
    
}

Configuration xBaL4NetEngC7LabCfg {
    [CmdletBinding()]

    Param (
        
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.PSCredential]
        [System.Management.Automation.Credential()]
        $Credential
    )

    Import-DscResource -ModuleName xPSDesiredStateConfiguration

    $features = @("Hyper-V", "RSAT-Hyper-V-Tools", "Hyper-V-Tools", "Hyper-V-PowerShell")

    Node localhost {

        LocalConfigurationManager {
            RebootNodeIfNeeded = $true
        }

        # This resource block create a local user
        xUser "CreateUserAccount" {
            Ensure = "Present"
            Username = Split-Path -Path $Credential.Username -Leaf
            Password = $Credential
            FullName = "Baltic Apprentice"
            Description = "Baltic Apprentice"
            PasswordNeverExpires = $true
            PasswordChangeRequired = $false
            PasswordChangeNotAllowed = $true
        }

        # This resource block adds user to a spacific group
        xGroup "AddToRemoteDesktopUserGroup"
        {
            GroupName = "Remote Desktop Users"
            Ensure = "Present"
            MembersToInclude = Split-Path -Path $Credential.Username -Leaf
            DependsOn = "[xUser]CreateUserAccount"
        }

        # This resource block adds user to a spacific group
        xGroup "AddToHyperVAdministratorGroup"
        {
            GroupName = "Hyper-V Administrators"
            Ensure = "Present"
            MembersToInclude = Split-Path -Path $Credential.Username -Leaf
            DependsOn = "[xUser]CreateUserAccount"
        }

        # This resource block ensures that a Windows Features (Roles) is present
        xWindowsFeatureSet "AddHyperVFeatures"
        {
            Name = $features
            Ensure = "Present"
            IncludeAllSubFeature = $true
        }

        # This resource block ensure that Enhanced Session mode is set to true in Hyper-V
        xscript "SetHyperVEnhancedSessionMode"
        {
            SetScript = {
                Set-VMHost -EnableEnhancedSessionMode $true
            }
            TestScript = { $false }
            GetScript = {
                # Do nothing
            }
            DependsOn = "[xWindowsFeatureSet]AddHyperVFeatures"
        }

        # This resource block sets Performance Options -> Visual Effects to
        # "Adjust for best performance" for every user: the Default profile (so any
        # account created later inherits it), every profile already on disk, and any
        # hive that is currently loaded. These are per-user (HKCU) settings, so there
        # is no single machine-wide value to set.
        xScript "SetVisualEffectsBestPerformance"
        {
            SetScript = {
                $ErrorActionPreference = "Stop"

                function Set-VisualEffects {
                    param ([string] $HiveRoot)

                    # The values Windows writes itself when "Adjust for best performance"
                    # is picked. Declared in here so the function does not rely on
                    # variables in the caller's scope.
                    $dwordValues = @{
                        "Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects" = @{ VisualFXSetting = 2 }
                        "Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"      = @{ ListviewAlphaSelect = 0; ListviewShadow = 0; TaskbarAnimations = 0; IconsOnly = 1 }
                        "Software\Microsoft\Windows\DWM"                                   = @{ EnableAeroPeek = 0; AlwaysHibernateThumbnails = 0 }
                    }

                    $stringValues = @{
                        "Control Panel\Desktop"               = @{ DragFullWindows = "0"; FontSmoothing = "0" }
                        "Control Panel\Desktop\WindowMetrics" = @{ MinAnimate = "0" }
                    }

                    $binaryValues = @{
                        "Control Panel\Desktop" = @{ UserPreferencesMask = [byte[]](0x90, 0x12, 0x03, 0x80, 0x10, 0x00, 0x00, 0x00) }
                    }

                    foreach ($set in @(
                        @{ Values = $dwordValues;  Type = "DWord"  },
                        @{ Values = $stringValues; Type = "String" },
                        @{ Values = $binaryValues; Type = "Binary" }
                    )) {
                        foreach ($subKey in $set.Values.Keys) {
                            $keyPath = Join-Path -Path $HiveRoot -ChildPath $subKey
                            if (-not (Test-Path -Path $keyPath)) {
                                New-Item -Path $keyPath -Force | Out-Null
                            }
                            foreach ($name in $set.Values[$subKey].Keys) {
                                New-ItemProperty -Path $keyPath -Name $name -Value $set.Values[$subKey][$name] -PropertyType $set.Type -Force | Out-Null
                            }
                        }
                    }
                }

                # Hives of real users that are already loaded. The S-1-5-21-* filter
                # deliberately skips the built-in service accounts (S-1-5-18/19/20) and
                # .DEFAULT, which is an alias for LocalSystem rather than the Default
                # profile and so has no bearing on accounts created later.
                $loadedSids = @(Get-ChildItem -Path "Registry::HKEY_USERS" |
                    Where-Object { $_.PSChildName -like "S-1-5-21-*" -and $_.PSChildName -notlike "*_Classes" } |
                    Select-Object -ExpandProperty PSChildName)

                foreach ($sid in $loadedSids) {
                    Set-VisualEffects -HiveRoot "Registry::HKEY_USERS\$sid"
                }

                # Profiles on disk whose hive is not loaded, plus the Default profile.
                # The value under ProfileList is ProfileImagePath, not ProfilePath. The
                # SID filter runs before it is read, so entries that do not carry it are
                # never touched, and GetValue is used in place of property access: DSC
                # runs these script blocks under Set-StrictMode, where reading a property
                # that does not exist is a terminating error rather than $null.
                $targets = @(Get-ChildItem -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList" |
                    Where-Object { $_.PSChildName -like "S-1-5-21-*" -and $_.PSChildName -notin $loadedSids } |
                    ForEach-Object {
                        $profilePath = $_.GetValue("ProfileImagePath")
                        if ($profilePath) {
                            [pscustomobject]@{ Sid = $_.PSChildName; Path = $profilePath }
                        }
                    })

                $targets += [pscustomobject]@{ Sid = "DefaultUser"; Path = "$env:SystemDrive\Users\Default" }

                foreach ($target in $targets) {
                    $hiveFile = Join-Path -Path $target.Path -ChildPath "NTUSER.DAT"
                    # SilentlyContinue because an unreachable or orphaned profile path
                    # raises access denied, which would be terminating under Stop
                    if (-not (Test-Path -LiteralPath $hiveFile -ErrorAction SilentlyContinue)) { continue }

                    $mountName = "DSC_$($target.Sid)"
                    & reg.exe load "HKU\$mountName" $hiveFile | Out-Null
                    if ($LASTEXITCODE -ne 0) { continue }

                    try {
                        Set-VisualEffects -HiveRoot "Registry::HKEY_USERS\$mountName"
                    }
                    finally {
                        [GC]::Collect()
                        [GC]::WaitForPendingFinalizers()
                        & reg.exe unload "HKU\$mountName" | Out-Null
                    }
                }
            }

            TestScript = {
                # In desired state when VisualFXSetting is 2 for every real user hive and
                # every profile on disk, including the Default profile. Values are read
                # with GetValue rather than Get-ItemProperty because DSC runs these script
                # blocks under Set-StrictMode, where reading a property that does not
                # exist is a terminating error that -ErrorAction cannot suppress.
                function Get-VisualFXSetting {
                    param ([string] $HiveRoot)

                    $key = Get-Item -Path "$HiveRoot\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects" -ErrorAction SilentlyContinue
                    if ($null -eq $key) { return $null }
                    return $key.GetValue("VisualFXSetting")
                }

                # Must use the same SID filter as SetScript, or the hives SetScript
                # deliberately skips would keep this test returning $false for ever
                $loadedSids = @(Get-ChildItem -Path "Registry::HKEY_USERS" -ErrorAction SilentlyContinue |
                    Where-Object { $_.PSChildName -like "S-1-5-21-*" -and $_.PSChildName -notlike "*_Classes" } |
                    Select-Object -ExpandProperty PSChildName)

                foreach ($sid in $loadedSids) {
                    if ((Get-VisualFXSetting -HiveRoot "Registry::HKEY_USERS\$sid") -ne 2) { return $false }
                }

                $targets = @(Get-ChildItem -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList" -ErrorAction SilentlyContinue |
                    Where-Object { $_.PSChildName -like "S-1-5-21-*" -and $_.PSChildName -notin $loadedSids } |
                    ForEach-Object {
                        $profilePath = $_.GetValue("ProfileImagePath")
                        if ($profilePath) {
                            [pscustomobject]@{ Sid = $_.PSChildName; Path = $profilePath }
                        }
                    })

                $targets += [pscustomobject]@{ Sid = "DefaultUser"; Path = "$env:SystemDrive\Users\Default" }

                foreach ($target in $targets) {
                    $hiveFile = Join-Path -Path $target.Path -ChildPath "NTUSER.DAT"
                    # SilentlyContinue because an unreachable or orphaned profile path
                    # raises access denied, which would be terminating under Stop
                    if (-not (Test-Path -LiteralPath $hiveFile -ErrorAction SilentlyContinue)) { continue }

                    $mountName = "DSCTest_$($target.Sid)"
                    & reg.exe load "HKU\$mountName" $hiveFile | Out-Null

                    # A hive that cannot be mounted is skipped rather than reported as
                    # non-compliant: SetScript skips it too, so returning $false here
                    # would put the LCM into a Set on every consistency check for ever
                    if ($LASTEXITCODE -ne 0) { continue }

                    try {
                        if ((Get-VisualFXSetting -HiveRoot "Registry::HKEY_USERS\$mountName") -ne 2) { return $false }
                    }
                    finally {
                        [GC]::Collect()
                        [GC]::WaitForPendingFinalizers()
                        & reg.exe unload "HKU\$mountName" | Out-Null
                    }
                }

                return $true
            }

            GetScript = {
                $hiveFile = "$env:SystemDrive\Users\Default\NTUSER.DAT"
                $result = "Unknown"

                & reg.exe load "HKU\DSCGet_DefaultUser" $hiveFile | Out-Null
                if ($LASTEXITCODE -eq 0) {
                    try {
                        $key = Get-Item -Path "Registry::HKEY_USERS\DSCGet_DefaultUser\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects" -ErrorAction SilentlyContinue
                        if ($null -eq $key) {
                            $result = "Default profile VisualFXSetting is not set"
                        }
                        else {
                            $result = "Default profile VisualFXSetting = $($key.GetValue('VisualFXSetting'))"
                        }
                    }
                    finally {
                        [GC]::Collect()
                        [GC]::WaitForPendingFinalizers()
                        & reg.exe unload "HKU\DSCGet_DefaultUser" | Out-Null
                    }
                }

                return @{ Result = $result }
            }
        }

        # This resource block ensures that the file or command is executed
        xScript "RemoveArtifacts"
        {
            SetScript = {
                Remove-Item "C:\workflow-artifacts\*" -Recurse -Force
                Remove-Item "C:\workflow-artifacts" -Force
                Remove-Item "C:\workflow-artifacts.zip" -Force
                Remove-Item "C:\*_buildlog.log" -Force
            }
            TestScript = { $false }
            GetScript = { 
                # Do Nothing
            }
        }
    }
    
}

Configuration xBaItBootcampLabCfg {
    [CmdletBinding()]

    Param (
        
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.PSCredential]
        [System.Management.Automation.Credential()]
        $Credential
    )

    Import-DscResource -ModuleName xPSDesiredStateConfiguration

    $features = @("Hyper-V", "RSAT-Hyper-V-Tools", "Hyper-V-Tools", "Hyper-V-PowerShell")

    Node localhost {

        LocalConfigurationManager {
            RebootNodeIfNeeded = $true
        }

        # This resource block create a local user
        xUser "CreateUserAccount" {
            Ensure = "Present"
            Username = Split-Path -Path $Credential.Username -Leaf
            Password = $Credential
            FullName = "Baltic Apprentice"
            Description = "Baltic Apprentice"
            PasswordNeverExpires = $true
            PasswordChangeRequired = $false
            PasswordChangeNotAllowed = $true
        }

        # This resource block adds user to a spacific group
        xGroup "AddToRemoteDesktopUserGroup"
        {
            GroupName = "Remote Desktop Users"
            Ensure = "Present"
            MembersToInclude = Split-Path -Path $Credential.Username -Leaf
            DependsOn = "[xUser]CreateUserAccount"
        }

        # This resource block adds user to a spacific group
        xGroup "AddToHyperVAdministratorGroup"
        {
            GroupName = "Hyper-V Administrators"
            Ensure = "Present"
            MembersToInclude = Split-Path -Path $Credential.Username -Leaf
            DependsOn = "[xUser]CreateUserAccount"
        }

        # This resource block ensures that a Windows Features (Roles) is present
        xWindowsFeatureSet "AddHyperVFeatures"
        {
            Name = $features
            Ensure = "Present"
            IncludeAllSubFeature = $true
        }

        # This resource block ensures that the file is executed
        xScript "SetDefaultVirtualHardDiskLocation"
        {
            SetScript = { 
                Set-VMHost -VirtualHardDiskPath "C:\Users\Public\Documents\Hyper-V\Virtual hard disks"
            }
            TestScript = { $false }
            GetScript = { 
                # Do Nothing
            }
            DependsOn = "[xWindowsFeatureSet]AddHyperVFeatures"
        }

        # This resource block ensures that the file is executed
        xScript "RunvSwitchForNestedVms"
        {
            SetScript = { 
                New-VMSwitch -SwitchName "vSwitch" -SwitchType Private
            }
            TestScript = { $false }
            GetScript = { 
                # Do Nothing
            }
            DependsOn = "[xWindowsFeatureSet]AddHyperVFeatures"
        }

        # This resource block ensure that Enhanced Session mode is set to true in Hyper-V
        xscript "SetHyperVEnhancedSessionMode"
        {
            SetScript = {
                Set-VMHost -EnableEnhancedSessionMode $true
            }
            TestScript = { $false }
            GetScript = {
                # Do nothing
            }
            DependsOn = "[xWindowsFeatureSet]AddHyperVFeatures"
        }

        xScript "RunCreateVms"
        {
            SetScript = { 
                New-VM -Name "DC" -MemoryStartupBytes 2GB -Generation 2 -BootDevice VHD -VHDPath "C:\Users\Public\Documents\Hyper-V\Virtual hard disks\ITBootcamp\ITB-DC.vhdx" -SwitchName "vSwitch"                
            }
            TestScript = { $false }
            GetScript = {  
                # Do Nothing
            }
            DependsOn = "[xWindowsFeatureSet]AddHyperVFeatures"
        }

        # This resource block ensures that the file or command is executed
        xScript "SetRdpTimeZone"
        {
            SetScript = {
                New-ItemProperty -ErrorAction SilentlyContinue -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services" -Name "fEnableTimeZoneRedirection" -Value "1" -PropertyType DWORD -Force
            }
            TestScript = { $false }
            GetScript = { 
                # Do Nothing
            }
        }

        # This resource block sets Performance Options -> Visual Effects to
        # "Adjust for best performance" for every user: the Default profile (so any
        # account created later inherits it), every profile already on disk, and any
        # hive that is currently loaded. These are per-user (HKCU) settings, so there
        # is no single machine-wide value to set.
        xScript "SetVisualEffectsBestPerformance"
        {
            SetScript = {
                $ErrorActionPreference = "Stop"

                # The values Windows writes itself when "Adjust for best performance" is picked
                $dwordValues = @{
                    "Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects" = @{ VisualFXSetting = 2 }
                    "Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"      = @{ ListviewAlphaSelect = 0; ListviewShadow = 0; TaskbarAnimations = 0; IconsOnly = 1 }
                    "Software\Microsoft\Windows\DWM"                                   = @{ EnableAeroPeek = 0; AlwaysHibernateThumbnails = 0 }
                }

                $stringValues = @{
                    "Control Panel\Desktop"               = @{ DragFullWindows = "0"; FontSmoothing = "0" }
                    "Control Panel\Desktop\WindowMetrics" = @{ MinAnimate = "0" }
                }

                $binaryValues = @{
                    "Control Panel\Desktop" = @{ UserPreferencesMask = [byte[]](0x90, 0x12, 0x03, 0x80, 0x10, 0x00, 0x00, 0x00) }
                }

                function Set-VisualEffects {
                    param ([string] $HiveRoot)

                    foreach ($set in @(
                        @{ Values = $dwordValues;  Type = "DWord"  },
                        @{ Values = $stringValues; Type = "String" },
                        @{ Values = $binaryValues; Type = "Binary" }
                    )) {
                        foreach ($subKey in $set.Values.Keys) {
                            $keyPath = Join-Path -Path $HiveRoot -ChildPath $subKey
                            if (-not (Test-Path -Path $keyPath)) {
                                New-Item -Path $keyPath -Force | Out-Null
                            }
                            foreach ($name in $set.Values[$subKey].Keys) {
                                New-ItemProperty -Path $keyPath -Name $name -Value $set.Values[$subKey][$name] -PropertyType $set.Type -Force | Out-Null
                            }
                        }
                    }
                }

                # Hives of real users that are already loaded. The S-1-5-21-* filter
                # deliberately skips the built-in service accounts (S-1-5-18/19/20) and
                # .DEFAULT, which is an alias for LocalSystem rather than the Default
                # profile and so has no bearing on accounts created later.
                $loadedSids = @(Get-ChildItem -Path "Registry::HKEY_USERS" |
                    Where-Object { $_.PSChildName -like "S-1-5-21-*" -and $_.PSChildName -notlike "*_Classes" } |
                    Select-Object -ExpandProperty PSChildName)

                foreach ($sid in $loadedSids) {
                    Set-VisualEffects -HiveRoot "Registry::HKEY_USERS\$sid"
                }

                # Profiles on disk whose hive is not loaded, plus the Default profile
                $targets = @(Get-ChildItem -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList" |
                    ForEach-Object {
                        [pscustomobject]@{
                            Sid  = $_.PSChildName
                            Path = (Get-ItemProperty -Path $_.PSPath -Name "ProfilePath" -ErrorAction SilentlyContinue).ProfilePath
                        }
                    } |
                    Where-Object { $_.Sid -like "S-1-5-21-*" -and $_.Sid -notin $loadedSids -and $_.Path })

                $targets += [pscustomobject]@{ Sid = "DefaultUser"; Path = "$env:SystemDrive\Users\Default" }

                foreach ($target in $targets) {
                    $hiveFile = Join-Path -Path $target.Path -ChildPath "NTUSER.DAT"
                    if (-not (Test-Path -LiteralPath $hiveFile)) { continue }

                    $mountName = "DSC_$($target.Sid)"
                    & reg.exe load "HKU\$mountName" $hiveFile | Out-Null
                    if ($LASTEXITCODE -ne 0) { continue }

                    try {
                        Set-VisualEffects -HiveRoot "Registry::HKEY_USERS\$mountName"
                    }
                    finally {
                        [GC]::Collect()
                        [GC]::WaitForPendingFinalizers()
                        & reg.exe unload "HKU\$mountName" | Out-Null
                    }
                }
            }

            TestScript = {
                # In desired state when VisualFXSetting is 2 in every loaded hive and in
                # every profile on disk, including the Default profile
                # Must use the same SID filter as SetScript, or the hives SetScript
                # deliberately skips would keep this test returning $false for ever
                $loadedSids = @(Get-ChildItem -Path "Registry::HKEY_USERS" -ErrorAction SilentlyContinue |
                    Where-Object { $_.PSChildName -like "S-1-5-21-*" -and $_.PSChildName -notlike "*_Classes" } |
                    Select-Object -ExpandProperty PSChildName)

                foreach ($sid in $loadedSids) {
                    $value = (Get-ItemProperty -Path "Registry::HKEY_USERS\$sid\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects" -Name "VisualFXSetting" -ErrorAction SilentlyContinue).VisualFXSetting
                    if ($value -ne 2) { return $false }
                }

                $targets = @(Get-ChildItem -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList" -ErrorAction SilentlyContinue |
                    ForEach-Object {
                        [pscustomobject]@{
                            Sid  = $_.PSChildName
                            Path = (Get-ItemProperty -Path $_.PSPath -Name "ProfilePath" -ErrorAction SilentlyContinue).ProfilePath
                        }
                    } |
                    Where-Object { $_.Sid -like "S-1-5-21-*" -and $_.Sid -notin $loadedSids -and $_.Path })

                $targets += [pscustomobject]@{ Sid = "DefaultUser"; Path = "$env:SystemDrive\Users\Default" }

                foreach ($target in $targets) {
                    $hiveFile = Join-Path -Path $target.Path -ChildPath "NTUSER.DAT"
                    if (-not (Test-Path -LiteralPath $hiveFile)) { continue }

                    $mountName = "DSCTest_$($target.Sid)"
                    & reg.exe load "HKU\$mountName" $hiveFile | Out-Null
                    if ($LASTEXITCODE -ne 0) { return $false }

                    try {
                        $value = (Get-ItemProperty -Path "Registry::HKEY_USERS\$mountName\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects" -Name "VisualFXSetting" -ErrorAction SilentlyContinue).VisualFXSetting
                        if ($value -ne 2) { return $false }
                    }
                    finally {
                        [GC]::Collect()
                        [GC]::WaitForPendingFinalizers()
                        & reg.exe unload "HKU\$mountName" | Out-Null
                    }
                }

                return $true
            }

            GetScript = {
                $hiveFile = "$env:SystemDrive\Users\Default\NTUSER.DAT"
                $result = "Unknown"

                & reg.exe load "HKU\DSCGet_DefaultUser" $hiveFile | Out-Null
                if ($LASTEXITCODE -eq 0) {
                    try {
                        $value = (Get-ItemProperty -Path "Registry::HKEY_USERS\DSCGet_DefaultUser\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects" -Name "VisualFXSetting" -ErrorAction SilentlyContinue).VisualFXSetting
                        $result = "Default profile VisualFXSetting = $value"
                    }
                    finally {
                        [GC]::Collect()
                        [GC]::WaitForPendingFinalizers()
                        & reg.exe unload "HKU\DSCGet_DefaultUser" | Out-Null
                    }
                }

                return @{ Result = $result }
            }
        }

        # This resource block ensures that the file or command is executed
        xScript "RemoveArtifacts"
        {
            SetScript = {
                Remove-Item "C:\workflow-artifacts\*" -Recurse -Force
                Remove-Item "C:\workflow-artifacts" -Force
                Remove-Item "C:\workflow-artifacts.zip" -Force
                Remove-Item "C:\*_buildlog.log" -Force
            }
            TestScript = { $false }
            GetScript = { 
                # Do Nothing
            }
        }
    }
    
}