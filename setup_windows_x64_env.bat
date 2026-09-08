@echo off
rem Called by build scripts. Do not use setlocal: the compiler environment
rem must remain available to the caller and its cargo/bindgen processes.
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
if not exist "%MDESK_VS_ROOT%\VC\Auxiliary\Build\vcvars64.bat" (
    echo [ERROR] vcvars64.bat was not found in "%MDESK_VS_ROOT%".
    exit /b 1
)

call "%MDESK_VS_ROOT%\VC\Auxiliary\Build\vcvars64.bat" >nul
if errorlevel 1 (
    echo [ERROR] Failed to initialize the Visual Studio x64 environment.
    exit /b 1
)
if not exist "%VCToolsInstallDir%include\vcruntime.h" (
    echo [ERROR] MSVC C runtime headers were not found.
    exit /b 1
)
if not exist "%UniversalCRTSdkDir%Include\%UCRTVersion%\ucrt\stdlib.h" (
    echo [ERROR] Windows SDK UCRT header stdlib.h was not found.
    echo Install or repair the Windows SDK in Visual Studio Installer.
    exit /b 1
)
echo [OK] MSVC x64 and Windows SDK %UCRTVersion% initialized.
set "MDESK_VSWHERE="
set "MDESK_VS_ROOT="
exit /b 0
