@echo off
setlocal EnableExtensions

set "PROJECT_DIR=%~dp0"
set "SOURCE_EXE=%PROJECT_DIR%target\win7-x64\MDeskMini-Win7-x64.exe"
set "TARGET_EXE=%PROJECT_DIR%target\win7-x64\MDeskMini-Win7-x64-UPX.exe"
set "NEW_EXE=%PROJECT_DIR%target\win7-x64\MDeskMini-Win7-x64-UPX-new.exe"
set "ADMIN_VERIFY_SCRIPT=%PROJECT_DIR%verify_admin_manifest.ps1"

where upx >nul 2>nul
if errorlevel 1 (
  echo ERROR: UPX was not found in PATH.
  echo Install UPX or add upx.exe to PATH, then run this again.
  exit /b 1
)

if not exist "%SOURCE_EXE%" (
  echo ERROR: Windows 7 64-bit executable not found:
  echo        %SOURCE_EXE%
  echo Run build_release_win7_64bit.bat first.
  exit /b 1
)

echo Creating a separate UPX-compressed Windows 7 working file...
if exist "%NEW_EXE%" del /q "%NEW_EXE%" >nul 2>nul
if exist "%NEW_EXE%" (
  set "NEW_EXE=%PROJECT_DIR%target\win7-x64\MDeskMini-Win7-x64-UPX-%RANDOM%.exe"
)

copy /y "%SOURCE_EXE%" "%NEW_EXE%" >nul
if errorlevel 1 (
  echo ERROR: Failed to create the UPX working copy.
  exit /b 1
)

upx --best --lzma "%NEW_EXE%"
if errorlevel 1 (
  echo ERROR: UPX compression failed.
  exit /b 1
)

upx -t "%NEW_EXE%"
if errorlevel 1 (
  echo ERROR: UPX integrity verification failed.
  exit /b 1
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%ADMIN_VERIFY_SCRIPT%" -Path "%NEW_EXE%"
if errorlevel 1 (
  echo ERROR: UPX output is missing the administrator manifest.
  exit /b 1
)

copy /y "%NEW_EXE%" "%TARGET_EXE%" >nul 2>nul
if errorlevel 1 (
  echo.
  echo WARNING: The old UPX file is still open and could not be replaced.
  echo A verified new UPX file was kept at:
  echo EXE: %NEW_EXE%
  echo Close any running copy, Explorer preview, or antivirus scan and rename it later.
  exit /b 0
)

del /q "%NEW_EXE%" >nul 2>nul

echo.
echo Windows 7 64-bit UPX compression complete.
echo EXE: %TARGET_EXE%
echo NOTE: Test this packed file on a real Windows 7 SP1 machine before release.
echo NOTE: Code signing must be performed after UPX compression.
exit /b 0
