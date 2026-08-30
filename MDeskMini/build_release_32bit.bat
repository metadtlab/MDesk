@echo off
setlocal EnableExtensions

set "PROJECT_DIR=%~dp0"
for %%I in ("%PROJECT_DIR%..") do set "REPO_DIR=%%~fI"
set "MANIFEST=%PROJECT_DIR%Cargo.toml"
set "TARGET=i686-pc-windows-msvc"
set "VCPKG_TRIPLET=x86-windows-static"
set "CARGO_TARGET_DIR=%PROJECT_DIR%target"
set "OUTPUT=%CARGO_TARGET_DIR%\%TARGET%\release\mdeskmini.exe"
set "ADMIN_VERIFY_SCRIPT=%PROJECT_DIR%verify_admin_manifest.ps1"

echo ========================================
echo MDeskMini 32-bit Windows release build
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

echo [1/5] Checking Rust target: %TARGET%
rustup target list --installed | findstr /c:"%TARGET%" >nul
if errorlevel 1 (
  echo Installing Rust target: %TARGET%
  rustup target add %TARGET%
  if errorlevel 1 (
    echo ERROR: Failed to install Rust target %TARGET%.
    exit /b 1
  )
)
echo [OK] Rust target is ready.

echo.
echo [2/5] Checking 32-bit native dependencies
if not defined VCPKG_ROOT (
  echo ERROR: VCPKG_ROOT is not set.
  echo Example: set VCPKG_ROOT=D:\path\to\vcpkg
  exit /b 1
)
set "VCPKG_EXE=%VCPKG_ROOT%\vcpkg.exe"
set "VCPKG_X86=%VCPKG_ROOT%\installed\%VCPKG_TRIPLET%"
if not exist "%VCPKG_EXE%" (
  echo ERROR: vcpkg.exe not found: "%VCPKG_EXE%"
  exit /b 1
)

set "NEED_VCPKG_INSTALL=0"
set "NEED_LIBVPX_INSTALL=0"
if not exist "%VCPKG_X86%\include\vpx\vp8.h" set "NEED_LIBVPX_INSTALL=1"
if not exist "%VCPKG_X86%\lib\vpx.lib" set "NEED_LIBVPX_INSTALL=1"
if "%NEED_LIBVPX_INSTALL%"=="1" set "NEED_VCPKG_INSTALL=1"
if not exist "%VCPKG_X86%\include\libyuv.h" set "NEED_VCPKG_INSTALL=1"
if not exist "%VCPKG_X86%\include\aom\aom_codec.h" set "NEED_VCPKG_INSTALL=1"
if not exist "%VCPKG_X86%\include\opus\opus_multistream.h" set "NEED_VCPKG_INSTALL=1"
if not exist "%VCPKG_X86%\lib\yuv.lib" set "NEED_VCPKG_INSTALL=1"
if not exist "%VCPKG_X86%\lib\aom.lib" set "NEED_VCPKG_INSTALL=1"
if not exist "%VCPKG_X86%\lib\opus.lib" set "NEED_VCPKG_INSTALL=1"

if "%NEED_VCPKG_INSTALL%"=="1" (
  echo Installing libvpx, libyuv, aom and opus for %VCPKG_TRIPLET%...
  rem The repository libvpx overlay does not install Windows headers/libraries,
  rem so use the maintained vcpkg registry port for libvpx on Windows.
  if "%NEED_LIBVPX_INSTALL%"=="1" (
    "%VCPKG_EXE%" remove libvpx:%VCPKG_TRIPLET% --classic
    if errorlevel 1 (
      echo ERROR: Failed to remove the incomplete libvpx:%VCPKG_TRIPLET% package.
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

if not exist "%VCPKG_X86%\include\vpx\vp8.h" goto :missing_vcpkg
if not exist "%VCPKG_X86%\include\libyuv.h" goto :missing_vcpkg
if not exist "%VCPKG_X86%\include\aom\aom_codec.h" goto :missing_vcpkg
if not exist "%VCPKG_X86%\include\opus\opus_multistream.h" goto :missing_vcpkg
if not exist "%VCPKG_X86%\lib\vpx.lib" goto :missing_vcpkg
if not exist "%VCPKG_X86%\lib\yuv.lib" goto :missing_vcpkg
if not exist "%VCPKG_X86%\lib\aom.lib" goto :missing_vcpkg
if not exist "%VCPKG_X86%\lib\opus.lib" goto :missing_vcpkg
echo [OK] Native dependencies are ready: %VCPKG_X86%

echo.
echo [3/5] Building MDeskMini for %TARGET%
rem scrap and magnum-opus must use the same VCPKG_ROOT\installed directory.
set "VCPKG_INSTALLED_ROOT="
pushd "%PROJECT_DIR%"
cargo build --manifest-path "%MANIFEST%" --release --target %TARGET%
if errorlevel 1 (
  popd
  echo ERROR: MDeskMini 32-bit release build failed.
  exit /b 1
)
popd

echo.
echo [4/5] Verifying output
if not exist "%OUTPUT%" (
  echo ERROR: Build finished but the executable was not found:
  echo        %OUTPUT%
  exit /b 1
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%ADMIN_VERIFY_SCRIPT%" -Path "%OUTPUT%"
if errorlevel 1 (
  echo ERROR: Administrator manifest verification failed.
  exit /b 1
)

echo.
echo [5/5] Compressing 32-bit executable with UPX
call "%PROJECT_DIR%upx_max_32bit.bat"
if errorlevel 1 (
  echo ERROR: MDeskMini was built, but UPX compression failed.
  exit /b 1
)

echo.
echo ========================================
echo 32-bit build complete
echo ========================================
echo EXE: %OUTPUT%
exit /b 0

:missing_vcpkg
echo ERROR: Required %VCPKG_TRIPLET% headers or libraries are still missing.
echo Checked: %VCPKG_X86%
exit /b 1
