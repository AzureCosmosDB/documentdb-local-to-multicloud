// DocumentDB on AKS - Techorama Demo Infrastructure
// Deploys: AKS cluster with managed identity, ready for DocumentDB operator

@description('Azure region for the AKS cluster')
param location string = resourceGroup().location

@description('AKS cluster name')
param clusterName string = 'docdb-demo-aks'

@description('Kubernetes version')
param kubernetesVersion string = '1.35'

@description('VM size for the node pool')
param vmSize string = 'Standard_D4s_v5'

@description('Number of nodes')
param nodeCount int = 2

@description('Enable cluster autoscaler')
param enableAutoScaling bool = true

@minValue(1)
param minNodeCount int = 1

@maxValue(5)
param maxNodeCount int = 3

@description('Owner email for resource tagging')
param ownerEmail string

// AKS Cluster
resource aksCluster 'Microsoft.ContainerService/managedClusters@2024-02-01' = {
  name: clusterName
  location: location
  tags: {
    owner: ownerEmail
    project: 'documentdb-local-to-multicloud'
  }
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    dnsPrefix: clusterName
    kubernetesVersion: kubernetesVersion
    agentPoolProfiles: [
      {
        name: 'default'
        count: nodeCount
        vmSize: vmSize
        osType: 'Linux'
        mode: 'System'
        enableAutoScaling: enableAutoScaling
        minCount: enableAutoScaling ? minNodeCount : null
        maxCount: enableAutoScaling ? maxNodeCount : null
      }
    ]
    networkProfile: {
      networkPlugin: 'azure'
      networkPolicy: 'azure'
      loadBalancerSku: 'standard'
    }
    addonProfiles: {
      omsagent: {
        enabled: false
      }
    }
  }
}

output clusterName string = aksCluster.name
output clusterFqdn string = aksCluster.properties.fqdn
