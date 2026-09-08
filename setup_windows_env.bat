@echo off
rem Called by build scripts. Do not use setlocal: the compiler environment
rem must remain available to the caller and its cargo/bindgen processes.
set "MDESK_VCVARS_ARCH="
if /i "%~1"=="x64" set "MDESK_VCVARS_ARCH=amd64"
if /i "%~1"=="x86" set "MDESK_VCVARS_ARCH=amd64_x86"
if not defined MDESK_VCVARS_ARCH (
    echo [ERROR] Usage: call setup_windows_env.bat x64 or x86
    exit /b 1
)
set "MDESK_VSWHERE=%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe"
if not exist "%MDESK_VSWHERE%" set "MDESK_VSWHERE=%ProgramFiles%\Microsoft Visual Studio\Installer\vswhere.exe"
if not exist "%MDESK_VSWHERE%" (
    echo [ERROR] Visual Studio Installer was not found.
    echo Install Visual Studio C++ Build Tools and a Windows SDK.
    exit /b 1
)

set "MDESK_VS_ROOT="
for /f "usebackq delims=" %%I in (`"%MDESK_VSWHERE%" -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath`) do set "MDESK_VS_ROOT=%%I"
if not defined MDESK_VS_ROOT (
    echo [ERROR] Visual Studio C++ x64/x86 build tools were not found.
    echo Add Desktop development with C++ and a Windows SDK in Visual Studio Installer.
    exit /b 1
)
if not exist "%MDESK_VS_ROOT%\VC\Auxiliary\Build\vcvarsall.bat" (
    echo [ERROR] vcvarsall.bat was not found in "%MDESK_VS_ROOT%".
    exit /b 1
)

rem Recent Visual Studio versions overwrite VCPKG_ROOT with their bundled copy.
set "MDESK_SAVED_VCPKG_ROOT=%VCPKG_ROOT%"
pushd "%CD%"
rem Reset a developer shell before reinitializing to avoid accumulating PATH/LIB.
if defined VSCMD_VER (
    call "%MDESK_VS_ROOT%\VC\Auxiliary\Build\vcvarsall.bat" /clean_env >nul
    if errorlevel 1 (
        popd
        set "VCPKG_ROOT=%MDESK_SAVED_VCPKG_ROOT%"
        set "MDESK_SAVED_VCPKG_ROOT="
        echo [ERROR] Failed to reset the previous Visual Studio environment.
        exit /b 1
    )
)
call "%MDESK_VS_ROOT%\VC\Auxiliary\Build\vcvarsall.bat" %MDESK_VCVARS_ARCH% >nul
if errorlevel 1 (
    popd
    set "VCPKG_ROOT=%MDESK_SAVED_VCPKG_ROOT%"
    set "MDESK_SAVED_VCPKG_ROOT="
    echo [ERROR] Failed to initialize the Visual Studio %~1 environment.
    exit /b 1
)
popd
set "VCPKG_ROOT=%MDESK_SAVED_VCPKG_ROOT%"
set "MDESK_SAVED_VCPKG_ROOT="
if /i not "%VSCMD_ARG_TGT_ARCH%"=="%~1" (
    echo [ERROR] Visual Studio initialized the wrong target architecture: %VSCMD_ARG_TGT_ARCH%.
    exit /b 1
)
if not exist "%VCToolsInstallDir%include\vcruntime.h" (
    echo [ERROR] MSVC C runtime headers were not found.
    exit /b 1
)
for %%F in (stdlib.h inttypes.h) do (
    if not exist "%UniversalCRTSdkDir%Include\%UCRTVersion%\ucrt\%%F" (
        echo [ERROR] Windows SDK UCRT header %%F was not found.
        echo Install or repair the Windows SDK in Visual Studio Installer.
        exit /b 1
    )
)
rem Use the sibling checkout only when the caller did not configure a root.
if not defined VCPKG_ROOT if exist "%~dp0..\vcpkg\vcpkg.exe" (
    for %%I in ("%~dp0..\vcpkg") do set "VCPKG_ROOT=%%~fI"
)
if not defined VCPKG_ROOT (
    echo [ERROR] VCPKG_ROOT is not set. Set it to the vcpkg checkout containing MDesk dependencies.
    exit /b 1
)
if not exist "%VCPKG_ROOT%\vcpkg.exe" (
    echo [ERROR] vcpkg.exe not found in "%VCPKG_ROOT%".
    exit /b 1
)
echo [OK] MSVC %~1 and Windows SDK %UCRTVersion% initialized.
echo [OK] VCPKG_ROOT: %VCPKG_ROOT%
set "MDESK_VSWHERE="
set "MDESK_VS_ROOT="
set "MDESK_VCVARS_ARCH="
exit /b 0
