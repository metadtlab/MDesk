# MDesk 빌드

MDesk(Flutter 데스크톱)와 MDeskMini(Windows 호스트)의 빌드 안내입니다.
공개 Markdown 문서는 이 파일 하나로 관리합니다. 개인 작업 기록, 인증 정보,
Git 로그인/푸시 안내는 저장소에 추가하지 않습니다.

## Windows 준비

- Git, Python 3, Rust MSVC 도구 체인, Flutter SDK를 PATH에 등록합니다.
- Visual Studio 또는 Build Tools의 C++ 데스크톱 개발 구성 요소와 Windows SDK를 설치합니다.
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

## MDesk 64비트

```bat
cd flutter
flutter pub get
cd ..
python -m pip install -r libs\portable\requirements.txt
build_windows.bat
```

배치가 MSVC/Windows SDK 설정, Rust DLL 빌드, Flutter 빌드, 포터블 패키징을 진행합니다.
중간에 실행 파일 서명을 위한 대기가 있으므로 해당 안내를 확인한 뒤 계속합니다.
실제 배포용 서명 키나 비밀번호는 저장소에 넣지 않습니다.

| 산출물 | 경로 |
| --- | --- |
| 실행 파일 | `flutter\build\windows\x64\runner\Release\MDesk.exe` |
| Rust DLL | `flutter\build\windows\x64\runner\Release\libmdesk.dll` |
| 포터블 | `MDesk_portable.exe` |
| 설치용 패키지 | `MDesk-<버전>.<빌드번호>-install.exe` |

Flutter 실행에는 Release 폴더의 DLL과 data 폴더도 필요합니다.
`MDesk.exe` 하나만 복사하지 말고 전체 Release 폴더 또는 포터블 패키지를 사용합니다.
패키징은 빌드 번호 등 메타데이터를 갱신할 수 있습니다.

Rust DLL만 빌드할 때:

```bat
build_windows.bat --rust-only
```

이 명령은 `target\release\librustdesk.dll`을 만듭니다.
이미 만들어진 Flutter 배포 폴더의 DLL은 자동 교체하지 않습니다.

## MDeskMini

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
- `--locked` 실패: 잠금 파일과 의존성 변경 원인을 먼저 확인합니다.
  무조건 캐시를 삭제하거나 잠금 파일을 갱신하지 않습니다.

소스, 잠금 파일, 빌드 스크립트, 리소스 및 포함된 라이선스 파일은 유지합니다.
다른 운영체제용 소스와 스크립트도 남아 있지만 이 문서의 대상은 Windows 빌드입니다.
