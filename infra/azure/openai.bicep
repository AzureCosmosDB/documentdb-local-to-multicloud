// Deploys an Azure OpenAI account with text-embedding-3-small in swedencentral.
// Used by the DocumentDB demo to embed query strings at runtime for vector
// search against demodb.stays. The cluster does not need to be co-located —
// this account only needs low latency to wherever you'll run the demo from.

@description('Name of the Azure OpenAI account. Must be globally unique.')
param accountName string = 'docdb-demo-aoai-${uniqueString(resourceGroup().id)}'

@description('Region for the Azure OpenAI account. swedencentral is the recommended Western Europe region for text-embedding-3-small.')
@allowed([
  'swedencentral'
  'westeurope'
  'francecentral'
  'eastus'
  'eastus2'
])
param location string = 'swedencentral'

@description('Embedding model name.')
param embeddingModel string = 'text-embedding-3-small'

@description('Embedding model version.')
param embeddingModelVersion string = '1'

@description('Deployment name to use in the SDK. Keep stable — apps reference this.')
param embeddingDeploymentName string = 'text-embedding-3-small'

@description('Standard (PAYG) capacity in thousands of tokens per minute. 50 = 50K TPM, plenty for a demo.')
@minValue(1)
@maxValue(500)
param embeddingCapacityK int = 50

@description('Tags applied to the account.')
param tags object = {
  workload: 'documentdb-demo'
  purpose: 'techorama-belgium-2026'
}

resource account 'Microsoft.CognitiveServices/accounts@2024-10-01' = {
  name: accountName
  location: location
  tags: tags
  kind: 'OpenAI'
  sku: {
    name: 'S0'
  }
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    customSubDomainName: accountName
    publicNetworkAccess: 'Enabled'
    disableLocalAuth: false
    networkAcls: {
      defaultAction: 'Allow'
    }
  }
}

resource embeddingDeployment 'Microsoft.CognitiveServices/accounts/deployments@2024-10-01' = {
  parent: account
  name: embeddingDeploymentName
  sku: {
    name: 'GlobalStandard'
    capacity: embeddingCapacityK
  }
  properties: {
    model: {
      format: 'OpenAI'
      name: embeddingModel
      version: embeddingModelVersion
    }
    versionUpgradeOption: 'OnceCurrentVersionExpired'
    raiPolicyName: 'Microsoft.DefaultV2'
  }
}

@description('Endpoint for the SDK (https://<sub-domain>.openai.azure.com).')
output endpoint string = account.properties.endpoint

@description('Account name.')
output accountName string = account.name

@description('Region.')
output location string = location

@description('Deployment name to pass to the SDK.')
output embeddingDeploymentName string = embeddingDeployment.name

@description('Underlying model name.')
output embeddingModel string = embeddingModel

@description('Underlying model version.')
output embeddingModelVersion string = embeddingModelVersion
