@echo off
setlocal

set "PROJECT_DIR=%~dp0"
set "MANIFEST=%PROJECT_DIR%Cargo.toml"
set "OUTPUT=%PROJECT_DIR%target\release\mdeskmini.exe"

if not exist "%MANIFEST%" (
  echo ERROR: Cargo.toml not found: "%MANIFEST%"
  exit /b 1
)

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

echo.
echo Build complete.
echo EXE: %OUTPUT%
upx_max.bat
exit /b 0
