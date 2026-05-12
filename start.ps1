# Repo-root launcher for the multi-cloud DocumentDB demo.
#
# This is a thin wrapper around app/monitor-app/start.ps1, which:
#   1. Sets the env vars the monitor app expects (PORT, hub/member contexts, etc.)
#   2. Opens the monitor app at http://localhost:5174
#   3. Opens both Grafana dashboards (Azure + AWS LoadBalancer URLs)
#   4. Starts node server.js — which spawns its own kubectl port-forwards
#      to each cluster's DocumentDB gateway (no manual port-forward terminals).
#
# Prereqs:
#   - Multi-cloud stack already deployed (see SETUP.md, Phase 3)
#   - `az login` + `aws sso login` current
#   - npm install already run in app/monitor-app
#
# Usage:
#   .\start.ps1               # full launch: monitor + both Grafana tabs
#   .\start.ps1 -NoGrafana    # skip the two Grafana tabs
#   .\start.ps1 -NoBrowser    # don't open any tabs, just start the server
[CmdletBinding()]
param(
    [switch]$NoBrowser,
    [switch]$NoGrafana
)

$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
& "$here\app\monitor-app\start.ps1" @PSBoundParameters
