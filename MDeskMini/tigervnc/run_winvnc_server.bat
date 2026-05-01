@echo off
setlocal EnableExtensions

cd /d "%~dp0"

if not defined DIST_DIR (
  if exist "%~dp0dist-windows-server-static\winvnc4.exe" (
    set "DIST_DIR=%~dp0dist-windows-server-static"
  ) else (
    set "DIST_DIR=%~dp0dist-windows-server"
  )
)
set "WINVNC=%DIST_DIR%\winvnc4.exe"
set "CONFIG=%DIST_DIR%\vncconfig.exe"

if not exist "%WINVNC%" (
  echo [ERROR] %WINVNC% was not found.
  echo Run this first:
  echo   build_windows.bat dist-server
  exit /b 1
)

set "ACTION=%~1"
if "%ACTION%"=="" set "ACTION=user"

if /I "%ACTION%"=="user" (
  "%WINVNC%" -noconsole
  exit /b %ERRORLEVEL%
)

if /I "%ACTION%"=="config" (
  "%CONFIG%"
  exit /b %ERRORLEVEL%
)

if /I "%ACTION%"=="register" (
  "%WINVNC%" -register
  exit /b %ERRORLEVEL%
)

if /I "%ACTION%"=="unregister" (
  "%WINVNC%" -unregister
  exit /b %ERRORLEVEL%
)

if /I "%ACTION%"=="start" (
  "%WINVNC%" -noconsole -start
  exit /b %ERRORLEVEL%
)

if /I "%ACTION%"=="stop" (
  "%WINVNC%" -noconsole -stop
  exit /b %ERRORLEVEL%
)

if /I "%ACTION%"=="help" goto usage
if /I "%ACTION%"=="-h" goto usage
if /I "%ACTION%"=="--help" goto usage

echo [ERROR] Unknown action: %ACTION%
echo.

:usage
echo TigerVNC Windows server runner
echo.
echo Usage:
echo   run_winvnc_server.bat [user^|config^|register^|unregister^|start^|stop^|help]
echo.
echo Examples:
echo   run_winvnc_server.bat user
echo   run_winvnc_server.bat config
echo   run_winvnc_server.bat register
echo   run_winvnc_server.bat start
echo.
echo Notes:
echo   register, unregister, start, and stop usually require Administrator PowerShell.
exit /b 0
