<p align="center">
  <img src="res/logo-header.svg" alt="MDesk - 원격 데스크톱 솔루션"><br>
  <a href="#빌드-방법">빌드</a> •
  <a href="#docker를-사용한-빌드">Docker</a> •
  <a href="#파일-구조">구조</a> •
  <a href="#스크린샷">스크린샷</a>
</p>

> [!주의]
> **오용 면책 조항:** <br>
> MDesk 개발자는 이 소프트웨어의 비윤리적이거나 불법적인 사용을 용인하거나 지원하지 않습니다. 무단 접근, 제어 또는 프라이버시 침해와 같은 오용은 엄격히 금지됩니다. 작성자는 애플리케이션의 오용에 대해 책임을 지지 않습니다.

## 소개

Rust로 작성된 원격 데스크톱 솔루션입니다. 설정 없이 바로 사용할 수 있으며, 데이터를 완전히 제어할 수 있어 보안에 대한 걱정이 없습니다. 자체 렌데부/릴레이 서버를 설정하거나 직접 작성할 수 있습니다.

![image](https://user-images.githubusercontent.com/71636191/171661982-430285f0-2e12-4b1d-9957-4a58e375304d.png)

MDesk는 모든 분들의 기여를 환영합니다. 시작하는 데 도움이 필요하시면 [CONTRIBUTING.md](docs/CONTRIBUTING.md)를 참고하세요.

## 의존성

데스크톱 버전은 GUI를 위해 Flutter 또는 Sciter(사용 중단)를 사용합니다. 이 튜토리얼은 Sciter만 다루며, 시작하기 더 쉽고 친화적이기 때문입니다. Flutter 버전 빌드는 [CI](https://github.com/rustdesk/rustdesk/blob/master/.github/workflows/flutter-build.yml)를 확인하세요.

Sciter 동적 라이브러리는 직접 다운로드해야 합니다.

[Windows](https://raw.githubusercontent.com/c-smile/sciter-sdk/master/bin.win/x64/sciter.dll) |
[Linux](https://raw.githubusercontent.com/c-smile/sciter-sdk/master/bin.lnx/x64/libsciter-gtk.so) |
[macOS](https://raw.githubusercontent.com/c-smile/sciter-sdk/master/bin.osx/libsciter.dylib)

## 빌드 방법

### 기본 빌드 단계

- Rust 개발 환경과 C++ 빌드 환경을 준비합니다

- [vcpkg](https://github.com/microsoft/vcpkg)를 설치하고 `VCPKG_ROOT` 환경 변수를 올바르게 설정합니다

  - Windows: `vcpkg install libvpx:x64-windows-static libyuv:x64-windows-static opus:x64-windows-static aom:x64-windows-static`
  - Linux/macOS: `vcpkg install libvpx libyuv opus aom`

- `cargo run` 실행

## Linux에서 빌드하기

### Ubuntu 18 (Debian 10)

```sh
sudo apt install -y zip g++ gcc git curl wget nasm yasm libgtk-3-dev clang libxcb-randr0-dev libxdo-dev \
        libxfixes-dev libxcb-shape0-dev libxcb-xfixes0-dev libasound2-dev libpulse-dev cmake make \
        libclang-dev ninja-build libgstreamer1.0-dev libgstreamer-plugins-base1.0-dev libpam0g-dev
```

### openSUSE Tumbleweed

```sh
sudo zypper install gcc-c++ git curl wget nasm yasm gcc gtk3-devel clang libxcb-devel libXfixes-devel cmake alsa-lib-devel gstreamer-devel gstreamer-plugins-base-devel xdotool-devel pam-devel
```

### Fedora 28 (CentOS 8)

```sh
sudo yum -y install gcc-c++ git curl wget nasm yasm gcc gtk3-devel clang libxcb-devel libxdo-devel libXfixes-devel pulseaudio-libs-devel cmake alsa-lib-devel gstreamer1-devel gstreamer1-plugins-base-devel pam-devel
```

### Arch (Manjaro)

```sh
sudo pacman -Syu --needed unzip git cmake gcc curl wget yasm nasm zip make pkg-config clang gtk3 xdotool libxcb libxfixes alsa-lib pipewire
```

### vcpkg 설치

```sh
git clone https://github.com/microsoft/vcpkg
cd vcpkg
git checkout 2023.04.15
cd ..
vcpkg/bootstrap-vcpkg.sh
export VCPKG_ROOT=$HOME/vcpkg
vcpkg/vcpkg install libvpx libyuv opus aom
```

### libvpx 수정 (Fedora용)

```sh
cd vcpkg/buildtrees/libvpx/src
cd *
./configure
sed -i 's/CFLAGS+=-I/CFLAGS+=-fPIC -I/g' Makefile
sed -i 's/CXXFLAGS+=-I/CXXFLAGS+=-fPIC -I/g' Makefile
make
cp libvpx.a $HOME/vcpkg/installed/x64-linux/lib/
cd
```

### 빌드

```sh
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
source $HOME/.cargo/env
git clone --recurse-submodules https://github.com/rustdesk/rustdesk
cd rustdesk
mkdir -p target/debug
wget https://raw.githubusercontent.com/c-smile/sciter-sdk/master/bin.lnx/x64/libsciter-gtk.so
mv libsciter-gtk.so target/debug
VCPKG_ROOT=$HOME/vcpkg cargo run
```

## Docker를 사용한 빌드

저장소를 클론하고 Docker 컨테이너를 빌드합니다:

```sh
git clone https://github.com/rustdesk/rustdesk
cd rustdesk
git submodule update --init --recursive
docker build -t "rustdesk-builder" .
```

그런 다음 애플리케이션을 빌드할 때마다 다음 명령을 실행합니다:

```sh
docker run --rm -it -v $PWD:/home/user/rustdesk -v rustdesk-git-cache:/home/user/.cargo/git -v rustdesk-registry-cache:/home/user/.cargo/registry -e PUID="$(id -u)" -e PGID="$(id -g)" rustdesk-builder
```

첫 빌드는 의존성이 캐시되기 전까지 시간이 더 걸릴 수 있으며, 이후 빌드는 더 빠릅니다. 또한 빌드 명령에 다른 인수를 지정해야 하는 경우 `<OPTIONAL-ARGS>` 위치에서 명령 끝에 지정할 수 있습니다. 예를 들어 최적화된 릴리스 버전을 빌드하려면 위 명령 뒤에 `--release`를 추가합니다. 결과 실행 파일은 시스템의 target 폴더에서 사용할 수 있으며 다음으로 실행할 수 있습니다:

```sh
target/debug/rustdesk
```

또는 릴리스 실행 파일을 실행하는 경우:

```sh
target/release/rustdesk
```

이 명령들은 RustDesk 저장소의 루트에서 실행해야 하며, 그렇지 않으면 애플리케이션이 필요한 리소스를 찾지 못할 수 있습니다. 또한 `install` 또는 `run`과 같은 다른 cargo 하위 명령은 현재 이 방법을 통해 지원되지 않습니다. 이는 호스트 대신 컨테이너 내부에 프로그램을 설치하거나 실행하기 때문입니다.

## 파일 구조

- **[libs/hbb_common](libs/hbb_common)**: 비디오 코덱, 설정, tcp/udp 래퍼, protobuf, 파일 전송을 위한 fs 함수 및 기타 유틸리티 함수
- **[libs/scrap](libs/scrap)**: 화면 캡처
- **[libs/enigo](libs/enigo)**: 플랫폼별 키보드/마우스 제어
- **[libs/clipboard](libs/clipboard)**: Windows, Linux, macOS용 파일 복사 및 붙여넣기 구현
- **[src/ui](src/ui)**: 구식 Sciter UI (사용 중단)
- **[src/server](src/server)**: 오디오/클립보드/입력/비디오 서비스 및 네트워크 연결
- **[src/client.rs](src/client.rs)**: 피어 연결 시작
- **[src/rendezvous_mediator.rs](src/rendezvous_mediator.rs)**: [rustdesk-server](https://github.com/rustdesk/rustdesk-server)와 통신하고 원격 직접(TCP 홀 펀칭) 또는 릴레이 연결을 대기
- **[src/platform](src/platform)**: 플랫폼별 코드
- **[flutter](flutter)**: 데스크톱 및 모바일용 Flutter 코드
- **[flutter/web/js](flutter/web/v1/js)**: Flutter 웹 클라이언트용 JavaScript

## 스크린샷

![연결 관리자](https://github.com/rustdesk/rustdesk/assets/28412477/db82d4e7-c4bc-4823-8e6f-6af7eadf7651)

![Windows PC에 연결됨](https://github.com/rustdesk/rustdesk/assets/28412477/9baa91e9-3362-4d06-aa1a-7518edcbd7ea)

![파일 전송](https://github.com/rustdesk/rustdesk/assets/28412477/39511ad3-aa9a-4f8c-8947-1cce286a46ad)

![TCP 터널링](https://github.com/rustdesk/rustdesk/assets/28412477/78e8708f-e87e-4570-8373-1360033ea6c5)

## 프로젝트 정보

- **프로젝트명**: MDesk
- **버전**: 1.4.5
- **개발자**: MetaDataLab
- **이메일**: metadtlab@Gmail.com

## 라이선스

이 프로젝트는 원본 RustDesk 프로젝트를 기반으로 합니다. 라이선스 정보는 [LICENCE](LICENCE) 파일을 참고하세요.
