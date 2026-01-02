# GitHub에 코드 올리기 가이드

## 준비사항

1. **GitHub 인증 설정** (둘 중 하나 선택)

### 방법 1: HTTPS + Personal Access Token (권장)
- GitHub → Settings → Developer settings → Personal access tokens → Tokens (classic)
- `repo` 권한으로 새 토큰 생성
- 토큰을 안전한 곳에 저장

### 방법 2: SSH 키 설정
- `setup_github_ssh.bat` 실행하여 SSH 설정

## 사용 방법

### 1. 일반 푸시 (권장)
```batch
push_to_github.bat
```
- 변경사항을 커밋하고 GitHub에 푸시
- 원격 저장소가 비어있거나 충돌이 없을 때 사용

### 2. 강제 푸시 (원격 저장소 덮어쓰기)
```batch
push_to_github_force.bat
```
- ⚠️ **주의**: 원격 저장소의 모든 내용을 덮어씁니다
- 저장소가 비어있거나 완전히 새로 시작할 때 사용

### 3. SSH 설정
```batch
setup_github_ssh.bat
```
- SSH 키를 사용하여 GitHub에 연결
- SSH 키가 없으면 생성 방법 안내

## 수동 실행 방법

### 1. Remote 추가
```batch
git remote add mdesk https://github.com/metadtlab/MDesk.git
```

### 2. 변경사항 커밋
```batch
git add .
git commit -m "Initial MDesk commit"
```

### 3. 푸시
```batch
git push -u mdesk master
```

### 4. 강제 푸시 (필요시)
```batch
git push -u mdesk master --force
```

## 문제 해결

### 인증 오류 발생 시

**HTTPS 사용 시:**
- Personal Access Token을 사용하여 인증
- 또는 GitHub Desktop 사용

**SSH 사용 시:**
- `setup_github_ssh.bat` 실행하여 SSH 키 설정 확인
- GitHub에 SSH 키 등록 확인

### 원격 저장소가 비어있지 않을 때
- `push_to_github_force.bat` 사용 (주의: 기존 내용 삭제됨)
- 또는 GitHub 웹에서 저장소를 비우고 다시 시도

## 참고

- 저장소 URL: https://github.com/metadtlab/MDesk
- 기본 브랜치: `master`
- `.gitignore` 파일이 이미 설정되어 있어 빌드 파일 등은 제외됩니다

