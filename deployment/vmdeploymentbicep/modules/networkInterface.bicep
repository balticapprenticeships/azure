param location string
param vmName string
param vmCount int
param vmSize string
param course string
param vnetNewOrExisting string
param pipDeleteOption string
param existingVnet string
param subnetName string
param enableBastion string
param createdBy string
param deliveringCoachInitials string
param courseStartDate string
param resourceGroupCleanup string

var vmNamePrefix = toUpper('${vmName}${deliveringCoachInitials}')
var vnetName = '${resourceGroup().name}-vnet'
var newVnetId = resourceId('Microsoft.Network/virtualNetworks/subnets', vnetName, subnetName)
var existingVnetId = resourceId('Microsoft.Network/virtualNetworks', existingVnet)
var existingSubnetId = '${existingVnetId}/subnets/${subnetName}'
var acceleratedNetworking = !contains(vmSize, 'Standard_B')

resource nics 'Microsoft.Network/networkInterfaces@2025-05-01' = [for i in range(0, vmCount): {
  name: '${vmNamePrefix}${i + 1}-nic'
  location: location
  tags: {
    DisplayName: 'Network Interface'
    ResourceType: 'NetworkInterface'
    CourseImage: course
    Dept: resourceGroup().tags['Dept']
    CreatedBy: createdBy
    CourseDate: 'WC-${courseStartDate}'
    Cleanup: resourceGroupCleanup
  }
  properties: {
    enableAcceleratedNetworking: acceleratedNetworking
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          privateIPAllocationMethod: 'Dynamic'
          subnet: {
            id: vnetNewOrExisting == 'new' ? newVnetId : existingSubnetId
          }
          publicIPAddress: toLower(enableBastion) == 'no' ? {
            id: resourceId('Microsoft.Network/publicIPAddresses', '${vmNamePrefix}${i + 1}-ip')
            properties: {
              deleteOption: pipDeleteOption
            }
          } : null
        }
      }
    ]
  }
}]

output networkInterfaceId array = [for i in range(0, vmCount): {
  value: nics[i].id
}]
output privateIP array = [for i in range(0, vmCount): {
  value: reference(resourceId('Microsoft.Network/networkInterfaces', '${vmNamePrefix}${i + 1}-nic'), '2025-05-01').ipConfigurations[0].properties.privateIPAddress
}]
