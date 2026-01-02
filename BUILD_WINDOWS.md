# Windows 빌드 및 배포 가이드

## 단계 5: 컴파일 및 배포 패키징

이 가이드는 RustDesk의 Windows 버전을 빌드하고 배포 패키지를 생성하는 방법을 설명합니다.

## 사전 요구사항

1. **Rust 개발 환경**
   - Rust 설치: https://rustup.rs/
   - `cargo` 명령어 사용 가능

2. **Flutter 개발 환경**
   - Flutter SDK 설치: https://flutter.dev/docs/get-started/install/windows
   - `flutter` 명령어 사용 가능

3. **Python 3**
   - Python 3 설치 필요
   - `pip` 명령어 사용 가능

4. **Windows SDK**
   - Windows 10 SDK 이상
   - Visual Studio Build Tools 또는 Visual Studio 설치

5. **코드 서명 (선택적, 상용화 시 필수)**
   - EV Code Signing 인증서 (.pfx 파일)
   - Windows SDK의 `signtool.exe` 사용 가능

## 빌드 방법

### 방법 1: 기본 빌드 (서명 없음)

```cmd
build_windows.bat
```

이 스크립트는 다음을 수행합니다:
1. Rust와 Flutter 통합 컴파일 (`python build.py --flutter`)
2. 빌드된 실행 파일 확인
3. 설치 프로그램 자동 생성 (`rustdesk-{version}-install.exe`)

### 방법 2: 코드 서명 포함 빌드 (권장)

**1단계: 환경변수 설정**

```cmd
set CERT_PASSWORD=인증서_패스워드
set CERT_FILE=cert.pfx
```

또는 인증서 파일 경로 지정:

```cmd
set CERT_PASSWORD=인증서_패스워드
set CERT_FILE=C:\path\to\your\cert.pfx
```

**2단계: 빌드 실행**

```cmd
build_windows_signed.bat
```

또는 기본 스크립트 사용:

```cmd
set CERT_PASSWORD=인증서_패스워드
build_windows.bat
```

## 빌드 프로세스 상세

### 1. 전체 빌드 실행

```cmd
python build.py --flutter
```

이 명령은 다음을 수행합니다:
- Rust 라이브러리 빌드 (`cargo build --features flutter --lib --release`)
- Flutter 앱 빌드 (`flutter build windows --release`)
- 가상 디스플레이 DLL 복사
- 포터블 패키저로 설치 프로그램 생성

### 2. 디지털 서명

EV Code Signing 인증서를 사용하여 실행 파일과 설치 프로그램에 서명합니다.

**서명 명령어:**
```cmd
signtool sign /a /v /p {패스워드} /f {인증서파일} /t http://timestamp.digicert.com {파일경로}
```

**서명 검증:**
```cmd
signtool verify /pa /v {파일경로}
```

### 3. 배포 파일 생성

빌드 완료 후 다음 파일이 생성됩니다:

- **실행 파일**: `flutter\build\windows\x64\runner\Release\rustdesk.exe`
- **설치 프로그램**: `rustdesk-{version}-install.exe`

## 출력 파일 위치

- **빌드 디렉토리**: `flutter\build\windows\x64\runner\Release\`
- **설치 프로그램**: 프로젝트 루트 디렉토리 (`rustdesk-{version}-install.exe`)

## 코드 서명 인증서 준비

### EV Code Signing 인증서 구매

상용 배포를 위해서는 신뢰할 수 있는 인증 기관(CA)에서 EV Code Signing 인증서를 구매해야 합니다.

**주요 인증 기관:**
- DigiCert
- Sectigo (이전 Comodo)
- GlobalSign
- SSL.com

### 인증서 파일 준비

1. 인증서를 `.pfx` 또는 `.p12` 형식으로 내보내기
2. 프로젝트 루트 디렉토리에 `cert.pfx`로 저장하거나 `CERT_FILE` 환경변수로 경로 지정

### 인증서 내보내기 (Windows)

1. 인증서 관리자에서 인증서 선택
2. 마우스 우클릭 → "모든 작업" → "내보내기"
3. "개인 키과 함께 내보내기" 선택
4. `.pfx` 형식 선택
5. 패스워드 설정

## 문제 해결

### 빌드 실패

- **Rust 컴파일 오류**: `cargo clean` 후 재빌드
- **Flutter 빌드 오류**: `flutter clean` 후 재빌드
- **의존성 오류**: `flutter pub get` 실행

### 서명 실패

- **signtool을 찾을 수 없음**: Windows SDK 설치 확인
- **인증서 오류**: 인증서 파일 경로 및 패스워드 확인
- **타임스탬프 서버 오류**: 인터넷 연결 확인 또는 다른 타임스탬프 서버 사용

### 설치 프로그램이 생성되지 않음

- `libs/portable` 디렉토리의 의존성 확인
- `pip3 install -r libs/portable/requirements.txt` 실행

## 수동 빌드 (고급)

### 단계별 수동 빌드

```cmd
REM 1. Rust 라이브러리 빌드
cargo build --features flutter --lib --release

REM 2. Flutter 앱 빌드
cd flutter
flutter build windows --release
cd ..

REM 3. DLL 복사
copy target\release\deps\dylib_virtual_display.dll flutter\build\windows\x64\runner\Release\

REM 4. 설치 프로그램 생성
cd libs\portable
pip3 install -r requirements.txt
python3 generate.py -f ..\..\flutter\build\windows\x64\runner\Release\ -o . -e ..\..\flutter\build\windows\x64\runner\Release\rustdesk.exe
cd ..\..
```

### 수동 코드 서명

```cmd
REM 실행 파일 서명
signtool sign /a /v /p {패스워드} /f cert.pfx /t http://timestamp.digicert.com flutter\build\windows\x64\runner\Release\rustdesk.exe

REM 설치 프로그램 서명
signtool sign /a /v /p {패스워드} /f cert.pfx /t http://timestamp.digicert.com rustdesk-{version}-install.exe

REM 서명 검증
signtool verify /pa /v flutter\build\windows\x64\runner\Release\rustdesk.exe
signtool verify /pa /v rustdesk-{version}-install.exe
```

## 참고 사항

- 코드 서명은 Windows Defender SmartScreen 경고를 제거하는 데 필수입니다
- EV Code Signing 인증서는 하드웨어 토큰(USB)이 필요할 수 있습니다
- 타임스탬프 서버를 사용하면 인증서 만료 후에도 서명이 유효합니다
- 빌드 시간은 시스템 성능에 따라 다릅니다 (일반적으로 10-30분)

## 추가 리소스

- [RustDesk 빌드 문서](https://rustdesk.com/docs/en/dev/build/)
- [Windows 코드 서명 가이드](https://docs.microsoft.com/en-us/windows/win32/seccrypto/cryptography-tools)
- [Flutter Windows 빌드](https://docs.flutter.dev/deployment/windows)

