@echo off
REM Repo-root launcher for the multi-cloud DocumentDB demo.
REM Delegates to app\monitor-app\start.ps1 — see that file or start.ps1 for details.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0start.ps1" %*
