@echo off
chcp 65001 >nul 2>&1
setlocal

echo ========================================
echo MDesk GitHub Force Push Script
echo WARNING: This will overwrite remote repository!
echo ========================================
echo.

cd /d D:\IMedix\Rust\rustdesk

echo [1/4] Checking Git status...
git status --short
echo.

echo [2/4] Adding new remote (if not exists)...
git remote remove mdesk 2>nul
git remote add mdesk https://github.com/metadtlab/MDesk.git
echo Remote 'mdesk' added: https://github.com/metadtlab/MDesk.git
echo.

echo [3/4] Staging and committing all changes...
git add .
set /p commit_msg="Enter commit message (or press Enter for default): "
if "%commit_msg%"=="" set commit_msg=Initial MDesk commit - Based on RustDesk
git commit -m "%commit_msg%"
if %ERRORLEVEL% NEQ 0 (
    echo [WARNING] Commit failed or nothing to commit. Continuing...
)
echo.

echo [4/4] Force pushing to GitHub (master branch)...
echo WARNING: This will overwrite the remote repository!
set /p confirm="Are you sure? (yes/no): "
if /i not "%confirm%"=="yes" (
    echo Cancelled.
    pause
    exit /b 0
)

git push -u mdesk master --force

if %ERRORLEVEL% NEQ 0 (
    echo.
    echo [ERROR] Force push failed!
    echo.
    echo Possible reasons:
    echo   - Authentication required (use GitHub token or SSH)
    echo   - Network issues
    echo.
    echo To use SSH instead, run:
    echo   git remote set-url mdesk git@github.com:metadtlab/MDesk.git
    echo   git push -u mdesk master --force
    echo.
    pause
    exit /b %ERRORLEVEL%
)

echo.
echo ========================================
echo Force push completed successfully!
echo ========================================
echo.
echo Repository: https://github.com/metadtlab/MDesk
echo.
pause

