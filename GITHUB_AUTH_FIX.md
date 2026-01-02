# GitHub 인증 문제 해결

## 현재 상황
- 저장소: `metadtlab/MDesk`
- 현재 계정: `newcomz` (권한 없음)
- 오류: `Permission denied (403)`

## 해결 방법

### 방법 1: Personal Access Token 사용 (권장)

1. **GitHub에서 토큰 생성**
   - https://github.com/settings/tokens
   - "Generate new token" → "Generate new token (classic)"
   - 이름: `MDesk Push Token`
   - 권한: `repo` (전체 체크)
   - 생성 후 토큰 복사 (한 번만 보임!)

2. **Remote URL에 토큰 포함**
   ```batch
   git remote set-url mdesk https://YOUR_TOKEN@github.com/metadtlab/MDesk.git
   ```
   또는
   ```batch
   git remote set-url mdesk https://metadtlab:YOUR_TOKEN@github.com/metadtlab/MDesk.git
   ```

3. **푸시**
   ```batch
   git push -u mdesk main
   ```

### 방법 2: SSH 키 사용

1. **SSH 키 생성** (없는 경우)
   ```batch
   ssh-keygen -t ed25519 -C "your_email@example.com"
   ```

2. **SSH 키를 GitHub에 등록**
   - https://github.com/settings/keys
   - "New SSH key" 클릭
   - 키 복사: `type %USERPROFILE%\.ssh\id_ed25519.pub`

3. **Remote를 SSH로 변경**
   ```batch
   git remote set-url mdesk git@github.com:metadtlab/MDesk.git
   ```

4. **푸시**
   ```batch
   git push -u mdesk main
   ```

### 방법 3: GitHub Desktop 사용

1. GitHub Desktop 설치
2. `metadtlab` 계정으로 로그인
3. 저장소 클론 또는 기존 저장소 추가
4. 변경사항 커밋 및 푸시

## 빠른 해결 스크립트

### Personal Access Token 사용
```batch
@echo off
set /p token="Enter your GitHub Personal Access Token: "
git remote set-url mdesk https://metadtlab:%token%@github.com/metadtlab/MDesk.git
git push -u mdesk main
```

### SSH 사용
```batch
git remote set-url mdesk git@github.com:metadtlab/MDesk.git
git push -u mdesk main
```

## 참고
- Personal Access Token은 안전하게 보관하세요
- 토큰은 저장소에 커밋하지 마세요
- 환경변수나 Git Credential Manager 사용 권장

