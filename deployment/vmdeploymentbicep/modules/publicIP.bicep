param location string
param vmName string
param vmCount int
param createdBy string
param deliveringCoachInitials string
param courseStartDate string
param resourceGroupCleanup string

var vmNamePrefix = toUpper('${vmName}${deliveringCoachInitials}')

resource publicIps 'Microsoft.Network/publicIPAddresses@2025-05-01' = [for i in range(0, vmCount): {
  name: '${vmNamePrefix}${i + 1}-ip'
  location: location
  tags: {
    DisplayName: 'Public IP Address'
    ResourceType: 'PublicIPAddress'
    Dept: resourceGroup().tags['Dept']
    CreatedBy: createdBy
    CourseDate: 'WC-${courseStartDate}'
    Cleanup: resourceGroupCleanup
  }
  properties: {
    publicIPAddressVersion: 'IPv4'
    publicIPAllocationMethod: 'Static'
    dnsSettings: {
      domainNameLabel: toLower('baltic-${vmNamePrefix}${i + 1}')
    }
  }
  sku: {
    name: 'Standard'
  }
}]

output fqdn array = [for i in range(0, vmCount): {
  value: reference(resourceId('Microsoft.Network/publicIPAddresses', '${vmNamePrefix}${i + 1}-ip'), '2025-05-01').dnsSettings.fqdn
}]
output publicIP string = ''
