@echo off
chcp 65001 >nul 2>&1
setlocal

echo ========================================
echo Git 인증 정보 초기화 및 재설정
echo ========================================
echo.

cd /d D:\IMedix\Rust\rustdesk

echo [1/4] 현재 저장된 인증 정보 확인...
git config --list | findstr credential
echo.

echo [2/4] Windows Credential Manager에서 GitHub 인증 정보 삭제...
cmdkey /list | findstr github
if %ERRORLEVEL% EQU 0 (
    echo GitHub 인증 정보를 찾았습니다.
    echo 삭제 중...
    cmdkey /delete:git:https://github.com 2>nul
    cmdkey /delete:git:https://github.com:443 2>nul
    echo 인증 정보가 삭제되었습니다.
) else (
    echo 저장된 GitHub 인증 정보가 없습니다.
)
echo.

echo [3/4] Git Credential Helper 설정 확인...
git config --global credential.helper
if %ERRORLEVEL% NEQ 0 (
    echo Credential helper가 설정되지 않았습니다.
    echo Windows Credential Manager로 설정합니다...
    git config --global credential.helper manager-core
    echo 설정 완료.
) else (
    echo Credential helper가 이미 설정되어 있습니다.
)
echo.

echo [4/4] Remote URL 확인 및 재설정...
git remote -v
echo.
echo Remote URL을 HTTPS로 설정합니다...
git remote set-url mdesk https://github.com/metadtlab/MDesk.git
echo Remote URL이 설정되었습니다.
echo.

echo ========================================
echo 설정 완료!
echo ========================================
echo.
echo 다음에 git push를 실행하면:
echo   1. 사용자명 입력 요청: metadtlab
echo   2. 비밀번호 입력 요청: Personal Access Token 입력
echo.
echo Personal Access Token 생성:
echo   https://github.com/settings/tokens
echo.
echo 테스트하려면:
echo   git push -u mdesk main
echo.
pause

