@echo off
setlocal enabledelayedexpansion

set "REPO_DIR=%~dp0"
set "LOCAL_PROPERTIES=%REPO_DIR%flutter\android\local.properties"
set "DEFAULT_AVD=Medium_Phone_API_36.1"
set "AVD_NAME=%~1"

if /i "%~1"=="list" goto :list_avds
if "%AVD_NAME%"=="" set "AVD_NAME=%DEFAULT_AVD%"

set "SDK_DIR="
if exist "%LOCAL_PROPERTIES%" (
    for /f "usebackq tokens=1,* delims==" %%A in ("%LOCAL_PROPERTIES%") do (
        if /i "%%A"=="sdk.dir" set "SDK_DIR=%%B"
    )
)

if defined SDK_DIR set "SDK_DIR=%SDK_DIR:\\=\%"
if not defined SDK_DIR set "SDK_DIR=%LOCALAPPDATA%\Android\sdk"

set "ADB=%SDK_DIR%\platform-tools\adb.exe"
set "EMULATOR=%SDK_DIR%\emulator\emulator.exe"

echo ============================================
echo Android Emulator Launcher
echo ============================================
echo.
echo   SDK_DIR: %SDK_DIR%
echo   AVD_NAME: %AVD_NAME%
echo.

if not exist "%EMULATOR%" (
    echo [ERROR] emulator.exe not found.
    echo         Expected: %EMULATOR%
    exit /b 1
)

if not exist "%ADB%" (
    echo [ERROR] adb.exe not found.
    echo         Expected: %ADB%
    exit /b 1
)

echo [1/4] Available AVDs
"%EMULATOR%" -list-avds
echo.

echo [2/4] Launching emulator...
start "" "%EMULATOR%" -avd "%AVD_NAME%"
if errorlevel 1 (
    echo [ERROR] Failed to launch emulator "%AVD_NAME%"
    exit /b 1
)
echo.

echo [3/4] Restarting adb...
"%ADB%" kill-server >nul 2>&1
"%ADB%" start-server >nul 2>&1
echo.

echo [4/4] Waiting for emulator to become ready...
set "EMULATOR_SERIAL="
for /l %%I in (1,1,90) do (
    set "EMULATOR_SERIAL="
    for /f "skip=1 tokens=1,2" %%A in ('"%ADB%" devices') do (
        set "SERIAL_CANDIDATE=%%A"
        if /i "%%B"=="device" (
            if /i "!SERIAL_CANDIDATE:~0,9!"=="emulator-" set "EMULATOR_SERIAL=%%A"
        )
    )

    if defined EMULATOR_SERIAL (
        set "BOOT_DONE="
        for /f %%A in ('"%ADB%" -s !EMULATOR_SERIAL! shell getprop sys.boot_completed') do (
            set "BOOT_DONE=%%A"
        )
        if "!BOOT_DONE!"=="1" goto :ready
    )

    echo   waiting... %%I/90
    ping -n 3 127.0.0.1 >nul
)

echo.
echo [ERROR] Emulator did not become ready in time.
echo         Check the emulator window or run:
echo         "%ADB%" devices
exit /b 1

:ready
echo.
echo Emulator is ready.
echo   Serial: %EMULATOR_SERIAL%
echo.
echo Next commands:
echo   cd flutter
echo   flutter devices
echo   flutter run -d %EMULATOR_SERIAL%
exit /b 0

:list_avds
if not defined SDK_DIR (
    set "SDK_DIR=%LOCALAPPDATA%\Android\sdk"
    set "EMULATOR=%SDK_DIR%\emulator\emulator.exe"
)
if not exist "%EMULATOR%" (
    echo [ERROR] emulator.exe not found.
    exit /b 1
)
"%EMULATOR%" -list-avds
exit /b 0
