# Demo-environment start script for the local Techorama setup.
# Sets the env vars the customer-facing server.js no longer hardcodes,
# launches the monitor app, and opens the Grafana dashboards on both
# clouds (Azure + AWS) in the default browser so the observability
# story is one click away during the demo.
[CmdletBinding()]
param(
    [switch]$NoBrowser,
    [switch]$NoGrafana,
    [string[]]$MemberContexts,
    [string]$HubContext
)

$ErrorActionPreference = "Stop"
$env:PATH = "$env:USERPROFILE\bin;$env:USERPROFILE\.azure-kubelogin;$env:PATH"
$env:PORT = if ($env:PORT) { $env:PORT } else { "5174" }
$env:DDB_NAMESPACE = if ($env:DDB_NAMESPACE) { $env:DDB_NAMESPACE } else { "documentdb-preview-ns" }
$env:DDB_RESOURCE = if ($env:DDB_RESOURCE) { $env:DDB_RESOURCE } else { "documentdb-preview" }
$env:DDB_HUB_CONTEXT = if ($HubContext) { $HubContext } elseif ($env:DDB_HUB_CONTEXT) { $env:DDB_HUB_CONTEXT } elseif ($env:HUB_CONTEXT) { $env:HUB_CONTEXT } else { "hub" }
if ($MemberContexts) {
    $env:DDB_MEMBER_CONTEXTS = $MemberContexts -join ","
} elseif (-not $env:DDB_MEMBER_CONTEXTS) {
    $members = @(if ($env:AKS_CLUSTER_NAME) { $env:AKS_CLUSTER_NAME } else { "azure-documentdb" })
    if ($env:INCLUDE_AKS_REPLICA -eq "true") {
        $members += if ($env:AKS_REPLICA_NAME) { $env:AKS_REPLICA_NAME } else { "azure-documentdb-secondary" }
    }
    if ($env:INCLUDE_EKS -ne "false") {
        $members += if ($env:EKS_CLUSTER_NAME) { $env:EKS_CLUSTER_NAME } else { "aws-documentdb" }
    }
    if ($env:INCLUDE_GKE -eq "true") {
        $members += if ($env:GKE_CLUSTER_NAME) { $env:GKE_CLUSTER_NAME } else { "gcp-documentdb" }
    }
    $env:DDB_MEMBER_CONTEXTS = $members -join ","
}
$env:DDB_DEMO_DATABASE = if ($env:DDB_DEMO_DATABASE) { $env:DDB_DEMO_DATABASE } else { "bookingsdb" }

# Grafana endpoints provisioned by monitoring/helm/values-kube-prometheus.yaml
# (kube-prometheus-stack on each cluster, anonymous Viewer enabled).
$GrafanaUrls = @()
if (-not $NoGrafana -and -not $NoBrowser) {
    foreach ($context in $env:DDB_MEMBER_CONTEXTS.Split(",")) {
        $services = & kubectl --context $context.Trim() -n monitoring get service -l app.kubernetes.io/name=grafana -o json
        if ($LASTEXITCODE -ne 0) { Write-Warning "Unable to discover Grafana on $context"; continue }
        foreach ($service in ($services | ConvertFrom-Json).items) {
            $ingress = $service.status.loadBalancer.ingress | Select-Object -First 1
            $hostName = if ($ingress.hostname) { $ingress.hostname } else { $ingress.ip }
            if ($hostName) {
                $GrafanaUrls += "http://$hostName/d/documentdb-failover/documentdb-failover-overview?orgId=1&refresh=10s"
            } else { Write-Warning "Grafana on $context has no LoadBalancer address yet" }
        }
    }
}
$MonitorUrl   = "http://localhost:$($env:PORT)"

Set-Location -Path $PSScriptRoot

if (-not $NoBrowser) {
    Start-Process $MonitorUrl
    if (-not $NoGrafana) {
        Start-Sleep -Seconds 1
        foreach ($url in $GrafanaUrls) { Start-Process $url }
    }
}

Write-Host ""
Write-Host "Monitor:        $MonitorUrl"
Write-Host "Members:        $env:DDB_MEMBER_CONTEXTS"
foreach ($url in $GrafanaUrls) { Write-Host "Grafana:        $url" }
Write-Host ""

node server.js
