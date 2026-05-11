targetScope = 'resourceGroup'

param location string = resourceGroup().location
param vmName string
param vmSize string
param vmCount int
param osDiskType string = 'StandardSSD_LRS'
param osDiskDeleteOption string = 'Delete'
param osPlatform string = 'Windows'
param apprenticeshipProgramme string = 'noValue'
param l3DmCcCourse string = 'NoValue'
param l3DataCourse string = 'NoValue'
param l4DataCourse string = 'NoValue'
param l4SoftDevCourse string = 'NoValue'
param examCourse string = 'NoValue'
param bootcampCourse string = 'NoValue'
param imageVersion string = 'latest'
param enableHotpatching bool = false
param securityType string = 'Standard'
param secureBoot bool = false
param vTPM bool = true
param guestAttestation bool = false
param vnetNewOrExisting string = 'existing'
param existingVnet string = ''
param subnetName string = 'default'
param nicDeleteOption string = 'Delete'
param pipDeleteOption string = 'Delete'
param enableBastion string = 'yes'
param bastionHostSku string = 'Standard'
param bastionHostScaleUnits int = 2
param bastionEnableTunneling bool = false
param bastionEnableIpConnect bool = false
param bastionEnableShareableLink bool = true
param bastionEnableKerberos bool = false
param bastionDisableCopyPaste bool = true
param bastionEnableSessionRecording bool = false
param enablePrivateOnlyBastion bool = false
param bastionZones array = []
param bastionPublicIpZones array = []
param createdBy string
param deliveringCoachInitials string
param routeway string
param courseStartDate string
param courseEndDay string
param startupSchedule string = 'No'
param idleVM string = 'No'
param resourceGroupCleanup string = 'Enabled'

var vmNamePrefix = toUpper('${vmName}${deliveringCoachInitials}')
var bastionHostName = '${resourceGroup().name}-Bastion'
var bastionPublicIPAddressName = '${resourceGroup().name}-bastion-pip'
var rwkeyVault = {
  IT: {
    keyVaultRg: 'ITRouteway'
    rwSuffix: 'ITR'
  }
  SoftwareDevelopment: {
    keyVaultRg: 'SWDRouteway'
    rwSuffix: 'SWD'
  }
  DigitalMarketing: {
    keyVaultRg: 'DMRouteway'
    rwSuffix: 'DM'
  }
  Data: {
    keyVaultRg: 'DataRouteway'
    rwSuffix: 'Data'
  }
  InternalDev: {
    keyVaultRg: 'IntDev'
    rwSuffix: 'IntDev'
  }
  DigitalSkills: {
    keyVaultRg: 'DigitalSkills'
    rwSuffix: 'Digital'
  }
}
var patchMode = osPlatform == 'Windows' ? 'AutomaticByOS' : 'ImageDefault'
var licenseType = 'AzureLicense'
var courseImageValue = {
  l3DmCc: {
    courseImageDefinitionName: l3DmCcCourse
  }
  l3Data: {
    courseImageDefinitionName: l3DataCourse
  }
  l4Data: {
    courseImageDefinitionName: l4DataCourse
  }
  l4SoftDev: {
    courseImageDefinitionName: l4SoftDevCourse
  }
  exams: {
    courseImageDefinitionName: examCourse
  }
  bootcamp: {
    courseImageDefinitionName: bootcampCourse
  }
}
var selectedCourse = courseImageValue[apprenticeshipProgramme].courseImageDefinitionName
var vaultResourceGroup = '${rwkeyVault[routeway].keyVaultRg}OMSRg'
var vaultName = 'VMDeployment${rwkeyVault[routeway].rwSuffix}'

resource deploymentKeyVault 'Microsoft.KeyVault/vaults@2023-07-01' existing = {
  name: vaultName
  scope: resourceGroup(vaultResourceGroup)
}

module networkSecurityGroup 'modules/networkSecurityGroup.bicep' = {
  name: 'DeployNetworkSecurityGroup'
  params: {
    location: location
    osPlatform: osPlatform
    enableBastion: enableBastion
    createdBy: createdBy
    courseStartDate: courseStartDate
    resourceGroupCleanup: resourceGroupCleanup
  }
}

module virtualNetwork 'modules/virtualNetwork.bicep' = if (vnetNewOrExisting == 'new') {
  name: 'DeployVirtualNetwork'
  params: {
    location: location
    subnetName: subnetName
    enableBastion: enableBastion
    createdBy: createdBy
    courseStartDate: courseStartDate
    resourceGroupCleanup: resourceGroupCleanup
  }
}

module bastionHost 'modules/bastionHost.bicep' = if (enableBastion == 'yes') {
  name: 'DeployBastionHost'
  params: {
    location: location
    bastionHostName: bastionHostName
    bastionHostSku: bastionHostSku
    bastionHostScaleUnits: bastionHostScaleUnits
    bastionPublicIpAddressName: bastionPublicIPAddressName
    bastionEnableTunneling: bastionEnableTunneling
    bastionEnableIpConnect: bastionEnableIpConnect
    bastionEnableShareableLink: bastionEnableShareableLink
    bastionEnableKerberos: bastionEnableKerberos
    bastionDisableCopyPaste: bastionDisableCopyPaste
    bastionEnableSessionRecording: bastionEnableSessionRecording
    enablePrivateOnlyBastion: enablePrivateOnlyBastion
    bastionZones: bastionZones
    bastionPublicIpZones: bastionPublicIpZones
    createdBy: createdBy
    courseStartDate: courseStartDate
    courseEndDay: courseEndDay
    resourceGroupCleanup: resourceGroupCleanup
  }
  dependsOn: [
    virtualNetwork
  ]
}

module publicIpAddresses 'modules/publicIP.bicep' = if (enableBastion == 'no') {
  name: 'DeployPublicIPAddress'
  params: {
    location: location
    vmName: vmName
    vmCount: vmCount
    createdBy: createdBy
    deliveringCoachInitials: deliveringCoachInitials
    courseStartDate: courseStartDate
    resourceGroupCleanup: resourceGroupCleanup
  }
}

module networkInterfaces 'modules/networkInterface.bicep' = {
  name: 'DeployNetworkInterface'
  params: {
    location: location
    vmName: vmName
    vmCount: vmCount
    vmSize: vmSize
    enableBastion: enableBastion
    course: selectedCourse
    vnetNewOrExisting: vnetNewOrExisting
    pipDeleteOption: pipDeleteOption
    existingVnet: existingVnet
    subnetName: subnetName
    createdBy: createdBy
    deliveringCoachInitials: deliveringCoachInitials
    courseStartDate: courseStartDate
    resourceGroupCleanup: resourceGroupCleanup
  }
  dependsOn: [
    networkSecurityGroup
    virtualNetwork
    bastionHost
    publicIpAddresses
  ]
}

module windowsVMs 'modules/windowsDesktop.bicep' = {
  name: 'DeployWindowsVM'
  params: {
    location: location
    subscriptionId: deploymentKeyVault.getSecret('SubscriptionId')
    vmName: vmName
    vmSize: vmSize
    vmCount: vmCount
    osDiskType: osDiskType
    osDiskDeleteOption: osDiskDeleteOption
    course: selectedCourse
    imageVersion: imageVersion
    licenseType: licenseType
    enableHotpatching: enableHotpatching
    patchMode: patchMode
    securityType: securityType
    secureBoot: secureBoot
    vTPM: vTPM
    guestAttestation: guestAttestation
    idleVM: idleVM
    nicDeleteOption: nicDeleteOption
    adminUsername: deploymentKeyVault.getSecret('LabAdmin')
    adminPassword: deploymentKeyVault.getSecret('LabAdminPassword')
    localUsername: deploymentKeyVault.getSecret('LabUser')
    localUserPassword: deploymentKeyVault.getSecret('LabUserPassword')
    postgresPassword: deploymentKeyVault.getSecret('PostgresAdminPassword')
    createdBy: createdBy
    deliveringCoachInitials: deliveringCoachInitials
    courseStartDate: courseStartDate
    courseEndDay: courseEndDay
    startupSchedule: startupSchedule
    resourceGroupCleanup: resourceGroupCleanup
  }
  dependsOn: [
    networkInterfaces
  ]
}

resource shutdownSchedules 'Microsoft.DevTestLab/schedules@2018-09-15' = [for i in range(0, vmCount): {
  name: 'shutdown-computevm-${vmNamePrefix}${i + 1}'
  location: location
  tags: {
    Displayname: 'Shutdown Schedule'
    Dept: resourceGroup().tags['Dept']
    CreatedBy: createdBy
    CourseDate: 'WC-${courseStartDate}'
    CourseEndDay: courseEndDay
    Cleanup: resourceGroupCleanup
  }
  properties: {
    status: 'Enabled'
    taskType: 'ComputeVmShutdownTask'
    dailyRecurrence: {
      time: '17:00'
    }
    timeZoneId: 'GMT Standard Time'
    targetResourceId: resourceId('Microsoft.Compute/virtualMachines', '${vmNamePrefix}${i + 1}')
    notificationSettings: {
      status: 'Disabled'
      notificationLocale: 'en'
      timeInMinutes: 30
    }
  }
  dependsOn: [
    windowsVMs
  ]
}]

output contentVersion string = deployment().properties.template.contentVersion
output location string = location
output vmNamePrefix string = vmNamePrefix
output createdBy string = createdBy
output coach string = deliveringCoachInitials
output scheduleOn string = startupSchedule
output idleVm string = idleVM
output resourceGroupCleanup string = resourceGroupCleanup
output osDiskType string = osDiskType
output vmSize string = vmSize
output osPlatform string = osPlatform
output apprenticeshipProgramme string = apprenticeshipProgramme
output courseImage string = selectedCourse
output imageVersion string = imageVersion
output virtualMachineFqdn array = enableBastion == 'no' ? publicIpAddresses.outputs.fqdn : []
output enableBastion string = enableBastion
output bastionHostName string = bastionHostName
