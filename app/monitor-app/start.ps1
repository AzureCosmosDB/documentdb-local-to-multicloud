# Demo-environment start script for the local Techorama setup.
# Sets the env vars the customer-facing server.js no longer hardcodes,
# launches the monitor app, and opens the Grafana dashboards on both
# clouds (Azure + AWS) in the default browser so the observability
# story is one click away during the demo.
[CmdletBinding()]
param(
    [switch]$NoBrowser,
    [switch]$NoGrafana
)

$ErrorActionPreference = "Stop"
$env:PATH = "$env:USERPROFILE\bin;$env:USERPROFILE\.azure-kubelogin;$env:PATH"
$env:PORT = if ($env:PORT) { $env:PORT } else { "5174" }
$env:DDB_NAMESPACE = "documentdb-preview-ns"
$env:DDB_RESOURCE = "documentdb-preview"
$env:DDB_HUB_CONTEXT = "hub"
$env:DDB_MEMBER_CONTEXTS = "azure-documentdb,aws-documentdb"
$env:DDB_DEMO_DATABASE = "bookingsdb"

# Grafana endpoints provisioned by monitoring/helm/values-kube-prometheus.yaml
# (kube-prometheus-stack on each cluster, anonymous Viewer enabled).
$AzureGrafana = "http://40.70.169.198/d/documentdb-failover/documentdb-failover-overview?orgId=1&refresh=10s"
$AwsGrafana   = "http://a6d5c0d8966584a85a1e540671a3132b-947608160.us-west-2.elb.amazonaws.com/d/documentdb-failover/documentdb-failover-overview?orgId=1&refresh=10s"
$MonitorUrl   = "http://localhost:$($env:PORT)"

Set-Location -Path $PSScriptRoot

if (-not $NoBrowser) {
    Start-Process $MonitorUrl
    if (-not $NoGrafana) {
        Start-Sleep -Seconds 1
        Start-Process $AzureGrafana
        Start-Process $AwsGrafana
    }
}

Write-Host ""
Write-Host "Monitor:        $MonitorUrl"
Write-Host "Azure Grafana:  $AzureGrafana"
Write-Host "AWS Grafana:    $AwsGrafana"
Write-Host "Grafana login:  anonymous Viewer (admin / techorama2026 for edit)"
Write-Host ""

node server.js
