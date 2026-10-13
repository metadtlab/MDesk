@echo off
rem Called without setlocal so the selected features remain in the caller.
rem MDESK_BUILD_VARIANT=B3 (default), B2 (hwcodec), B1 (software baseline).
if not defined MDESK_BUILD_VARIANT set "MDESK_BUILD_VARIANT=B3"
set "MDESK_CARGO_FEATURES="
set "MDESK_PYTHON_FEATURE_ARGS="
if /i "%MDESK_BUILD_VARIANT%"=="B1" set "MDESK_CARGO_FEATURES=flutter"
if /i "%MDESK_BUILD_VARIANT%"=="B2" (
    set "MDESK_CARGO_FEATURES=flutter,hwcodec"
    set "MDESK_PYTHON_FEATURE_ARGS=--hwcodec"
)
if /i "%MDESK_BUILD_VARIANT%"=="B3" (
    set "MDESK_CARGO_FEATURES=flutter,hwcodec,vram"
    set "MDESK_PYTHON_FEATURE_ARGS=--hwcodec --vram"
)
if not defined MDESK_CARGO_FEATURES (
    echo [ERROR] MDESK_BUILD_VARIANT must be B1, B2 or B3.
    exit /b 1
)
echo [OK] Variant=%MDESK_BUILD_VARIANT% Features=%MDESK_CARGO_FEATURES%
exit /b 0
