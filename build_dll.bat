@echo off
chcp 65001 >nul 2>&1
setlocal

cd /d "%~dp0"
call "%~dp0select_windows_build_features.bat"
if errorlevel 1 exit /b 1
call "%~dp0prepare_windows_native.bat"
if errorlevel 1 exit /b 1
call "%~dp0setup_windows_x64_env.bat"
if errorlevel 1 exit /b 1
set "CARGO_TARGET_DIR=%~dp0target"
if not defined LIBCLANG_PATH if exist "C:\Program Files\LLVM\bin\libclang.dll" set "LIBCLANG_PATH=C:\Program Files\LLVM\bin"

:: VCPKG 경로 설정
if "%VCPKG_ROOT%"=="" set VCPKG_ROOT=D:\IMedix\Rust\vcpkg

echo ==========================================
echo   RustDesk DLL 컴파일 및 자동 복사 도구
echo ==========================================
echo.
echo 1. Release 모드로 컴파일 (최적화됨, 권장)
echo 2. Debug 모드로 컴파일 (디버깅용, 속도 느림)
echo.
set /p choice="빌드 모드를 선택하세요 (1/2): "

set DEBUG_DEST=flutter\build\windows\x64\runner\Debug
set RELEASE_DEST=flutter\build\windows\x64\runner\Release

if "%choice%"=="1" (
    echo.
    echo [Release 모드] 빌드를 시작합니다...
    cargo build --locked --lib --release --features %MDESK_CARGO_FEATURES%
    if errorlevel 1 goto error
    
    echo.
    echo [복사] target\release\librustdesk.dll 파일을 libmdesk.dll 이름으로 플러터 빌드 폴더에 복사합니다...
    if exist "%RELEASE_DEST%" (
        copy /y "target\release\librustdesk.dll" "%RELEASE_DEST%\libmdesk.dll"
        if errorlevel 1 goto error
        powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\verify_windows_dll.ps1" -RustDll "target\release\librustdesk.dll" -PackagedDll "%RELEASE_DEST%\libmdesk.dll" -Variant "%MDESK_BUILD_VARIANT%"
        if errorlevel 1 goto error
        if exist "%RELEASE_DEST%\librustdesk.dll" del /f /q "%RELEASE_DEST%\librustdesk.dll" 2>nul
        echo Release 폴더로 복사 완료.
    ) else (
        echo [알림] Release 빌드 폴더가 없어 복사를 건너뜁니다.
    )
    echo 빌드 및 복사 완료: target\release\librustdesk.dll
) else if "%choice%"=="2" (
    echo.
    echo [Debug 모드] 빌드를 시작합니다...
    cargo build --locked --lib --features %MDESK_CARGO_FEATURES%
    if errorlevel 1 goto error
    
    echo.
    echo [복사] target\debug\librustdesk.dll 파일을 libmdesk.dll 이름으로 플러터 빌드 폴더에 복사합니다...
    if exist "%DEBUG_DEST%" (
        copy /y "target\debug\librustdesk.dll" "%DEBUG_DEST%\libmdesk.dll"
        if errorlevel 1 goto error
        powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\verify_windows_dll.ps1" -RustDll "target\debug\librustdesk.dll" -PackagedDll "%DEBUG_DEST%\libmdesk.dll" -Variant "%MDESK_BUILD_VARIANT%"
        if errorlevel 1 goto error
        if exist "%DEBUG_DEST%\librustdesk.dll" del /f /q "%DEBUG_DEST%\librustdesk.dll" 2>nul
        echo Debug 폴더로 복사 완료.
    ) else (
        echo [알림] Debug 빌드 폴더가 없어 복사를 건너뜁니다.
    )
    echo 빌드 및 복사 완료: target\debug\librustdesk.dll
) else (
    echo 잘못된 선택입니다.
    pause
    exit /b 1
)

echo.
echo ==========================================
echo   컴파일 및 파일 복사가 성공적으로 완료되었습니다.
echo ==========================================
pause
exit /b 0

:error
set "MDESK_BUILD_ERROR=%ERRORLEVEL%"
echo.
echo [ERROR] 컴파일 중 오류가 발생했습니다.
pause
exit /b %MDESK_BUILD_ERROR%
