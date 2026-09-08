@echo off
setlocal enabledelayedexpansion
REM MDesk Windows Build Script
REM --rust-only builds the DLL without cleaning caches, Flutter, or packaging.

cd /d "%~dp0"
call "%~dp0setup_windows_x64_env.bat"
if errorlevel 1 exit /b 1

echo ========================================
echo MDesk Windows Build Script
echo ========================================
echo.

REM Check submodules
if not exist "libs\hbb_common\Cargo.toml" (
    echo [WARN] Submodules not initialized. Initializing...
    git submodule update --init --recursive
    if errorlevel 1 (
        echo [ERROR] Submodule init failed.
        pause
        exit /b 1
    )
)

REM Check VCPKG
if "%VCPKG_ROOT%"=="" (
    echo [ERROR] VCPKG_ROOT not set!
    echo Run: set VCPKG_ROOT=D:\IMedix\Rust\vcpkg
    pause
    exit /b 1
)
if not exist "%VCPKG_ROOT%\vcpkg.exe" (
    echo [ERROR] vcpkg.exe not found at %VCPKG_ROOT%
    pause
    exit /b 1
)
echo [OK] VCPKG_ROOT: %VCPKG_ROOT%

REM Get version (first version = line only)
for /f "tokens=2 delims==" %%a in ('findstr /B /C:"version" Cargo.toml') do (
    if not defined VERSION (
        set VERSION=%%a
        set VERSION=!VERSION:"=!
        set VERSION=!VERSION: =!
    )
)
echo [OK] Version: %VERSION%
echo.

REM Check clean build option
if /i "%~1"=="--rust-only" goto BUILD_RUST
set CLEAN_BUILD=0
if "%1"=="--clean" set CLEAN_BUILD=1
if "%1"=="-c" set CLEAN_BUILD=1

if %CLEAN_BUILD%==1 (
    echo [INFO] Clean build mode enabled
    echo.
    
    echo [1/5] Cleaning Rust cache...
    if exist "target\release" rd /s /q "target\release" 2>nul
    echo [OK] Rust cache cleaned
    
    echo [2/5] Cleaning Flutter cache...
    if exist "flutter\build\windows" rd /s /q "flutter\build\windows" 2>nul
    cd flutter
    call flutter clean
    call flutter pub get
    cd ..
    echo [OK] Flutter cache cleaned
) else (
    echo [INFO] Incremental build. Use --clean for clean build
    echo.
    
    echo [1/5] Preparing Rust DLL...
    if exist "target\release\librustdesk.dll" del /f /q "target\release\librustdesk.dll" 2>nul
    
    echo [2/5] Checking Flutter cache...
    if exist "flutter\build\windows" rd /s /q "flutter\build\windows" 2>nul
)

echo.
:BUILD_RUST
echo [3/5] Building Rust DLL...
cargo build --features flutter --lib --release
if errorlevel 1 (
    echo [ERROR] Rust build failed!
    pause
    exit /b 1
)
if not exist "target\release\librustdesk.dll" (
    echo [ERROR] Rust DLL source target\release\librustdesk.dll not created!
    pause
    exit /b 1
)
echo [OK] Rust DLL built successfully
if /i "%~1"=="--rust-only" exit /b 0

echo.
echo [4/5] Building Flutter...
cd flutter
call flutter build windows --release
if errorlevel 1 (
    cd ..
    echo [ERROR] Flutter build failed!
    pause
    exit /b 1
)
cd ..

set BUILD_DIR=flutter\build\windows\x64\runner\Release
if not exist "%BUILD_DIR%\MDesk.exe" (
    echo [ERROR] MDesk.exe not found at %BUILD_DIR%
    pause
    exit /b 1
)
echo [OK] Flutter built successfully

REM Copy DLLs
echo [COPY] Copying DLLs...
copy /y "target\release\librustdesk.dll" "%BUILD_DIR%\libmdesk.dll" >nul
if exist "%BUILD_DIR%\librustdesk.dll" del /f /q "%BUILD_DIR%\librustdesk.dll" 2>nul
if exist "target\release\deps\dylib_virtual_display.dll" (
    copy /y "target\release\deps\dylib_virtual_display.dll" "%BUILD_DIR%\" >nul
)
echo [OK] DLLs copied

echo.
echo ========================================
echo   Please code sign MDesk.exe
echo ========================================
echo   %BUILD_DIR%\MDesk.exe
echo.
echo   Copy to USB, sign on another PC, then overwrite
echo   the file above. Press any key to continue build.
echo ========================================
pause

echo.
echo [5/5] Creating portable package...
if exist "%BUILD_DIR%\is_portable" del /f /q "%BUILD_DIR%\is_portable" 2>nul

cd libs\portable
pip install -r requirements.txt >nul 2>&1
python ./generate.py -f "../../%BUILD_DIR%" -o . -e "../../%BUILD_DIR%/MDesk.exe"
if errorlevel 1 (
    cd ..\..
    echo [WARN] Portable packaging failed
    goto SKIP_PORTABLE
)
cd ..\..

if exist "target\release\rustdesk-portable-packer.exe" (
    move /y "target\release\rustdesk-portable-packer.exe" "MDesk_portable.exe" >nul
    
    set BUILD_NUM=1
    if exist "build_number.txt" set /p BUILD_NUM=<build_number.txt
    set /a BUILD_NUM=BUILD_NUM+1
    echo !BUILD_NUM!>build_number.txt
    
    set FULL_VERSION=%VERSION%.!BUILD_NUM!
    copy /y "MDesk_portable.exe" "MDesk-!FULL_VERSION!-install.exe" >nul
    echo [OK] Portable created: MDesk-!FULL_VERSION!-install.exe
)

:SKIP_PORTABLE
echo.
echo ========================================
echo BUILD COMPLETE!
echo ========================================
echo.
echo Output:
echo   - DLL: %BUILD_DIR%\libmdesk.dll
echo   - EXE: %BUILD_DIR%\MDesk.exe
if exist "MDesk_portable.exe" echo   - Portable: MDesk_portable.exe
for %%f in (MDesk-*-install.exe) do echo   - Installer: %%f
echo.
echo Test: %BUILD_DIR%\MDesk.exe
echo.
pause
