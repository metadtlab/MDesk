@echo off
chcp 65001 > nul
setlocal

echo ============================================
echo   MDesk 웹 클라이언트 실행 (개발 모드)
echo ============================================
echo.
echo Chrome 브라우저에서 실행됩니다...
echo 종료하려면 Ctrl+C를 누르세요.
echo.

cd /d "%~dp0flutter"

echo [1/4] Flutter 환경 확인 중...
call flutter --version
if errorlevel 1 (
    echo [오류] Flutter가 설치되어 있지 않습니다.
    goto :error
)
echo.

echo [2/4] 웹 지원 활성화 확인...
call flutter config --enable-web
if errorlevel 1 (
    echo [오류] 웹 지원 활성화 실패
    goto :error
)
echo.

echo [3/4] 의존성 설치 중...
call flutter pub get
if errorlevel 1 (
    echo [오류] 의존성 설치 실패
    goto :error
)
echo.

echo [4/4] Chrome에서 웹 앱 실행 중...
call flutter run -d chrome -t lib/main_web.dart
if errorlevel 1 (
    echo [오류] 웹 실행 실패
    goto :error
)

goto :end

:error
cd /d "%~dp0"
echo.
pause

:end
cd /d "%~dp0"


