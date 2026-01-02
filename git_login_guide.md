# Git 로그인 재설정 가이드

## 방법 1: 스크립트 사용 (간단)

```batch
reset_git_auth.bat
```

스크립트가 자동으로:
- 저장된 인증 정보 삭제
- Credential Helper 설정
- Remote URL 확인

## 방법 2: 수동으로 인증 정보 삭제

### Windows Credential Manager에서 삭제

1. **제어판** → **자격 증명 관리자** → **Windows 자격 증명**
2. `git:https://github.com` 찾아서 삭제
3. 또는 명령어로:
   ```batch
   cmdkey /delete:git:https://github.com
   ```

### Git Credential Helper 초기화

```batch
git credential-manager-core erase
```

또는 특정 URL만:
```batch
echo url=https://github.com | git credential-manager-core erase
```

## 방법 3: Git 설정 확인 및 변경

### 현재 설정 확인
```batch
git config --global --list
git config --global credential.helper
```

### Credential Helper 설정
```batch
# Windows Credential Manager 사용
git config --global credential.helper manager-core

# 또는 캐시 사용 (15분)
git config --global credential.helper cache

# 또는 파일에 저장 (보안 주의)
git config --global credential.helper store
```

## 방법 4: Remote URL에 직접 인증 정보 포함

### Personal Access Token 사용
```batch
git remote set-url mdesk https://metadtlab:YOUR_TOKEN@github.com/metadtlab/MDesk.git
```

### 사용자명만 포함 (비밀번호는 입력)
```batch
git remote set-url mdesk https://metadtlab@github.com/metadtlab/MDesk.git
```

## 방법 5: SSH 키 사용

### SSH로 전환
```batch
git remote set-url mdesk git@github.com:metadtlab/MDesk.git
```

### SSH 키 확인
```batch
ssh -T git@github.com
```

## 테스트

인증 정보를 재설정한 후:

```batch
git push -u mdesk main
```

이때 사용자명과 비밀번호(토큰)를 입력하라는 프롬프트가 나타납니다.

## Personal Access Token 생성

1. https://github.com/settings/tokens
2. "Generate new token" → "Generate new token (classic)"
3. 이름: `MDesk Push Token`
4. 권한: `repo` (전체 체크)
5. 생성 후 토큰 복사 (한 번만 보임!)

## 문제 해결

### 인증 정보가 계속 저장되는 경우
```batch
git config --global --unset credential.helper
git config --global credential.helper ""
```

### 특정 저장소만 다른 계정 사용
```batch
cd D:\IMedix\Rust\rustdesk
git config credential.helper ""
git config user.name "metadtlab"
git config user.email "your-email@example.com"
```

