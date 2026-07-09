################################################################
# Script to configure Windows lab environment using DSC        #
# Author: Chris Langford                                       #
# Version: 7.0.5                                               #
################################################################

Configuration BaWinDesktopLabCfg {
    [CmdletBinding()]

    param (
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.PSCredential]
        [System.Management.Automation.Credential()]
        $Credential
    )

    Import-DscResource -ModuleName ComputerManagementDsc, PSDesiredStateConfiguration

    Node localhost {
        LocalConfigurationmanager {
            RebootNodeIfNeeded = $true
        }

        # Construct fully-qualified local username
        $localUser = "$env:COMPUTERNAME\$($Credential.UserName)"

        # This resource block creates a local User
        User "CreateUserAccount"
        {
            Ensure = "Present"
            UserName = $Credential.Username
            Password = $Credential
            FullName = "Baltic Apprentice"
            Description = "Baltic Apprentice User Account"
            PasswordNeverExpires = $true
            PasswordChangeRequired = $false
            PasswordChangeNotAllowed = $true
        }

        # This resource block adds a user to specific groups
        Group "AddToRemoteDesktopUserGroup"
        {
            Ensure = "Present"
            GroupName = "Remote Desktop Users"
            MembersToInclude = @($localUser)
            DependsOn = "[User]CreateUserAccount"
        }        
        
        # This resource block ensures that the file or command is executed
        Script "RemoveArtifacts"
        {
            SetScript = {
                Remove-Item -Path "C:\workflow-artifacts\" -Recurse -Force -ErrorAction SilentlyContinue
                Remove-Item -Path "C:\workflow-artifacts" -Force -ErrorAction SilentlyContinue   
                Remove-Item -Path "C:\workflow-artifacts.zip" -Force -ErrorAction SilentlyContinue 
                Remove-Item -Path "C:\buildArtifacts\*" -Recurse -Force -ErrorAction SilentlyContinue
                Remove-Item -Path "C:\buildArtifacts" -Force -ErrorAction SilentlyContinue
            }
            TestScript = { $false }
            GetScript = {
                @{ Result = "Removing build artifacts" } # Do not return anything, just a placeholder
            }
        }
    }
}

Configuration BaDataBootCampLabCfg {
    [CmdletBinding()]

    param (
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.PSCredential]
        [System.Management.Automation.Credential()]
        $Credential
    )

    Import-DscResource -ModuleName ComputerManagementDsc, PSDesiredStateConfiguration

    Node localhost {
        LocalConfigurationmanager {
            RebootNodeIfNeeded = $true
        }

        # Construct fully-qualified local username
        $localUser = "$env:COMPUTERNAME\$($Credential.UserName)"

        # This resource block creates a local User
        User "CreateUserAccount"
        {
            Ensure = "Present"
            UserName = $Credential.Username
            Password = $Credential
            FullName = "Baltic Apprentice"
            Description = "Baltic Apprentice User Account"
            PasswordNeverExpires = $true
            PasswordChangeRequired = $false
            PasswordChangeNotAllowed = $true
        }

        # This resource block adds a user to specific groups
        Group "AddToRemoteDesktopUserGroup"
        {
            Ensure = "Present"
            GroupName = "Remote Desktop Users"
            MembersToInclude = @($localUser)
            DependsOn = "[User]CreateUserAccount"
        }        
        
        # This resource block ensures that the file or command is executed
        Script "RemoveArtifacts"
        {
            SetScript = {
                Remove-Item -Path "C:\workflow-artifacts\" -Recurse -Force -ErrorAction SilentlyContinue
                Remove-Item -Path "C:\workflow-artifacts" -Force -ErrorAction SilentlyContinue   
                Remove-Item -Path "C:\workflow-artifacts.zip" -Force -ErrorAction SilentlyContinue 
                Remove-Item -Path "C:\buildArtifacts\*" -Recurse -Force -ErrorAction SilentlyContinue
                Remove-Item -Path "C:\buildArtifacts" -Force -ErrorAction SilentlyContinue
            }
            TestScript = { $false}
            GetScript = {
                @{ Result = "Removing build artifacts" } # Do not return anything, just a placeholder
            }
        }
    }
}

Configuration BaExamImageLabCfg {
    [CmdletBinding()]

    param (
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.PSCredential]
        [System.Management.Automation.Credential()]
        $Credential
    )

    Import-DscResource -ModuleName ComputerManagementDsc, PSDesiredStateConfiguration

    Node localhost {
        LocalConfigurationmanager {
            RebootNodeIfNeeded = $true
        }

        # Construct fully-qualified local username
        $localUser = "$env:COMPUTERNAME\$($Credential.UserName)"

        # This resource block creates a local User
        User "CreateUserAccount"
        {
            Ensure = "Present"
            UserName = $Credential.Username
            Password = $Credential
            FullName = "Baltic Apprentice"
            Description = "Baltic Apprentice User Account"
            PasswordNeverExpires = $true
            PasswordChangeRequired = $false
            PasswordChangeNotAllowed = $true
        }

        # This resource block adds a user to specific groups
        Group "AddToRemoteDesktopUserGroup"
        {
            Ensure = "Present"
            GroupName = "Remote Desktop Users"
            MembersToInclude = @($localUser)
            DependsOn = "[User]CreateUserAccount"
        }        
        
        # This resource block ensures that the file or command is executed
        Script "RemoveArtifacts"
        {
            SetScript = {
                Remove-Item -Path "C:\workflow-artifacts\" -Recurse -Force -ErrorAction SilentlyContinue
                Remove-Item -Path "C:\workflow-artifacts" -Force -ErrorAction SilentlyContinue   
                Remove-Item -Path "C:\workflow-artifacts.zip" -Force -ErrorAction SilentlyContinue 
                Remove-Item -Path "C:\buildArtifacts\*" -Recurse -Force -ErrorAction SilentlyContinue
                Remove-Item -Path "C:\buildArtifacts" -Force -ErrorAction SilentlyContinue
            }
            TestScript = { $false}
            GetScript = {
                @{ Result = "Removing build artifacts" } # Do not return anything, just a placeholder
            }
        }
    }
}

Configuration BaExamTestingLabCfg {
    [CmdletBinding()]

    param (
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.PSCredential]
        [System.Management.Automation.Credential()]
        $Credential
    )

    Import-DscResource -ModuleName ComputerManagementDsc, PSDesiredStateConfiguration

    Node localhost {
        LocalConfigurationmanager {
            RebootNodeIfNeeded = $true
        }

        # Construct fully-qualified local username
        $localUser = "$env:COMPUTERNAME\$($Credential.UserName)"

        # This resource block creates a local User
        User "CreateUserAccount"
        {
            Ensure = "Present"
            UserName = $Credential.Username
            Password = $Credential
            FullName = "Baltic Apprentice"
            Description = "Baltic Apprentice User Account"
            PasswordNeverExpires = $true
            PasswordChangeRequired = $false
            PasswordChangeNotAllowed = $true
        }
        # This resource block adds a user to specific groups
        Group "AddToRemoteDesktopUserGroup"
        {
            Ensure = "Present"
            GroupName = "Remote Desktop Users"
            MembersToInclude = @($localUser)
            DependsOn = "[User]CreateUserAccount"
        }        
        
        # This resource block ensures that the file or command is executed
        Script "RemoveArtifacts"
        {
            SetScript = {
                Remove-Item -Path "C:\workflow-artifacts\" -Recurse -Force -ErrorAction SilentlyContinue
                Remove-Item -Path "C:\workflow-artifacts" -Force -ErrorAction SilentlyContinue   
                Remove-Item -Path "C:\workflow-artifacts.zip" -Force -ErrorAction SilentlyContinue
                Remove-Item -Path "C:\buildArtifacts\*" -Recurse -Force -ErrorAction SilentlyContinue
                Remove-Item -Path "C:\buildArtifacts" -Force -ErrorAction SilentlyContinue
            }
            TestScript = { $false}
            GetScript = {
                @{ Result = "Removing build artifacts" } # Do not return anything, just a placeholder
            }
        }
    }
}

Configuration BaDataLevel3LabCfg {
    [CmdletBinding()]

    param (
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.PSCredential]
        [System.Management.Automation.Credential()]
        $Credential
    )

    Import-DscResource -ModuleName ComputerManagementDsc, PSDesiredStateConfiguration

    Node localhost {
        LocalConfigurationmanager {
            RebootNodeIfNeeded = $true
        }

        # Construct fully-qualified local username
        $localUser = "$env:COMPUTERNAME\$($Credential.UserName)"

        # This resource block creates a local User
        User "CreateUserAccount"
        {
            Ensure = "Present"
            UserName = $Credential.Username
            Password = $Credential
            FullName = "Baltic Apprentice"
            Description = "Baltic Apprentice User Account"
            PasswordNeverExpires = $true
            PasswordChangeRequired = $false
            PasswordChangeNotAllowed = $true
        }

        # This resource block adds a user to specific groups
        Group "AddToRemoteDesktopUserGroup"
        {
            Ensure = "Present"
            GroupName = "Remote Desktop Users"
            MembersToInclude = @($localUser)
            DependsOn = "[User]CreateUserAccount"
        }        
        
        # This resource block ensures that the file or command is executed
        Script "RemoveArtifacts"
        {
            SetScript = {
                Remove-Item -Path "C:\workflow-artifacts\" -Recurse -Force -ErrorAction SilentlyContinue
                Remove-Item -Path "C:\workflow-artifacts" -Force -ErrorAction SilentlyContinue   
                Remove-Item -Path "C:\workflow-artifacts.zip" -Force -ErrorAction SilentlyContinue
                Remove-Item -Path "C:\buildArtifacts\*" -Recurse -Force -ErrorAction SilentlyContinue
                Remove-Item -Path "C:\buildArtifacts" -Force -ErrorAction SilentlyContinue
            }
            TestScript = { $false}
            GetScript = {
                @{ Result = "Removing build artifacts" }
            }
        }
    }
}

Configuration BaDataLevel4LabCfg {
    [CmdletBinding()]

    param (
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.PSCredential]
        [System.Management.Automation.Credential()]
        $Credential
    )

    Import-DscResource -ModuleName ComputerManagementDsc, PSDesiredStateConfiguration

    Node localhost {
        LocalConfigurationmanager {
            RebootNodeIfNeeded = $true
        }

        # Construct fully-qualified local username
        $localUser = "$env:COMPUTERNAME\$($Credential.UserName)"

        # This resource block creates a local User
        User "CreateUserAccount"
        {
            Ensure = "Present"
            UserName = $Credential.UserName
            Password = $Credential
            FullName = "Baltic Apprentice"
            Description = "Baltic Apprentice User Account"
            PasswordNeverExpires = $true
            PasswordChangeRequired = $false
            PasswordChangeNotAllowed = $true
        }

        # This resource block adds a user to specific groups
        Group "AddToRemoteDesktopUserGroup"
        {
            Ensure = "Present"
            GroupName = "Remote Desktop Users"
            MembersToInclude = @($localUser)
            DependsOn = "[User]CreateUserAccount"
        }

        # This resource block adds a user to the docker-users groups
        Group "AddToDockerUsersGroup"
        {
            Ensure = "Present"
            GroupName = "docker-users"
            MembersToInclude = @($localUser)
            DependsOn = "[User]CreateUserAccount"
        }

        # This resource block ensures that the file or command is executed        
        Script "InstallPythonModules" {

            GetScript = { @{ Result = "Checking Python modules" } }

            TestScript = {
                $pythonPath = "C:\Program Files\Python314\python.exe"
                if (-not (Test-Path $pythonPath)) { return $false }

                $modules = @("numpy","pandas","scikit-learn","statsmodels","matplotlib","seaborn","scipy")
                foreach ($module in $modules) {
                    if (-not (& $pythonPath -m pip show $module 2>$null)) {
                        return $false
                    }
                }
                return $true
            }

            SetScript = {
                $pythonPath = "C:\Program Files\Python314\python.exe"

                # Ensure pip is up-to-date
                & $pythonPath -m ensurepip --upgrade
                & $pythonPath -m pip install --upgrade pip

                $modules = @("numpy","pandas","scikit-learn","statsmodels","matplotlib","seaborn","scipy")
                foreach ($module in $modules) {
                    Write-Verbose "Installing Python module: $module"
                    & $pythonPath -m pip install $module --quiet --disable-pip-version-check
                }
            }
        }

        # This resource block ensures that the file or command is executed
        Script "RemoveArtifacts"
        {
            SetScript = {
                Remove-Item -Path "C:\workflow-artifacts\" -Recurse -Force -ErrorAction SilentlyContinue
                Remove-Item -Path "C:\workflow-artifacts" -Force -ErrorAction SilentlyContinue   
                Remove-Item -Path "C:\workflow-artifacts.zip" -Force -ErrorAction SilentlyContinue 
                Remove-Item -Path "C:\buildArtifacts\*" -Recurse -Force -ErrorAction SilentlyContinue
                Remove-Item -Path "C:\buildArtifacts" -Force -ErrorAction SilentlyContinue
            }
            TestScript = { $false}
            GetScript = {
                @{ Result = "Removing build artifacts" } # Do not return anything, just a placeholder
            }
        }
    }
}

Configuration BaDataLevel4SqlLabCfg {
    [CmdletBinding()]

    param (
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.PSCredential]
        [System.Management.Automation.Credential()]
        $Credential
    )

    Import-DscResource -ModuleName ComputerManagementDsc, PSDesiredStateConfiguration, SqlServerDsc

    Node localhost {
        LocalConfigurationmanager {
            RebootNodeIfNeeded = $true
        }

        # Construct fully-qualified local username
        $localUser = "$env:COMPUTERNAME\$($Credential.UserName)"

        # This resource block creates a local User
        User "CreateUserAccount"
        {
            Ensure = "Present"
            UserName = $Credential.Username
            Password = $Credential
            FullName = "Baltic Apprentice"
            Description = "Baltic Apprentice User Account"
            PasswordNeverExpires = $true
            PasswordChangeRequired = $false
            PasswordChangeNotAllowed = $true
        }

        # This resource block adds a user to specific groups
        Group "AddToAdministratorGroup"
        {
            Ensure = "Present"
            GroupName = "Administrators"
            MembersToInclude = @($localUser)
            DependsOn = "[User]CreateUserAccount"
        }        

        # This resource block adds a user to specific groups
        Group "AddToRemoteDesktopUserGroup"
        {
            Ensure = "Present"
            GroupName = "Remote Desktop Users"
            MembersToInclude = @($localUser)
            DependsOn = "[User]CreateUserAccount"
        }
        
        # This resource block will install SQL Server 2022 Devloper Edition
        SqlSetup "InstallSQLServer"
        {
            InstanceName = 'MSSQLSERVER'
            Features = 'SQLENGINE'
            SourcePath = 'C:\sqlBuildArtifacts\SQLServer2022-Dev'
            SQLCollation = 'Latin1_General_CI_AS'
            SQLSysAdminAccounts = @('Administrators', $localUser)
            InstallSharedDir = 'C:\Program Files\Microsoft SQL Server'
            InstallSharedWOWDir = 'C:\Program Files (x86)\Microsoft SQL Server'
            InstanceDir = 'C:\Program Files\Microsoft SQL Server'
            NpEnabled = $false
            TcpEnabled = $false
            UpdateEnabled = $false
            UseEnglish = $true
            ForceReboot = $false

            SqlTempdbFileCount = 8
            SqlTempdbFileSize = 8
            SqlTempdbFileGrowth = 64
            SqlTempdbLogFileSize = 8
            SqlTempdbLogFileGrowth = 64

            SqlSvcStartupType = 'Automatic'
            AgtSvcStartupType = 'Manual'
            BrowserSvcStartupType = 'Manual'
            
            DependsOn = "[User]CreateUserAccount", "[Group]AddToAdministratorGroup"
        }

        # This resource block ensures that the file or command is executed after SQL Server installation
        Script "AddSSMSDesktopShortcut"
        {
            SetScript = {
                $ssmsTargetFile = "C:\Program Files (x86)\Microsoft SQL Server Management Studio 20\Common7\IDE\Ssms.exe"
                $ssmsShortcutFile = "C:\Users\Public\Desktop\Sql Server Management Studio.lnk"
                if (Test-Path -Path $ssmsTargetFile) {
                    $ssmsWShell = New-Object -ComObject WScript.Shell
                    $ssmsShortcut = $ssmsWShell.CreateShortcut($ssmsShortcutFile)
                    $ssmsShortcut.TargetPath = $ssmsTargetFile
                    $ssmsShortcut.Save()
                } else {
                    Write-Error "SQL Server Management Studio executable not found at $ssmsTargetFile"
                }
            }
            TestScript = { $false}
            GetScript = {
                @{ Result = "Creating SSMS shortcut" } # Do not return anything, just a placeholder
            }

            dependsOn = "[SqlSetup]InstallSQLServer"
        }

        # This resource block ensures that the file or command is executed
        Script "RemoveArtifacts"
        {
            SetScript = {
                Remove-Item -Path "C:\workflow-artifacts\" -Recurse -Force -ErrorAction SilentlyContinue
                Remove-Item -Path "C:\workflow-artifacts" -Force -ErrorAction SilentlyContinue   
                Remove-Item -Path "C:\workflow-artifacts.zip" -Force -ErrorAction SilentlyContinue
                Remove-Item -Path "C:\buildArtifacts\*" -Recurse -Force -ErrorAction SilentlyContinue
                Remove-Item -Path "C:\buildArtifacts" -Force -ErrorAction SilentlyContinue 
            }
            TestScript = { $false}
            GetScript = {
                @{ Result = "Removing build artifacts" } # Do not return anything, just a placeholder
            }
        }
    }
}

Configuration BaDataLevel5LabCfg {
    [CmdletBinding()]

    param (
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.PSCredential]
        [System.Management.Automation.Credential()]
        $Credential
    )

    Import-DscResource -ModuleName ComputerManagementDsc, PSDesiredStateConfiguration

    Node localhost {
        LocalConfigurationmanager {
            RebootNodeIfNeeded = $true
        }

        # Construct fully-qualified local username
        $localUser = "$env:COMPUTERNAME\$($Credential.UserName)"

        # This resource block creates a local User
        User "CreateUserAccount"
        {
            Ensure = "Present"
            UserName = $Credential.UserName
            Password = $Credential
            FullName = "Baltic Apprentice"
            Description = "Baltic Apprentice User Account"
            PasswordNeverExpires = $true
            PasswordChangeRequired = $false
            PasswordChangeNotAllowed = $true
        }

        # This resource block adds a user to specific groups
        Group "AddToRemoteDesktopUserGroup"
        {
            Ensure = "Present"
            GroupName = "Remote Desktop Users"
            MembersToInclude = @($localUser)
            DependsOn = "[User]CreateUserAccount"
        }

        # This resource block adds a user to the docker-users groups
        Group "AddToDockerUsersGroup"
        {
            Ensure = "Present"
            GroupName = "docker-users"
            MembersToInclude = @($localUser)
            DependsOn = "[User]CreateUserAccount"
        }

        # This resource block ensures that the file or command is executed        
        Script "InstallPythonModules" {

            GetScript = { @{ Result = "Checking Python modules" } }

            TestScript = {
                $pythonPath = "C:\Program Files\Python314\python.exe"
                if (-not (Test-Path $pythonPath)) { return $false }

                $modules = @("numpy","pandas","scikit-learn","statsmodels","matplotlib","seaborn","scipy")
                foreach ($module in $modules) {
                    if (-not (& $pythonPath -m pip show $module 2>$null)) {
                        return $false
                    }
                }
                return $true
            }

            SetScript = {
                $pythonPath = "C:\Program Files\Python314\python.exe"

                # Ensure pip is up-to-date
                & $pythonPath -m ensurepip --upgrade
                & $pythonPath -m pip install --upgrade pip

                $modules = @("numpy","pandas","scikit-learn","statsmodels","matplotlib","seaborn","scipy")
                foreach ($module in $modules) {
                    Write-Verbose "Installing Python module: $module"
                    & $pythonPath -m pip install $module --quiet --disable-pip-version-check
                }
            }
        }

        # This resource block ensures that the lab files are downloaded from GitHub and extracted to the correct location.
        Script "DownloadLabFiles" {
            
            GetScript = { @{ Result = "Checking if lab files are downloaded" } }

            TestScript = {
                $labFilesPath = "C:\Users\Public\Documents\CourseResources\L5 Data Enginner\Exploring Suitable Data Storage Solutions"
                $markerPath = Join-Path -Path $labFilesPath -ChildPath ".sales-data-pipeline_airflow.extracted"

                return (Test-Path -Path $markerPath -PathType Leaf)
            }

            SetScript = {
                $tempPath = "C:\buildArtifacts"
                $zipPath = Join-Path -Path $tempPath -ChildPath "sales-data-pipeline_airflow.zip"
                $labFilesPath = "C:\Users\Public\Documents\CourseResources\L5 Data Enginner\Exploring Suitable Data Storage Solutions"
                $markerPath = Join-Path -Path $labFilesPath -ChildPath ".sales-data-pipeline_airflow.extracted"
                $labFilesUrl = "https://github.com/balticapprenticeships/courses/raw/refs/heads/main/DataRouteway/Level%205/Data%20Engineer/Course%205/sales-data-pipeline_airflow.zip"
                
                New-Item -ItemType Directory -Path $tempPath -Force | Out-Null
                New-Item -ItemType Directory -Path $labFilesPath -Force | Out-Null

                if (Test-Path -Path $zipPath -PathType Leaf) {
                    Remove-Item -Path $zipPath -Force
                }

                Invoke-WebRequest -Uri $labFilesUrl -OutFile $zipPath 
                Expand-Archive -Path $zipPath -DestinationPath $labFilesPath -Force
                New-Item -ItemType File -Path $markerPath -Force | Out-Null
            }
        }

        # This resource block ensures that the file or command is executed
        Script "RemoveArtifacts"
        {
            SetScript = {
                Remove-Item -Path "C:\workflow-artifacts\" -Recurse -Force -ErrorAction SilentlyContinue
                Remove-Item -Path "C:\workflow-artifacts" -Force -ErrorAction SilentlyContinue   
                Remove-Item -Path "C:\workflow-artifacts.zip" -Force -ErrorAction SilentlyContinue 
                Remove-Item -Path "C:\buildArtifacts\*" -Recurse -Force -ErrorAction SilentlyContinue
                Remove-Item -Path "C:\buildArtifacts" -Force -ErrorAction SilentlyContinue
            }
            TestScript = { $false}
            GetScript = {
                @{ Result = "Removing build artifacts" } # Do not return anything, just a placeholder
            }
        }
    }
}

Configuration BaSWAPC5LabCfg {
    [CmdletBinding()]

    param (
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.PSCredential]
        [System.Management.Automation.Credential()]
        $Credential
    )

    Import-DscResource -ModuleName ComputerManagementDsc, PSDesiredStateConfiguration

    Node localhost {
        LocalConfigurationmanager {
            RebootNodeIfNeeded = $true
        }

        # Construct fully-qualified local username
        $localUser = "$env:COMPUTERNAME\$($Credential.UserName)"

        # This resource block creates a local User
        User "CreateUserAccount"
        {
            Ensure = "Present"
            UserName = $Credential.Username
            Password = $Credential
            FullName = "Baltic Apprentice"
            Description = "Baltic Apprentice User Account"
            PasswordNeverExpires = $true
            PasswordChangeRequired = $false
            PasswordChangeNotAllowed = $true
        }
        # This resource block adds a user to specific groups
        Group "AddToRemoteDesktopUserGroup"
        {
            Ensure = "Present"
            GroupName = "Remote Desktop Users"
            MembersToInclude = @($localUser)
            DependsOn = "[User]CreateUserAccount"
        }        
        
        # This resource block ensures that the file or command is executed
        Script "RemoveArtifacts"
        {
            SetScript = {
                Remove-Item -Path "C:\workflow-artifacts\" -Recurse -Force -ErrorAction SilentlyContinue
                Remove-Item -Path "C:\workflow-artifacts" -Force -ErrorAction SilentlyContinue   
                Remove-Item -Path "C:\workflow-artifacts.zip" -Force -ErrorAction SilentlyContinue
                Remove-Item -Path "C:\buildArtifacts\*" -Recurse -Force -ErrorAction SilentlyContinue
                Remove-Item -Path "C:\buildArtifacts" -Force -ErrorAction SilentlyContinue
            }
            TestScript = { $false}
            GetScript = {
                @{ Result = "Removing build artifacts" } # Do not return anything, just a placeholder
            }
        }
    }
}

Configuration BaSWAPC5UE5LabCfg {
    [CmdletBinding()]

    param (
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.PSCredential]
        [System.Management.Automation.Credential()]
        $Credential
    )

    Import-DscResource -ModuleName ComputerManagementDsc, PSDesiredStateConfiguration

    Node localhost {
        LocalConfigurationmanager {
            RebootNodeIfNeeded = $true
        }

        # Construct fully-qualified local username
        $localUser = "$env:COMPUTERNAME\$($Credential.UserName)"

        # This resource block creates a local User
        User "CreateUserAccount"
        {
            Ensure = "Present"
            UserName = $Credential.Username
            Password = $Credential
            FullName = "Baltic Apprentice"
            Description = "Baltic Apprentice User Account"
            PasswordNeverExpires = $true
            PasswordChangeRequired = $false
            PasswordChangeNotAllowed = $true
        }

        # This resource block adds a user to specific groups
        Group "AddToRemoteDesktopUserGroup"
        {
            Ensure = "Present"
            GroupName = "Remote Desktop Users"
            MembersToInclude = @($localUser)
            DependsOn = "[User]CreateUserAccount"
        }        
        
        # This resource block ensures that the file or command is executed
        Script "RemoveArtifacts"
        {
            SetScript = {
                Remove-Item -Path "C:\workflow-artifacts\" -Recurse -Force -ErrorAction SilentlyContinue
                Remove-Item -Path "C:\workflow-artifacts" -Force -ErrorAction SilentlyContinue   
                Remove-Item -Path "C:\workflow-artifacts.zip" -Force -ErrorAction SilentlyContinue
                Remove-Item -Path "C:\buildArtifacts\*" -Recurse -Force -ErrorAction SilentlyContinue
                Remove-Item -Path "C:\buildArtifacts" -Force -ErrorAction SilentlyContinue
            }
            TestScript = { $false}
            GetScript = {
                @{ Result = "Removing build artifacts" } # Do not return anything, just a placeholder
            }
        }
    }
}