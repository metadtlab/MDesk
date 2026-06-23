@echo off
setlocal

set "DEVICE_ID=%~1"
set "PACKAGE_NAME=com.carriez.flutter_hbb.host"

set "ADB_EXE=adb"
where adb >nul 2>&1
if errorlevel 1 (
    if exist "%LOCALAPPDATA%\Android\Sdk\platform-tools\adb.exe" (
        set "ADB_EXE=%LOCALAPPDATA%\Android\Sdk\platform-tools\adb.exe"
    )
)

if "%DEVICE_ID%"=="" (
    set "ADB_DEVICE_ARG="
) else (
    set "ADB_DEVICE_ARG=-s %DEVICE_ID%"
)

echo Allowing Android restricted settings for %PACKAGE_NAME%...
"%ADB_EXE%" %ADB_DEVICE_ARG% shell appops set %PACKAGE_NAME% ACCESS_RESTRICTED_SETTINGS allow
if errorlevel 1 (
    echo [ERROR] Failed to allow restricted settings.
    echo Make sure the host app is installed and the device is connected.
    exit /b 1
)

echo Current app-op state:
"%ADB_EXE%" %ADB_DEVICE_ARG% shell appops get %PACKAGE_NAME% | findstr /I "ACCESS_RESTRICTED_SETTINGS BIND_ACCESSIBILITY_SERVICE"
echo.
echo Done. Now open Accessibility settings and enable "MDesk Host Input".
exit /b 0
