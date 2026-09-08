@echo off
setlocal

set "PROJECT_DIR=%~dp0"
set "MANIFEST=%PROJECT_DIR%Cargo.toml"
set "OUTPUT=%PROJECT_DIR%target\release\mdeskmini.exe"
set "ADMIN_VERIFY_SCRIPT=%PROJECT_DIR%verify_admin_manifest.ps1"

if not exist "%MANIFEST%" (
  echo ERROR: Cargo.toml not found: "%MANIFEST%"
  exit /b 1
)

call "%PROJECT_DIR%..\setup_windows_x64_env.bat"
if errorlevel 1 exit /b 1

echo Building mdeskmini release...
echo Project: %PROJECT_DIR%

cargo build --manifest-path "%MANIFEST%" --release
if errorlevel 1 (
  echo ERROR: mdeskmini release build failed.
  exit /b 1
)

if not exist "%OUTPUT%" (
  echo ERROR: Build finished but executable was not found: "%OUTPUT%"
  exit /b 1
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%ADMIN_VERIFY_SCRIPT%" -Path "%OUTPUT%"
if errorlevel 1 (
  echo ERROR: Administrator manifest verification failed.
  exit /b 1
)

echo.
echo Build complete.
echo EXE: %OUTPUT%
call "%PROJECT_DIR%upx_max.bat"
if errorlevel 1 (
  echo ERROR: UPX packaging or administrator manifest verification failed.
  exit /b 1
)
exit /b 0
