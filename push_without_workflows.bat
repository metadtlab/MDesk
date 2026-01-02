@echo off
chcp 65001 >nul 2>&1
setlocal

echo ========================================
echo MDesk GitHub Push (without workflows)
echo ========================================
echo.

cd /d D:\IMedix\Rust\rustdesk

echo [1/3] .github/workflows 파일들을 제외하고 커밋...
git reset HEAD .github/workflows 2>nul
git restore --staged .github/workflows 2>nul
echo.

echo [2/3] .github/workflows를 .gitignore에 추가...
if not exist .gitignore (
    echo .github/workflows/ > .gitignore
) else (
    findstr /C:".github/workflows" .gitignore >nul
    if %ERRORLEVEL% NEQ 0 (
        echo .github/workflows/ >> .gitignore
        echo .gitignore에 추가되었습니다.
    ) else (
        echo .gitignore에 이미 있습니다.
    )
)
echo.

echo [3/3] 푸시 중...
git push -u mdesk main

if %ERRORLEVEL% NEQ 0 (
    echo.
    echo [ERROR] Push failed!
    echo.
    echo 해결 방법:
    echo   1. 토큰에 workflow scope 추가:
    echo      https://github.com/settings/tokens
    echo      - 기존 토큰 편집 또는 새 토큰 생성
    echo      - "workflow" 권한 체크
    echo.
    echo   2. 또는 .github 폴더를 완전히 제외:
    echo      git rm -r --cached .github
    echo      git commit -m "Remove .github workflows"
    echo      git push -u mdesk main
    echo.
    pause
    exit /b %ERRORLEVEL%
)

echo.
echo ========================================
echo Push completed successfully!
echo ========================================
echo.
echo Repository: https://github.com/metadtlab/MDesk
echo.
echo Note: .github/workflows 파일들은 제외되었습니다.
echo.
pause

