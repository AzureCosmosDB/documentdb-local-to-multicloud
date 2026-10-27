using './main.bicep'

param hubClusterName = 'aks-fleet-hub'
param hubRegion = 'eastus2'
param memberRegion = 'eastus2'
param kubernetesVersion = '1.35'
param nodeCount = 1
param hubVmSize = 'Standard_DS3_v2'
