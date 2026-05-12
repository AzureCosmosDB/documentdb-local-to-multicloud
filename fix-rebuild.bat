@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\fix-rebuild-certs.ps1" %*
