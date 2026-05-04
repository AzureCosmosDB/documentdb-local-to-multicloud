using 'main.bicep'

param location = 'eastus2'
param clusterName = 'docdb-demo-aks'
param kubernetesVersion = '1.35'
param vmSize = 'Standard_D4s_v5'
param nodeCount = 2
param enableAutoScaling = true
param minNodeCount = 1
param maxNodeCount = 3
param ownerEmail = ''
