param location string
param subnetName string
param enableBastion string
param createdBy string
param courseStartDate string
param resourceGroupCleanup string

var vnetName = '${resourceGroup().name}-vnet'
var addressPrefixes = '10.255.0.0/16'
var subnetsAddressPrefix = '10.255.0.0/24'
var bastionSubnetPrefix = '10.255.1.0/26'
var workloadSubnet = {
  name: subnetName
  properties: {
    addressPrefix: subnetsAddressPrefix
    networkSecurityGroup: {
      id: resourceId('Microsoft.Network/networkSecurityGroups', '${resourceGroup().name}-nsg')
    }
  }
}
var bastionSubnet = {
  name: 'AzureBastionSubnet'
  properties: {
    addressPrefix: bastionSubnetPrefix
  }
}

resource vnet 'Microsoft.Network/virtualNetworks@2025-05-01' = {
  name: vnetName
  location: location
  tags: {
    DisplayName: 'Virtual Network'
    ResourceType: 'VirtualNetwork'
    Dept: resourceGroup().tags['Dept']
    CreatedBy: createdBy
    CourseDate: 'WC-${courseStartDate}'
    Cleanup: resourceGroupCleanup
  }
  properties: {
    addressSpace: {
      addressPrefixes: [
        addressPrefixes
      ]
    }
    subnets: toLower(enableBastion) == 'yes' ? [
      bastionSubnet
      workloadSubnet
    ] : [
      workloadSubnet
    ]
  }
}

output vnetName object = vnet
output subnetName array = vnet.properties.subnets
output vnetId object = vnet
