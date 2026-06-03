#!/usr/bin/env bash
# 우분투(네이티브 또는 WSL2 Ubuntu)에서 MDesk/RustDesk Flutter 리눅스 빌드 + .deb 패키지 생성.
# 사용: 저장소 루트에서 bash ./build_ubuntu_flutter.sh
#
# 참고: CI(.github/workflows/flutter-build.yml)와 유사한 순서입니다.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

# flutter/pubspec.lock requires Flutter >=3.38.1 / Dart >=3.10.0.
# Flutter 3.24.5 ships Dart 3.5.4 and cannot resolve app_links 7.x.
FLUTTER_VERSION="${FLUTTER_VERSION:-3.41.9}"
VCPKG_COMMIT="${VCPKG_COMMIT:-120deac3062162151622ca4860575a33844ba10b}"

usage() {
  sed -n '1,120p' "$0" | sed -n '/^#/p'
  cat <<EOF

옵션:
  --deps-only       APT 패키지만 설치하고 종료
  --quick           hwcodec 없이 빌드 (의존성·컴파일 시간 단축, 영상 코덱 기능 제한 가능)
  --skip-submodules 서브모듈 업데이트 생략
  --help            이 도움말

환경 변수:
  VCPKG_ROOT        vcpkg 클론 경로 (기본: \$HOME/vcpkg-rustdesk)
  FLUTTER_HOME      Flutter SDK 상위 디렉터리 (기본: \$HOME/flutter_linux_${FLUTTER_VERSION}_sdk)

EOF
}

DEPS_ONLY=0
SKIP_DEPS=0
QUICK=0
SKIP_SUBMODULES=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --deps-only) DEPS_ONLY=1 ;;
    --skip-deps) SKIP_DEPS=1 ;;
    --quick) QUICK=1 ;;
    --skip-submodules) SKIP_SUBMODULES=1 ;;
    --help|-h) usage; exit 0 ;;
    *) echo "알 수 없는 인자: $1"; usage; exit 2 ;;
  esac
  shift
done

if [[ "$(uname -s)" != "Linux" ]]; then
  echo "이 스크립트는 Linux(Ubuntu/WSL) 전용입니다."
  exit 1
fi

M="$(uname -m)"
case "$M" in
  x86_64)
    DEB_ARCH=amd64
    VCPKG_TRIPLET=x64-linux
    ;;
  aarch64)
    echo "이 스크립트는 현재 x86_64(amd64) 우분투를 기준으로 합니다."
    echo "ARM64 빌드는 flutter-elinux 등 별도 절차가 필요합니다(.github/workflows/flutter-build.yml 참고)."
    exit 1
    ;;
  *)
    echo "지원하지 않는 아키텍처: $M"
    exit 1
    ;;
esac
export DEB_ARCH

if ! command -v sudo >/dev/null 2>&1; then
  echo "sudo 가 필요합니다."
  exit 1
fi

install_apt_deps() {
  echo ">>> APT 의존성 설치..."
  sudo apt-get update -y
  sudo apt-get install -y \
    autoconf \
    autoconf-archive \
    automake \
    autotools-dev \
    bison \
    build-essential \
    ca-certificates \
    clang \
    cmake \
    curl \
    flex \
    gcc \
    g++ \
    git \
    libayatana-appindicator3-dev \
    libasound2-dev \
    libclang-dev \
    libgstreamer1.0-dev \
    libgstreamer-plugins-base1.0-dev \
    libgtk-3-dev \
    libpam0g-dev \
    libpulse-dev \
    libtool \
    libva-dev \
    libxcb-randr0-dev \
    libxcb-shape0-dev \
    libxcb-xfixes0-dev \
    libxdo-dev \
    libxfixes-dev \
    llvm-dev \
    m4 \
    nasm \
    ninja-build \
    pkg-config \
    python3 \
    rpm \
    unzip \
    wget \
    xz-utils \
    zip \
    libssl-dev
  # vcpkg 가 opus 를 빌드하므로 시스템 libopus 헤더와 충돌할 수 있음
  sudo apt-get remove -y libopus-dev 2>/dev/null || true
}

if [[ "$SKIP_DEPS" -eq 0 ]]; then
  install_apt_deps
else
  echo ">>> --skip-deps: APT dependency installation skipped."
fi
if [[ "$DEPS_ONLY" -eq 1 ]]; then
  echo ">>> --deps-only: 완료."
  exit 0
fi

if [[ "$SKIP_SUBMODULES" -eq 0 ]]; then
  echo ">>> git submodule..."
  mapfile -t SUBMODULE_PATHS < <(
    git config --file .gitmodules --get-regexp path 2>/dev/null | awk '{print $2}'
  )
  if [[ "${#SUBMODULE_PATHS[@]}" -eq 0 ]]; then
    echo "    .gitmodules에 등록된 submodule path가 없어 건너뜁니다."
  else
    for submodule_path in "${SUBMODULE_PATHS[@]}"; do
      echo "    updating $submodule_path"
      git submodule update --init --recursive -- "$submodule_path"
    done
  fi
fi

export VCPKG_ROOT="${VCPKG_ROOT:-$HOME/vcpkg-rustdesk}"
if [[ ! -d "$VCPKG_ROOT/.git" ]]; then
  echo ">>> vcpkg 클론: $VCPKG_ROOT (처음 한 번 크기가 큽니다)"
  git clone https://github.com/microsoft/vcpkg "$VCPKG_ROOT"
fi
echo ">>> vcpkg 커밋 체크아웃: $VCPKG_COMMIT"
git -C "$VCPKG_ROOT" fetch origin || true
git -C "$VCPKG_ROOT" checkout -f "$VCPKG_COMMIT"
if [[ ! -f "$VCPKG_ROOT/vcpkg" ]]; then
  "$VCPKG_ROOT/bootstrap-vcpkg.sh" -disableMetrics
fi

echo ">>> vcpkg 패키지 설치 (시간이 오래 걸릴 수 있음)..."
if [[ "$SKIP_DEPS" -eq 0 ]]; then
  sudo apt-get install -y libva-dev
fi
# CI와 동일하게 루트의 vcpkg.json(오버레이) 사용
if ! "$VCPKG_ROOT/vcpkg" install \
  --triplet "$VCPKG_TRIPLET" \
  --x-install-root="$VCPKG_ROOT/installed"; then
  echo "vcpkg install 실패. $VCPKG_ROOT/buildtrees 아래 로그를 확인하세요."
  exit 1
fi

if ! command -v rustup >/dev/null 2>&1; then
  echo ">>> rustup 설치..."
  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
fi
# shellcheck source=/dev/null
[[ -f "$HOME/.cargo/env" ]] && source "$HOME/.cargo/env"

# Cargo.toml rust-version 과 CI 정합
if ! rustup toolchain list | grep -q '1.75'; then
  rustup toolchain install 1.75 --profile minimal
fi
rustup default 1.75
rustup component add rustfmt --toolchain 1.75 2>/dev/null || true

FLUTTER_HOME="${FLUTTER_HOME:-$HOME/flutter_linux_${FLUTTER_VERSION}_sdk}"
mkdir -p "$FLUTTER_HOME"
FLUTTER_SDK="$FLUTTER_HOME/flutter"
if [[ ! -f "$FLUTTER_SDK/bin/flutter" ]]; then
  echo ">>> Flutter ${FLUTTER_VERSION} 다운로드..."
  TMP="/tmp/flutter_linux_${FLUTTER_VERSION}-stable.tar.xz"
  wget -qO "$TMP" "https://storage.googleapis.com/flutter_infra_release/releases/stable/linux/flutter_linux_${FLUTTER_VERSION}-stable.tar.xz"
  tar -C "$FLUTTER_HOME" -xf "$TMP"
  rm -f "$TMP"
fi
export PATH="$FLUTTER_SDK/bin:$PATH"

flutter config --enable-linux-desktop >/dev/null
flutter precache --linux

PATCH="$ROOT/.github/patches/flutter_3.24.4_dropdown_menu_enableFilter.diff"
if [[ -f "$PATCH" ]] && [[ "$FLUTTER_VERSION" == "3.24.5" ]]; then
  echo ">>> Flutter 패치 확인/적용..."
  pushd "$FLUTTER_SDK" >/dev/null
  if git apply --check "$PATCH" >/dev/null 2>&1; then
    git apply "$PATCH"
  elif git apply --reverse --check "$PATCH" >/dev/null 2>&1; then
    echo "    (이미 적용된 패치 — 건너뜀)"
  else
    echo "    경고: Flutter SDK 소스와 패치 context가 맞지 않아 패치를 건너뜁니다."
    echo "    빌드에는 필수 패치가 아니므로 계속 진행합니다."
    echo "    엄격히 실패 처리하려면 STRICT_FLUTTER_PATCH=1 로 실행하세요."
    if [[ "${STRICT_FLUTTER_PATCH:-0}" == "1" ]]; then
      echo "패치 상태를 확인할 수 없습니다. Flutter SDK 버전을 FLUTTER_VERSION=${FLUTTER_VERSION} 과 맞추세요."
      exit 1
    fi
  fi
  popd >/dev/null
fi

if [[ "$QUICK" -eq 1 ]]; then
  CARGO_FEATURES="flutter,unix-file-copy-paste"
else
  CARGO_FEATURES="hwcodec,flutter,unix-file-copy-paste"
fi

echo ">>> cargo build --lib --features $CARGO_FEATURES --release"
export VCPKG_ROOT
cargo build --lib --features "$CARGO_FEATURES" --release

echo ">>> python3 build.py --flutter --skip-cargo (.deb 생성)"
pushd flutter >/dev/null
flutter build linux --release
popd >/dev/null

VERSION="$(python3 - <<'PY'
from pathlib import Path
for line in Path("Cargo.toml").read_text(encoding="utf-8").splitlines():
    if line.startswith("version"):
        print(line.split("=", 1)[1].replace('"', '').strip())
        break
PY
)"
EXTRA_DEPENDS=""
if [[ "${DEB_ARCH}" == "armhf" ]]; then
  EXTRA_DEPENDS=", libatomic1"
fi
PKG_ROOT="$(mktemp -d /tmp/mdesk-deb.XXXXXX)"
OUT_DEB="$ROOT/mdesk-${VERSION}.deb"
mkdir -p \
  "$PKG_ROOT/usr/share/rustdesk" \
  "$PKG_ROOT/usr/share/rustdesk/files/systemd" \
  "$PKG_ROOT/usr/share/icons/hicolor/256x256/apps" \
  "$PKG_ROOT/usr/share/icons/hicolor/scalable/apps" \
  "$PKG_ROOT/usr/share/applications" \
  "$PKG_ROOT/usr/share/polkit-1/actions" \
  "$PKG_ROOT/etc/rustdesk" \
  "$PKG_ROOT/etc/pam.d" \
  "$PKG_ROOT/DEBIAN"
cp -a "$ROOT/flutter/build/linux/x64/release/bundle/." "$PKG_ROOT/usr/share/rustdesk/"
cp "$ROOT/res/rustdesk.service" "$PKG_ROOT/usr/share/rustdesk/files/systemd/"
cp "$ROOT/res/mdesk.png" "$PKG_ROOT/usr/share/icons/hicolor/256x256/apps/mdesk.png"
cp "$ROOT/res/mdesk.svg" "$PKG_ROOT/usr/share/icons/hicolor/scalable/apps/mdesk.svg"
cp "$ROOT/res/mdesk.desktop" "$PKG_ROOT/usr/share/applications/mdesk.desktop"
cp "$ROOT/res/mdesk-link.desktop" "$PKG_ROOT/usr/share/applications/mdesk-link.desktop"
cp "$ROOT/res/startwm.sh" "$PKG_ROOT/etc/rustdesk/"
cp "$ROOT/res/xorg.conf" "$PKG_ROOT/etc/rustdesk/"
cp "$ROOT/res/pam.d/rustdesk.debian" "$PKG_ROOT/etc/pam.d/rustdesk"
printf '#!/bin/sh\n' > "$PKG_ROOT/usr/share/rustdesk/files/polkit"
chmod a+x "$PKG_ROOT/usr/share/rustdesk/files/polkit"
cp -a "$ROOT/res/DEBIAN/." "$PKG_ROOT/DEBIAN/"
find "$PKG_ROOT/DEBIAN" -type f -exec sed -i 's/\r$//' {} +
cat > "$PKG_ROOT/DEBIAN/control" <<EOF
Package: mdesk
Section: net
Priority: optional
Version: ${VERSION}
Architecture: ${DEB_ARCH}
Maintainer: metadatalab <metadtlab@gmail.com>
Homepage: https://www.mdesk.co.kr
Depends: libgtk-3-0, libxcb-randr0, libxdo3, libxfixes3, libxcb-shape0, libxcb-xfixes0, libasound2, libsystemd0, curl, libva2, libva-drm2, libva-x11-2, libgstreamer-plugins-base1.0-0, libpam0g, gstreamer1.0-pipewire${EXTRA_DEPENDS}
Recommends: libayatana-appindicator3-1
Provides: rustdesk
Conflicts: rustdesk
Replaces: rustdesk
Description: A remote control software.

EOF
rm -f "$PKG_ROOT/DEBIAN/md5sums"
(
  cd "$PKG_ROOT"
  find . -type f ! -path './DEBIAN/*' -print0 | sort -z | xargs -0 md5sum | sed 's#  ./#  /#' > DEBIAN/md5sums
)
chmod -R 755 "$PKG_ROOT/DEBIAN"
dpkg-deb --root-owner-group -b "$PKG_ROOT" "$OUT_DEB"
rm -rf "$PKG_ROOT"

echo ">>> 완료. 산출물 예: $ROOT/mdesk-*.deb"
ls -la "$ROOT"/mdesk-*.deb 2>/dev/null || true
echo "번들 실행 파일(압축 해제 없이 테스트): flutter/build/linux/x64/release/bundle/"
