@echo off
setlocal enabledelayedexpansion
REM ========================================
REM MDesk Portable Packer Only
REM ========================================
REM 이미 빌드된 파일로 MDesk_portable.exe 만 패킹합니다.
REM (Rust DLL/Flutter 빌드는 하지 않음)
REM ========================================

echo ========================================
echo   MDesk Portable Packer
echo ========================================
echo.

REM 버전 추출
for /f "tokens=2 delims==" %%a in ('findstr /B /C:"version" Cargo.toml') do (
    if not defined VERSION (
        set VERSION=%%a
        set VERSION=!VERSION:"=!
        set VERSION=!VERSION: =!
    )
)
echo [OK] Version: %VERSION%

REM 빌드 디렉토리 확인
set BUILD_DIR=flutter\build\windows\x64\runner\Release
if not exist "%BUILD_DIR%\MDesk.exe" (
    echo [ERROR] MDesk.exe 를 찾을 수 없습니다: %BUILD_DIR%
    echo         먼저 build_windows.bat 로 빌드하세요.
    pause
    exit /b 1
)
echo [OK] Build directory: %BUILD_DIR%

REM libmdesk.dll 확인
if exist "%BUILD_DIR%\librustdesk.dll" del /f /q "%BUILD_DIR%\librustdesk.dll" 2>nul
if not exist "%BUILD_DIR%\libmdesk.dll" (
    if exist "target\release\librustdesk.dll" (
        echo [COPY] libmdesk.dll 복사 중...
        copy /y "target\release\librustdesk.dll" "%BUILD_DIR%\libmdesk.dll" >nul
    ) else (
        echo [WARN] libmdesk.dll 이 없습니다. 정상 동작하지 않을 수 있습니다.
    )
)

REM 이전 빌드에서 남은 사용하지 않는 is_portable 마커 제거
if exist "%BUILD_DIR%\is_portable" del /f /q "%BUILD_DIR%\is_portable" 2>nul

echo.
echo [PACK] Portable 패키징 시작...

REM generate.py 실행
cd libs\portable
pip install -r requirements.txt >nul 2>&1
python ./generate.py -f "../../%BUILD_DIR%" -o . -e "../../%BUILD_DIR%/MDesk.exe"
if errorlevel 1 (
    cd ..\..
    echo [ERROR] Portable 패키징 실패!
    pause
    exit /b 1
)
cd ..\..

REM 결과물 이동 및 이름 변경
if exist "target\release\rustdesk-portable-packer.exe" (
    move /y "target\release\rustdesk-portable-packer.exe" "MDesk_portable.exe" >nul
    echo [OK] MDesk_portable.exe 생성 완료

    REM 빌드 번호 증가
    set BUILD_NUM=1
    if exist "build_number.txt" set /p BUILD_NUM=<build_number.txt
    set /a BUILD_NUM=BUILD_NUM+1
    echo !BUILD_NUM!>build_number.txt

    REM 버전 포함 install 파일 복사
    set FULL_VERSION=%VERSION%.!BUILD_NUM!
    copy /y "MDesk_portable.exe" "MDesk-!FULL_VERSION!-install.exe" >nul
    echo [OK] MDesk-!FULL_VERSION!-install.exe 생성 완료

    REM MDesk-install.exe 도 복사 (서버 업로드용 고정 이름)
    copy /y "MDesk_portable.exe" "MDesk-install.exe" >nul
    echo [OK] MDesk-install.exe 생성 완료
) else (
    echo [ERROR] rustdesk-portable-packer.exe 를 찾을 수 없습니다!
    pause
    exit /b 1
)

echo.
echo ========================================
echo   PACKING COMPLETE!
echo ========================================
echo.
echo   Output files:
echo     - MDesk_portable.exe
if defined FULL_VERSION echo     - MDesk-!FULL_VERSION!-install.exe
echo     - MDesk-install.exe
echo.
pause
