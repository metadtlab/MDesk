@echo off
setlocal EnableExtensions EnableDelayedExpansion

set "PROJECT_DIR=%~dp0"
for %%I in ("%PROJECT_DIR%..") do set "REPO_DIR=%%~fI"
set "MANIFEST=%PROJECT_DIR%Cargo.toml"
set "TARGET=i686-win7-windows-msvc"
set "CARGO_TARGET_DIR=%PROJECT_DIR%target"
set "BUILD_OUTPUT=%CARGO_TARGET_DIR%\%TARGET%\release\mdeskmini.exe"
set "DIST_DIR=%CARGO_TARGET_DIR%\windows-x86"
set "OUTPUT=%DIST_DIR%\mdeskmini.exe"
set "PACKAGE=%DIST_DIR%\MDeskMini-x86.zip"
set "BUILD_ONLY=0"
if /i "%~1"=="--build-only" set "BUILD_ONLY=1"
if not "%~1"=="" if "%BUILD_ONLY%"=="0" goto :usage
if not "%~2"=="" goto :usage

if not exist "%MANIFEST%" (
  echo ERROR: Cargo.toml not found: "%MANIFEST%"
  exit /b 1
)

rem One Win7-compatible EXE. Mini allows hardware codecs only on Windows 10+.
if not defined MDESK_BUILD_VARIANT set "MDESK_BUILD_VARIANT=B2"
call "%REPO_DIR%\select_windows_build_features.bat"
if errorlevel 1 exit /b 1
if /i "%MDESK_BUILD_VARIANT%"=="B3" (
  echo ERROR: The unified x86 build supports B1 or B2; VRAM is not included.
  exit /b 1
)
call "%REPO_DIR%\prepare_windows_native.bat" x86
if errorlevel 1 exit /b 1
call "%REPO_DIR%\setup_windows_env.bat" x86
if errorlevel 1 exit /b 1

rustc --print target-list | findstr /c:"%TARGET%" >nul
if errorlevel 1 (
  echo ERROR: This Rust compiler does not support %TARGET%.
  exit /b 1
)
rustup component list --installed | findstr /b /c:"rust-src" >nul
if errorlevel 1 (
  rustup component add rust-src
  if errorlevel 1 exit /b 1
)

rem The Win7 Rust target needs build-std and the normal i686 import libraries.
pushd "%PROJECT_DIR%"
cargo fetch --manifest-path "%MANIFEST%" --locked --target i686-pc-windows-msvc
if errorlevel 1 (
  popd
  exit /b 1
)
popd
set "RUST_WINDOWS_LIBS="
set "MINI_CARGO_HOME=%CARGO_HOME%"
if not defined MINI_CARGO_HOME set "MINI_CARGO_HOME=%USERPROFILE%\.cargo"
for /d %%R in ("%MINI_CARGO_HOME%\registry\src\*") do (
  for /d %%D in ("%%~fR\windows_i686_msvc-*") do (
    if exist "%%~fD\lib" set "RUST_WINDOWS_LIBS=%%~fD\lib;!RUST_WINDOWS_LIBS!"
  )
)
if not defined RUST_WINDOWS_LIBS (
  echo ERROR: Rust Windows i686 import libraries were not found.
  exit /b 1
)
set "LIB=!RUST_WINDOWS_LIBS!!LIB!"
set "RUSTC_BOOTSTRAP=1"
set "RUSTFLAGS=-C target-feature=+crt-static -C link-arg=/SUBSYSTEM:WINDOWS,6.01 -C link-arg=/NODEFAULTLIB:MSVCRT"
echo Building MDeskMini x86: Win7 software, Windows 10+ hardware. Variant: %MDESK_BUILD_VARIANT%
pushd "%PROJECT_DIR%"
cargo build -Z build-std=std,panic_abort --manifest-path "%MANIFEST%" --locked --release --target %TARGET% --no-default-features --features "%MDESK_CARGO_FEATURES%"
if errorlevel 1 (
  popd
  echo ERROR: MDeskMini unified x86 release build failed.
  exit /b 1
)
popd
if not exist "%BUILD_OUTPUT%" (
  echo ERROR: Build output missing: "%BUILD_OUTPUT%"
  exit /b 1
)

rem Check actual loader imports; lowering the PE version alone is insufficient.
powershell -NoProfile -ExecutionPolicy Bypass -File "%PROJECT_DIR%win7\verify_win7_binary.ps1" -Path "%BUILD_OUTPUT%" -Architecture x86
if errorlevel 1 exit /b 1
rem Keep the native PE intact; distribute a ZIP instead of an executable packer.
if not exist "%DIST_DIR%" mkdir "%DIST_DIR%"
copy /y "%BUILD_OUTPUT%" "%OUTPUT%" >nul
if errorlevel 1 exit /b 1
powershell -NoProfile -ExecutionPolicy Bypass -File "%PROJECT_DIR%verify_admin_manifest.ps1" -Path "%OUTPUT%"
if errorlevel 1 exit /b 1
powershell -NoProfile -ExecutionPolicy Bypass -File "%PROJECT_DIR%verify_build_capabilities.ps1" -Path "%OUTPUT%" -Variant "%MDESK_BUILD_VARIANT%" -Architecture x86 -MinimumSubsystemVersion 6.1 -RequireWindowsCodecPolicy -OutputJson "%OUTPUT%.capabilities.json"
if errorlevel 1 exit /b 1
if "%BUILD_ONLY%"=="1" goto :done
powershell -NoProfile -ExecutionPolicy Bypass -File "%PROJECT_DIR%package_windows_x86.ps1" -Path "%OUTPUT%" -OutputZip "%PACKAGE%"
if errorlevel 1 exit /b 1
echo ZIP: %PACKAGE%

:done
echo.
echo Unified Windows x86 build complete. Variant: %MDESK_BUILD_VARIANT%
echo EXE: %OUTPUT%
echo Capabilities: %OUTPUT%.capabilities.json
exit /b 0

:usage
echo ERROR: Usage: build_release_32bit.bat [--build-only]
exit /b 1
