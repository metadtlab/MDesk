@echo off
REM RustDesk Windows 빌드 및 배포 스크립트 (코드 서명 포함)
REM 단계 5: 컴파일 및 배포 패키징 (EV Code Signing 인증서 사용)

REM 한글 인코딩 설정 (UTF-8)
chcp 65001 >nul 2>&1

setlocal enabledelayedexpansion

echo ========================================
echo RustDesk Windows 빌드 및 배포 스크립트
echo (코드 서명 포함)
echo ========================================
echo.

REM 인증서 정보 확인
if not defined CERT_PASSWORD (
    echo [오류] 인증서 패스워드가 설정되지 않았습니다.
    echo.
    echo 사용법:
    echo   set CERT_PASSWORD=인증서_패스워드
    echo   set CERT_FILE=cert.pfx  (선택적, 기본값: cert.pfx)
    echo   build_windows_signed.bat
    echo.
    echo 예시:
    echo   set CERT_PASSWORD=your_password
    echo   set CERT_FILE=C:\path\to\your\cert.pfx
    echo   build_windows_signed.bat
    echo.
    pause
    exit /b 1
)

if not defined CERT_FILE (
    set CERT_FILE=cert.pfx
)

if not exist "%CERT_FILE%" (
    echo [오류] 인증서 파일을 찾을 수 없습니다: %CERT_FILE%
    echo.
    pause
    exit /b 1
)

echo 인증서 파일: %CERT_FILE%
echo.

REM 사전 체크: 서브모듈 초기화 확인
echo [사전 체크] 서브모듈 확인 중...
if not exist "libs\hbb_common\Cargo.toml" (
    echo [경고] 서브모듈이 초기화되지 않았습니다.
    echo 서브모듈을 초기화합니다...
    echo.
    git submodule update --init --recursive
    if errorlevel 1 (
        echo.
        echo [오류] 서브모듈 초기화 실패!
        echo 수동으로 다음 명령을 실행하세요:
        echo   git submodule update --init --recursive
        echo.
        pause
        exit /b 1
    )
    echo.
    echo [완료] 서브모듈 초기화 완료!
    echo.
) else (
    echo [완료] 서브모듈이 이미 초기화되어 있습니다.
    echo.
)

REM 사전 체크: VCPKG 환경변수 확인
echo [사전 체크] VCPKG 확인 중...
if "%VCPKG_ROOT%"=="" goto NO_VCPKG
if not exist "%VCPKG_ROOT%\vcpkg.exe" goto VCPKG_NOT_FOUND

echo [완료] VCPKG_ROOT: %VCPKG_ROOT%
echo [완료] vcpkg.exe 확인됨
echo.
goto VCPKG_OK

:NO_VCPKG
echo [오류] VCPKG_ROOT 환경변수가 설정되지 않았습니다!
echo.
echo VCPKG는 RustDesk 빌드에 필수입니다.
echo.
echo VCPKG 설치 및 설정 방법:
echo   1. vcpkg 클론 및 빌드:
echo      git clone https://github.com/microsoft/vcpkg
echo      cd vcpkg
echo      .\bootstrap-vcpkg.bat
echo.
echo   2. 환경변수 설정 (현재 세션용):
echo      set VCPKG_ROOT=C:\path\to\vcpkg
echo.
echo   3. 환경변수 설정 (영구적):
echo      setx VCPKG_ROOT "C:\path\to\vcpkg"
echo      주의: setx 후 새 명령 프롬프트 창을 열어야 합니다.
echo.
echo   4. 필요한 패키지 설치:
echo      vcpkg install libvpx:x64-windows-static libyuv:x64-windows-static opus:x64-windows-static aom:x64-windows-static
echo.
echo   5. 또는 vcpkg.json 사용 (자동 설치):
echo      vcpkg install --x-manifest-root=. --x-install-root=[VCPKG_ROOT]\installed
echo.
pause
exit /b 1

:VCPKG_NOT_FOUND
echo [경고] VCPKG_ROOT 경로에 vcpkg.exe를 찾을 수 없습니다: %VCPKG_ROOT%
echo vcpkg가 제대로 설치되었는지 확인하세요.
echo.
pause
exit /b 1

:VCPKG_OK
REM 버전 정보 확인 (첫 번째 version = 라인만 사용)
for /f "tokens=2 delims==" %%a in ('findstr /B /C:"version" Cargo.toml') do (
    if not defined VERSION (
        set VERSION=%%a
        set VERSION=!VERSION:"=!
        set VERSION=!VERSION: =!
    )
)
echo 현재 버전: %VERSION%
echo.

REM 1단계: 전체 빌드 실행
echo [1/3] 전체 빌드 실행 중...
echo 명령: python build.py --flutter
echo VCPKG_ROOT: %VCPKG_ROOT%
echo.
python build.py --flutter
if errorlevel 1 (
    echo.
    echo [오류] 빌드 실패!
    echo.
    echo 일반적인 빌드 오류 해결 방법:
    echo   1. VCPKG_ROOT 환경변수 확인:
    echo      echo [VCPKG_ROOT]
    echo.
    echo   2. 필요한 패키지가 설치되었는지 확인:
    echo      vcpkg list
    echo.
    echo   3. 패키지 재설치:
    echo      vcpkg install libvpx:x64-windows-static libyuv:x64-windows-static opus:x64-windows-static aom:x64-windows-static
    echo.
    echo   4. 또는 vcpkg.json으로 자동 설치:
    echo      vcpkg install --x-manifest-root=. --x-install-root=[VCPKG_ROOT]\installed
    echo      (VCPKG_ROOT 환경변수를 실제 경로로 교체하세요)
    echo.
    pause
    exit /b 1
)
echo.
echo [완료] 빌드 성공!
echo.

REM 빌드된 파일 확인
set BUILD_DIR=flutter\build\windows\x64\runner\Release
if not exist "%BUILD_DIR%\rustdesk.exe" (
    echo [오류] 빌드된 실행 파일을 찾을 수 없습니다: %BUILD_DIR%\rustdesk.exe
    pause
    exit /b 1
)

REM 2단계: 디지털 서명
echo [2/3] 디지털 서명 실행 중...
echo.

REM rustdesk.exe 서명
echo rustdesk.exe 서명 중...
signtool sign /a /v /p %CERT_PASSWORD% /f %CERT_FILE% /t http://timestamp.digicert.com "%BUILD_DIR%\rustdesk.exe"
if errorlevel 1 (
    echo [오류] rustdesk.exe 서명 실패!
    pause
    exit /b 1
)
echo [완료] rustdesk.exe 서명 성공
echo.

REM 설치 파일 서명 (생성된 경우)
set INSTALL_FILE=rustdesk-%VERSION%-install.exe
if exist "%INSTALL_FILE%" (
    echo 설치 파일 서명 중...
    signtool sign /a /v /p %CERT_PASSWORD% /f %CERT_FILE% /t http://timestamp.digicert.com "%INSTALL_FILE%"
    if errorlevel 1 (
        echo [오류] 설치 파일 서명 실패!
        pause
        exit /b 1
    )
    echo [완료] 설치 파일 서명 성공
    echo.
) else (
    echo [정보] 설치 파일이 아직 생성되지 않았습니다.
    echo 빌드 프로세스에서 자동으로 생성됩니다.
    echo.
)

REM 서명 검증
echo 서명 검증 중...
signtool verify /pa /v "%BUILD_DIR%\rustdesk.exe"
if errorlevel 1 (
    echo [경고] 서명 검증 실패
) else (
    echo [완료] 서명 검증 성공
)
echo.

REM 3단계: 배포 파일 확인
echo [3/3] 배포 파일 확인 중...
echo.

if exist "%INSTALL_FILE%" (
    echo [완료] 설치 프로그램 생성됨: %INSTALL_FILE%
    for %%A in ("%INSTALL_FILE%") do (
        echo 파일 크기: %%~zA bytes
    )
    
    REM 설치 파일 서명 검증
    echo.
    echo 설치 파일 서명 검증 중...
    signtool verify /pa /v "%INSTALL_FILE%"
    if errorlevel 1 (
        echo [경고] 설치 파일 서명 검증 실패
    ) else (
        echo [완료] 설치 파일 서명 검증 성공
    )
) else (
    echo [경고] 설치 프로그램을 찾을 수 없습니다: %INSTALL_FILE%
    echo 빌드 디렉토리: %BUILD_DIR%
    echo.
    echo 빌드된 파일 목록:
    dir /b "%BUILD_DIR%\*.exe" 2>nul
)

echo.
echo ========================================
echo 빌드 및 배포 완료! (코드 서명 포함)
echo ========================================
echo.
echo 빌드 결과:
echo   - 실행 파일: %BUILD_DIR%\rustdesk.exe (서명됨)
if exist "%INSTALL_FILE%" (
    echo   - 설치 프로그램: %INSTALL_FILE% (서명됨)
)
echo.
echo 다음 단계:
echo   1. 테스트 실행: %BUILD_DIR%\rustdesk.exe
if exist "%INSTALL_FILE%" (
    echo   2. 설치 프로그램 배포: %INSTALL_FILE%
)
echo   3. Windows Defender SmartScreen 경고 없이 실행 가능합니다.
echo.
pause

