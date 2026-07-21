@echo off
setlocal EnableExtensions

set "PROJECT_DIR=%~dp0"
set "TARGET_EXE=%PROJECT_DIR%target\i686-pc-windows-msvc\release\mdeskmini.exe"

where upx >nul 2>nul
if errorlevel 1 (
  echo ERROR: UPX was not found in PATH.
  echo Install UPX or add upx.exe to PATH, then run this again.
  exit /b 1
)

if not exist "%TARGET_EXE%" (
  echo ERROR: 32-bit release executable not found: "%TARGET_EXE%"
  echo Run build_release_32bit.bat first.
  exit /b 1
)

echo Compressing 32-bit MDeskMini with UPX maximum settings...
echo EXE: %TARGET_EXE%

upx -t "%TARGET_EXE%" >nul 2>nul
if not errorlevel 1 (
  echo [OK] The executable is already UPX-compressed and passed the integrity test.
  exit /b 0
)

upx --best --lzma "%TARGET_EXE%"
if errorlevel 1 (
  echo ERROR: UPX compression failed.
  exit /b 1
)

upx -t "%TARGET_EXE%"
if errorlevel 1 (
  echo ERROR: UPX integrity verification failed.
  exit /b 1
)

echo.
echo 32-bit UPX compression complete.
echo EXE: %TARGET_EXE%
echo NOTE: Code signing must be performed after UPX compression.
exit /b 0
