param location string
@secure()
param subscriptionId string
param vmName string
param vmSize string
param vmCount int
param osDiskType string
param osDiskDeleteOption string
param course string
param imageVersion string
param licenseType string
param enableHotpatching bool
param patchMode string
param securityType string
param secureBoot bool
param vTPM bool
param guestAttestation bool
param idleVM string
param nicDeleteOption string
@secure()
param adminUsername string
@secure()
param adminPassword string
@secure()
param localUsername string
@secure()
param localUserPassword string
@secure()
param postgresPassword string
param createdBy string
param deliveringCoachInitials string
param courseStartDate string
param courseEndDay string
param startupSchedule string
param resourceGroupCleanup string

var vmNamePrefix = toUpper('${vmName}${deliveringCoachInitials}')
var acgRG = 'BalticImageGalleryRg'
var galleryImageName = 'TrainingACG'
var windowsLicense = 'Windows_Client'
var operatingSystemValues = {
  DataBootCamp: {
    galleryImageDefinitionName: 'BA-Win10-Courses'
  }
  Diploma: {
    galleryImageDefinitionName: 'BA-Win10-Courses'
  }
  RawDigital: {
    galleryImageDefinitionName: 'BA-Win10-Courses'
  }
  SQLDataAnalysis: {
    galleryImageDefinitionName: 'BA-Win10-Courses'
  }
  ExamImage: {
    galleryImageDefinitionName: 'BA-ExamImage'
  }
  ExamTesting: {
    galleryImageDefinitionName: 'BA-Testing'
  }
  DataLevel3: {
    galleryImageDefinitionName: 'BA-DataCourses'
  }
  DataLevel4: {
    galleryImageDefinitionName: 'BA-DataCourses-V2'
  }
  DataLevel4Sql: {
    galleryImageDefinitionName: 'BA-DataCourses'
  }
  DMCC3: {
    galleryImageDefinitionName: 'BA-DMContentCreator'
  }
  DMCC4: {
    galleryImageDefinitionName: 'BA-DMContentCreator'
  }
  SWAPC5: {
    galleryImageDefinitionName: 'BA-SWDCourse5'
  }
  SWAPC5UE5: {
    galleryImageDefinitionName: 'BA-L4SWDCourse5'
  }
}
var labConfigDscFunction = 'Ba${course}LabCfg'
var trustedLaunch = {
  securityType: securityType
  uefiSettings: {
    secureBootEnabled: secureBoot
    vTpmEnabled: vTPM
  }
}
var hibernation = {
  hibernationEnabled: true
}
var dscArtifactsLocation = 'https://raw.githubusercontent.com/balticapprenticeships/azure/'
var dscExtensionRepo = 'main/deployment/vmextensions'
var dscArchiveFolder = 'DSC'
var dscArchiveFileName = 'BaLabWinDesktopCfg.zip'

resource virtualMachines 'Microsoft.Compute/virtualMachines@2025-04-01' = [for i in range(0, vmCount): {
  name: '${vmNamePrefix}${i + 1}'
  location: location
  tags: {
    Displayname: 'Virtual Machine'
    ResourceType: 'VirtualMachine'
    Platform: 'WindowsClient'
    Dept: resourceGroup().tags['Dept']
    CreatedBy: createdBy
    CourseDate: 'WC-${courseStartDate}'
    CourseEndDay: courseEndDay
    Schedule: startupSchedule == 'Yes' ? 'StartDaily' : 'NoSchedule'
    IdleShutdown: idleVM
    Cleanup: resourceGroupCleanup
  }
  properties: {
    hardwareProfile: {
      vmSize: vmSize
    }
    storageProfile: {
      osDisk: {
        name: '${vmNamePrefix}${i + 1}-osdisk'
        createOption: 'FromImage'
        managedDisk: {
          storageAccountType: osDiskType
        }
        deleteOption: osDiskDeleteOption
      }
      imageReference: {
        id: '/subscriptions/${subscriptionId}/resourceGroups/${acgRG}/providers/Microsoft.Compute/galleries/${galleryImageName}/images/${operatingSystemValues[course].galleryImageDefinitionName}/versions/${imageVersion}'
      }
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: resourceId('Microsoft.Network/networkInterfaces', '${vmNamePrefix}${i + 1}-nic')
          properties: {
            deleteOption: nicDeleteOption
          }
        }
      ]
    }
    osProfile: {
      computerName: '${vmNamePrefix}${i + 1}'
      adminUsername: adminUsername
      adminPassword: adminPassword
      windowsConfiguration: {
        enableAutomaticUpdates: true
        provisionVMAgent: true
        timeZone: 'GMT Standard Time'
        patchSettings: {
          enableHotpatching: enableHotpatching
          patchMode: patchMode
        }
      }
    }
    securityProfile: securityType == 'TrustedLaunch' ? trustedLaunch : null
    additionalCapabilities: securityType == 'TrustedLaunch' ? hibernation : null
    licenseType: licenseType == 'AzureHybrid' ? windowsLicense : null
    diagnosticsProfile: {
      bootDiagnostics: {
        enabled: false
      }
    }
  }
}]

resource dscExtensions 'Microsoft.Compute/virtualMachines/extensions@2021-11-01' = [for i in range(0, vmCount): {
  parent: virtualMachines[i]
  name: 'Microsoft.PowerShell.DSC'
  location: location
  tags: {
    DisplayName: 'DSC'
    Dept: resourceGroup().tags['Dept']
    CreatedBy: createdBy
    CourseDate: courseStartDate
    CourseEndDay: courseEndDay
    Cleanup: resourceGroupCleanup
  }
  properties: {
    publisher: 'Microsoft.PowerShell'
    type: 'DSC'
    typeHandlerVersion: '2.80'
    autoUpgradeMinorVersion: true
    settings: {
      wmfVersion: 'latest'
      configuration: {
        url: '${dscArtifactsLocation}/${dscExtensionRepo}/${dscArchiveFolder}/${dscArchiveFileName}'
        script: 'BaLabWinDesktopCfg.ps1'
        function: labConfigDscFunction
      }
    }
    protectedSettings: {
      configurationArguments: {
        Credential: {
          Username: localUsername
          Password: localUserPassword
        }
      }
    }
  }
}]

resource policyExtensions 'Microsoft.Compute/virtualMachines/extensions@2020-12-01' = [for i in range(0, vmCount): {
  parent: virtualMachines[i]
  name: 'AzurePolicyforWindows'
  location: location
  properties: {
    publisher: 'Microsoft.GuestConfiguration'
    type: 'ConfigurationforWindows'
    typeHandlerVersion: '1.0'
    autoUpgradeMinorVersion: true
    enableAutomaticUpgrade: true
    settings: {}
    protectedSettings: {}
  }
}]

resource guestAttestationExtensions 'Microsoft.Compute/virtualMachines/extensions@2018-10-01' = [for i in range(0, vmCount): if (guestAttestation) {
  parent: virtualMachines[i]
  name: 'GuestAttestation'
  location: location
  properties: {
    publisher: 'Microsoft.Azure.Security.WindowsAttestation'
    type: 'GuestAttestation'
    typeHandlerVersion: '1.0'
    autoUpgradeMinorVersion: true
    settings: {
      AttestationConfig: {
        MaaSettings: {
          maaEndpoint: ''
          maaTenantName: 'GuestAttestation'
        }
        AscSettings: {
          ascReportingEndpoint: ''
          ascReportingFrequency: ''
        }
        useCustomToken: 'false'
        disableAlerts: 'false'
      }
    }
  }
}]

resource nvidiaGpuDriverExtensions 'Microsoft.Compute/virtualMachines/extensions@2020-12-01' = [for i in range(0, vmCount): if (vmSize == 'Standard_NC4as_T4_v3') {
  parent: virtualMachines[i]
  name: 'NvidiaGPUDriver'
  location: location
  properties: {
    publisher: 'Microsoft.Compute'
    type: 'CustomScriptExtension'
    typeHandlerVersion: '1.9'
    autoUpgradeMinorVersion: true
    settings: {
      fileUris: [
        'https://raw.githubusercontent.com/balticapprenticeships/azure/main/vmextensions/install-nvidia-drivers.ps1'
      ]
    }
    protectedSettings: {
      commandToExecute: 'powershell -ExecutionPolicy Unrestricted -File install-nvidia-drivers.ps1'
    }
  }
}]

resource amdGpuDriverExtensions 'Microsoft.Compute/virtualMachines/extensions@2020-12-01' = [for i in range(0, vmCount): if (vmSize == 'Standard_NV4as_v4') {
  parent: virtualMachines[i]
  name: 'AMDGpuDriver'
  location: location
  properties: {
    publisher: 'Microsoft.HpcCompute'
    type: 'AmdGpuDriverWindows'
    typeHandlerVersion: '1.1'
    autoUpgradeMinorVersion: true
    settings: {}
  }
}]

output vmId array = [for i in range(0, vmCount): {
  value: resourceId('Microsoft.Compute/virtualMachines', '${vmNamePrefix}${i + 1}')
}]
