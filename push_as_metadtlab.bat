@echo off
chcp 65001 >nul 2>&1
setlocal

echo ========================================
echo MDesk GitHub Push as metadtlab
echo ========================================
echo.

cd /d D:\IMedix\Rust\rustdesk

echo [1/4] Setting remote URL...
git remote remove mdesk 2>nul
git remote add mdesk https://github.com/metadtlab/MDesk.git
echo Remote 'mdesk' set to: https://github.com/metadtlab/MDesk.git
echo.

echo [2/4] Authentication options:
echo   1. Use Personal Access Token (recommended)
echo   2. Use SSH key
echo   3. Use GitHub credential helper (will prompt for username/password)
set /p auth_choice="Choose authentication method (1-3): "
if "%auth_choice%"=="" set auth_choice=1
echo.

if "%auth_choice%"=="1" (
    echo [3/4] Setting up with Personal Access Token...
    echo.
    echo To create a token:
    echo   1. Go to: https://github.com/settings/tokens
    echo   2. Click "Generate new token" ^> "Generate new token (classic)"
    echo   3. Select "repo" scope
    echo   4. Copy the token
    echo.
    set /p token="Enter your Personal Access Token: "
    if "%token%"=="" (
        echo [ERROR] Token is required!
        pause
        exit /b 1
    )
    git remote set-url mdesk https://metadtlab:%token%@github.com/metadtlab/MDesk.git
    echo Remote URL updated with token.
) else if "%auth_choice%"=="2" (
    echo [3/4] Setting up with SSH...
    git remote set-url mdesk git@github.com:metadtlab/MDesk.git
    echo Remote URL updated to SSH.
    echo.
    echo Testing SSH connection...
    ssh -T git@github.com
    if %ERRORLEVEL% NEQ 0 (
        echo.
        echo [WARNING] SSH connection test failed!
        echo Make sure your SSH key is added to GitHub:
        echo   https://github.com/settings/keys
        echo.
    )
) else (
    echo [3/4] Using GitHub credential helper...
    echo You will be prompted for username and password/token when pushing.
    echo Username should be: metadtlab
    echo.
)

echo.
echo [4/4] Pushing to GitHub (main branch)...
git push -u mdesk main

if %ERRORLEVEL% NEQ 0 (
    echo.
    echo [ERROR] Push failed!
    echo.
    echo Troubleshooting:
    echo   - Make sure you have access to metadtlab/MDesk repository
    echo   - Check your authentication credentials
    echo   - Try: git push -u mdesk main --force (if repository is empty)
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

