@echo off
setlocal

set "REPO_ROOT=%~dp0"
if "%REPO_ROOT:~-1%"=="\" set "REPO_ROOT=%REPO_ROOT:~0,-1%"

if /i "%~1"=="--help" goto :show_help
if not "%~1"=="" goto :show_help

echo ============================================
echo MDesk Android Remote Release AAB
echo ============================================
echo.

if not exist "%REPO_ROOT%\flutter\android\key.properties" (
    echo [ERROR] Missing signing config:
    echo   %REPO_ROOT%\flutter\android\key.properties
    echo.
    echo Create upload-keystore.jks and key.properties first.
    echo This script refuses to build a Play Store bundle with debug signing.
    exit /b 1
)

call "%REPO_ROOT%\build_android.bat" release --flavor remote --aab
exit /b %ERRORLEVEL%

:show_help
echo Usage:
echo   build_android_remote_release_aab.bat
echo.
echo Always builds the Android remote client as a signed release AAB.
echo Output:
echo   flutter\build\app\outputs\bundle\remoteRelease\app-remote-release.aab
echo.
exit /b 0
