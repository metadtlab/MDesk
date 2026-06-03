@echo off
chcp 65001 >nul 2>&1
setlocal EnableExtensions EnableDelayedExpansion

rem Build MDesk/RustDesk Linux package from Windows by running the real build
rem inside the default WSL Linux distribution.
rem
rem Usage:
rem   run_build_ubuntu_wsl.bat
rem   run_build_ubuntu_wsl.bat --quick
rem   run_build_ubuntu_wsl.bat --deps-only
rem   run_build_ubuntu_wsl.bat --skip-deps
rem   run_build_ubuntu_wsl.bat --skip-submodules
rem
rem Notes:
rem   - Requires WSL2 Ubuntu with sudo access.
rem   - The Linux build output is written under flutter/build/linux/... and
rem     mdesk-*.deb in this repository.
rem   - Windows VCPKG_ROOT is intentionally not reused; the WSL script uses
rem     a Linux-side vcpkg under $HOME by default.

set "ROOT=%~dp0"
if "%ROOT:~-1%"=="\" set "ROOT=%ROOT:~0,-1%"
set "SCRIPT=build_ubuntu_flutter.sh"
set "HELP_MODE=0"
if /i "%~1"=="--help" set "HELP_MODE=1"
if /i "%~1"=="-h" set "HELP_MODE=1"

echo ============================================
echo MDesk Linux Build via WSL
echo ============================================
echo.

where wsl.exe >nul 2>&1
if errorlevel 1 (
    echo [ERROR] wsl.exe not found.
    echo Install WSL2 Ubuntu first:
    echo   wsl --install -d Ubuntu
    exit /b 1
)

if not exist "%ROOT%\%SCRIPT%" (
    echo [ERROR] %SCRIPT% not found in:
    echo   %ROOT%
    echo.
    echo Create or restore %SCRIPT% before running this BAT.
    exit /b 1
)

for /f "delims=" %%i in ('wsl.exe wslpath -a "%ROOT%" 2^>nul') do set "WSL_ROOT=%%i"
if not defined WSL_ROOT (
    echo [ERROR] Failed to convert Windows path to WSL path:
    echo   %ROOT%
    exit /b 1
)

echo [INFO] Windows repo: %ROOT%
echo [INFO] WSL repo:     %WSL_ROOT%
echo [INFO] Script:       %SCRIPT%
echo.

wsl.exe -e bash -lc "cd '%WSL_ROOT%' && sed -i 's/\r$//' './%SCRIPT%' && chmod +x './%SCRIPT%' && unset VCPKG_ROOT && './%SCRIPT%' %*"
set "RESULT=%ERRORLEVEL%"

echo.
if not "%RESULT%"=="0" (
    echo ============================================
    echo Linux build failed. Exit code: %RESULT%
    echo ============================================
    exit /b %RESULT%
)

if "%HELP_MODE%"=="1" (
    exit /b 0
)

echo ============================================
echo Linux build completed.
echo ============================================
echo Outputs:
echo   %ROOT%\mdesk-*.deb
echo   %ROOT%\flutter\build\linux\x64\release\bundle
echo.
exit /b 0
