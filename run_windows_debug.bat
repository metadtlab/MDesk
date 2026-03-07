@echo off
chcp 65001 > nul

echo ============================================
echo   RustDesk 윈도우 모드 디버깅 실행
echo ============================================
echo.
echo Windows 데스크톱 앱이 디버그 모드로 실행됩니다...
echo 종료하려면 Ctrl+C를 누르거나 앱을 닫으세요.
echo.
echo 디버깅 정보는 이 콘솔 창에 표시됩니다.
echo.

cd /d "%~dp0flutter"

flutter run -d windows

cd /d "%~dp0"
pause
