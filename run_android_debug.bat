@echo off
setlocal

set "REPO_DIR=%~dp0"
set "DEVICE_ID=%~1"
if "%DEVICE_ID%"=="" set "DEVICE_ID=emulator-5554"

echo ============================================
echo Android Emulator Debug Runner
echo ============================================
echo.
echo   DEVICE_ID: %DEVICE_ID%
echo.

call "%REPO_DIR%run_android_emulator.bat"
if errorlevel 1 (
    echo [ERROR] Emulator is not ready.
    exit /b 1
)

echo.
echo [1/3] Building Android x86_64 debug libraries and APK...
call "%REPO_DIR%build_android.bat" debug --x64-only
if errorlevel 1 (
    echo [ERROR] Android debug build failed.
    exit /b 1
)

echo.
echo [2/3] Checking Flutter devices...
cmd /c "cd /d "%REPO_DIR%flutter" && flutter devices"
if errorlevel 1 (
    echo [ERROR] flutter devices failed.
    exit /b 1
)

echo.
echo [3/3] Starting flutter run...
echo.
cmd /c "cd /d "%REPO_DIR%flutter" && flutter run -d %DEVICE_ID% --debug --target lib/main.dart"
exit /b %errorlevel%
