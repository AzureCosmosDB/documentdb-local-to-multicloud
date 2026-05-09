# Demo-environment start script for the local Techorama setup.
# Sets the env vars the customer-facing server.js no longer hardcodes.
$ErrorActionPreference = "Stop"
$env:PATH = "$env:USERPROFILE\bin;$env:USERPROFILE\.azure-kubelogin;$env:PATH"
$env:PORT = if ($env:PORT) { $env:PORT } else { "5174" }
$env:DDB_NAMESPACE = "documentdb-preview-ns"
$env:DDB_RESOURCE = "documentdb-preview"
$env:DDB_HUB_CONTEXT = "hub"
$env:DDB_MEMBER_CONTEXTS = "azure-documentdb,aws-documentdb"
$env:DDB_DEMO_DATABASE = "bookingsdb"
Set-Location -Path $PSScriptRoot
node server.js
