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
param createdBy string
param deliveringCoachInitials string
param courseStartDate string
param courseEndDay string
param startupSchedule string
param resourceGroupCleanup string

var vmNamePrefix = toUpper('${vmName}${deliveringCoachInitials}')
var acgRG = 'BalticImageGalleryRg'
var galleryImageName = 'TrainingACG'
var windowsLicense = 'Windows_Server'
var operatingSystemValues = {
  ICTSupC2: {
    galleryImageDefinitionName: 'BA-ICTSupMstr-v2'
  }
  ICTSupC3: {
    galleryImageDefinitionName: 'BA-ICTSupMstr-v2'
  }
  ICTSupC4: {
    galleryImageDefinitionName: 'BA-ICTSupMstr-v2'
  }
  ICTSupC6: {
    galleryImageDefinitionName: 'BA-ICTSupMstr-v2'
  }
  L4NetEngC4: {
    galleryImageDefinitionName: 'BA-L4NetEngC4'
  }
  L4NetEngC5: {
    galleryImageDefinitionName: 'BA-L4NetEngC5'
  }
  L4NetEngC7: {
    galleryImageDefinitionName: 'BA-L4NetEngC7'
  }
  ItBootcamp: {
    galleryImageDefinitionName: 'BA-Bootcamp'
  }
}
var labConfigDscFunction = 'xBa${course}LabCfg'
var trustedLaunch = {
  securityType: securityType
  uefiSettings: {
    secureBootEnabled: secureBoot
    vTpmEnabled: vTPM
  }
}
var hibernation = {
  hibernationEnabled: false
}
var dscArtifactsLocation = 'https://raw.githubusercontent.com/balticapprenticeships/azure/'
var dscExtensionRepo = 'main/deployment/vmextensions'
var dscArchiveFolder = 'DSC'
var dscArchiveFileName = 'xBaLabWinSvrCfg.zip'

resource virtualMachines 'Microsoft.Compute/virtualMachines@2025-04-01' = [for i in range(0, vmCount): {
  name: '${vmNamePrefix}${i + 1}'
  location: location
  tags: {
    Displayname: 'Virtual Machine'
    ResourceType: 'VirtualMachine'
    Platform: 'WindowsServer'
    Dept: resourceGroup().tags['Dept']
    CreatedBy: createdBy
    CourseDate: 'WC-${courseStartDate}'
    CourseEndDay: courseEndDay
    Schedule: startupSchedule == 'Yes' ? 'StartDaily' : 'NoSchedule'
    IdleShutdown: idleVM
    Hiberbation: 'False'
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
    ResourceType: 'StateConfiguration'
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
        script: 'xBaLabWinSvrCfg.ps1'
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

output vmId array = [for i in range(0, vmCount): {
  value: resourceId('Microsoft.Compute/virtualMachines', '${vmNamePrefix}${i + 1}')
}]
