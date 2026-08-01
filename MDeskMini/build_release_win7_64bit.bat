@echo off
setlocal EnableExtensions EnableDelayedExpansion

set "PROJECT_DIR=%~dp0"
for %%I in ("%PROJECT_DIR%..") do set "REPO_DIR=%%~fI"
set "MANIFEST=%PROJECT_DIR%Cargo.toml"
set "TARGET=x86_64-win7-windows-msvc"
set "FETCH_TARGET=x86_64-pc-windows-msvc"
set "VCPKG_TRIPLET=x64-windows-static"
set "CARGO_TARGET_DIR=%PROJECT_DIR%target"
set "BUILD_OUTPUT=%CARGO_TARGET_DIR%\%TARGET%\release\mdeskmini.exe"
set "DIST_DIR=%CARGO_TARGET_DIR%\win7-x64"
set "DIST_OUTPUT=%DIST_DIR%\MDeskMini-Win7-x64.exe"
set "VERIFY_SCRIPT=%PROJECT_DIR%win7\verify_win7_binary.ps1"

echo ========================================
echo MDeskMini Windows 7 SP1 64-bit build
echo ========================================
echo.

if not exist "%MANIFEST%" (
  echo ERROR: Cargo.toml not found: "%MANIFEST%"
  exit /b 1
)

where cargo >nul 2>nul
if errorlevel 1 (
  echo ERROR: cargo was not found in PATH.
  exit /b 1
)

where rustup >nul 2>nul
if errorlevel 1 (
  echo ERROR: rustup was not found in PATH.
  exit /b 1
)

echo [1/6] Checking the Rust Windows 7 build support
rustc --print target-list | findstr /c:"%TARGET%" >nul
if errorlevel 1 (
  echo ERROR: The installed Rust compiler does not support %TARGET%.
  echo Update Rust with: rustup update stable
  exit /b 1
)

rustup component list --installed | findstr /b /c:"rust-src" >nul
if errorlevel 1 (
  echo Installing the Rust standard library sources...
  rustup component add rust-src
  if errorlevel 1 (
    echo ERROR: Failed to install the rust-src component.
    exit /b 1
  )
)
echo [OK] Rust source build support is ready.

echo.
echo [2/6] Checking 64-bit native dependencies
if not defined VCPKG_ROOT (
  echo ERROR: VCPKG_ROOT is not set.
  echo Example: set VCPKG_ROOT=D:\path\to\vcpkg
  exit /b 1
)
set "VCPKG_EXE=%VCPKG_ROOT%\vcpkg.exe"
set "VCPKG_X64=%VCPKG_ROOT%\installed\%VCPKG_TRIPLET%"
if not exist "%VCPKG_EXE%" (
  echo ERROR: vcpkg.exe not found: "%VCPKG_EXE%"
  exit /b 1
)

set "NEED_VCPKG_INSTALL=0"
set "NEED_LIBVPX_INSTALL=0"
if not exist "%VCPKG_X64%\include\vpx\vp8.h" set "NEED_LIBVPX_INSTALL=1"
if not exist "%VCPKG_X64%\lib\vpx.lib" set "NEED_LIBVPX_INSTALL=1"
if "!NEED_LIBVPX_INSTALL!"=="1" set "NEED_VCPKG_INSTALL=1"
if not exist "%VCPKG_X64%\include\libyuv.h" set "NEED_VCPKG_INSTALL=1"
if not exist "%VCPKG_X64%\include\aom\aom_codec.h" set "NEED_VCPKG_INSTALL=1"
if not exist "%VCPKG_X64%\include\opus\opus_multistream.h" set "NEED_VCPKG_INSTALL=1"
if not exist "%VCPKG_X64%\lib\yuv.lib" set "NEED_VCPKG_INSTALL=1"
if not exist "%VCPKG_X64%\lib\aom.lib" set "NEED_VCPKG_INSTALL=1"
if not exist "%VCPKG_X64%\lib\opus.lib" set "NEED_VCPKG_INSTALL=1"

if "!NEED_VCPKG_INSTALL!"=="1" (
  echo Installing libvpx, libyuv, aom and opus for %VCPKG_TRIPLET%...
  if "!NEED_LIBVPX_INSTALL!"=="1" (
    "%VCPKG_EXE%" remove libvpx:%VCPKG_TRIPLET% --classic
    if errorlevel 1 (
      echo ERROR: Failed to remove the incomplete libvpx package.
      exit /b 1
    )
    "%VCPKG_EXE%" install libvpx:%VCPKG_TRIPLET% --classic
    if errorlevel 1 (
      echo ERROR: Failed to install libvpx:%VCPKG_TRIPLET%.
      exit /b 1
    )
  )
  "%VCPKG_EXE%" install libyuv:%VCPKG_TRIPLET% aom:%VCPKG_TRIPLET% opus:%VCPKG_TRIPLET% --classic --overlay-ports="%REPO_DIR%\res\vcpkg"
  if errorlevel 1 (
    echo ERROR: Failed to install %VCPKG_TRIPLET% dependencies.
    exit /b 1
  )
)

if not exist "%VCPKG_X64%\include\vpx\vp8.h" goto :missing_vcpkg
if not exist "%VCPKG_X64%\include\libyuv.h" goto :missing_vcpkg
if not exist "%VCPKG_X64%\include\aom\aom_codec.h" goto :missing_vcpkg
if not exist "%VCPKG_X64%\include\opus\opus_multistream.h" goto :missing_vcpkg
if not exist "%VCPKG_X64%\lib\vpx.lib" goto :missing_vcpkg
if not exist "%VCPKG_X64%\lib\yuv.lib" goto :missing_vcpkg
if not exist "%VCPKG_X64%\lib\aom.lib" goto :missing_vcpkg
if not exist "%VCPKG_X64%\lib\opus.lib" goto :missing_vcpkg
echo [OK] Native dependencies are ready: %VCPKG_X64%

echo.
echo [3/6] Preparing Rust Windows import libraries
pushd "%PROJECT_DIR%"
cargo fetch --manifest-path "%MANIFEST%" --locked --target %FETCH_TARGET%
if errorlevel 1 (
  popd
  echo ERROR: Failed to prepare the Rust Windows dependencies.
  exit /b 1
)
popd

set "RUST_WINDOWS_LIBS="
for /d %%R in ("%USERPROFILE%\.cargo\registry\src\*") do (
  for /d %%D in ("%%~fR\windows_x86_64_msvc-*") do (
    if exist "%%~fD\lib" set "RUST_WINDOWS_LIBS=%%~fD\lib;!RUST_WINDOWS_LIBS!"
  )
)
if not defined RUST_WINDOWS_LIBS (
  echo ERROR: Rust Windows import libraries were not found in the Cargo cache.
  exit /b 1
)
set "LIB=!RUST_WINDOWS_LIBS!!LIB!"
echo [OK] Rust Windows import libraries are ready.

echo.
echo [4/6] Building MDeskMini for %TARGET%
set "RUSTC_BOOTSTRAP=1"
set "RUSTFLAGS=-C target-feature=+crt-static -C link-arg=/SUBSYSTEM:WINDOWS,6.01"
set "VCPKG_INSTALLED_ROOT="
pushd "%PROJECT_DIR%"
cargo build -Z build-std=std,panic_abort --manifest-path "%MANIFEST%" --locked --release --target %TARGET%
if errorlevel 1 (
  popd
  echo ERROR: MDeskMini Windows 7 64-bit build failed.
  exit /b 1
)
popd

if not exist "%BUILD_OUTPUT%" (
  echo ERROR: Build finished but the executable was not found:
  echo        %BUILD_OUTPUT%
  exit /b 1
)

echo.
echo [5/6] Verifying Windows 7 executable compatibility
powershell -NoProfile -ExecutionPolicy Bypass -File "%VERIFY_SCRIPT%" -Path "%BUILD_OUTPUT%"
if errorlevel 1 (
  echo ERROR: Windows 7 compatibility verification failed.
  exit /b 1
)

echo.
echo [6/6] Creating the separate Windows 7 distribution file
if not exist "%DIST_DIR%" mkdir "%DIST_DIR%"
copy /y "%BUILD_OUTPUT%" "%DIST_OUTPUT%" >nul
if errorlevel 1 (
  echo ERROR: Failed to create the distribution file.
  exit /b 1
)

echo.
echo ========================================
echo Windows 7 64-bit build complete
echo ========================================
echo EXE: %DIST_OUTPUT%
echo NOTE: This initial verification build is not UPX-compressed.
exit /b 0

:missing_vcpkg
echo ERROR: Required %VCPKG_TRIPLET% headers or libraries are missing.
echo Checked: %VCPKG_X64%
exit /b 1
