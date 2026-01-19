@echo off
setlocal enabledelayedexpansion

echo ============================================
echo MDesk Android Build Script
echo ============================================
echo.

:: Strawberry Perl path (required for OpenSSL)
if exist "D:\IMedix\Rust\strawberry-perl-5.42.0.1-64bit-portable\perl\bin\perl.exe" (
    set "PATH=D:\IMedix\Rust\strawberry-perl-5.42.0.1-64bit-portable\perl\bin;D:\IMedix\Rust\strawberry-perl-5.42.0.1-64bit-portable\c\bin;%PATH%"
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

:: Parse arguments
:parse_args
if "%~1"=="" goto :check_env
if /i "%~1"=="debug" set "BUILD_MODE=debug"
if /i "%~1"=="release" set "BUILD_MODE=release"
if /i "%~1"=="--arm64-only" (
    set "BUILD_ARM64=1"
    set "BUILD_ARM=0"
)
if /i "%~1"=="--arm-only" (
    set "BUILD_ARM64=0"
    set "BUILD_ARM=1"
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

echo   ANDROID_NDK_HOME: %ANDROID_NDK_HOME%
echo   BUILD_MODE: %BUILD_MODE%
echo.

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

:: ARM64 build
if "%BUILD_ARM64%"=="1" (
    echo   Building arm64-v8a ^(aarch64-linux-android^)
    cargo ndk -t aarch64-linux-android -P 21 -o "%JNILIBS_DIR%" -- build --%BUILD_MODE% --features flutter
    if errorlevel 1 (
        echo   [ARM64] Build failed
        goto :error
    )
    echo   [ARM64] Done
    echo.
)

:: ARM32 build
if "%BUILD_ARM%"=="1" (
    echo   Building armeabi-v7a ^(armv7-linux-androideabi^)
    cargo ndk -t armv7-linux-androideabi -P 21 -o "%JNILIBS_DIR%" -- build --%BUILD_MODE% --features flutter
    if errorlevel 1 (
        echo   [ARM32] Build failed
        goto :error
    )
    echo   [ARM32] Done
    echo.
)

:: x86_64 build
if "%BUILD_X64%"=="1" (
    echo   Building x86_64 ^(x86_64-linux-android^)
    cargo ndk -t x86_64-linux-android -P 21 -o "%JNILIBS_DIR%" -- build --%BUILD_MODE% --features flutter
    if errorlevel 1 (
        echo   [x86_64] Build failed
        goto :error
    )
    echo   [x86_64] Done
    echo.
)

:: x86 build
if "%BUILD_X86%"=="1" (
    echo   Building x86 ^(i686-linux-android^)
    cargo ndk -t i686-linux-android -P 21 -o "%JNILIBS_DIR%" -- build --%BUILD_MODE% --features flutter
    if errorlevel 1 (
        echo   [x86] Build failed
        goto :error
    )
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
