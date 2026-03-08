@echo off
setlocal

set "REPO_DIR=%~dp0"
set "MODE=%~1"
set "DEVICE_ID=%~2"

if "%MODE%"=="" set "MODE=fast"
if "%DEVICE_ID%"=="" set "DEVICE_ID=emulator-5554"

if /i "%MODE%"=="-h" goto :help
if /i "%MODE%"=="--help" goto :help

echo ============================================
echo Android Quick Runner
echo ============================================
echo.
echo   MODE: %MODE%
echo   DEVICE_ID: %DEVICE_ID%
echo.

if /i "%MODE%"=="full" goto :full
if /i "%MODE%"=="clean" goto :clean
if /i "%MODE%"=="fast" goto :fast

echo [ERROR] Unknown mode: %MODE%
echo.
goto :help

:fast
echo [1/2] Checking Flutter devices...
cmd /c "cd /d "%REPO_DIR%flutter" && flutter devices"
if errorlevel 1 exit /b 1

echo.
echo [2/2] Running app quickly...
cmd /c "cd /d "%REPO_DIR%flutter" && flutter run -d %DEVICE_ID% --debug --target lib/main.dart"
exit /b %errorlevel%

:clean
echo [1/3] Cleaning Flutter build cache...
cmd /c "cd /d "%REPO_DIR%flutter" && flutter clean"
if errorlevel 1 exit /b 1

echo.
echo [2/3] Restoring Flutter packages...
cmd /c "cd /d "%REPO_DIR%flutter" && flutter pub get"
if errorlevel 1 exit /b 1

echo.
echo [3/3] Running app after clean rebuild...
cmd /c "cd /d "%REPO_DIR%flutter" && flutter run -d %DEVICE_ID% --debug --target lib/main.dart"
exit /b %errorlevel%

:full
echo [1/1] Running full Android debug build and launch...
call "%REPO_DIR%run_android_debug.bat" %DEVICE_ID%
exit /b %errorlevel%

:help
echo Usage:
echo   run_android_quick.bat [fast^|clean^|full] [device-id]
echo.
echo Examples:
echo   run_android_quick.bat
echo   run_android_quick.bat fast emulator-5554
echo   run_android_quick.bat clean emulator-5554
echo   run_android_quick.bat full emulator-5554
exit /b 1
