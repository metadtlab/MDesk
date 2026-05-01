@echo off
REM Use ASCII-only messages: UTF-8 Korean breaks cmd.exe line parsing on some systems.
chcp 65001 >nul 2>&1
setlocal
cd /d "%~dp0"

if /i "%~1"=="release" goto RELEASE
if /i "%~1"=="run" goto DEV
if "%~1"=="" goto DEV

echo.
echo Usage:
echo   %~nx0              Debug run ^(Hot Reload: press r in console after UI edits^)
echo   %~nx0 run          Same as above
echo   %~nx0 release      Flutter release only ^(skip Rust librustdesk rebuild^)
echo.
echo For full installer/signing/portable, use build_windows.bat
echo.
pause
exit /b 1

:DEV
echo ============================================
echo   Flutter quick preview ^(debug + Hot Reload^)
echo   Stop: Ctrl+C or close app
echo ============================================
echo.
cd flutter
flutter run -d windows
set ERR=%ERRORLEVEL%
cd ..
exit /b %ERR%

:RELEASE
REM Use forward slashes: backslash in "target\release\..." can break if parsed wrong
if not exist "target/release/librustdesk.dll" (
    echo [ERROR] target\release\librustdesk.dll not found.
    echo         Run build_windows.bat once for a full build, then use this script.
    pause
    exit /b 1
)
echo ============================================
echo   Flutter release only ^(skip main Rust DLL rebuild^)
echo ============================================
echo.
python build.py --flutter --skip-cargo --skip-portable-pack
set ERR=%ERRORLEVEL%
if not "%ERR%"=="0" pause
exit /b %ERR%
