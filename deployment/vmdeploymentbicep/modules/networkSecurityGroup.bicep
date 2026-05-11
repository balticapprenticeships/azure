param location string
param createdBy string
param osPlatform string
param enableBastion string
param courseStartDate string
param resourceGroupCleanup string

var nsgName = '${resourceGroup().name}-nsg'
var allowRdp = {
  name: 'Allow-RDP'
  properties: {
    priority: 300
    protocol: 'Tcp'
    access: 'Allow'
    direction: 'Inbound'
    sourceAddressPrefix: '*'
    sourcePortRange: '*'
    destinationAddressPrefix: '*'
    destinationPortRange: '3389'
  }
}
var allowRdpBastion = {
  name: 'Allow-RDP-Bastion'
  properties: {
    priority: 300
    protocol: 'Tcp'
    access: 'Allow'
    direction: 'Inbound'
    sourceAddressPrefix: '10.30.1.0/26'
    sourcePortRange: '*'
    destinationAddressPrefix: '*'
    destinationPortRange: '3389'
  }
}
var allowSsh = {
  name: 'Allow-SSH'
  properties: {
    priority: 310
    protocol: 'Tcp'
    access: 'Allow'
    direction: 'Inbound'
    sourceAddressPrefix: '*'
    sourcePortRange: '*'
    destinationAddressPrefix: '*'
    destinationPortRange: '22'
  }
}
var securityRules = osPlatform == 'Windows' ? (enableBastion == 'yes' ? [
  allowRdpBastion
] : [
  allowRdp
]) : [
  allowSsh
]

resource nsg 'Microsoft.Network/networkSecurityGroups@2025-05-01' = {
  name: nsgName
  location: location
  tags: {
    DisplayName: 'Network Security Group'
    ResourceType: 'NetworkSecurityGroup'
    Dept: resourceGroup().tags['Dept']
    CreatedBy: createdBy
    CourseDate: 'WC-${courseStartDate}'
    Cleanup: resourceGroupCleanup
  }
  properties: {
    securityRules: securityRules
  }
}

output nsgId object = nsg
output nsgRules array = nsg.properties.securityRules
