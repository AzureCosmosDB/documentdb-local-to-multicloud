targetScope = 'resourceGroup'

@description('Name of the Fleet Hub AKS cluster')
param hubClusterName string = 'aks-fleet-hub'

@description('Location for the Fleet Hub')
param hubRegion string = 'eastus2'

@description('Name for member cluster')
param memberName string = 'aks-fleet-member'

@description('Location for member cluster')
param memberRegion string = 'eastus2'

@description('Provision a second AKS member in a different region.')
param includeAksReplica bool = false
param replicaName string = 'azure-documentdb-secondary'
param replicaRegion string = ''

@description('Use a supported regional GA version with ImageVolume enabled (1.35+).')
param kubernetesVersion string = '1.35'

@description('VM size for cluster nodes')
param hubVmSize string = 'Standard_DS3_v2'

@description('Number of nodes per cluster')
param nodeCount int = 1

var fleetName = '${hubClusterName}-fleet'

// Optionally include kubernetesVersion in cluster properties
var maybeK8sVersion = empty(kubernetesVersion) ? {} : { kubernetesVersion: kubernetesVersion }
var members = concat([
  { name: memberName, location: memberRegion }
], includeAksReplica ? [
  { name: replicaName, location: replicaRegion }
] : [])

// Fleet resource
resource fleet 'Microsoft.ContainerService/fleets@2025-03-01' = {
  name: fleetName
  location: hubRegion
  properties: {
    hubProfile: {
      dnsPrefix: fleetName
    }
  }
}

// Member AKS Cluster (using default Azure CNI without custom VNets)
resource memberCluster 'Microsoft.ContainerService/managedClusters@2025-01-01' = [for member in members: {
  name: member.name
  location: member.location
  identity: {
    type: 'SystemAssigned'
  }
  properties: union({
    dnsPrefix: '${member.name}-dns'
    enableRBAC: true
    agentPoolProfiles: [
      {
        name: 'agentpool'
        count: nodeCount
        vmSize: hubVmSize
        mode: 'System'
        osType: 'Linux'
      }
    ]
  }, maybeK8sVersion)
}]

// Member clusters fleet membership
resource memberFleetMembers 'Microsoft.ContainerService/fleets/members@2025-03-01' = [for (member, i) in members: {
  name: member.name
  parent: fleet
  properties: {
    clusterResourceId: memberCluster[i].id
  }
}]

// Outputs
output fleetId string = fleet.id
output fleetName string = fleet.name
output memberClusterId string = memberCluster[0].id
output memberClusterName string = memberCluster[0].name
output memberClusterNames array = [for member in members: member.name]
