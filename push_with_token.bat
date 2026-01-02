@echo off
chcp 65001 >nul 2>&1
setlocal

echo ========================================
echo MDesk GitHub Push with Token
echo ========================================
echo.

cd /d D:\IMedix\Rust\rustdesk

echo [1/3] Setting up remote with token...
set /p token="Enter your GitHub Personal Access Token: "
if "%token%"=="" (
    echo [ERROR] Token is required!
    pause
    exit /b 1
)

git remote set-url mdesk https://metadtlab:%token%@github.com/metadtlab/MDesk.git
echo Remote URL updated.
echo.

echo [2/3] Checking status...
git status --short
echo.

echo [3/3] Pushing to GitHub (main branch)...
git push -u mdesk main

if %ERRORLEVEL% NEQ 0 (
    echo.
    echo [ERROR] Push failed!
    echo.
    echo Possible reasons:
    echo   - Invalid token
    echo   - Token expired
    echo   - No repository access
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
echo Note: Token is stored in Git credential manager.
echo To remove: git credential-manager-core erase https://github.com
echo.
pause

