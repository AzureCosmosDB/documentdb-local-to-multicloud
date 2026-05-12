<#
.SYNOPSIS
  Recovers a DocumentDB cluster stuck in "Instance Status Extraction Error:
  HTTP communication issue" after a replica rebuild.

.DESCRIPTION
  Caused by a race in the documentdb-kubernetes-operator's rebuild path:
  the regenerated -ca and -server secrets are mutually inconsistent
  (operator log shows `x509: ... unknown authority`).

  This script:
    1. Auto-detects which cluster (azure-documentdb / aws-documentdb) is stuck.
    2. Finds the underlying CNPG cluster name (hashed).
    3. Deletes the broken cert secrets.
    4. Restarts the operator deployment so it regenerates them atomically.
    5. Deletes the postgres pod so it picks up the fresh certs.
    6. Waits for "Cluster in healthy state".

  Total recovery time: ~3-5 minutes.

.PARAMETER Context
  Optional. If omitted, scans both clusters and fixes whichever one is stuck.

.EXAMPLE
  .\fix-rebuild-certs.ps1
  .\fix-rebuild-certs.ps1 -Context aws-documentdb
#>
[CmdletBinding()]
param(
    [string]$Context,
    [string]$Namespace = "documentdb-preview-ns",
    [string]$OperatorNamespace = "cnpg-system",
    [string]$OperatorDeploy = "documentdb-operator-cloudnative-pg"
)

$ErrorActionPreference = "Stop"

function Write-Step($msg) { Write-Host "==> $msg" -ForegroundColor Cyan }
function Write-Ok($msg)   { Write-Host "    $msg" -ForegroundColor Green }
function Write-Bad($msg)  { Write-Host "    $msg" -ForegroundColor Red }

function Get-StuckCluster([string]$ctx) {
    $phase = & kubectl --context $ctx -n $Namespace get cluster -o jsonpath='{.items[0].status.phase}' 2>$null
    $name  = & kubectl --context $ctx -n $Namespace get cluster -o jsonpath='{.items[0].metadata.name}' 2>$null
    [pscustomobject]@{ Context = $ctx; ClusterName = $name; Phase = $phase }
}

# 1. Discover stuck cluster(s)
Write-Step "Scanning clusters ..."
$candidates = if ($Context) { @($Context) } else { @("azure-documentdb", "aws-documentdb") }
$targets = @()
foreach ($c in $candidates) {
    $info = Get-StuckCluster $c
    Write-Host "    $($info.Context.PadRight(20)) cluster=$($info.ClusterName)  phase=$($info.Phase)"
    if ($info.Phase -match "Instance Status Extraction Error|HTTP communication issue") {
        $targets += $info
    }
}
if (-not $targets) {
    Write-Ok "No clusters in stuck-cert state. Nothing to fix."
    exit 0
}

foreach ($t in $targets) {
    $ctx = $t.Context
    $cl  = $t.ClusterName

    Write-Host ""
    Write-Step "Repairing $ctx / cluster=$cl"

    Write-Step "Deleting broken cert secrets ..."
    & kubectl --context $ctx -n $Namespace delete secret "$cl-ca" "$cl-server" "$cl-replication" --ignore-not-found | Out-Host

    Write-Step "Restarting operator (forces fresh CA generation) ..."
    & kubectl --context $ctx -n $OperatorNamespace rollout restart deploy/$OperatorDeploy | Out-Host
    & kubectl --context $ctx -n $OperatorNamespace rollout status  deploy/$OperatorDeploy --timeout=120s | Out-Host

    Write-Step "Waiting for operator to recreate cert secrets ..."
    $deadline = (Get-Date).AddSeconds(60)
    while ((Get-Date) -lt $deadline) {
        $secs = & kubectl --context $ctx -n $Namespace get secrets -o name 2>$null | Select-String "$cl-ca|$cl-server"
        if (($secs | Measure-Object).Count -ge 2) { Write-Ok "Secrets regenerated."; break }
        Start-Sleep -Seconds 3
    }

    Write-Step "Deleting postgres pod $cl-1 to pick up fresh certs ..."
    & kubectl --context $ctx -n $Namespace delete pod "$cl-1" --wait=$false | Out-Host
    Write-Step "Waiting for pod to become Ready (up to 3 min) ..."
    & kubectl --context $ctx -n $Namespace wait --for=condition=Ready pod "$cl-1" --timeout=180s | Out-Host

    Write-Step "Polling cluster phase until healthy (up to 5 min) ..."
    $deadline = (Get-Date).AddMinutes(5)
    $healthy = $false
    while ((Get-Date) -lt $deadline) {
        $phase = & kubectl --context $ctx -n $Namespace get cluster -o jsonpath='{.items[0].status.phase}' 2>$null
        $ready = & kubectl --context $ctx -n $Namespace get cluster -o jsonpath='{.items[0].status.readyInstances}/{.items[0].status.instances}' 2>$null
        Write-Host "    $(Get-Date -Format HH:mm:ss)  phase='$phase'  ready=$ready"
        if ($phase -match "^Cluster in healthy state") { $healthy = $true; break }
        Start-Sleep -Seconds 15
    }
    if ($healthy) {
        Write-Ok "$ctx is healthy."
    } else {
        Write-Bad "$ctx did not reach healthy state within 5 min - check 'kubectl get cluster' manually."
    }
}

Write-Host ""
Write-Ok "Done. Refresh the topology tab in the monitor app."
