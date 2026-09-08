@echo off
setlocal EnableExtensions
for %%I in ("%~dp0..") do set "REPO_DIR=%%~fI"
set "EXPECTED_DIR=%CD%"
set "EXPECTED_VCPKG_ROOT=%VCPKG_ROOT%"

call "%REPO_DIR%\setup_windows_env.bat" invalid >nul 2>&1
if not errorlevel 1 (
    echo [ERROR] Unsupported target architecture was accepted.
    exit /b 1
)

rem Also exercise switching architectures in an already initialized shell.
call :check_arch x64 64
if errorlevel 1 exit /b 1
call :check_arch x86 32
if errorlevel 1 exit /b 1
call :check_arch x64 64
if errorlevel 1 exit /b 1
echo [OK] SDK headers and architecture switching passed.
exit /b 0

:check_arch
call "%REPO_DIR%\setup_windows_env.bat" %1
if errorlevel 1 exit /b 1
if /i not "%CD%"=="%EXPECTED_DIR%" (
    echo [ERROR] Setup changed the working directory.
    exit /b 1
)
if defined EXPECTED_VCPKG_ROOT if /i not "%VCPKG_ROOT%"=="%EXPECTED_VCPKG_ROOT%" (
    echo [ERROR] Setup changed the configured vcpkg root.
    exit /b 1
)
cl /nologo /Zs /DEXPECTED_POINTER_BITS=%2 "%~dp0windows_sdk_headers.c"
if errorlevel 1 exit /b 1
echo [OK] %1 compiler found UCRT and Windows headers; pointer width is %2 bits.
exit /b 0
