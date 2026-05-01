@echo off
setlocal EnableExtensions EnableDelayedExpansion

rem TigerVNC Windows build helper.
rem This project does not support Visual Studio builds. Use MinGW or MinGW-w64.
rem
rem Recommended MSYS2 MinGW64 packages:
rem   pacman -S --needed mingw-w64-x86_64-cmake mingw-w64-x86_64-gcc mingw-w64-x86_64-pkgconf mingw-w64-x86_64-make mingw-w64-x86_64-fltk mingw-w64-x86_64-libjpeg-turbo mingw-w64-x86_64-pixman mingw-w64-x86_64-zlib mingw-w64-x86_64-gnutls mingw-w64-x86_64-nettle mingw-w64-x86_64-gettext
rem
rem Usage:
rem   build_windows.bat [bootstrap^|onefile-viewer^|dist-viewer^|viewer^|onefile-server^|dist-server^|static-server^|server^|all^|install^|installer^|winvnc-installer^|clean^|help]
rem
rem Defaults:
rem   onefile-viewer    Build one distributable TigerVNC Viewer executable.
rem   BUILD_DIR         .\build-windows-viewer for onefile-viewer
rem   INSTALL_DIR       .\install-windows
rem   DIST_DIR          .\dist-windows-viewer for onefile-viewer
rem   BUILD_CONFIG      Release
rem   BUILD_WINVNC      ON
rem   BUILD_VIEWER      OFF for server, ON for viewer/installer/all
rem   BUILD_JAVA        OFF
rem
rem Optional environment overrides:
rem   set MSYS2_ROOT=C:\msys64
rem   set MINGW_ARCH=mingw64
rem   set MINGW_PREFIX=C:\msys64\mingw64
rem   set CMAKE_GENERATOR=MSYS Makefiles
rem   set CMAKE_EXTRA_ARGS=-DENABLE_GNUTLS=OFF -DENABLE_NETTLE=OFF
rem   set UPX_ARGS=--best --lzma
rem   set SKIP_UPX=1

set "ACTION=%~1"
if "%ACTION%"=="" set "ACTION=onefile-viewer"

if /I "%ACTION%"=="help" goto usage
if /I "%ACTION%"=="-h" goto usage
if /I "%ACTION%"=="--help" goto usage

set "ACTION_OK=0"
for %%A in (bootstrap viewer dist-viewer onefile-viewer server dist-server static-server onefile-server all install installer winvnc-installer clean) do (
  if /I "%ACTION%"=="%%A" set "ACTION_OK=1"
)
if not "%ACTION_OK%"=="1" (
  echo [ERROR] Unknown action: %ACTION%
  echo.
  goto usage
)

cd /d "%~dp0"
set "SRC_DIR=%CD%"
set "ORIGINAL_PATH=%PATH%"

if /I "%ACTION%"=="static-server" (
  if not defined BUILD_DIR set "BUILD_DIR=%SRC_DIR%\build-windows-static"
  if not defined DIST_DIR set "DIST_DIR=%SRC_DIR%\dist-windows-server-static"
  if not defined BUILD_STATIC set "BUILD_STATIC=ON"
  if not defined BUILD_VIEWER set "BUILD_VIEWER=OFF"
  if not defined ENABLE_NLS set "ENABLE_NLS=OFF"
  if not defined ENABLE_GNUTLS set "ENABLE_GNUTLS=OFF"
  if not defined ENABLE_NETTLE set "ENABLE_NETTLE=OFF"
  if not defined ENABLE_H264 set "ENABLE_H264=OFF"
)

if /I "%ACTION%"=="onefile-server" (
  if not defined BUILD_DIR set "BUILD_DIR=%SRC_DIR%\build-windows-static"
  if not defined DIST_DIR set "DIST_DIR=%SRC_DIR%\dist-windows-server-static"
  if not defined ONEFILE_DIR set "ONEFILE_DIR=%SRC_DIR%\dist-windows-onefile"
  if not defined BUILD_STATIC set "BUILD_STATIC=ON"
  if not defined BUILD_VIEWER set "BUILD_VIEWER=OFF"
  if not defined ENABLE_NLS set "ENABLE_NLS=OFF"
  if not defined ENABLE_GNUTLS set "ENABLE_GNUTLS=OFF"
  if not defined ENABLE_NETTLE set "ENABLE_NETTLE=OFF"
  if not defined ENABLE_H264 set "ENABLE_H264=OFF"
)

if /I "%ACTION%"=="dist-viewer" (
  if not defined BUILD_DIR set "BUILD_DIR=%SRC_DIR%\build-windows-viewer"
  if not defined DIST_DIR set "DIST_DIR=%SRC_DIR%\dist-windows-viewer"
  if not defined BUILD_WINVNC set "BUILD_WINVNC=OFF"
  if not defined BUILD_VIEWER set "BUILD_VIEWER=ON"
  if not defined ENABLE_H264 set "ENABLE_H264=OFF"
)

if /I "%ACTION%"=="onefile-viewer" (
  if not defined BUILD_DIR set "BUILD_DIR=%SRC_DIR%\build-windows-viewer"
  if not defined DIST_DIR set "DIST_DIR=%SRC_DIR%\dist-windows-viewer"
  if not defined ONEFILE_DIR set "ONEFILE_DIR=%SRC_DIR%\dist-windows-viewer-onefile"
  if not defined BUILD_WINVNC set "BUILD_WINVNC=OFF"
  if not defined BUILD_VIEWER set "BUILD_VIEWER=ON"
  if not defined ENABLE_H264 set "ENABLE_H264=OFF"
)

if not defined BUILD_DIR set "BUILD_DIR=%SRC_DIR%\build-windows"
if not defined INSTALL_DIR set "INSTALL_DIR=%SRC_DIR%\install-windows"
if not defined DIST_DIR set "DIST_DIR=%SRC_DIR%\dist-windows-server"
if not defined BUILD_CONFIG (
  if defined CONFIG (
    set "BUILD_CONFIG=%CONFIG%"
  ) else (
    set "BUILD_CONFIG=Release"
  )
)
if not defined BUILD_WINVNC set "BUILD_WINVNC=ON"
if not defined BUILD_VIEWER (
  set "BUILD_VIEWER=OFF"
  if /I "%ACTION%"=="viewer" set "BUILD_VIEWER=ON"
  if /I "%ACTION%"=="all" set "BUILD_VIEWER=ON"
  if /I "%ACTION%"=="installer" set "BUILD_VIEWER=ON"
)
if not defined BUILD_JAVA set "BUILD_JAVA=OFF"
if not defined BUILD_STATIC set "BUILD_STATIC=OFF"
if not defined ENABLE_NLS set "ENABLE_NLS=AUTO"
if not defined ENABLE_GNUTLS set "ENABLE_GNUTLS=AUTO"
if not defined ENABLE_NETTLE set "ENABLE_NETTLE=AUTO"
if not defined ENABLE_H264 set "ENABLE_H264=AUTO"
if not defined JOBS set "JOBS=%NUMBER_OF_PROCESSORS%"
if "%JOBS%"=="" set "JOBS=4"
if not defined UPX_ARGS set "UPX_ARGS=--best --lzma"

if not defined MINGW_ARCH set "MINGW_ARCH=mingw64"
if not defined MSYS2_ROOT if exist "C:\msys64\%MINGW_ARCH%\bin\gcc.exe" set "MSYS2_ROOT=C:\msys64"
if not defined MINGW_PREFIX if defined MSYS2_ROOT set "MINGW_PREFIX=%MSYS2_ROOT%\%MINGW_ARCH%"

set "MSYS_USR_BIN="
if defined MSYS2_ROOT if exist "%MSYS2_ROOT%\usr\bin\sh.exe" set "MSYS_USR_BIN=%MSYS2_ROOT%\usr\bin"

if /I "%ACTION%"=="bootstrap" goto bootstrap

if defined MINGW_PREFIX (
  set "PATH=%MINGW_PREFIX%\bin;%ORIGINAL_PATH%"
  if not defined CMAKE_PREFIX_PATH set "CMAKE_PREFIX_PATH=%MINGW_PREFIX%"
  if not defined PKG_CONFIG_PATH (
    set "PKG_CONFIG_PATH=%MINGW_PREFIX%\lib\pkgconfig;%MINGW_PREFIX%\share\pkgconfig"
  )
)

if not defined CMAKE_GENERATOR (
  if defined MSYS_USR_BIN (
    if exist "%MSYS_USR_BIN%\make.exe" set "CMAKE_GENERATOR=MSYS Makefiles"
  )
)

if not defined CMAKE_GENERATOR (
  where mingw32-make.exe >nul 2>nul
  if not errorlevel 1 set "CMAKE_GENERATOR=MinGW Makefiles"
)

if not defined CMAKE_GENERATOR (
  where ninja.exe >nul 2>nul
  if not errorlevel 1 set "CMAKE_GENERATOR=Ninja"
)

if not defined CMAKE_GENERATOR (
  echo [ERROR] Could not find a supported make program.
  echo Install MSYS2 MinGW64 first:
  echo   build_windows.bat bootstrap
  echo.
  echo Or put one of these in PATH:
  echo   mingw32-make.exe
  echo   ninja.exe
  exit /b 1
)

if /I "%CMAKE_GENERATOR%"=="MSYS Makefiles" (
  if defined MINGW_PREFIX if defined MSYS_USR_BIN set "PATH=%MINGW_PREFIX%\bin;%MSYS_USR_BIN%;%ORIGINAL_PATH%"
)

call :require_tool cmake.exe "CMake was not found. Install MSYS2 MinGW CMake or add cmake.exe to PATH." || exit /b 1
call :require_tool gcc.exe "MinGW gcc.exe was not found. Install MinGW-w64 or add it to PATH." || exit /b 1
call :require_tool g++.exe "MinGW g++.exe was not found. Install MinGW-w64 or add it to PATH." || exit /b 1
call :require_tool windres.exe "MinGW windres.exe was not found. Install MinGW-w64 or add it to PATH." || exit /b 1

if /I "%ACTION%"=="installer" call :prepare_inno || exit /b 1
if /I "%ACTION%"=="winvnc-installer" call :prepare_inno || exit /b 1

echo [config] Source      : %SRC_DIR%
echo [config] Build dir   : %BUILD_DIR%
echo [config] Install dir : %INSTALL_DIR%
echo [config] Generator   : %CMAKE_GENERATOR%
echo [config] Config      : %BUILD_CONFIG%
echo [config] Jobs        : %JOBS%
echo [config] Action      : %ACTION%
echo.

cmake -S "%SRC_DIR%" -B "%BUILD_DIR%" -G "%CMAKE_GENERATOR%" ^
  -DCMAKE_BUILD_TYPE="%BUILD_CONFIG%" ^
  -DCMAKE_INSTALL_PREFIX="%INSTALL_DIR%" ^
  -DBUILD_WINVNC="%BUILD_WINVNC%" ^
  -DBUILD_VIEWER="%BUILD_VIEWER%" ^
  -DBUILD_JAVA="%BUILD_JAVA%" ^
  -DBUILD_STATIC="%BUILD_STATIC%" ^
  -DENABLE_NLS="%ENABLE_NLS%" ^
  -DENABLE_GNUTLS="%ENABLE_GNUTLS%" ^
  -DENABLE_NETTLE="%ENABLE_NETTLE%" ^
  -DENABLE_H264="%ENABLE_H264%" ^
  %CMAKE_EXTRA_ARGS%
if errorlevel 1 goto build_failed

if /I "%ACTION%"=="server" goto action_server
if /I "%ACTION%"=="dist-server" goto action_dist_server
if /I "%ACTION%"=="static-server" goto action_static_server
if /I "%ACTION%"=="onefile-server" goto action_onefile_server
if /I "%ACTION%"=="dist-viewer" goto action_dist_viewer
if /I "%ACTION%"=="onefile-viewer" goto action_onefile_viewer
if /I "%ACTION%"=="viewer" goto action_viewer
if /I "%ACTION%"=="all" goto action_all
if /I "%ACTION%"=="install" goto action_install
if /I "%ACTION%"=="installer" goto action_installer
if /I "%ACTION%"=="winvnc-installer" goto action_winvnc_installer
if /I "%ACTION%"=="clean" goto action_clean
goto usage

:action_server
call :build_target winvnc4 || goto build_failed
call :build_target vncconfig || goto build_failed
call :build_target wm_hooks || goto build_failed
goto success_server

:action_dist_server
call :build_target winvnc4 || goto build_failed
call :build_target vncconfig || goto build_failed
call :build_target wm_hooks || goto build_failed
call :copy_server_dist || goto build_failed
goto success_dist_server

:action_static_server
call :build_target winvnc4 || goto build_failed
call :build_target vncconfig || goto build_failed
call :build_target wm_hooks || goto build_failed
call :copy_server_dist || goto build_failed
goto success_static_server

:action_onefile_server
call :build_target winvnc4 || goto build_failed
call :build_target vncconfig || goto build_failed
call :build_target wm_hooks || goto build_failed
call :copy_server_dist || goto build_failed
call :build_onefile_server || goto build_failed
call :compress_latest_onefile "%ONEFILE_DIR%" "TigerVNC-Server-OneFile*.exe" || goto build_failed
goto success_onefile_server

:action_dist_viewer
call :build_target vncviewer || goto build_failed
call :copy_viewer_dist || goto build_failed
goto success_dist_viewer

:action_onefile_viewer
call :build_target vncviewer || goto build_failed
call :copy_viewer_dist || goto build_failed
call :build_onefile_viewer || goto build_failed
call :compress_latest_onefile "%ONEFILE_DIR%" "TigerVNC-Viewer-OneFile*.exe" || goto build_failed
goto success_onefile_viewer

:action_viewer
call :build_target vncviewer || goto build_failed
goto success_viewer

:action_all
cmake --build "%BUILD_DIR%" --config "%BUILD_CONFIG%" --parallel "%JOBS%"
if errorlevel 1 goto build_failed
goto success_all

:action_install
cmake --build "%BUILD_DIR%" --target install --config "%BUILD_CONFIG%" --parallel "%JOBS%"
if errorlevel 1 goto build_failed
goto success_install

:action_installer
call :build_target installer || goto build_failed
call :build_target winvnc_installer || goto build_failed
goto success_installer

:action_winvnc_installer
call :build_target winvnc_installer || goto build_failed
goto success_installer

:action_clean
cmake --build "%BUILD_DIR%" --target clean --config "%BUILD_CONFIG%"
if errorlevel 1 goto build_failed
echo [OK] Clean completed.
exit /b 0

:build_target
set "TARGET_NAME=%~1"
echo [build] %TARGET_NAME%
cmake --build "%BUILD_DIR%" --target "%TARGET_NAME%" --config "%BUILD_CONFIG%" --parallel "%JOBS%"
exit /b %ERRORLEVEL%

:require_tool
where %~1 >nul 2>nul
if errorlevel 1 (
  echo [ERROR] %~2
  exit /b 1
)
exit /b 0

:prepare_inno
if not defined INNO_SETUP_DIR (
  if exist "%ProgramFiles(x86)%\Inno Setup 6\ISCC.exe" set "INNO_SETUP_DIR=%ProgramFiles(x86)%\Inno Setup 6"
)
if not defined INNO_SETUP_DIR (
  if exist "%ProgramFiles%\Inno Setup 6\ISCC.exe" set "INNO_SETUP_DIR=%ProgramFiles%\Inno Setup 6"
)
if defined INNO_SETUP_DIR set "PATH=%INNO_SETUP_DIR%;%PATH%"
where iscc.exe >nul 2>nul
if errorlevel 1 (
  echo [ERROR] Inno Setup iscc.exe was not found. Install Inno Setup or add it to PATH.
  exit /b 1
)
exit /b 0

:copy_server_dist
if not exist "%DIST_DIR%" mkdir "%DIST_DIR%"
copy /Y "%BUILD_DIR%\win\winvnc\winvnc4.exe" "%DIST_DIR%\" >nul
copy /Y "%BUILD_DIR%\win\vncconfig\vncconfig.exe" "%DIST_DIR%\" >nul
copy /Y "%BUILD_DIR%\win\wm_hooks\wm_hooks.dll" "%DIST_DIR%\" >nul
powershell -NoProfile -ExecutionPolicy Bypass -File "%SRC_DIR%\package_windows_server.ps1" -DistDir "%DIST_DIR%" -MingwPrefix "%MINGW_PREFIX%"
exit /b %ERRORLEVEL%

:build_onefile_server
if not defined ONEFILE_DIR set "ONEFILE_DIR=%SRC_DIR%\dist-windows-onefile"
powershell -NoProfile -ExecutionPolicy Bypass -File "%SRC_DIR%\package_windows_onefile.ps1" -SourceDir "%SRC_DIR%" -StaticDistDir "%DIST_DIR%" -OutputDir "%ONEFILE_DIR%" -MingwPrefix "%MINGW_PREFIX%"
exit /b %ERRORLEVEL%

:copy_viewer_dist
if not exist "%DIST_DIR%" mkdir "%DIST_DIR%"
powershell -NoProfile -ExecutionPolicy Bypass -File "%SRC_DIR%\package_windows_viewer.ps1" -BuildDir "%BUILD_DIR%" -DistDir "%DIST_DIR%" -MingwPrefix "%MINGW_PREFIX%"
exit /b %ERRORLEVEL%

:build_onefile_viewer
if not defined ONEFILE_DIR set "ONEFILE_DIR=%SRC_DIR%\dist-windows-viewer-onefile"
powershell -NoProfile -ExecutionPolicy Bypass -File "%SRC_DIR%\package_windows_viewer_onefile.ps1" -SourceDir "%SRC_DIR%" -ViewerDistDir "%DIST_DIR%" -OutputDir "%ONEFILE_DIR%" -MingwPrefix "%MINGW_PREFIX%"
exit /b %ERRORLEVEL%

:compress_latest_onefile
if /I "%SKIP_UPX%"=="1" (
  echo [upx] Skipped because SKIP_UPX=1.
  exit /b 0
)
set "UPX_SEARCH_DIR=%~1"
set "UPX_SEARCH_PATTERN=%~2"
set "UPX_TARGET="
for /f "delims=" %%F in ('dir /b /a-d /o-d "%UPX_SEARCH_DIR%\%UPX_SEARCH_PATTERN%" 2^>nul') do (
  set "UPX_TARGET=%UPX_SEARCH_DIR%\%%F"
  goto compress_latest_onefile_found
)

:compress_latest_onefile_found
if not defined UPX_TARGET (
  echo [ERROR] UPX target was not found: %UPX_SEARCH_DIR%\%UPX_SEARCH_PATTERN%
  exit /b 1
)
call :compress_exe "%UPX_TARGET%"
exit /b %ERRORLEVEL%

:compress_exe
set "UPX_TARGET=%~1"
call :require_tool upx.exe "UPX was not found. Install UPX or set SKIP_UPX=1 to build without compression." || exit /b 1
echo [upx] Compressing: %UPX_TARGET%
upx.exe %UPX_ARGS% "%UPX_TARGET%"
exit /b %ERRORLEVEL%

:bootstrap
where winget.exe >nul 2>nul
if errorlevel 1 (
  echo [ERROR] winget.exe was not found. Install MSYS2 manually from https://www.msys2.org/
  exit /b 1
)

if not defined MSYS2_ROOT set "MSYS2_ROOT=C:\msys64"
if not defined MINGW_PREFIX set "MINGW_PREFIX=%MSYS2_ROOT%\%MINGW_ARCH%"
set "MSYS_USR_BIN=%MSYS2_ROOT%\usr\bin"

if not exist "%MSYS_USR_BIN%\bash.exe" (
  echo [bootstrap] Installing MSYS2 with winget...
  winget install --id MSYS2.MSYS2 -e --accept-package-agreements --accept-source-agreements
  if errorlevel 1 (
    echo [ERROR] MSYS2 installation failed.
    exit /b 1
  )
)

if not exist "%MSYS_USR_BIN%\bash.exe" (
  echo [ERROR] MSYS2 bash.exe was not found at:
  echo   %MSYS_USR_BIN%\bash.exe
  echo Set MSYS2_ROOT if MSYS2 is installed elsewhere.
  exit /b 1
)

echo [bootstrap] Updating MSYS2 package database...
"%MSYS_USR_BIN%\bash.exe" -lc "unset CONFIG; pacman-key --init; pacman-key --populate msys2; pacman -Sy --noconfirm"
if errorlevel 1 (
  echo [ERROR] MSYS2 package database update failed.
  exit /b 1
)

echo [bootstrap] Installing MinGW build dependencies...
"%MSYS_USR_BIN%\bash.exe" -lc "unset CONFIG; pacman -S --needed --noconfirm mingw-w64-x86_64-cmake mingw-w64-x86_64-gcc mingw-w64-x86_64-pkgconf mingw-w64-x86_64-make mingw-w64-x86_64-ninja mingw-w64-x86_64-fltk mingw-w64-x86_64-libjpeg-turbo mingw-w64-x86_64-pixman mingw-w64-x86_64-zlib mingw-w64-x86_64-gnutls mingw-w64-x86_64-nettle mingw-w64-x86_64-gettext"
if errorlevel 1 (
  echo [ERROR] MinGW dependency installation failed.
  exit /b 1
)

echo.
echo [OK] Bootstrap completed.
echo Run:
echo   build_windows.bat onefile-viewer
exit /b 0

:success_server
echo.
echo [OK] Windows server build completed.
echo   %BUILD_DIR%\win\winvnc\winvnc4.exe
echo   %BUILD_DIR%\win\vncconfig\vncconfig.exe
echo   %BUILD_DIR%\win\wm_hooks\wm_hooks.dll
exit /b 0

:success_dist_server
echo.
echo [OK] Windows server distribution completed.
echo   Dist dir: %DIST_DIR%
exit /b 0

:success_static_server
echo.
echo [OK] Static Windows server distribution completed.
echo   Dist dir: %DIST_DIR%
echo   Note: wm_hooks.dll is still a separate Windows hook DLL.
exit /b 0

:success_onefile_server
echo.
echo [OK] One-file Windows server package completed.
echo   %ONEFILE_DIR%\TigerVNC-Server-OneFile.exe
echo   Note: the one-file launcher extracts embedded runtime files before launching WinVNC.
exit /b 0

:success_dist_viewer
echo.
echo [OK] Windows viewer distribution completed.
echo   Dist dir: %DIST_DIR%
exit /b 0

:success_onefile_viewer
echo.
echo [OK] One-file Windows viewer package completed.
echo   Output dir: %ONEFILE_DIR%
echo   Default EXE: %ONEFILE_DIR%\TigerVNC-Viewer-OneFile.exe
echo   If the default EXE is running, a timestamped EXE is created in the same directory.
echo   Note: the one-file launcher extracts embedded runtime files before launching vncviewer.
exit /b 0

:success_viewer
echo.
echo [OK] Windows viewer build completed.
echo   %BUILD_DIR%\vncviewer\vncviewer.exe
exit /b 0

:success_all
echo.
echo [OK] Full Windows build completed.
echo   Build dir: %BUILD_DIR%
exit /b 0

:success_install
echo.
echo [OK] Install completed.
echo   Install dir: %INSTALL_DIR%
exit /b 0

:success_installer
echo.
echo [OK] Installer build completed.
echo   Build dir: %BUILD_DIR%
exit /b 0

:build_failed
echo.
echo [ERROR] Windows build failed.
echo Check the CMake output above. Missing MinGW packages are the most common cause.
exit /b 1

:usage
echo TigerVNC Windows build helper
echo.
echo Usage:
echo   build_windows.bat [bootstrap^|onefile-viewer^|dist-viewer^|viewer^|onefile-server^|dist-server^|static-server^|server^|all^|install^|installer^|winvnc-installer^|clean^|help]
echo.
echo Common examples:
echo   build_windows.bat bootstrap
echo   build_windows.bat
echo   build_windows.bat onefile-viewer
echo   build_windows.bat dist-viewer
echo   build_windows.bat viewer
echo   build_windows.bat onefile-server
echo   build_windows.bat dist-server
echo   build_windows.bat static-server
echo   build_windows.bat server
echo   build_windows.bat winvnc-installer
echo.
echo Environment examples:
echo   set MSYS2_ROOT=C:\msys64
echo   set MINGW_ARCH=mingw64
echo   set BUILD_VIEWER=ON
echo   set BUILD_STATIC=ON
echo   set CMAKE_EXTRA_ARGS=-DENABLE_GNUTLS=OFF -DENABLE_NETTLE=OFF
echo.
exit /b 0
