@echo off
chcp 65001 >nul 2>&1
setlocal

echo ========================================
echo MDesk GitHub SSH Setup Script
echo ========================================
echo.

cd /d D:\IMedix\Rust\rustdesk

echo [1/2] Setting remote URL to SSH...
git remote remove mdesk 2>nul
git remote add mdesk git@github.com:metadtlab/MDesk.git
echo Remote 'mdesk' set to SSH: git@github.com:metadtlab/MDesk.git
echo.

echo [2/2] Testing SSH connection...
ssh -T git@github.com
if %ERRORLEVEL% NEQ 0 (
    echo.
    echo [WARNING] SSH connection test failed!
    echo.
    echo To set up SSH key:
    echo   1. Generate SSH key: ssh-keygen -t ed25519 -C "your_email@example.com"
    echo   2. Add to SSH agent: ssh-add ~/.ssh/id_ed25519
    echo   3. Add public key to GitHub: https://github.com/settings/keys
    echo   4. Copy public key: type %USERPROFILE%\.ssh\id_ed25519.pub
    echo.
) else (
    echo SSH connection successful!
    echo.
    echo You can now use:
    echo   push_to_github.bat
    echo   or
    echo   git push -u mdesk master
    echo.
)

pause

