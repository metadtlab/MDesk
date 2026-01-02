@echo off
chcp 65001 >nul 2>&1
setlocal

:: VCPKG 경로 설정 (필요시 수정)
if "%VCPKG_ROOT%"=="" set VCPKG_ROOT=D:\IMedix\Rust\vcpkg

echo [1/3] 플러터 빌드 시작...
python build.py --skip-cargo

if %ERRORLEVEL% NEQ 0 (
    echo [ERROR] 플러터 빌드 실패!
    pause
    exit /b %ERRORLEVEL%
)

echo.
echo [2/3] MDesk_portable.exe 생성 완료!
echo [3/3] UPX 압축 실행...
call UpdateSVR.Bat

echo.
echo ==========================================
echo   플러터 빌드 및 패키징이 완료되었습니다.
echo ==========================================
pause






