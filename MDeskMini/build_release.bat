@echo off
setlocal EnableExtensions

set "PROJECT_DIR=%~dp0"
for %%I in ("%PROJECT_DIR%..") do set "REPO_DIR=%%~fI"
set "MANIFEST=%PROJECT_DIR%Cargo.toml"
set "CARGO_TARGET_DIR=%PROJECT_DIR%target"
set "TARGET=x86_64-pc-windows-msvc"
set "BUILD_OUTPUT=%CARGO_TARGET_DIR%\%TARGET%\release\mdeskmini.exe"
set "OUTPUT=%PROJECT_DIR%target\release\mdeskmini.exe"
set "ADMIN_VERIFY_SCRIPT=%PROJECT_DIR%verify_admin_manifest.ps1"
set "BUILD_ONLY=0"
if /i "%~1"=="--build-only" set "BUILD_ONLY=1"
if not "%~1"=="" if "%BUILD_ONLY%"=="0" (
  echo ERROR: Usage: build_release.bat [--build-only]
  exit /b 1
)

if not exist "%MANIFEST%" (
  echo ERROR: Cargo.toml not found: "%MANIFEST%"
  exit /b 1
)

rem Same B1/B2/B3 selection as MDesk. Modern Mini defaults to B3.
call "%REPO_DIR%\select_windows_build_features.bat"
if errorlevel 1 exit /b 1
call "%REPO_DIR%\prepare_windows_native.bat"
if errorlevel 1 exit /b 1
call "%REPO_DIR%\setup_windows_x64_env.bat"
if errorlevel 1 exit /b 1

echo Building mdeskmini release...
echo Project: %PROJECT_DIR%

rem Build from Mini so the repository Cargo config applies from any caller CWD.
pushd "%PROJECT_DIR%"
cargo build --manifest-path "%MANIFEST%" --locked --release --target %TARGET% --no-default-features --features "%MDESK_CARGO_FEATURES%"
if errorlevel 1 (
  popd
  echo ERROR: mdeskmini release build failed.
  exit /b 1
)
popd

if not exist "%BUILD_OUTPUT%" (
  echo ERROR: Build finished but executable was not found: "%BUILD_OUTPUT%"
  exit /b 1
)

rem Preserve Cargo's pristine output. Repeated builds must not repack an UPX EXE.
if not exist "%PROJECT_DIR%target\release" mkdir "%PROJECT_DIR%target\release"
copy /y "%BUILD_OUTPUT%" "%OUTPUT%" >nul
if errorlevel 1 exit /b 1

powershell -NoProfile -ExecutionPolicy Bypass -File "%ADMIN_VERIFY_SCRIPT%" -Path "%OUTPUT%"
if errorlevel 1 (
  echo ERROR: Administrator manifest verification failed.
  exit /b 1
)

if "%BUILD_ONLY%"=="1" goto :verify_capabilities
call "%PROJECT_DIR%upx_max.bat"
if errorlevel 1 (
  echo ERROR: UPX packaging or administrator manifest verification failed.
  exit /b 1
)

:verify_capabilities
powershell -NoProfile -ExecutionPolicy Bypass -File "%PROJECT_DIR%verify_build_capabilities.ps1" -Path "%OUTPUT%" -Variant "%MDESK_BUILD_VARIANT%" -OutputJson "%OUTPUT%.capabilities.json"
if errorlevel 1 exit /b 1
echo.
echo Build complete. Variant: %MDESK_BUILD_VARIANT%
echo EXE: %OUTPUT%
echo Build capabilities: %OUTPUT%.capabilities.json
exit /b 0
