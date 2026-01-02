@echo off
chcp 65001 > nul
setlocal enabledelayedexpansion

echo ============================================
echo   MDesk GitHub 업로드 스크립트
echo ============================================
echo.

:: Git 설치 확인
where git >nul 2>nul
if %errorlevel% neq 0 (
    echo [오류] Git이 설치되어 있지 않습니다.
    echo Git을 설치해 주세요: https://git-scm.com/download/win
    pause
    exit /b 1
)

:: 원격 저장소 확인
echo [정보] 원격 저장소를 확인합니다...
git remote -v
echo.

:: 커밋 메시지 입력
set /p COMMIT_MSG="커밋 메시지를 입력하세요 (기본값: Update): "
if "%COMMIT_MSG%"=="" set COMMIT_MSG=Update

:: 현재 상태 확인
echo.
echo [정보] 현재 Git 상태:
git status --short
echo.

:: .github 폴더를 Git 추적에서 제거 시도 (에러 무시)
echo [정보] .github 폴더를 Git 추적에서 제거합니다 (workflow 스코프 필요)...
git rm -r --cached .github 2>nul
echo.

:: 모든 파일 추가
echo [정보] 변경된 파일을 추가합니다...
git add .
echo.

:: 커밋
echo [정보] 커밋을 생성합니다: %COMMIT_MSG%
git commit -m "%COMMIT_MSG%"
if %errorlevel% neq 0 (
    echo [경고] 커밋할 변경 사항이 없거나 오류가 발생했습니다.
)
echo.

:: 브랜치 이름 확인 및 설정
for /f "tokens=*" %%a in ('git branch --show-current 2^>nul') do set BRANCH=%%a
if "%BRANCH%"=="" (
    echo [정보] main 브랜치를 생성합니다...
    git branch -M main
    set BRANCH=main
)
echo [정보] 현재 브랜치: %BRANCH%
echo.

:: 원격 저장소 선택 (mdesk가 있으면 사용, 없으면 origin 사용)
set REMOTE=mdesk
git remote get-url %REMOTE% >nul 2>nul
if %errorlevel% neq 0 (
    set REMOTE=origin
    echo [정보] mdesk 원격 저장소가 없습니다. origin을 사용합니다.
) else (
    echo [정보] mdesk 원격 저장소를 사용합니다.
)
echo.

:: 푸시
echo [정보] GitHub에 푸시합니다 (%REMOTE% 원격 저장소)...
git push -u %REMOTE% %BRANCH%
if %errorlevel% neq 0 (
    echo.
    echo [경고] 푸시에 실패했습니다. 강제 푸시를 시도할까요?
    set /p FORCE_PUSH="강제 푸시 (y/N): "
    if /i "!FORCE_PUSH!"=="y" (
        echo [정보] 강제 푸시를 시도합니다...
        git push -u %REMOTE% %BRANCH% --force
    )
)

echo.
echo ============================================
echo   완료!
echo ============================================
echo.
pause

