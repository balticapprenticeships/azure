param location string
param bastionHostName string
param bastionHostSku string
param bastionHostScaleUnits int
param bastionEnableTunneling bool
param bastionEnableIpConnect bool
param bastionEnableShareableLink bool
param bastionEnableKerberos bool
param bastionDisableCopyPaste bool
param bastionEnableSessionRecording bool
param enablePrivateOnlyBastion bool
param bastionZones array
param bastionPublicIpZones array
param bastionPublicIpAddressName string
param createdBy string
param courseStartDate string
param courseEndDay string
param resourceGroupCleanup string

resource bastionPublicIp 'Microsoft.Network/publicIPAddresses@2025-05-01' = {
  name: bastionPublicIpAddressName
  location: location
  tags: {
    DisplayName: 'Public IP Address'
    ResourceType: 'PublicIPAddress'
    ResourceUsage: 'Bastion Host'
    Dept: resourceGroup().tags['Dept']
    CreatedBy: createdBy
    CourseDate: 'WC-${courseStartDate}'
    Cleanup: resourceGroupCleanup
  }
  properties: {
    publicIPAllocationMethod: 'Static'
    publicIPAddressVersion: 'IPv4'
  }
  sku: {
    name: 'Standard'
  }
  zones: bastionPublicIpZones
}

resource bastionHost 'Microsoft.Network/bastionHosts@2025-05-01' = {
  name: bastionHostName
  location: location
  tags: {
    DisplayName: 'Bastion Host'
    ResourceType: 'Bastion'
    Dept: resourceGroup().tags['Dept']
    CreatedBy: createdBy
    CourseDate: 'WC-${courseStartDate}'
    CourseEndDay: courseEndDay
    Cleanup: resourceGroupCleanup
  }
  sku: {
    name: bastionHostSku
  }
  properties: {
    ipConfigurations: [
      {
        name: 'bastionHostIpConfig'
        properties: {
          subnet: {
            id: resourceId('Microsoft.Network/virtualNetworks/subnets', '${resourceGroup().name}-vnet', 'AzureBastionSubnet')
          }
          privateIPAllocationMethod: 'Dynamic'
          publicIPAddress: {
            id: bastionPublicIp.id
          }
        }
      }
    ]
    scaleUnits: bastionHostScaleUnits
    enableTunneling: bastionEnableTunneling
    enableIpConnect: bastionEnableIpConnect
    enableShareableLink: bastionEnableShareableLink
    enableKerberos: bastionEnableKerberos
    disableCopyPaste: bastionDisableCopyPaste
    enableSessionRecording: bastionEnableSessionRecording
    enablePrivateOnlyBastion: enablePrivateOnlyBastion
  }
  zones: bastionZones
}
