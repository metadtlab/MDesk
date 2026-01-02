@echo off
chcp 65001 >nul 2>&1
setlocal

echo ========================================
echo MDesk GitHub Push Script
echo ========================================
echo.

cd /d D:\IMedix\Rust\rustdesk

echo [1/5] Checking Git status...
git status --short
echo.

echo [2/5] Checking remote configuration...
git remote -v
echo.

echo [3/5] Adding new remote (if not exists)...
git remote remove mdesk 2>nul
git remote add mdesk https://github.com/metadtlab/MDesk.git
echo Remote 'mdesk' added: https://github.com/metadtlab/MDesk.git
echo.

echo [4/5] Staging all changes...
git add .
if %ERRORLEVEL% NEQ 0 (
    echo [ERROR] Failed to stage files!
    pause
    exit /b %ERRORLEVEL%
)
echo Files staged successfully.
echo.

echo [5/5] Committing changes...
set /p commit_msg="Enter commit message (or press Enter for default): "
if "%commit_msg%"=="" set commit_msg=Initial MDesk commit - Based on RustDesk
git commit -m "%commit_msg%"
if %ERRORLEVEL% NEQ 0 (
    echo [WARNING] Commit failed or nothing to commit. Continuing...
)
echo.

echo [6/6] Pushing to GitHub...
echo Choose branch:
echo   1. Push to master branch (default)
echo   2. Push to main branch
echo   3. Create new branch
set /p branch_choice="Enter choice (1-3): "
if "%branch_choice%"=="" set branch_choice=1
if "%branch_choice%"=="1" (
    git push -u mdesk master
) else if "%branch_choice%"=="2" (
    git push -u mdesk master:main
) else if "%branch_choice%"=="3" (
    set /p branch_name="Enter branch name: "
    git push -u mdesk master:%branch_name%
) else (
    git push -u mdesk master
)

if %ERRORLEVEL% NEQ 0 (
    echo.
    echo [ERROR] Push failed!
    echo.
    echo Possible reasons:
    echo   - Authentication required (use GitHub token or SSH)
    echo   - Repository is not empty (use --force to overwrite)
    echo   - Network issues
    echo.
    echo To use SSH instead, run:
    echo   git remote set-url mdesk git@github.com:metadtlab/MDesk.git
    echo   git push -u mdesk master
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
pause

