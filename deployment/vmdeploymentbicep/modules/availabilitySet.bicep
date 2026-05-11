param location string
param platformFaultDomainCount int
param platformUpdateDomainCount int
param skuName string
param createdBy string

var availabilitySetName = '${resourceGroup().name}-as'

resource availabilitySet 'Microsoft.Compute/availabilitySets@2025-04-01' = {
  name: availabilitySetName
  location: location
  tags: {
    DisplayName: 'Availability Set'
    ResourceType: 'AvailabilitySet'
    Dept: resourceGroup().tags['Dept']
    CreatedBy: createdBy
  }
  properties: {
    platformFaultDomainCount: platformFaultDomainCount
    platformUpdateDomainCount: platformUpdateDomainCount
  }
  sku: {
    name: skuName
  }
}

output availabilitySetName object = availabilitySet
