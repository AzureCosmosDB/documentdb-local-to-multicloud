@echo off
REM Repo-root wrapper for data/load-data.ps1 — auto-discovers the AKS primary
REM endpoint + credentials and loads the demo dataset. See data/load-data.ps1
REM for parameters (-Local, -Context, etc.).
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0data\load-data.ps1" %*
