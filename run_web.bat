@echo off
chcp 65001 > nul

echo ============================================
echo   MDesk 웹 클라이언트 실행 (개발 모드)
echo ============================================
echo.
echo Chrome 브라우저에서 실행됩니다...
echo 종료하려면 Ctrl+C를 누르세요.
echo.

cd /d "%~dp0flutter"

flutter run -d chrome

cd /d "%~dp0"
pause


