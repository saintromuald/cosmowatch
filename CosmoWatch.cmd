@echo off
rem CosmoWatch.cmd - convenience wrapper (avoids PowerShell execution-policy friction)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0CosmoWatch.ps1" %*
