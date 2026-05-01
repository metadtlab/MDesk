@echo off
setlocal

set "PROJECT_DIR=%~dp0"
set "TARGET_EXE=%PROJECT_DIR%target\release\mdeskmini.exe"

where upx >nul 2>nul
if errorlevel 1 (
  echo ERROR: UPX was not found in PATH.
  echo Install UPX or add upx.exe to PATH, then run this again.
  exit /b 1
)

if not exist "%TARGET_EXE%" (
  echo ERROR: Release executable not found: "%TARGET_EXE%"
  echo Run build_release.bat first.
  exit /b 1
)

echo Compressing with UPX maximum settings...
echo EXE: %TARGET_EXE%

upx --best --lzma "%TARGET_EXE%"
if errorlevel 1 (
  echo ERROR: UPX compression failed.
  echo If the file is already packed, rebuild with build_release.bat and run this again.
  exit /b 1
)

echo.
echo UPX compression complete.
echo EXE: %TARGET_EXE%
exit /b 0
