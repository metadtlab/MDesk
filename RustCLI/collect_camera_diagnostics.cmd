@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0collect_camera_diagnostics.ps1"
pause
