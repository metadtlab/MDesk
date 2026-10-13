@echo off
rem Propagate the effective native root to the calling build, without global changes.
set "MDESK_NATIVE_ARCH=%~1"
if not defined MDESK_NATIVE_ARCH set "MDESK_NATIVE_ARCH=x64"
set "MDESK_NATIVE_ENV_FILE=%~dp0.deps\native-root-%RANDOM%-%RANDOM%.txt"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\prepare_windows_native.ps1" -RepoRoot "%~dp0." -Variant "%MDESK_BUILD_VARIANT%" -Architecture "%MDESK_NATIVE_ARCH%" -OutEnvFile "%MDESK_NATIVE_ENV_FILE%"
if errorlevel 1 exit /b 1
set /p VCPKG_ROOT=<"%MDESK_NATIVE_ENV_FILE%"
del /q "%MDESK_NATIVE_ENV_FILE%"
set "MDESK_NATIVE_ENV_FILE="
set "VCPKG_INSTALLED_ROOT=%VCPKG_ROOT%\installed"
set "VCPKG_DEFAULT_TRIPLET=%MDESK_NATIVE_ARCH%-windows-static"
set "VCPKG_DEFAULT_HOST_TRIPLET=%MDESK_NATIVE_ARCH%-windows-static"
echo [OK] Effective native dependencies: %VCPKG_ROOT%
exit /b 0
