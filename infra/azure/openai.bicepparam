using './openai.bicep'

// Override any of these via env vars in deploy-openai.sh, or edit here.
param accountName = 'docdb-demo-aoai'
param location = 'swedencentral'
param embeddingModel = 'text-embedding-3-small'
param embeddingDeploymentName = 'text-embedding-3-small'
param embeddingCapacityK = 50
