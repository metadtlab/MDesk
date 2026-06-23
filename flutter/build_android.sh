#!/usr/bin/env bash

MODE=${MODE:=release}
FLAVOR=${FLAVOR:=host}
if [[ "$FLAVOR" != "host" && "$FLAVOR" != "remote" ]]; then
    echo "Invalid FLAVOR: $FLAVOR. Use host or remote."
    exit 1
fi
$ANDROID_NDK_HOME/toolchains/aarch64-linux-android-4.9/prebuilt/linux-x86_64/bin/aarch64-linux-android-strip android/app/src/main/jniLibs/arm64-v8a/*
flutter build apk --flavor "$FLAVOR" --dart-define=ANDROID_APP_ROLE="$FLAVOR" --target-platform android-arm64,android-arm --${MODE} --obfuscate --split-debug-info ./split-debug-info
flutter build apk --flavor "$FLAVOR" --dart-define=ANDROID_APP_ROLE="$FLAVOR" --split-per-abi --target-platform android-arm64,android-arm --${MODE} --obfuscate --split-debug-info ./split-debug-info
flutter build appbundle --flavor "$FLAVOR" --dart-define=ANDROID_APP_ROLE="$FLAVOR" --target-platform android-arm64,android-arm --${MODE} --obfuscate --split-debug-info ./split-debug-info

# build in linux
# $ANDROID_NDK/toolchains/aarch64-linux-android-4.9/prebuilt/linux-x86_64/bin/aarch64-linux-android-strip android/app/src/main/jniLibs/arm64-v8a/*
