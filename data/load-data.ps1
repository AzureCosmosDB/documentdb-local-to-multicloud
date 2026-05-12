# Auto-discovering data loader for the multi-cloud DocumentDB demo.
#
# Loads the bookings/listings dataset onto the current AKS primary (which then
# replicates it to EKS over WAL). Users don't need to know the endpoint,
# password, port, or which cloud is currently primary — this script figures
# all of that out from the Fleet hub.
#
# Auto-discovers:
#   - Current primary context (from spec.clusterReplication.primary on the
#     DocumentDB CR on the Fleet hub)
#   - Gateway password (from the documentdb-credentials Secret)
#   - Cluster gateway service + port
#   - Sets up + tears down its own kubectl port-forward
#
# Usage:
#   .\data\load-data.ps1                # auto: discover primary and load
#   .\data\load-data.ps1 -Context azure-documentdb   # force a target
#   .\data\load-data.ps1 -Local         # load into local Docker (port 27017)
#
# Requires: kubectl, mongosh.exe OR mongoimport on PATH.
[CmdletBinding()]
param(
    [string]$Context,
    [switch]$Local,
    [string]$DataFile,
    [string]$Database = "bookingsdb",
    [string]$Collection = "listings",
    [string]$HubContext = "hub",
    [string]$Namespace = "documentdb-preview-ns",
    [string]$Resource = "documentdb-preview",
    [string]$CredentialsSecret = "documentdb-credentials",
    [string]$GatewayUser = "docdb",
    [int]$LocalPort = 57100
)

$ErrorActionPreference = "Stop"
$repoRoot = Split-Path -Parent $PSScriptRoot
if (-not $DataFile) {
    $DataFile = Join-Path $PSScriptRoot "listings_vectors.json"
}
if (-not (Test-Path $DataFile)) {
    throw "Data file not found: $DataFile"
}

function Write-Info($msg) { Write-Host "  $msg" -ForegroundColor Cyan }
function Write-Ok($msg)   { Write-Host "  $msg" -ForegroundColor Green }

if ($Local) {
    Write-Host "=== Local Docker target ===" -ForegroundColor Yellow
    $uri = "mongodb://demo:demo@localhost:27017/?tls=true&tlsAllowInvalidCertificates=true"
    Write-Info "URI: mongodb://demo:***@localhost:27017"
}
else {
    Write-Host "=== Multi-cloud target (auto-discover) ===" -ForegroundColor Yellow

    # 1. Discover primary context from the DocumentDB CR on the hub
    if (-not $Context) {
        Write-Info "Reading current primary from --context $HubContext ..."
        $Context = (kubectl --context $HubContext -n $Namespace get documentdb $Resource `
            -o jsonpath='{.spec.clusterReplication.primary}' 2>$null)
        if ([string]::IsNullOrWhiteSpace($Context)) {
            throw "Could not read primary context from hub. Is the multi-cloud stack deployed? Try -Context azure-documentdb to force it."
        }
        Write-Ok "Current primary context: $Context"
    } else {
        Write-Info "Using explicit primary context: $Context"
    }

    # 2. Fetch gateway password from credentials secret
    Write-Info "Fetching credentials from secret '$CredentialsSecret' on $Context ..."
    $passwordB64 = (kubectl --context $Context -n $Namespace get secret $CredentialsSecret `
        -o jsonpath='{.data.password}' 2>$null)
    if ([string]::IsNullOrWhiteSpace($passwordB64)) {
        throw "Could not read $CredentialsSecret on $Context. Has deploy-documentdb.sh been run?"
    }
    $password = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($passwordB64))

    # 3. Start port-forward to the gateway service
    $gwSvc = "documentdb-service-$Resource"
    Write-Info "Starting port-forward: svc/$gwSvc :${LocalPort} -> 10260 on $Context ..."
    $pfArgs = @("--context", $Context, "-n", $Namespace, "port-forward", "svc/$gwSvc", "${LocalPort}:10260")
    $pf = Start-Process kubectl -ArgumentList $pfArgs -PassThru -WindowStyle Hidden `
        -RedirectStandardOutput "$env:TEMP\pf-stdout-$Context.log" `
        -RedirectStandardError  "$env:TEMP\pf-stderr-$Context.log"

    # 4. Wait until the local port is accepting connections (max 15s)
    $deadline = (Get-Date).AddSeconds(15)
    $ready = $false
    while ((Get-Date) -lt $deadline) {
        try {
            $tcp = New-Object System.Net.Sockets.TcpClient
            $tcp.Connect("127.0.0.1", $LocalPort)
            $tcp.Close()
            $ready = $true
            break
        } catch { Start-Sleep -Milliseconds 400 }
    }
    if (-not $ready) {
        try { Stop-Process -Id $pf.Id -Force -ErrorAction SilentlyContinue } catch {}
        throw "Port-forward never became ready on localhost:$LocalPort"
    }
    Write-Ok "Port-forward up on localhost:$LocalPort (pid $($pf.Id))"

    Add-Type -AssemblyName System.Web | Out-Null
    $encPw = [System.Web.HttpUtility]::UrlEncode($password)
    $uri = "mongodb://${GatewayUser}:${encPw}@127.0.0.1:${LocalPort}/?tls=true&tlsAllowInvalidCertificates=true&directConnection=true"
}

try {
    $start = Get-Date

    # Prefer mongoimport (fast); fall back to mongosh inline insert
    $haveMongoimport = $null -ne (Get-Command mongoimport -ErrorAction SilentlyContinue)
    if ($haveMongoimport) {
        Write-Info "Loading $DataFile via mongoimport ..."
        & mongoimport --uri="$uri" --db=$Database --collection=$Collection --file="$DataFile" --jsonArray --drop
        if ($LASTEXITCODE -ne 0) { throw "mongoimport failed (exit $LASTEXITCODE)" }
    }
    else {
        Write-Info "mongoimport not found, falling back to mongosh ..."
        $dataFileEsc = $DataFile -replace '\\','\\\\'
        $script = @"
use('$Database');
db['$Collection'].drop();
const fs = require('fs');
const data = JSON.parse(fs.readFileSync('$dataFileEsc', 'utf8'));
const result = db['$Collection'].insertMany(data);
print('Inserted: ' + result.insertedIds.length + ' documents');
"@
        & mongosh "$uri" --quiet --eval $script
        if ($LASTEXITCODE -ne 0) { throw "mongosh load failed (exit $LASTEXITCODE)" }
    }

    Write-Info "Creating vector index + query indexes ..."
    $indexScript = @"
use('$Database');
db.runCommand({
  createIndexes: '$Collection',
  indexes: [{ key: { 'descriptionVector': 'cosmosSearch' }, name: 'vectorSearchIndex',
              cosmosSearchOptions: { kind: 'vector-hnsw', similarity: 'COS', dimensions: 1536 } }]
});
db['$Collection'].createIndex({ property_type: 1, price: 1 });
db['$Collection'].createIndex({ price: 1 });
db['$Collection'].createIndex({ bedrooms: 1, beds: 1 });
db['$Collection'].createIndex({ tags: 1 });
db['$Collection'].createIndex({ id: 1 });
print('Total documents: ' + db['$Collection'].countDocuments());
"@
    & mongosh "$uri" --quiet --eval $indexScript
    if ($LASTEXITCODE -ne 0) { throw "Index creation failed (exit $LASTEXITCODE)" }

    $elapsed = [int]((Get-Date) - $start).TotalSeconds
    Write-Host ""
    Write-Host "Data loaded in ${elapsed}s" -ForegroundColor Green
    Write-Host "  Database:     $Database"
    Write-Host "  Collection:   $Collection"
    Write-Host "  Vector index: vectorSearchIndex (HNSW, cosine, 1536 dim)"
    if (-not $Local) {
        Write-Host "  Target:       $Context (replicates to other cloud via WAL)"
    }
}
finally {
    if (-not $Local -and $pf) {
        Write-Info "Stopping port-forward (pid $($pf.Id)) ..."
        try { Stop-Process -Id $pf.Id -Force -ErrorAction SilentlyContinue } catch {}
    }
}
