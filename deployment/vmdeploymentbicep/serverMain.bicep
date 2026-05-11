targetScope = 'resourceGroup'

param location string = resourceGroup().location
param vmName string
param vmSize string
param vmCount int
param osDiskType string = 'StandardSSD_LRS'
param osDiskDeleteOption string = 'Delete'
param osPlatform string = 'Windows'
param apprenticeshipProgramme string = 'noValue'
param l3SupTechCourse string = 'NoValue'
param l3NetTechCourse string = 'NoValue'
param l4NetEngCourse string = 'NoValue'
param bootcampCourse string = 'NoValue'
param imageVersion string = 'latest'
param enableHotpatching bool = false
param securityType string = 'Standard'
param secureBoot bool = false
param vTPM bool = false
param guestAttestation bool = false
param vnetNewOrExisting string = 'new'
param existingVnet string = ''
param subnetName string = 'default'
param nicDeleteOption string = 'Delete'
param pipDeleteOption string = 'Delete'
param enableBastion string = 'no'
param createdBy string
param deliveringCoachInitials string
param routeway string
param courseStartDate string
param courseEndDay string
param startupSchedule string = 'No'
param idleVM string = 'No'
param resourceGroupCleanup string = 'Enabled'

var vmNamePrefix = toUpper('${vmName}${deliveringCoachInitials}')
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
  l3IctSupTech: {
    courseImageDefinitionName: l3SupTechCourse
  }
  l3IctNetTech: {
    courseImageDefinitionName: l3NetTechCourse
  }
  l4NetEng: {
    courseImageDefinitionName: l4NetEngCourse
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

module publicIpAddresses 'modules/publicIP.bicep' = {
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
    publicIpAddresses
  ]
}

module windowsVMs 'modules/windowsServer.bicep' = {
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
output virtualMachineFQDN array = publicIpAddresses.outputs.fqdn
