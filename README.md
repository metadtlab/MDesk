# MDesk

MDesk는 RustDesk 기반의 원격지원 프로그램입니다. Rust 원격제어 엔진과
Flutter 데스크톱 UI를 사용하며, 상담사와 고객을 인증번호로 연결하는
사용자 정의 원격지원 흐름을 개발하고 있습니다. 현재 본체 버전은 1.5.9입니다.

이 문서는 제품 구성, Windows 개발 환경, 빌드 및 실행 방법을 설명합니다.
공개 Markdown 문서는 이 파일 하나로 관리합니다. 인증 정보, 개인 작업 기록,
Git 로그인/푸시 안내는 저장소에 추가하지 않습니다.

## 현재 개발 구성

| 구성 요소 | 역할 |
| --- | --- |
| MDesk | 상담사/관리자용 Flutter 데스크톱 앱. 원격 접속과 피원격 세션 수락, 설정, 기기 목록을 제공합니다. |
| 사용자 정의 원격 | 인증번호 발급·조회, 고객 프로그램 준비 상태 표시, 원격 연결 및 재연결을 담당합니다. |
| MDeskMini | 고객 PC에서 실행하는 경량 Windows 호스트. 인증번호 검증 후 원격 연결을 기다리며 Flutter UI 빌드는 필요하지 않습니다. |
| 공통 Rust 엔진 | 화면 전송, 키보드·마우스 입력, 파일 전송, 클립보드, 세션 및 네트워크 처리를 담당합니다. |

MDesk 본체는 파일 전송, 채팅, 세션 녹화 등의 원격지원 기능을 포함합니다.
실제 사용 가능 여부는 상대 프로그램과 세션 권한, 빌드 옵션에 따라 달라집니다.
설정이 없는 본체의 기본 수락 방식은 **비밀번호를 통해 세션 수락**이며,
저장된 사용자 설정이나 관리 정책이 있으면 해당 값을 우선합니다.
Mini의 기본 자동 승인 정책은 본체와 별도로 동작합니다.

### 서비스 연동

사용자 정의 원격은 운영 API의 계정 정보와 인증번호 발급·검증 기능에 의존합니다.
현재 코드에는 ID/릴레이 호스트 `787.kr`와 관리 API `https://admin.787.kr`가
사용됩니다. 빌드 성공만으로 계정이나 유효한 인증번호가 생성되지는 않습니다.
실제 원격지원에는 접근 가능한 ID/릴레이 서버, API 및 필요한 계정 권한이 있어야 합니다.
이 클라이언트 빌드 절차는 서버/API를 설치하거나 실행하지 않습니다.

### 소스 구조

| 경로 | 내용 |
| --- | --- |
| `src/` | 본체 엔진, 클라이언트·서버 세션, 운영체제별 처리 |
| `flutter/` | 데스크톱 UI 및 공유 Flutter 코드 |
| `MDeskMini/` | Mini 실행 파일, Windows 빌드·검증 스크립트 |
| `libs/hbb_common/` | 설정, 프로토콜, 네트워크, 파일 전송 공통 코드 |
| `libs/scrap/` | 화면 캡처 및 코덱 연동 |
| `libs/clipboard/`, `libs/enigo/` | 클립보드 및 입력 처리 |
| `libs/portable/` | Windows 포터블 패키징 |
| `tests/` | 빌드 환경 및 회귀 테스트 |

## Windows 준비

- Git, Python 3, Rust MSVC 도구 체인, Flutter SDK를 PATH에 등록합니다.
- Visual Studio 또는 Build Tools의 C++ 데스크톱 개발 구성 요소와 Windows SDK를 설치합니다.
- CMake와 네이티브 빌드 도구도 준비합니다. Visual Studio의 C++ CMake 도구를 사용할 수 있습니다.
- LLVM/Clang과 libclang을 설치합니다. 필요하면
  `LIBCLANG_PATH=C:\Program Files\LLVM\bin`을 지정합니다.
- vcpkg와 UPX를 준비합니다. UPX는 Mini 배치의 최종 압축에 필요합니다.
- 현재 개발 환경에서 확인한 버전은 Rust 1.92.0, Flutter 3.41.1(Dart 3.11.0)입니다.
  저장소의 오래된 CI 버전과 혼용하지 마십시오.

아래 명령은 Windows 명령 프롬프트(cmd.exe) 기준입니다.

```bat
git clone https://github.com/metadtlab/MDesk.git MDesk
cd MDesk
set "VCPKG_ROOT=D:\dev\vcpkg"
set "LIBCLANG_PATH=C:\Program Files\LLVM\bin"
rustup target add x86_64-pc-windows-msvc i686-pc-windows-msvc
```

`VCPKG_ROOT`는 실제 vcpkg 설치 위치로 바꿉니다. `libs/hbb_common`은 이 저장소에
소스로 포함되어 있고 Opus는 Cargo가 지정된 Git 리비전으로 가져옵니다.
현재 남아 있는 `.gitmodules` 메타데이터 때문에 재귀 submodule 초기화를 빌드 필수
단계로 사용하지 않습니다. 새 PC의 첫 빌드에는 의존성 다운로드가 필요합니다.

vcpkg가 없는 PC에서만 아래 명령으로 설치합니다. 기존 vcpkg 폴더에는 다시 clone하지 않습니다.

```bat
git clone https://github.com/microsoft/vcpkg.git "%VCPKG_ROOT%"
call "%VCPKG_ROOT%\bootstrap-vcpkg.bat" -disableMetrics
```

도구 설치 후 `rustc --version`, `cargo --version`, `flutter --version`,
`python --version`, `flutter doctor -v`로 확인합니다. 아래 작업은 별도 안내가
없는 한 MDesk 프로젝트 루트에서 시작합니다.

## 네이티브 의존성

기본 Windows 빌드에는 libvpx, libyuv, aom, opus가 필요합니다.
vcpkg를 별도로 설치하고 bootstrap한 뒤, MDesk 루트에서 실행합니다.

```bat
set "MDESK_ROOT=%CD%"
pushd "%VCPKG_ROOT%"
vcpkg install libvpx:x64-windows-static --classic
vcpkg install libyuv:x64-windows-static aom:x64-windows-static opus:x64-windows-static --classic --overlay-ports="%MDESK_ROOT%\res\vcpkg"
popd
```

32비트 Mini는 같은 패키지의 `x86-windows-static` 버전이 필요하며,
`build_release_32bit.bat`가 누락 여부를 확인하고 설치합니다.
Windows libvpx는 저장소 overlay 대신 vcpkg 기본 포트를 사용합니다.
`hwcodec` 등 추가 기능은 별도 네이티브 의존성이 필요하므로 기본 빌드와 구분합니다.

## MDesk 빌드 및 실행

### 전체 빌드

```bat
cd flutter
flutter pub get
cd ..
python -m pip install -r libs\portable\requirements.txt
build_windows.bat
```

배치가 MSVC/Windows SDK 설정, Rust DLL 빌드, Flutter 빌드, 포터블 패키징을 진행합니다.
중간에 실행 파일 서명을 위한 대기가 있으므로 해당 안내를 확인한 뒤 계속합니다.
로컬 개발 확인만 할 때는 서명 없이 계속할 수 있지만, 서명 대기를 통과했다고
자동으로 서명되는 것은 아닙니다. 실제 배포용 서명 키나 비밀번호는 저장소에 넣지 않습니다.
마지막에 패키징 경고가 있으면 완료 문구만 보지 말고 아래 산출물이 새로 생성됐는지 확인합니다.

| 산출물 | 경로 |
| --- | --- |
| 실행 파일 | `flutter\build\windows\x64\runner\Release\MDesk.exe` |
| Rust DLL | `flutter\build\windows\x64\runner\Release\libmdesk.dll` |
| 포터블 | `MDesk_portable.exe` |
| 설치용 패키지 | `MDesk-<버전>.<빌드번호>-install.exe` |

Flutter 실행에는 Release 폴더의 DLL과 data 폴더도 필요합니다.
`MDesk.exe` 하나만 복사하지 말고 전체 Release 폴더 또는 포터블 패키지를 사용합니다.
패키징은 빌드 번호 등 메타데이터를 갱신할 수 있습니다.

### 빌드 결과 실행

프로젝트 루트에서 Release 실행 파일을 시작합니다.

```bat
start "" "flutter\build\windows\x64\runner\Release\MDesk.exe"
```

포터블 패키지가 생성된 경우 다음과 같이 실행할 수도 있습니다.

```bat
start "" "MDesk_portable.exe"
```

설치형 동작을 확인하려면 생성된 `MDesk-<버전>.<빌드번호>-install.exe`를 실행하고
설치 절차를 진행합니다. 설치·서비스·관리자 권한 테스트는 개발용 PC에서 수행합니다.

### 원격 연결 확인

1. 본체를 실행하고 설정의 네트워크 항목에서 사용할 ID/릴레이 서버와 필요한 키를 확인합니다.
2. 일반 ID 접속은 접속 대상 PC의 MDesk ID와 유효한 접속 비밀번호를 사용합니다.
   기본 비밀번호 방식은 비밀번호 검증을 생략하거나 모든 요청을 자동 수락한다는 뜻이 아닙니다.
3. 사용자 정의 원격은 연동 계정으로 로그인한 뒤 해당 탭에서 인증번호를 발급합니다.
4. 고객 PC에서 해당 번호를 사용하는 Mini를 실행하고, 본체에 표시되는 준비 상태를 확인합니다.
5. 원격 연결 후 화면·입력·파일 전송 등 필요한 기능을 확인하고 세션을 종료합니다.

### Rust DLL만 다시 빌드

```bat
build_windows.bat --rust-only
```

이 명령은 `target\release\librustdesk.dll`을 만듭니다.
이미 만들어진 Flutter 배포 폴더의 DLL은 자동 교체하지 않습니다.
본체와 관련 서비스가 DLL을 사용 중이지 않은 개발 환경에서, 기존 Release 폴더가 있다면
아래와 같이 복사한 뒤 다시 실행합니다.

```bat
copy /y "target\release\librustdesk.dll" "flutter\build\windows\x64\runner\Release\libmdesk.dll"
start "" "flutter\build\windows\x64\runner\Release\MDesk.exe"
```

Flutter UI나 Rust/Flutter 연동 코드가 함께 바뀌었다면 DLL만 교체하지 말고 전체 빌드를 수행합니다.

## MDeskMini 빌드 및 실행

### 빌드

프로젝트 루트에서 원하는 아키텍처의 배치를 실행합니다.

```bat
MDeskMini\build_release.bat
```

```bat
MDeskMini\build_release_32bit.bat
```

| 대상 | 산출물 |
| --- | --- |
| 64비트 | `MDeskMini\target\release\mdeskmini.exe` |
| 32비트 | `MDeskMini\target\i686-pc-windows-msvc\release\mdeskmini.exe` |

배치가 관리자 권한 manifest를 검사하고 UPX로 압축합니다.
코드 서명은 최종 압축 후 수행합니다. Mini에는 Flutter UI 빌드가 필요하지 않습니다.

### 고객 PC에서 실행

1. MDesk의 사용자 정의 원격에서 발급한 유효한 인증번호를 준비합니다.
2. 고객 안내 페이지 흐름을 통해 번호를 전달하거나, 개발 테스트에서는 아래처럼
   **실제 발급된 번호**를 클립보드에 넣습니다. 임의의 번호로는 검증을 통과할 수 없습니다.
3. 고객 PC에서 Mini를 실행하고 Windows 관리자 권한 요청을 확인합니다.
4. 인증번호 검증과 서버 준비가 완료되면 상담사 MDesk에서 원격 접속합니다.

프로젝트 루트에서 32비트 빌드를 테스트하는 예입니다. 64비트는 실행 파일 경로를
`MDeskMini\target\release\mdeskmini.exe`로 바꿉니다.

```bat
set /p "CERTNO=발급받은 인증번호 입력: "
echo certno:%CERTNO%| clip
start "" "MDeskMini\target\i686-pc-windows-msvc\release\mdeskmini.exe"
```

Mini는 클립보드의 `certno:숫자`를 읽어 HTTPS API에서 검증합니다.
번호가 없거나 검증에 실패하면 원격 대기를 시작하지 않습니다.
검증 성공 시 해당 번호를 클립보드에서 지우므로 재실행 때는 유효한 번호를 다시 준비합니다.

기본 `auto` 모드는 검증 후 Mini가 대기하는 동안 개별 연결 확인창 없이 수락합니다.
이 시작 단계의 인증번호 검증은 각 접속자의 신원을 따로 인증하는 절차는 아닙니다.
수동 승인 테스트가 필요하면, 번호를 다시 준비한 뒤 다음 옵션으로 실행합니다.

```bat
start "" "MDeskMini\target\i686-pc-windows-msvc\release\mdeskmini.exe" serve --approve-mode click
```

`--approve-mode password`는 본체 엔진의 비밀번호 검증을 사용하고,
`click`/`both`는 수동 승인 흐름을 유지합니다. `--headless`는 Mini의 승인 감시 루프를
끄므로 기본 자동 접속 예제에 추가하지 않습니다. 고객 PC에 MDesk가 이미 설치되어
설치본으로 실행을 넘기는 경우에는 Mini 자체 승인 루프와 동작이 다를 수 있습니다.

### Windows 7 전용 빌드

Windows 7 전용 배치는 `MDeskMini\build_release_win7_32bit.bat`와
`MDeskMini\build_release_win7_64bit.bat`입니다. Rust 표준 라이브러리 소스,
호환성 패치 및 바이너리 검사가 추가되므로 일반 Windows 빌드와 구분합니다.
기존 PC의 Cargo 캐시 수정은 새 PC에 자동 복제되지 않으며, 새 환경 재현과
실제 Windows 7 실행 검증은 별도로 필요합니다.

## 점검 및 오류 해결

```bat
tests\test_windows_build_env.bat
call setup_windows_env.bat x64
cargo check --features flutter --locked
cd flutter
flutter analyze --no-pub
```

- `opus/opus_multistream.h` 누락: `VCPKG_ROOT`와 대상 아키텍처의 opus 설치를 확인합니다.
- `inttypes.h` 누락: C++ 구성 요소와 Windows SDK를 확인하고,
  `setup_windows_env.bat x64` 또는 `x86`으로 환경을 초기화합니다.
- libclang 로딩 실패: `LIBCLANG_PATH`에 실제 `libclang.dll`이 있는지 확인합니다.
- UPX 실패: UPX의 PATH 등록과 최종 실행 파일 경로를 확인합니다.
- 본체 실행 시 DLL 오류: `libmdesk.dll`, Flutter DLL 및 data 폴더가 Release 폴더에 있는지 확인합니다.
- Mini가 원격 대기에 진입하지 않음: 인증번호의 유효성, 클립보드 내용,
  API 연결 및 HTTPS 인증서 검증 실패 여부를 확인합니다. TLS 검증을 끄는 방식으로 우회하지 않습니다.
- `--locked` 실패: 잠금 파일과 의존성 변경 원인을 먼저 확인합니다.
  무조건 캐시를 삭제하거나 잠금 파일을 갱신하지 않습니다.

소스, 잠금 파일, 빌드 스크립트, 리소스 및 포함된 라이선스 파일은 유지합니다.
다른 운영체제용 소스와 스크립트도 남아 있지만 이 문서의 대상은 Windows 빌드입니다.
빌드 완료는 실제 두 PC 사이의 접속, 설치·권한 처리, 모든 OS 호환성까지 검증했다는 의미가 아닙니다.
