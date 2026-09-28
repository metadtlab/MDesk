@echo off
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\linux-publish\publish-linux.ps1" %*
set "PUBLISH_EXIT=%ERRORLEVEL%"
if "%PUBLISH_EXIT%"=="0" if "%~1"=="" if exist "%~dp0dist\linux-publish\upload\linux" explorer.exe "%~dp0dist\linux-publish\upload\linux"
if "%~1"=="" pause
exit /b %PUBLISH_EXIT%
