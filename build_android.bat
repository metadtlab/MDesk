@echo off
setlocal enabledelayedexpansion

set "MSYS2_ROOT=C:\msys64"
set "MSYS2_USR_BIN=%MSYS2_ROOT%\usr\bin"
set "MSYS2_PERL=%MSYS2_USR_BIN%\perl.exe"
set "MSYS2_BASH=%MSYS2_USR_BIN%\bash.exe"
set "STRAWBERRY_PERL=D:\IMedix\Rust\strawberry-perl-5.42.0.1-64bit-portable\perl\bin\perl.exe"
set "STRAWBERRY_C_BIN=D:\IMedix\Rust\strawberry-perl-5.42.0.1-64bit-portable\c\bin"
set "PERL_PROVIDER="

echo ============================================
echo MDesk Android Build Script
echo ============================================
echo.

:: Prefer MSYS2 Perl because OpenSSL Android cross-build expects Unix-style paths.
if exist "%MSYS2_PERL%" (
    set "PATH=%MSYS2_USR_BIN%;%PATH%"
    set "PERL_PROVIDER=MSYS2"
    echo MSYS2 Perl added to PATH
) else if exist "%STRAWBERRY_PERL%" (
    set "PATH=%~dp0;%PATH%"
    set "PATH=%STRAWBERRY_PERL:\perl.exe=%;%STRAWBERRY_C_BIN%;%PATH%"
    set "PERL_PROVIDER=Strawberry"
    echo Strawberry Perl added to PATH
)

:: VCPKG path
if exist "D:\IMedix\Rust\vcpkg\vcpkg.exe" (
    set "VCPKG_ROOT=D:\IMedix\Rust\vcpkg"
    echo VCPKG_ROOT set to D:\IMedix\Rust\vcpkg
)

:: Default settings
set "BUILD_MODE=release"
set "BUILD_ARM64=1"
set "BUILD_ARM=1"
set "BUILD_X64=0"
set "BUILD_X86=0"
set "CARGO_BUILD_FLAG=--release"

:: Parse arguments
:parse_args
if "%~1"=="" goto :check_env
if /i "%~1"=="debug" (
    set "BUILD_MODE=debug"
    set "CARGO_BUILD_FLAG="
)
if /i "%~1"=="release" (
    set "BUILD_MODE=release"
    set "CARGO_BUILD_FLAG=--release"
)
if /i "%~1"=="--arm64-only" (
    set "BUILD_ARM64=1"
    set "BUILD_ARM=0"
    set "BUILD_X64=0"
    set "BUILD_X86=0"
)
if /i "%~1"=="--arm-only" (
    set "BUILD_ARM64=0"
    set "BUILD_ARM=1"
    set "BUILD_X64=0"
    set "BUILD_X86=0"
)
if /i "%~1"=="--x64-only" (
    set "BUILD_ARM64=0"
    set "BUILD_ARM=0"
    set "BUILD_X64=1"
    set "BUILD_X86=0"
)
if /i "%~1"=="--all" (
    set "BUILD_ARM64=1"
    set "BUILD_ARM=1"
    set "BUILD_X64=1"
    set "BUILD_X86=1"
)
if /i "%~1"=="--help" goto :show_help
shift
goto :parse_args

:show_help
echo.
echo Usage: build_android.bat [mode] [options]
echo.
echo Mode:
echo   release       Release mode (default)
echo   debug         Debug mode
echo.
echo Options:
echo   --arm64-only  Build ARM64 only
echo   --arm-only    Build ARM32 only
echo   --x64-only    Build x86_64 only ^(best for emulator^)
echo   --all         Build all architectures
echo   --help        Show this help
echo.
goto :eof

:check_env
echo [1/6] Checking environment...
echo.

:: Check ANDROID_NDK_HOME
if not defined ANDROID_NDK_HOME (
    if defined ANDROID_NDK (
        set "ANDROID_NDK_HOME=%ANDROID_NDK%"
    ) else (
        if exist "%LOCALAPPDATA%\Android\Sdk\ndk" (
            for /d %%i in ("%LOCALAPPDATA%\Android\Sdk\ndk\*") do (
                set "ANDROID_NDK_HOME=%%i"
            )
        )
    )
)

if not defined ANDROID_NDK_HOME (
    echo [ERROR] ANDROID_NDK_HOME is not set.
    echo.
    echo Please install Android NDK and set the environment variable:
    echo   set ANDROID_NDK_HOME=C:\Android\ndk\25.2.9519653
    echo.
    goto :error
)

set "NDK_PREBUILT=%ANDROID_NDK_HOME%\toolchains\llvm\prebuilt\windows-x86_64"
set "NDK_TOOLCHAIN_BIN=%NDK_PREBUILT%\bin"
set "LIBCXX_ARM64=%NDK_PREBUILT%\sysroot\usr\lib\aarch64-linux-android\libc++_shared.so"
set "LIBCXX_ARM=%NDK_PREBUILT%\sysroot\usr\lib\arm-linux-androideabi\libc++_shared.so"
set "LIBCXX_X64=%NDK_PREBUILT%\sysroot\usr\lib\x86_64-linux-android\libc++_shared.so"
set "LIBCXX_X86=%NDK_PREBUILT%\sysroot\usr\lib\i686-linux-android\libc++_shared.so"
set "ANDROID_NDK_HOME_UNIX=%ANDROID_NDK_HOME:\=/%"
set "ANDROID_NDK_HOME=%ANDROID_NDK_HOME_UNIX%"
set "ANDROID_NDK=%ANDROID_NDK_HOME_UNIX%"

echo   ANDROID_NDK_HOME: %ANDROID_NDK_HOME%
echo   BUILD_MODE: %BUILD_MODE%
if defined PERL_PROVIDER (
    echo   PERL_PROVIDER: %PERL_PROVIDER%
) else (
    echo   PERL_PROVIDER: not found in configured locations
)
echo.

if /i "%PERL_PROVIDER%"=="MSYS2" (
    set "WIN_ANDROID_NDK_HOME=%ANDROID_NDK_HOME%"
    set "WIN_REPO_DIR=%~dp0"
    set "WIN_CARGO_BIN=%USERPROFILE%\.cargo\bin"
)

if "%BUILD_X64%"=="1" (
    if /i not "%PERL_PROVIDER%"=="MSYS2" (
        echo [ERROR] x86_64 Android build requires MSYS2 Perl.
        echo.
        echo Install MSYS2 so this path exists:
        echo   %MSYS2_PERL%
        echo.
        echo Strawberry Perl cannot build vendored OpenSSL for Android x86_64
        echo because it does not produce Unix-style paths.
        echo.
        goto :error
    )
    echo   x86_64 MSYS bash build enabled
)

if "%BUILD_X86%"=="1" (
    if /i not "%PERL_PROVIDER%"=="MSYS2" (
        echo [ERROR] x86 Android build requires MSYS2 Perl.
        echo.
        echo Install MSYS2 so this path exists:
        echo   %MSYS2_PERL%
        echo.
        echo Strawberry Perl cannot build vendored OpenSSL for Android x86
        echo because it does not produce Unix-style paths.
        echo.
        goto :error
    )
    echo   x86 MSYS bash build enabled
)

:: rustup installs cargo/rustup here; some CMD sessions do not inherit user PATH
if exist "%USERPROFILE%\.cargo\bin\cargo.exe" (
    set "PATH=%USERPROFILE%\.cargo\bin;%PATH%"
)

:: Check cargo-ndk
echo [2/6] Checking cargo-ndk...
cargo ndk --version >nul 2>&1
if errorlevel 1 (
    echo   Installing cargo-ndk...
    cargo install cargo-ndk
    if errorlevel 1 (
        echo [ERROR] Failed to install cargo-ndk
        goto :error
    )
)
echo   cargo-ndk OK
echo.

:: Add Rust targets
echo [3/6] Adding Rust Android targets...
if "%BUILD_ARM64%"=="1" (
    rustup target add aarch64-linux-android >nul 2>&1
    echo   aarch64-linux-android added
)
if "%BUILD_ARM%"=="1" (
    rustup target add armv7-linux-androideabi >nul 2>&1
    echo   armv7-linux-androideabi added
)
if "%BUILD_X64%"=="1" (
    rustup target add x86_64-linux-android >nul 2>&1
    echo   x86_64-linux-android added
)
if "%BUILD_X86%"=="1" (
    rustup target add i686-linux-android >nul 2>&1
    echo   i686-linux-android added
)
echo.

:: Create jniLibs directory
echo [4/6] Building Rust libraries...
echo.

set "JNILIBS_DIR=%~dp0flutter\android\app\src\main\jniLibs"
if not exist "%JNILIBS_DIR%" mkdir "%JNILIBS_DIR%"
if not exist "%JNILIBS_DIR%\arm64-v8a" mkdir "%JNILIBS_DIR%\arm64-v8a"
if not exist "%JNILIBS_DIR%\armeabi-v7a" mkdir "%JNILIBS_DIR%\armeabi-v7a"
if not exist "%JNILIBS_DIR%\x86_64" mkdir "%JNILIBS_DIR%\x86_64"
if not exist "%JNILIBS_DIR%\x86" mkdir "%JNILIBS_DIR%\x86"
if /i "%PERL_PROVIDER%"=="MSYS2" (
    set "WIN_JNILIBS_DIR=%JNILIBS_DIR%"
)

:: libsodium-sys: GNU make/configure need cmp/diff; libtool breaks CC paths with Windows backslashes in sh
if exist "%MSYS2_ROOT%\usr\bin" (
    set "PATH=%MSYS2_ROOT%\usr\bin;%PATH%"
    echo   Prepended MSYS2 usr\bin to PATH ^(cmp, diff for libsodium build^)
) else (
    echo [WARN] MSYS2 not found at %MSYS2_ROOT%\usr\bin - install MSYS2 or add cmp/diff to PATH.
    echo   https://www.msys2.org/
)

:: ARM64 build
if "%BUILD_ARM64%"=="1" (
    echo   Building arm64-v8a ^(aarch64-linux-android^)
    if /i "%PERL_PROVIDER%"=="MSYS2" (
        "%MSYS2_BASH%" -c "NDK_DIR=$(cygpath -u \"$WIN_ANDROID_NDK_HOME\"); REPO_DIR=$(cygpath -u \"$WIN_REPO_DIR\"); JNILIBS_DIR=$(cygpath -u \"$WIN_JNILIBS_DIR\"); CARGO_BIN=$(cygpath -u \"$WIN_CARGO_BIN\"); TOOLCHAIN_BIN=\"$NDK_DIR/toolchains/llvm/prebuilt/windows-x86_64/bin\"; ARM64_CC=\"$TOOLCHAIN_BIN/clang.exe\"; ARM64_CXX=\"$TOOLCHAIN_BIN/clang++.exe\"; ARM64_LINKER=$(cygpath -w \"$TOOLCHAIN_BIN/aarch64-linux-android21-clang.cmd\"); ARM64_AR=\"$TOOLCHAIN_BIN/llvm-ar.exe\"; ARM64_RANLIB=\"$TOOLCHAIN_BIN/llvm-ranlib.exe\"; ARM64_CLANG_PATH=$(cygpath -w \"$TOOLCHAIN_BIN/clang.exe\"); ARM64_TARGET_FLAG=\"--target=aarch64-linux-android21\"; export ANDROID_NDK_HOME=\"$NDK_DIR\"; export ANDROID_NDK_ROOT=\"$NDK_DIR\"; export CLANG_PATH=\"$ARM64_CLANG_PATH\"; export CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER=\"$ARM64_LINKER\"; export CARGO_TARGET_AARCH64_LINUX_ANDROID_AR=\"$ARM64_AR\"; export BINDGEN_EXTRA_CLANG_ARGS_aarch64_linux_android=\"$ARM64_TARGET_FLAG\"; export PATH=\"$CARGO_BIN:$TOOLCHAIN_BIN:$PATH\"; cd \"$REPO_DIR\"; env 'CC_aarch64-linux-android'=\"$ARM64_CC\" 'CXX_aarch64-linux-android'=\"$ARM64_CXX\" 'AR_aarch64-linux-android'=\"$ARM64_AR\" 'RANLIB_aarch64-linux-android'=\"$ARM64_RANLIB\" 'CFLAGS_aarch64-linux-android'=\"$ARM64_TARGET_FLAG\" 'CXXFLAGS_aarch64-linux-android'=\"$ARM64_TARGET_FLAG\" cargo build --target aarch64-linux-android %CARGO_BUILD_FLAG% --features flutter && cp \"target/aarch64-linux-android/%BUILD_MODE%/liblibrustdesk.so\" \"$JNILIBS_DIR/arm64-v8a/librustdesk.so\""
    ) else (
        set "PATH=%NDK_TOOLCHAIN_BIN%;%PATH%"
        set "CLANG_PATH=%NDK_TOOLCHAIN_BIN%\clang.exe"
        set "BINDGEN_EXTRA_CLANG_ARGS_aarch64_linux_android=--target=aarch64-linux-android21"
        cargo ndk -t aarch64-linux-android -P 21 -o "%JNILIBS_DIR%" -- build %CARGO_BUILD_FLAG% --features flutter
    )
    if errorlevel 1 (
        echo   [ARM64] Build failed
        goto :error
    )
    if exist "%LIBCXX_ARM64%" copy /Y "%LIBCXX_ARM64%" "%JNILIBS_DIR%\arm64-v8a\libc++_shared.so" >nul
    echo   [ARM64] Done
    echo.
)

:: ARM32 build
if "%BUILD_ARM%"=="1" (
    echo   Building armeabi-v7a ^(armv7-linux-androideabi^)
    set "PATH=%NDK_TOOLCHAIN_BIN%;%PATH%"
    set "CLANG_PATH=%NDK_TOOLCHAIN_BIN%\clang.exe"
    set "BINDGEN_EXTRA_CLANG_ARGS_armv7_linux_androideabi=--target=armv7-linux-androideabi21"
    cargo ndk -t armv7-linux-androideabi -P 21 -o "%JNILIBS_DIR%" -- build %CARGO_BUILD_FLAG% --features flutter
    if errorlevel 1 (
        echo   [ARM32] Build failed
        goto :error
    )
    if exist "%LIBCXX_ARM%" copy /Y "%LIBCXX_ARM%" "%JNILIBS_DIR%\armeabi-v7a\libc++_shared.so" >nul
    echo   [ARM32] Done
    echo.
)

:: x86_64 build
if "%BUILD_X64%"=="1" (
    echo   Building x86_64 ^(x86_64-linux-android^)
    if /i "%PERL_PROVIDER%"=="MSYS2" (
        "%MSYS2_BASH%" -c "NDK_DIR=$(cygpath -u \"$WIN_ANDROID_NDK_HOME\"); REPO_DIR=$(cygpath -u \"$WIN_REPO_DIR\"); JNILIBS_DIR=$(cygpath -u \"$WIN_JNILIBS_DIR\"); CARGO_BIN=$(cygpath -u \"$WIN_CARGO_BIN\"); TOOLCHAIN_BIN=\"$NDK_DIR/toolchains/llvm/prebuilt/windows-x86_64/bin\"; X64_CC=\"$TOOLCHAIN_BIN/clang.exe\"; X64_CXX=\"$TOOLCHAIN_BIN/clang++.exe\"; X64_LINKER=$(cygpath -w \"$TOOLCHAIN_BIN/x86_64-linux-android21-clang.cmd\"); X64_AR=\"$TOOLCHAIN_BIN/llvm-ar.exe\"; X64_RANLIB=\"$TOOLCHAIN_BIN/llvm-ranlib.exe\"; X64_TARGET_FLAG=\"--target=x86_64-linux-android21\"; export ANDROID_NDK_HOME=\"$NDK_DIR\"; export ANDROID_NDK_ROOT=\"$NDK_DIR\"; export CLANG_PATH=\"$X64_CC\"; export CARGO_TARGET_X86_64_LINUX_ANDROID_LINKER=\"$X64_LINKER\"; export CARGO_TARGET_X86_64_LINUX_ANDROID_AR=\"$X64_AR\"; export BINDGEN_EXTRA_CLANG_ARGS_x86_64_linux_android=\"$X64_TARGET_FLAG\"; export PATH=\"$CARGO_BIN:$TOOLCHAIN_BIN:$PATH\"; cd \"$REPO_DIR\"; env 'CC_x86_64-linux-android'=\"$X64_CC\" 'CXX_x86_64-linux-android'=\"$X64_CXX\" 'AR_x86_64-linux-android'=\"$X64_AR\" 'RANLIB_x86_64-linux-android'=\"$X64_RANLIB\" 'CFLAGS_x86_64-linux-android'=\"$X64_TARGET_FLAG\" 'CXXFLAGS_x86_64-linux-android'=\"$X64_TARGET_FLAG\" cargo build --target x86_64-linux-android %CARGO_BUILD_FLAG% --features flutter && cp \"target/x86_64-linux-android/%BUILD_MODE%/liblibrustdesk.so\" \"$JNILIBS_DIR/x86_64/librustdesk.so\""
    ) else (
        cargo ndk -t x86_64-linux-android -P 21 -o "%JNILIBS_DIR%" -- build %CARGO_BUILD_FLAG% --features flutter
    )
    if errorlevel 1 (
        echo   [x86_64] Build failed
        goto :error
    )
    if exist "%LIBCXX_X64%" copy /Y "%LIBCXX_X64%" "%JNILIBS_DIR%\x86_64\libc++_shared.so" >nul
    echo   [x86_64] Done
    echo.
)

:: x86 build
if "%BUILD_X86%"=="1" (
    echo   Building x86 ^(i686-linux-android^)
    if /i "%PERL_PROVIDER%"=="MSYS2" (
        "%MSYS2_BASH%" -c "NDK_DIR=$(cygpath -u \"$WIN_ANDROID_NDK_HOME\"); REPO_DIR=$(cygpath -u \"$WIN_REPO_DIR\"); JNILIBS_DIR=$(cygpath -u \"$WIN_JNILIBS_DIR\"); CARGO_BIN=$(cygpath -u \"$WIN_CARGO_BIN\"); TOOLCHAIN_BIN=\"$NDK_DIR/toolchains/llvm/prebuilt/windows-x86_64/bin\"; X86_CC=\"$TOOLCHAIN_BIN/clang.exe\"; X86_CXX=\"$TOOLCHAIN_BIN/clang++.exe\"; X86_LINKER=$(cygpath -w \"$TOOLCHAIN_BIN/i686-linux-android21-clang.cmd\"); X86_AR=\"$TOOLCHAIN_BIN/llvm-ar.exe\"; X86_RANLIB=\"$TOOLCHAIN_BIN/llvm-ranlib.exe\"; X86_TARGET_FLAG=\"--target=i686-linux-android21\"; export ANDROID_NDK_HOME=\"$NDK_DIR\"; export ANDROID_NDK_ROOT=\"$NDK_DIR\"; export CLANG_PATH=\"$X86_CC\"; export CARGO_TARGET_I686_LINUX_ANDROID_LINKER=\"$X86_LINKER\"; export CARGO_TARGET_I686_LINUX_ANDROID_AR=\"$X86_AR\"; export BINDGEN_EXTRA_CLANG_ARGS_i686_linux_android=\"$X86_TARGET_FLAG\"; export PATH=\"$CARGO_BIN:$TOOLCHAIN_BIN:$PATH\"; cd \"$REPO_DIR\"; env 'CC_i686-linux-android'=\"$X86_CC\" 'CXX_i686-linux-android'=\"$X86_CXX\" 'AR_i686-linux-android'=\"$X86_AR\" 'RANLIB_i686-linux-android'=\"$X86_RANLIB\" 'CFLAGS_i686-linux-android'=\"$X86_TARGET_FLAG\" 'CXXFLAGS_i686-linux-android'=\"$X86_TARGET_FLAG\" cargo build --target i686-linux-android %CARGO_BUILD_FLAG% --features flutter && cp \"target/i686-linux-android/%BUILD_MODE%/liblibrustdesk.so\" \"$JNILIBS_DIR/x86/librustdesk.so\""
    ) else (
        cargo ndk -t i686-linux-android -P 21 -o "%JNILIBS_DIR%" -- build %CARGO_BUILD_FLAG% --features flutter
    )
    if errorlevel 1 (
        echo   [x86] Build failed
        goto :error
    )
    if exist "%LIBCXX_X86%" copy /Y "%LIBCXX_X86%" "%JNILIBS_DIR%\x86\libc++_shared.so" >nul
    echo   [x86] Done
    echo.
)

:: Flutter build
echo [5/6] Building Flutter APK...
echo.

cd flutter

:: Set target platforms
set "TARGET_PLATFORMS="
if "%BUILD_ARM64%"=="1" set "TARGET_PLATFORMS=android-arm64"
if "%BUILD_ARM%"=="1" (
    if defined TARGET_PLATFORMS (
        set "TARGET_PLATFORMS=!TARGET_PLATFORMS!,android-arm"
    ) else (
        set "TARGET_PLATFORMS=android-arm"
    )
)
if "%BUILD_X64%"=="1" (
    if defined TARGET_PLATFORMS (
        set "TARGET_PLATFORMS=!TARGET_PLATFORMS!,android-x64"
    ) else (
        set "TARGET_PLATFORMS=android-x64"
    )
)

echo   Target platforms: %TARGET_PLATFORMS%
echo.

:: Flutter pub get
flutter pub get
if errorlevel 1 (
    echo [ERROR] flutter pub get failed
    cd ..
    goto :error
)

:: Build APK
echo   Building APK...
flutter build apk --target-platform %TARGET_PLATFORMS% --%BUILD_MODE%
if errorlevel 1 (
    echo [ERROR] Flutter APK build failed
    cd ..
    goto :error
)

:: Build split APKs
echo   Building split APKs...
flutter build apk --split-per-abi --target-platform %TARGET_PLATFORMS% --%BUILD_MODE%

cd ..

:: Results
echo.
echo [6/6] Build completed!
echo.
echo ============================================
echo Build Results
echo ============================================
echo.

set "APK_DIR=%~dp0flutter\build\app\outputs\flutter-apk"
if exist "%APK_DIR%\app-%BUILD_MODE%.apk" (
    echo   Universal APK: %APK_DIR%\app-%BUILD_MODE%.apk
)
if exist "%APK_DIR%\app-arm64-v8a-%BUILD_MODE%.apk" (
    echo   ARM64 APK: %APK_DIR%\app-arm64-v8a-%BUILD_MODE%.apk
)
if exist "%APK_DIR%\app-armeabi-v7a-%BUILD_MODE%.apk" (
    echo   ARM32 APK: %APK_DIR%\app-armeabi-v7a-%BUILD_MODE%.apk
)
if exist "%APK_DIR%\app-x86_64-%BUILD_MODE%.apk" (
    echo   x64 APK: %APK_DIR%\app-x86_64-%BUILD_MODE%.apk
)

echo.
echo Build Success!
goto :eof

:error
echo.
echo Build Failed!
exit /b 1
