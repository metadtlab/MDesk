@echo off
chcp 65001 >nul 2>&1
setlocal

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
    cargo build --lib --release --features flutter
    if %ERRORLEVEL% NEQ 0 goto error
    
    echo.
    echo [복사] target\release\librustdesk.dll 파일을 플러터 빌드 폴더로 복사합니다...
    if exist "%RELEASE_DEST%" (
        copy /y "target\release\librustdesk.dll" "%RELEASE_DEST%\librustdesk.dll"
        echo Release 폴더로 복사 완료.
    ) else (
        echo [알림] Release 빌드 폴더가 없어 복사를 건너뜁니다.
    )
    echo 빌드 및 복사 완료: target\release\librustdesk.dll
) else if "%choice%"=="2" (
    echo.
    echo [Debug 모드] 빌드를 시작합니다...
    cargo build --lib --features flutter
    if %ERRORLEVEL% NEQ 0 goto error
    
    echo.
    echo [복사] target\debug\librustdesk.dll 파일을 플러터 빌드 폴더로 복사합니다...
    if exist "%DEBUG_DEST%" (
        copy /y "target\debug\librustdesk.dll" "%DEBUG_DEST%\librustdesk.dll"
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
echo.
echo [ERROR] 컴파일 중 오류가 발생했습니다.
pause
exit /b %ERRORLEVEL%
