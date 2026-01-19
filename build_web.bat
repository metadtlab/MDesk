@echo off
chcp 65001 > nul
setlocal enabledelayedexpansion

echo ============================================
echo   MDesk 웹 클라이언트 빌드
echo ============================================
echo.

REM Flutter 디렉토리로 이동
cd /d "%~dp0flutter"

echo [1/4] Flutter 환경 확인 중...
flutter --version
if errorlevel 1 (
    echo [오류] Flutter가 설치되어 있지 않습니다.
    goto :error
)
echo.

echo [2/4] 웹 지원 활성화 확인...
flutter config --enable-web
echo.

echo [3/4] 의존성 설치 중...
flutter pub get
if errorlevel 1 (
    echo [오류] 의존성 설치 실패
    goto :error
)
echo.

echo [4/4] 웹 빌드 중... (시간이 걸릴 수 있습니다)
echo.
flutter build web --release
if errorlevel 1 (
    echo [오류] 웹 빌드 실패
    goto :error
)

echo.
echo ============================================
echo   빌드 완료!
echo ============================================
echo.
echo 빌드 결과 위치:
echo   %~dp0flutter\build\web\
echo.
echo 배포 방법:
echo   1. 위 폴더의 내용을 웹서버에 업로드
echo   2. Nginx, Apache 등으로 서빙
echo   3. HTTPS 설정 권장
echo.
echo 로컬 테스트:
echo   cd flutter
echo   flutter run -d chrome
echo ============================================
goto :end

:error
echo.
echo [빌드 실패] 오류를 확인하세요.
cd /d "%~dp0"

:end
cd /d "%~dp0"
echo.
pause


