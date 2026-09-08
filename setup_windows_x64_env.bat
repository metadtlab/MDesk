@echo off
rem Keep the existing desktop entry point and native dependency preflight.
call "%~dp0setup_windows_env.bat" x64
if errorlevel 1 exit /b 1

for %%F in (include\opus\opus_multistream.h lib\opus.lib) do (
    if not exist "%VCPKG_ROOT%\installed\x64-windows-static\%%F" (
        echo [ERROR] Missing "%VCPKG_ROOT%\installed\x64-windows-static\%%F".
        echo Check VCPKG_ROOT and install the x64-windows-static dependencies before building.
        exit /b 1
    )
)
exit /b 0
