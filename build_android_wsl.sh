#!/bin/bash
set -e

echo "============================================"
echo "MDesk Android Build Script (WSL)"
echo "============================================"
echo

# 필수 패키지 확인 및 설치
echo "[0/5] 필수 패키지 확인 중..."
MISSING_PACKAGES=""

for pkg in zip unzip tar curl cmake ninja-build nasm; do
    if ! command -v $pkg &> /dev/null; then
        MISSING_PACKAGES="$MISSING_PACKAGES $pkg"
    fi
done

if [ -n "$MISSING_PACKAGES" ]; then
    echo "  다음 패키지가 필요합니다:$MISSING_PACKAGES"
    echo "  설치 중..."
    sudo apt-get update -qq
    sudo apt-get install -y curl zip unzip tar cmake ninja-build nasm build-essential pkg-config libssl-dev git
    echo "  패키지 설치 완료"
else
    echo "  모든 필수 패키지가 설치되어 있습니다"
fi
echo

# 기존 Android NDK 환경 변수 제거 (Windows 경로 방지)
unset ANDROID_NDK_HOME
unset ANDROID_NDK

# 환경 변수 설정
export ANDROID_SDK_ROOT=/mnt/c/Users/owner/AppData/Local/Android/Sdk
export VCPKG_ROOT=/mnt/d/IMedix/Rust/vcpkg

# Rust 환경 로드
source ~/.cargo/env

# rustdesk 디렉토리로 이동
cd /mnt/d/IMedix/Rust/rustdesk

echo "[1/5] Android NDK 확인 및 설치..."
echo

# WSL용 NDK 경로 (Linux용)
NDK_VERSION="27.0.12077973"
NDK_DIR="$HOME/android-ndk"
ANDROID_NDK_HOME="$NDK_DIR/android-ndk-r27c"

# NDK가 없으면 다운로드
if [ ! -d "$ANDROID_NDK_HOME" ]; then
    echo "  Android NDK가 WSL에 없습니다. 다운로드 중..."
    mkdir -p "$NDK_DIR"
    cd "$NDK_DIR"
    
    # Linux용 NDK 다운로드
    NDK_URL="https://dl.google.com/android/repository/android-ndk-r27c-linux.zip"
    
    if [ ! -f "android-ndk-r27c-linux.zip" ]; then
        echo "  NDK 다운로드 중... (약 1GB, 시간이 걸릴 수 있습니다)"
        wget -q --show-progress "$NDK_URL" || curl -L -o android-ndk-r27c-linux.zip "$NDK_URL"
    fi
    
    if [ -f "android-ndk-r27c-linux.zip" ]; then
        echo "  NDK 압축 해제 중..."
        unzip -q android-ndk-r27c-linux.zip
        echo "  NDK 설치 완료"
    else
        echo "ERROR: NDK 다운로드 실패"
        echo "수동으로 다운로드하세요:"
        echo "  wget $NDK_URL"
        echo "  unzip android-ndk-r27c-linux.zip"
        exit 1
    fi
    
    cd /mnt/d/IMedix/Rust/rustdesk
fi

export ANDROID_NDK_HOME="$ANDROID_NDK_HOME"

echo "[2/5] 환경 변수 확인..."
echo "  ANDROID_NDK_HOME: $ANDROID_NDK_HOME"
echo "  ANDROID_SDK_ROOT: $ANDROID_SDK_ROOT"
echo "  VCPKG_ROOT: $VCPKG_ROOT"
echo

# NDK 존재 확인
if [ ! -d "$ANDROID_NDK_HOME" ]; then
    echo "ERROR: Android NDK not found at $ANDROID_NDK_HOME"
    exit 1
fi

# NDK의 clang 경로 확인
if [ ! -f "$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/bin/clang" ]; then
    echo "ERROR: NDK clang not found at $ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/bin/clang"
    echo "NDK가 올바르게 설치되지 않았습니다."
    exit 1
fi

# vcpkg 확인 및 설치 (WSL용)
# 먼저 WSL 홈 디렉토리의 vcpkg 확인
WSL_VCPKG_ROOT="$HOME/vcpkg"

if [ -f "$WSL_VCPKG_ROOT/vcpkg" ]; then
    # WSL에 이미 vcpkg가 설치되어 있음
    export VCPKG_ROOT="$WSL_VCPKG_ROOT"
    echo "  WSL vcpkg found: $VCPKG_ROOT/vcpkg"
elif [ -f "$VCPKG_ROOT/vcpkg.exe" ]; then
    # Windows vcpkg만 있음 - WSL용으로 설치 필요
    echo "  Windows vcpkg.exe는 WSL에서 사용할 수 없습니다."
    echo "  WSL에 Linux용 vcpkg 설치 중..."
    
    if [ ! -d "$WSL_VCPKG_ROOT" ]; then
        echo "  vcpkg 클론 중..."
        cd ~
        git clone https://github.com/microsoft/vcpkg.git
        cd vcpkg
        echo "  vcpkg 빌드 중... (시간이 걸릴 수 있습니다)"
        ./bootstrap-vcpkg.sh
        echo "  vcpkg 설치 완료"
        cd /mnt/d/IMedix/Rust/rustdesk
    elif [ ! -f "$WSL_VCPKG_ROOT/vcpkg" ]; then
        # 디렉토리는 있지만 vcpkg 실행 파일이 없음 - 빌드만 실행
        echo "  vcpkg 디렉토리는 있지만 실행 파일이 없습니다. 빌드 중..."
        cd "$WSL_VCPKG_ROOT"
        ./bootstrap-vcpkg.sh
        echo "  vcpkg 빌드 완료"
        cd /mnt/d/IMedix/Rust/rustdesk
    fi
    
    export VCPKG_ROOT="$WSL_VCPKG_ROOT"
    echo "  VCPKG_ROOT를 $VCPKG_ROOT로 변경했습니다"
elif [ -f "$VCPKG_ROOT/vcpkg" ]; then
    # Linux vcpkg가 이미 있음
    echo "  vcpkg found: $VCPKG_ROOT/vcpkg"
else
    # vcpkg가 전혀 없음 - 설치
    echo "  vcpkg가 없습니다. Linux용 vcpkg 설치 중..."
    
    if [ ! -d "$WSL_VCPKG_ROOT" ]; then
        echo "  vcpkg 클론 중..."
        cd ~
        git clone https://github.com/microsoft/vcpkg.git
        cd vcpkg
        echo "  vcpkg 빌드 중... (시간이 걸릴 수 있습니다)"
        ./bootstrap-vcpkg.sh
        echo "  vcpkg 설치 완료"
        cd /mnt/d/IMedix/Rust/rustdesk
    elif [ ! -f "$WSL_VCPKG_ROOT/vcpkg" ]; then
        # 디렉토리는 있지만 vcpkg 실행 파일이 없음 - 빌드만 실행
        echo "  vcpkg 디렉토리는 있지만 실행 파일이 없습니다. 빌드 중..."
        cd "$WSL_VCPKG_ROOT"
        ./bootstrap-vcpkg.sh
        echo "  vcpkg 빌드 완료"
        cd /mnt/d/IMedix/Rust/rustdesk
    fi
    
    export VCPKG_ROOT="$WSL_VCPKG_ROOT"
    echo "  VCPKG_ROOT를 $VCPKG_ROOT로 설정했습니다"
fi

# 최종 vcpkg 확인
if [ ! -f "$VCPKG_ROOT/vcpkg" ]; then
    echo "ERROR: vcpkg not found at $VCPKG_ROOT"
    echo "수동으로 설치하세요:"
    echo "  cd ~"
    echo "  git clone https://github.com/microsoft/vcpkg.git"
    echo "  cd vcpkg"
    echo "  ./bootstrap-vcpkg.sh"
    exit 1
fi

echo "  Using vcpkg: $VCPKG_ROOT/vcpkg"

# rustdesk 디렉토리로 돌아가기 (vcpkg 설치 중 cd로 이동했을 수 있음)
cd /mnt/d/IMedix/Rust/rustdesk

# flutter/build_android_deps.sh 파일 존재 확인
if [ ! -f "flutter/build_android_deps.sh" ]; then
    echo "ERROR: flutter/build_android_deps.sh not found"
    echo "Current directory: $(pwd)"
    echo "Please run this script from the rustdesk root directory"
    exit 1
fi

# Windows 줄바꿈(CRLF)을 Unix 형식(LF)으로 변환
echo "  줄바꿈 형식 변환 중..."
if command -v dos2unix &> /dev/null; then
    dos2unix flutter/build_android_deps.sh 2>/dev/null || true
else
    sed -i 's/\r$//' flutter/build_android_deps.sh 2>/dev/null || true
fi

echo "[3/5] Android 의존성 빌드 중..."
echo "  이 작업은 30분~1시간 정도 소요될 수 있습니다..."
echo

# Android 의존성 빌드
bash flutter/build_android_deps.sh arm64-v8a

if [ $? -ne 0 ]; then
    echo "ERROR: Android dependencies build failed"
    exit 1
fi

echo
echo "[4/5] Rust 라이브러리 빌드 중..."
echo

# 환경 변수 명시적 설정 (cargo ndk가 올바른 NDK를 사용하도록)
export ANDROID_NDK_HOME="$ANDROID_NDK_HOME"
export ANDROID_NDK="$ANDROID_NDK_HOME"
unset ANDROID_NDK_HOME_WINDOWS 2>/dev/null || true

# 기존 빌드 캐시 정리 (선택사항, 문제가 계속되면 주석 해제)
# echo "  기존 빌드 캐시 정리 중..."
# rm -rf target/aarch64-linux-android
# rm -rf target/armv7-linux-androideabi

# jniLibs 디렉토리 생성
mkdir -p flutter/android/app/src/main/jniLibs/arm64-v8a
mkdir -p flutter/android/app/src/main/jniLibs/armeabi-v7a

# ARM64 빌드
echo "  Building ARM64 (aarch64-linux-android)..."
echo "  Using NDK: $ANDROID_NDK_HOME"
echo "  Clang path: $ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/bin/clang"

# cargo ndk 환경 변수 확인
cargo ndk-env -t aarch64-linux-android -P 21 || true

cargo ndk -t aarch64-linux-android -P 21 -o flutter/android/app/src/main/jniLibs -- build --release --features flutter

if [ $? -ne 0 ]; then
    echo "ERROR: ARM64 build failed"
    exit 1
fi

echo "  ARM64 build completed"
echo

# ARM32 빌드
echo "  Building ARM32 (armv7-linux-androideabi)..."
echo "  Using NDK: $ANDROID_NDK_HOME"
cargo ndk -t armv7-linux-androideabi -P 21 -o flutter/android/app/src/main/jniLibs -- build --release --features flutter

if [ $? -ne 0 ]; then
    echo "ERROR: ARM32 build failed"
    exit 1
fi

echo "  ARM32 build completed"
echo

echo "[5/5] Flutter APK 빌드 준비 완료!"
echo
echo "다음 명령어로 Flutter APK를 빌드하세요:"
echo "  cd flutter"
echo "  flutter clean"
echo "  flutter pub get"
echo "  flutter build apk --release --target-platform android-arm64,android-arm --split-per-abi"
echo
echo "또는 Windows에서:"
echo "  cd flutter"
echo "  flutter clean"
echo "  flutter pub get"
echo "  flutter build apk --release --target-platform android-arm64,android-arm --split-per-abi"
echo

