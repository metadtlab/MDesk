#!/usr/bin/env python3

import os
import pathlib
import platform
import zipfile
import urllib.request
import shutil
import hashlib
import argparse
import sys
from pathlib import Path

windows = platform.platform().startswith('Windows')
osx = platform.platform().startswith(
    'Darwin') or platform.platform().startswith("macOS")
hbb_name = 'rustdesk' + ('.exe' if windows else '')
exe_path = 'target/release/' + hbb_name
if windows:
    flutter_build_dir = 'build/windows/x64/runner/Release/'
elif osx:
    flutter_build_dir = 'build/macos/Build/Products/Release/'
else:
    flutter_build_dir = 'build/linux/x64/release/bundle/'
flutter_build_dir_2 = f'flutter/{flutter_build_dir}'
skip_cargo = False


def get_deb_arch() -> str:
    custom_arch = os.environ.get("DEB_ARCH")
    if custom_arch is None:
        return "amd64"
    return custom_arch

def get_deb_extra_depends() -> str:
    custom_arch = os.environ.get("DEB_ARCH")
    if custom_arch == "armhf": # for arm32v7 libsciter-gtk.so
        return ", libatomic1"
    return ""

def system2(cmd):
    exit_code = os.system(cmd)
    if exit_code != 0:
        sys.stderr.write(f"Error occurred when executing: `{cmd}`. Exiting.\n")
        sys.exit(-1)


def get_version():
    with open("Cargo.toml", encoding="utf-8") as fh:
        for line in fh:
            if line.startswith("version"):
                return line.replace("version", "").replace("=", "").replace('"', '').strip()
    return ''


def get_build_number():
    """빌드 번호를 가져오고 자동 증가"""
    build_file = "build_number.txt"
    build_num = 1
    
    # 기존 빌드 번호 읽기
    if os.path.exists(build_file):
        try:
            with open(build_file, 'r') as f:
                build_num = int(f.read().strip()) + 1
        except:
            build_num = 1
    
    # 새 빌드 번호 저장
    with open(build_file, 'w') as f:
        f.write(str(build_num))
    
    return build_num


def get_full_version():
    """전체 버전 (기본버전.빌드번호) 반환"""
    base_version = get_version()
    build_num = get_build_number()
    return f"{base_version}.{build_num}"


def parse_rc_features(feature):
    available_features = {}
    apply_features = {}
    if not feature:
        feature = []

    def platform_check(platforms):
        if windows:
            return 'windows' in platforms
        elif osx:
            return 'osx' in platforms
        else:
            return 'linux' in platforms

    def get_all_features():
        features = []
        for (feat, feat_info) in available_features.items():
            if platform_check(feat_info['platform']):
                features.append(feat)
        return features

    if isinstance(feature, str) and feature.upper() == 'ALL':
        return get_all_features()
    elif isinstance(feature, list):
        if windows:
            # download third party is deprecated, we use github ci instead.
            # feature.append('PrivacyMode')
            pass
        for feat in feature:
            if isinstance(feat, str) and feat.upper() == 'ALL':
                return get_all_features()
            if feat in available_features:
                if platform_check(available_features[feat]['platform']):
                    apply_features[feat] = available_features[feat]
            else:
                print(f'Unrecognized feature {feat}')
        return apply_features
    else:
        raise Exception(f'Unsupported features param {feature}')


def make_parser():
    parser = argparse.ArgumentParser(description='Build script.')
    parser.add_argument(
        '-f',
        '--feature',
        dest='feature',
        metavar='N',
        type=str,
        nargs='+',
        default='',
        help='Integrate features, windows only.'
             'Available: [Not used for now]. Special value is "ALL" and empty "". Default is empty.')
    parser.add_argument('--flutter', action='store_true',
                        help='Build flutter package', default=False)
    parser.add_argument(
        '--hwcodec',
        action='store_true',
        help='Enable feature hwcodec' + (
            '' if windows or osx else ', need libva-dev.')
    )
    parser.add_argument(
        '--vram',
        action='store_true',
        help='Enable feature vram, only available on windows now.'
    )
    parser.add_argument(
        '--portable',
        action='store_true',
        help='Build windows portable'
    )
    parser.add_argument(
        '--unix-file-copy-paste',
        action='store_true',
        help='Build with unix file copy paste feature'
    )
    parser.add_argument(
        '--skip-cargo',
        action='store_true',
        help='Skip cargo build process, only flutter version + Linux supported currently'
    )
    if windows:
        parser.add_argument(
            '--skip-portable-pack',
            action='store_true',
            help='Skip packing, only flutter version + Windows supported'
        )
    parser.add_argument(
        "--package",
        type=str
    )
    if osx:
        parser.add_argument(
            '--screencapturekit',
            action='store_true',
            help='Enable feature screencapturekit'
        )
    return parser


# Generate build script for docker
#
# it assumes all build dependencies are installed in environments
# Note: do not use it in bare metal, or may break build environments
def generate_build_script_for_docker():
    with open("/tmp/build.sh", "w") as f:
        f.write('''
            #!/bin/bash
            # environment
            export CPATH="$(clang -v 2>&1 | grep "Selected GCC installation: " | cut -d' ' -f4-)/include"
            # flutter
            pushd /opt
            wget https://storage.googleapis.com/flutter_infra_release/releases/stable/linux/flutter_linux_3.0.5-stable.tar.xz
            tar -xvf flutter_linux_3.0.5-stable.tar.xz
            export PATH=`pwd`/flutter/bin:$PATH
            popd
            # flutter_rust_bridge
            dart pub global activate ffigen --version 5.0.1
            pushd /tmp && git clone https://github.com/SoLongAndThanksForAllThePizza/flutter_rust_bridge --depth=1 && popd
            pushd /tmp/flutter_rust_bridge/frb_codegen && cargo install --path . && popd
            pushd flutter && flutter pub get && popd
            ~/.cargo/bin/flutter_rust_bridge_codegen --rust-input ./src/flutter_ffi.rs --dart-output ./flutter/lib/generated_bridge.dart
            # install vcpkg
            pushd /opt
            export VCPKG_ROOT=`pwd`/vcpkg
            git clone https://github.com/microsoft/vcpkg
            vcpkg/bootstrap-vcpkg.sh
            popd
            $VCPKG_ROOT/vcpkg install --x-install-root="$VCPKG_ROOT/installed"
            # build rustdesk
            ./build.py --flutter --hwcodec
        ''')
    system2("chmod +x /tmp/build.sh")
    system2("bash /tmp/build.sh")


# Downloading third party resources is deprecated.
# We can use this function in an offline build environment.
# Even in an online environment, we recommend building third-party resources yourself.
def download_extract_features(features, res_dir):
    import re

    proxy = ''

    def req(url):
        if not proxy:
            return url
        else:
            r = urllib.request.Request(url)
            r.set_proxy(proxy, 'http')
            r.set_proxy(proxy, 'https')
            return r

    for (feat, feat_info) in features.items():
        includes = feat_info['include'] if 'include' in feat_info and feat_info['include'] else []
        includes = [re.compile(p) for p in includes]
        excludes = feat_info['exclude'] if 'exclude' in feat_info and feat_info['exclude'] else []
        excludes = [re.compile(p) for p in excludes]

        print(f'{feat} download begin')
        download_filename = feat_info['zip_url'].split('/')[-1]
        checksum_md5_response = urllib.request.urlopen(
            req(feat_info['checksum_url']))
        for line in checksum_md5_response.read().decode('utf-8').splitlines():
            if line.split()[1] == download_filename:
                checksum_md5 = line.split()[0]
                filename, _headers = urllib.request.urlretrieve(feat_info['zip_url'],
                                                                download_filename)
                md5 = hashlib.md5(open(filename, 'rb').read()).hexdigest()
                if checksum_md5 != md5:
                    raise Exception(f'{feat} download failed')
                print(f'{feat} download end. extract bein')
                zip_file = zipfile.ZipFile(filename)
                zip_list = zip_file.namelist()
                for f in zip_list:
                    file_exclude = False
                    for p in excludes:
                        if p.match(f) is not None:
                            file_exclude = True
                            break
                    if file_exclude:
                        continue

                    file_include = False if includes else True
                    for p in includes:
                        if p.match(f) is not None:
                            file_include = True
                            break
                    if file_include:
                        print(f'extract file {f}')
                        zip_file.extract(f, res_dir)
                zip_file.close()
                os.remove(download_filename)
                print(f'{feat} extract end')


def external_resources(flutter, args, res_dir):
    features = parse_rc_features(args.feature)
    if not features:
        return

    print(f'Build with features {list(features.keys())}')
    if os.path.isdir(res_dir) and not os.path.islink(res_dir):
        shutil.rmtree(res_dir)
    elif os.path.exists(res_dir):
        raise Exception(f'Find file {res_dir}, not a directory')
    os.makedirs(res_dir, exist_ok=True)
    download_extract_features(features, res_dir)
    if flutter:
        os.makedirs(flutter_build_dir_2, exist_ok=True)
        for f in pathlib.Path(res_dir).iterdir():
            print(f'{f}')
            if f.is_file():
                shutil.copy2(f, flutter_build_dir_2)
            else:
                shutil.copytree(f, f'{flutter_build_dir_2}{f.stem}')


def get_features(args):
    features = ['inline'] if not args.flutter else []
    if args.hwcodec:
        features.append('hwcodec')
    if args.vram:
        features.append('vram')
    if args.flutter:
        features.append('flutter')
    if args.unix_file_copy_paste:
        features.append('unix-file-copy-paste')
    if osx:
        if args.screencapturekit:
            features.append('screencapturekit')
    print("features:", features)
    return features


def generate_control_file(version):
    control_file_path = "../res/DEBIAN/control"
    system2('/bin/rm -rf %s' % control_file_path)

    content = """Package: rustdesk
Section: net
Priority: optional
Version: %s
Architecture: %s
Maintainer: metadatalab <metadtlab@gmail.com>
Homepage: https://www.mdesk.co.kr
Depends: libgtk-3-0, libxcb-randr0, libxdo3, libxfixes3, libxcb-shape0, libxcb-xfixes0, libasound2, libsystemd0, curl, libva2, libva-drm2, libva-x11-2, libgstreamer-plugins-base1.0-0, libpam0g, gstreamer1.0-pipewire%s
Recommends: libayatana-appindicator3-1
Description: A remote control software.

""" % (version, get_deb_arch(), get_deb_extra_depends())
    file = open(control_file_path, "w")
    file.write(content)
    file.close()


def ffi_bindgen_function_refactor():
    # workaround ffigen
    system2(
        'sed -i "s/ffi.NativeFunction<ffi.Bool Function(DartPort/ffi.NativeFunction<ffi.Uint8 Function(DartPort/g" flutter/lib/generated_bridge.dart')


def build_flutter_deb(version, features):
    if not skip_cargo:
        system2(f'cargo build --features {features} --lib --release')
        ffi_bindgen_function_refactor()
    os.chdir('flutter')
    system2('flutter build linux --release')
    system2('mkdir -p tmpdeb/usr/bin/')
    system2('mkdir -p tmpdeb/usr/share/rustdesk')
    system2('mkdir -p tmpdeb/etc/rustdesk/')
    system2('mkdir -p tmpdeb/etc/pam.d/')
    system2('mkdir -p tmpdeb/usr/share/rustdesk/files/systemd/')
    system2('mkdir -p tmpdeb/usr/share/icons/hicolor/256x256/apps/')
    system2('mkdir -p tmpdeb/usr/share/icons/hicolor/scalable/apps/')
    system2('mkdir -p tmpdeb/usr/share/applications/')
    system2('mkdir -p tmpdeb/usr/share/polkit-1/actions')
    system2('rm tmpdeb/usr/bin/rustdesk || true')
    system2(
        f'cp -r {flutter_build_dir}/* tmpdeb/usr/share/rustdesk/')
    system2(
        'cp ../res/rustdesk.service tmpdeb/usr/share/rustdesk/files/systemd/')
    system2(
        'cp ../res/128x128@2x.png tmpdeb/usr/share/icons/hicolor/256x256/apps/rustdesk.png')
    system2(
        'cp ../res/scalable.svg tmpdeb/usr/share/icons/hicolor/scalable/apps/rustdesk.svg')
    system2(
        'cp ../res/rustdesk.desktop tmpdeb/usr/share/applications/rustdesk.desktop')
    system2(
        'cp ../res/rustdesk-link.desktop tmpdeb/usr/share/applications/rustdesk-link.desktop')
    system2(
        'cp ../res/startwm.sh tmpdeb/etc/rustdesk/')
    system2(
        'cp ../res/xorg.conf tmpdeb/etc/rustdesk/')
    system2(
        'cp ../res/pam.d/rustdesk.debian tmpdeb/etc/pam.d/rustdesk')
    system2(
        "echo \"#!/bin/sh\" >> tmpdeb/usr/share/rustdesk/files/polkit && chmod a+x tmpdeb/usr/share/rustdesk/files/polkit")

    system2('mkdir -p tmpdeb/DEBIAN')
    generate_control_file(version)
    system2('cp -a ../res/DEBIAN/* tmpdeb/DEBIAN/')
    md5_file_folder("tmpdeb/")
    system2('dpkg-deb -b tmpdeb rustdesk.deb;')

    system2('/bin/rm -rf tmpdeb/')
    system2('/bin/rm -rf ../res/DEBIAN/control')
    os.rename('rustdesk.deb', '../rustdesk-%s.deb' % version)
    os.chdir("..")


def build_deb_from_folder(version, binary_folder):
    os.chdir('flutter')
    system2('mkdir -p tmpdeb/usr/bin/')
    system2('mkdir -p tmpdeb/usr/share/rustdesk')
    system2('mkdir -p tmpdeb/usr/share/rustdesk/files/systemd/')
    system2('mkdir -p tmpdeb/usr/share/icons/hicolor/256x256/apps/')
    system2('mkdir -p tmpdeb/usr/share/icons/hicolor/scalable/apps/')
    system2('mkdir -p tmpdeb/usr/share/applications/')
    system2('mkdir -p tmpdeb/usr/share/polkit-1/actions')
    system2('rm tmpdeb/usr/bin/rustdesk || true')
    system2(
        f'cp -r ../{binary_folder}/* tmpdeb/usr/share/rustdesk/')
    system2(
        'cp ../res/rustdesk.service tmpdeb/usr/share/rustdesk/files/systemd/')
    system2(
        'cp ../res/128x128@2x.png tmpdeb/usr/share/icons/hicolor/256x256/apps/rustdesk.png')
    system2(
        'cp ../res/scalable.svg tmpdeb/usr/share/icons/hicolor/scalable/apps/rustdesk.svg')
    system2(
        'cp ../res/rustdesk.desktop tmpdeb/usr/share/applications/rustdesk.desktop')
    system2(
        'cp ../res/rustdesk-link.desktop tmpdeb/usr/share/applications/rustdesk-link.desktop')
    system2(
        "echo \"#!/bin/sh\" >> tmpdeb/usr/share/rustdesk/files/polkit && chmod a+x tmpdeb/usr/share/rustdesk/files/polkit")

    system2('mkdir -p tmpdeb/DEBIAN')
    generate_control_file(version)
    system2('cp -a ../res/DEBIAN/* tmpdeb/DEBIAN/')
    md5_file_folder("tmpdeb/")
    system2('dpkg-deb -b tmpdeb rustdesk.deb;')

    system2('/bin/rm -rf tmpdeb/')
    system2('/bin/rm -rf ../res/DEBIAN/control')
    os.rename('rustdesk.deb', '../rustdesk-%s.deb' % version)
    os.chdir("..")


def build_flutter_dmg(version, features):
    if not skip_cargo:
        # set minimum osx build target, now is 10.14, which is the same as the flutter xcode project
        system2(
            f'MACOSX_DEPLOYMENT_TARGET=10.14 cargo build --features {features} --release')
    # copy dylib
    system2(
        "cp target/release/liblibrustdesk.dylib target/release/librustdesk.dylib")
    os.chdir('flutter')
    system2('flutter build macos --release')
    system2('cp -rf ../target/release/service ./build/macos/Build/Products/Release/RustDesk.app/Contents/MacOS/')
    '''
    system2(
        "create-dmg --volname \"RustDesk Installer\" --window-pos 200 120 --window-size 800 400 --icon-size 100 --app-drop-link 600 185 --icon RustDesk.app 200 190 --hide-extension RustDesk.app rustdesk.dmg ./build/macos/Build/Products/Release/RustDesk.app")
    os.rename("rustdesk.dmg", f"../rustdesk-{version}.dmg")
    '''
    os.chdir("..")


def update_exe_metadata(exe_path):
    """Windows 실행 파일의 메타데이터를 MDesk로 변경"""
    if not windows:
        return
    
    if not os.path.exists(exe_path):
        print(f'Executable not found: {exe_path}')
        return
    
    try:
        # rcedit를 사용하여 실행 파일의 리소스 수정
        # rcedit는 Node.js 기반이므로 npx를 통해 실행
        import subprocess
        
        # rcedit가 설치되어 있는지 확인
        try:
            result = subprocess.run(['npx', '--version'], 
                                  capture_output=True, 
                                  text=True, 
                                  timeout=5)
            if result.returncode != 0:
                print('npx not found, trying alternative method...')
                # 대안: 빌드 전에 Runner.rc를 수정하는 방법은 이미 적용됨
                return
        except:
            print('npx not available, metadata will be updated via Runner.rc modification')
            return
        
        # rcedit를 사용하여 메타데이터 변경
        print(f'Updating metadata for {exe_path}...')
        cmd = ['npx', '-y', 'rcedit', exe_path, 
               '--set-version-string', 'FileDescription', 'MDesk Remote Desktop',
               '--set-version-string', 'ProductName', 'MDesk',
               '--set-version-string', 'InternalName', 'mdesk',
               '--set-version-string', 'OriginalFilename', 'MDesk.exe']
        
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
        if result.returncode != 0:
            print(f'Warning: Failed to update metadata with rcedit: {result.stderr}')
            print('Metadata will be set via Runner.rc modification during build')
        else:
            print(f'Successfully updated metadata for {exe_path}')
                
    except Exception as e:
        print(f'Warning: Could not update metadata with rcedit: {e}')
        print('Metadata will be set via Runner.rc modification during build')
        # 실패해도 빌드는 계속 진행


def modify_runner_rc_for_mdesk():
    """Runner.rc 파일을 MDesk로 임시 수정"""
    if not windows:
        return None
    
    rc_path = 'flutter/windows/runner/Runner.rc'
    backup_path = rc_path + '.backup'
    
    if not os.path.exists(rc_path):
        return None
    
    try:
        # 백업 생성
        if os.path.exists(backup_path):
            os.remove(backup_path)
        shutil.copy2(rc_path, backup_path)
        
        # 파일 읽기 및 수정
        with open(rc_path, 'r', encoding='utf-8') as f:
            content = f.read()
        
        # RustDesk를 MDesk로 변경
        modified_content = content.replace(
            '"RustDesk Remote Desktop"',
            '"MDesk Remote Desktop"'
        ).replace(
            '"RustDesk"',
            '"MDesk"'
        ).replace(
            '"rustdesk.exe"',
            '"MDesk.exe"'
        )
        
        # 파일 쓰기
        with open(rc_path, 'w', encoding='utf-8') as f:
            f.write(modified_content)
        
        print('Temporarily modified Runner.rc for MDesk branding')
        return backup_path
        
    except Exception as e:
        print(f'Warning: Could not modify Runner.rc: {e}')
        return None


def restore_runner_rc(backup_path):
    """Runner.rc 파일 복원"""
    if not backup_path or not os.path.exists(backup_path):
        return
    
    rc_path = backup_path.replace('.backup', '')
    try:
        shutil.copy2(backup_path, rc_path)
        os.remove(backup_path)
        print('Restored Runner.rc from backup')
    except Exception as e:
        print(f'Warning: Could not restore Runner.rc: {e}')


def modify_portable_cargo_toml_for_mdesk():
    """portable Cargo.toml을 MDesk로 임시 수정"""
    if not windows:
        return None
    
    cargo_path = 'libs/portable/Cargo.toml'
    backup_path = cargo_path + '.backup'
    
    if not os.path.exists(cargo_path):
        return None
    
    try:
        # 백업 생성
        if os.path.exists(backup_path):
            os.remove(backup_path)
        shutil.copy2(cargo_path, backup_path)
        
        # 파일 읽기 및 수정
        with open(cargo_path, 'r', encoding='utf-8') as f:
            content = f.read()
        
        # RustDesk를 MDesk로 변경
        modified_content = content.replace(
            'ProductName = "RustDesk"',
            'ProductName = "MDesk"'
        ).replace(
            'FileDescription = "RustDesk Remote Desktop"',
            'FileDescription = "MDesk Remote Desktop"'
        ).replace(
            'OriginalFilename = "rustdesk.exe"',
            'OriginalFilename = "MDesk.exe"'
        ).replace(
            'description = "RustDesk Remote Desktop"',
            'description = "MDesk Remote Desktop"'
        )
        
        # 파일 쓰기
        with open(cargo_path, 'w', encoding='utf-8') as f:
            f.write(modified_content)
        
        print('Temporarily modified portable Cargo.toml for MDesk branding')
        return backup_path
        
    except Exception as e:
        print(f'Warning: Could not modify portable Cargo.toml: {e}')
        return None


def restore_portable_cargo_toml(backup_path):
    """portable Cargo.toml 파일 복원"""
    if not backup_path or not os.path.exists(backup_path):
        return
    
    cargo_path = backup_path.replace('.backup', '')
    try:
        shutil.copy2(backup_path, cargo_path)
        os.remove(backup_path)
        print('Restored portable Cargo.toml from backup')
    except Exception as e:
        print(f'Warning: Could not restore portable Cargo.toml: {e}')


def build_flutter_arch_manjaro(version, features):
    if not skip_cargo:
        system2(f'cargo build --features {features} --lib --release')
    ffi_bindgen_function_refactor()
    os.chdir('flutter')
    system2('flutter build linux --release')
    system2(f'strip {flutter_build_dir}/lib/librustdesk.so')
    os.chdir('../res')
    system2('HBB=`pwd`/.. FLUTTER=1 makepkg -f')


def build_msi(version, dist_dir='rustdesk'):
    """MSI 설치 파일 빌드 (MDesk로 설정)"""
    if not windows:
        print('MSI build is only supported on Windows')
        return
    
    try:
        os.chdir('res/msi')
        # preprocess.py를 MDesk로 실행
        python_cmd = 'python' if windows else 'python3'
        system2(f'{python_cmd} preprocess.py --arp --app-name MDesk -d ../../{dist_dir}')
        
        # MSBuild로 MSI 빌드 (MSBuild가 PATH에 있다고 가정)
        # 실제 빌드는 사용자가 별도로 수행해야 할 수 있음
        print('MSI preprocessing completed. Run MSBuild manually if needed:')
        print('  nuget restore msi.sln')
        print('  msbuild msi.sln -p:Configuration=Release -p:Platform=x64')
        
    except Exception as e:
        print(f'Warning: MSI build failed: {e}')
    finally:
        os.chdir('../..')


def build_flutter_windows(version, features, skip_portable_pack):
    # Runner.rc를 MDesk로 임시 수정 (빌드 전)
    rc_backup = modify_runner_rc_for_mdesk()
    
    try:
        if not skip_cargo:
            system2(f'cargo build --features {features} --lib --release')
            if not os.path.exists("target/release/librustdesk.dll"):
                print("cargo build failed, please check rust source code.")
                exit(-1)
        os.chdir('flutter')
        system2('flutter build windows --release')
        os.chdir('..')
    finally:
        # Runner.rc 복원
        if rc_backup:
            restore_runner_rc(rc_backup)
    shutil.copy2('target/release/deps/dylib_virtual_display.dll',
                 flutter_build_dir_2)
    
    # Update executable metadata to MDesk (before code signing)
    exe_path_for_metadata = os.path.join(flutter_build_dir_2, 'MDesk.exe')
    if os.path.exists(exe_path_for_metadata):
        update_exe_metadata(exe_path_for_metadata)
    
    # Code signing for rustdesk.exe (if certificate is available)
    cert_password = os.environ.get('CERT_PASSWORD') or os.environ.get('P')
    cert_file = os.environ.get('CERT_FILE', 'cert.pfx')
    if cert_password and os.path.exists(cert_file):
        exe_path = os.path.join(flutter_build_dir_2, 'MDesk.exe')
        if os.path.exists(exe_path):
            print(f'Signing {exe_path}...')
            if windows:
                system2(
                    f'signtool sign /a /v /p {cert_password} /f {cert_file} /t http://timestamp.digicert.com "{exe_path}"')
            else:
                print('Code signing is only supported on Windows')
        else:
            print(f'Executable not found: {exe_path}')
    elif cert_password:
        print(f'Certificate file not found: {cert_file}')
    else:
        print('Code signing skipped (set CERT_PASSWORD or P environment variable to enable)')
    
    if skip_portable_pack:
        return
    
    # 포터블 전용 마커 파일 생성 (패커가 압축할 폴더에 생성)
    # 일반 설치 빌드 완료 후, 포터블 패키징 직전에만 생성함
    if os.path.exists(flutter_build_dir_2):
        with open(os.path.join(flutter_build_dir_2, 'is_portable'), 'w') as f:
            f.write('1')
        print(f"Created portable marker: {os.path.join(flutter_build_dir_2, 'is_portable')}")

    # 포터블 빌드를 위한 Cargo.toml 임시 수정
    portable_cargo_backup = modify_portable_cargo_toml_for_mdesk()
    
    try:
        os.chdir('libs/portable')
        system2('pip install -r requirements.txt')
        system2(
            f'python ./generate.py -f ../../{flutter_build_dir_2} -o . -e ../../{flutter_build_dir_2}/MDesk.exe')
    finally:
        # Cargo.toml 복원
        if portable_cargo_backup:
            os.chdir('../..')
            restore_portable_cargo_toml(portable_cargo_backup)
    
    # 빌드 결과물 경로 확인 (workspace 설정에 따라 다를 수 있음)
    portable_exe_src = None
    portable_dir = os.getcwd()
    if os.path.exists(os.path.join(portable_dir, 'target/release/rustdesk-portable-packer.exe')):
        portable_exe_src = os.path.join(portable_dir, 'target/release/rustdesk-portable-packer.exe')
    elif os.path.exists(os.path.join(portable_dir, '../../target/release/rustdesk-portable-packer.exe')):
        portable_exe_src = os.path.abspath(os.path.join(portable_dir, '../../target/release/rustdesk-portable-packer.exe'))
    else:
        # workspace 멤버이므로 루트의 target에 빌드됨
        root_dir = os.path.abspath(os.path.join(portable_dir, '../..'))
        root_target = os.path.join(root_dir, 'target/release/rustdesk-portable-packer.exe')
        if os.path.exists(root_target):
            portable_exe_src = root_target
        else:
            print("Error: rustdesk-portable-packer.exe not found after build")
            print(f"Checked: {os.path.join(portable_dir, 'target/release/rustdesk-portable-packer.exe')}")
            print(f"Checked: {root_target}")
            print("Please check if cargo build completed successfully in libs/portable")
            os.chdir('../..')
            exit(-1)
    
    os.chdir('../..')
    root_dir = os.getcwd()
    portable_exe_dst = os.path.join(root_dir, 'MDesk_portable.exe')
    if os.path.exists(portable_exe_dst):
        os.replace(portable_exe_src, portable_exe_dst)
    else:
        os.rename(portable_exe_src, portable_exe_dst)
    
    # Update metadata for portable executable
    if os.path.exists(portable_exe_dst):
        update_exe_metadata(portable_exe_dst)
    
    print(
        f'output location: {os.path.abspath(os.curdir)}/MDesk_portable.exe')
    
    # 전체 버전 (기본버전.빌드번호) 사용
    full_version = get_full_version()
    install_exe = f'./MDesk-{full_version}-install.exe'
    shutil.copy2('./MDesk_portable.exe', install_exe)
    print(f'Build version: {full_version}')
    
    # Update metadata for install executable
    if os.path.exists(install_exe):
        update_exe_metadata(install_exe)
    
    print(
        f'output location: {os.path.abspath(os.curdir)}/{install_exe}')
    
    # Code signing for install executable (if certificate is available)
    if cert_password and os.path.exists(cert_file):
        if os.path.exists(install_exe):
            print(f'Signing {install_exe}...')
            if windows:
                system2(
                    f'signtool sign /a /v /p {cert_password} /f {cert_file} /t http://timestamp.digicert.com "{install_exe}"')
            else:
                print('Code signing is only supported on Windows')
        else:
            print(f'Install executable not found: {install_exe}')


def main():
    global skip_cargo
    parser = make_parser()
    args = parser.parse_args()

    if os.path.exists(exe_path):
        os.unlink(exe_path)
    if os.path.isfile('/usr/bin/pacman'):
        system2('git checkout src/ui/common.tis')
    version = get_version()
    features = ','.join(get_features(args))
    flutter = args.flutter
    if not flutter:
        python_cmd = 'python' if windows else 'python3'
        system2(f'{python_cmd} res/inline-sciter.py')
    print(args.skip_cargo)
    if args.skip_cargo:
        skip_cargo = True
    portable = args.portable
    package = args.package
    if package:
        build_deb_from_folder(version, package)
        return
    res_dir = 'resources'
    external_resources(flutter, args, res_dir)
    if windows:
        # build virtual display dynamic library
        os.chdir('libs/virtual_display/dylib')
        system2('cargo build --release')
        os.chdir('../../..')

        if flutter:
            build_flutter_windows(version, features, args.skip_portable_pack)
            return
        system2('cargo build --release --features ' + features)
        # system2('upx.exe target/release/rustdesk.exe')
        system2('mv target/release/rustdesk.exe target/release/RustDesk.exe')
        pa = os.environ.get('P')
        if pa:
            # https://certera.com/kb/tutorial-guide-for-safenet-authentication-client-for-code-signing/
            system2(
                f'signtool sign /a /v /p {pa} /debug /f .\\cert.pfx /t http://timestamp.digicert.com  '
                'target\\release\\rustdesk.exe')
        else:
            print('Not signed')
        system2(
            f'cp -rf target/release/RustDesk.exe {res_dir}')
        os.chdir('libs/portable')
        system2('pip3 install -r requirements.txt')
        system2(
            f'python3 ./generate.py -f ../../{res_dir} -o . -e ../../{res_dir}/rustdesk-{version}-win7-install.exe')
        system2('mv ../../{res_dir}/rustdesk-{version}-win7-install.exe ../..')
    elif os.path.isfile('/usr/bin/pacman'):
        # pacman -S -needed base-devel
        system2("sed -i 's/pkgver=.*/pkgver=%s/g' res/PKGBUILD" % version)
        if flutter:
            build_flutter_arch_manjaro(version, features)
        else:
            system2('cargo build --release --features ' + features)
            system2('git checkout src/ui/common.tis')
            system2('strip target/release/rustdesk')
            system2('ln -s res/pacman_install && ln -s res/PKGBUILD')
            system2('HBB=`pwd` makepkg -f')
        system2('mv rustdesk-%s-0-x86_64.pkg.tar.zst rustdesk-%s-manjaro-arch.pkg.tar.zst' % (
            version, version))
        # pacman -U ./rustdesk.pkg.tar.zst
    elif os.path.isfile('/usr/bin/yum'):
        system2('cargo build --release --features ' + features)
        system2('strip target/release/rustdesk')
        system2(
            "sed -i 's/Version:    .*/Version:    %s/g' res/rpm.spec" % version)
        system2('HBB=`pwd` rpmbuild -ba res/rpm.spec')
        system2(
            'mv $HOME/rpmbuild/RPMS/x86_64/rustdesk-%s-0.x86_64.rpm ./rustdesk-%s-fedora28-centos8.rpm' % (
                version, version))
        # yum localinstall rustdesk.rpm
    elif os.path.isfile('/usr/bin/zypper'):
        system2('cargo build --release --features ' + features)
        system2('strip target/release/rustdesk')
        system2(
            "sed -i 's/Version:    .*/Version:    %s/g' res/rpm-suse.spec" % version)
        system2('HBB=`pwd` rpmbuild -ba res/rpm-suse.spec')
        system2(
            'mv $HOME/rpmbuild/RPMS/x86_64/rustdesk-%s-0.x86_64.rpm ./rustdesk-%s-suse.rpm' % (
                version, version))
        # yum localinstall rustdesk.rpm
    else:
        if flutter:
            if osx:
                build_flutter_dmg(version, features)
                pass
            else:
                # system2(
                #     'mv target/release/bundle/deb/rustdesk*.deb ./flutter/rustdesk.deb')
                build_flutter_deb(version, features)
        else:
            system2('cargo bundle --release --features ' + features)
            if osx:
                system2(
                    'strip target/release/bundle/osx/RustDesk.app/Contents/MacOS/rustdesk')
                system2(
                    'cp libsciter.dylib target/release/bundle/osx/RustDesk.app/Contents/MacOS/')
                # https://github.com/sindresorhus/create-dmg
                system2('/bin/rm -rf *.dmg')
                pa = os.environ.get('P')
                if pa:
                    system2('''
    # buggy: rcodesign sign ... path/*, have to sign one by one
    # install rcodesign via cargo install apple-codesign
    #rcodesign sign --p12-file ~/.p12/rustdesk-developer-id.p12 --p12-password-file ~/.p12/.cert-pass --code-signature-flags runtime ./target/release/bundle/osx/RustDesk.app/Contents/MacOS/rustdesk
    #rcodesign sign --p12-file ~/.p12/rustdesk-developer-id.p12 --p12-password-file ~/.p12/.cert-pass --code-signature-flags runtime ./target/release/bundle/osx/RustDesk.app/Contents/MacOS/libsciter.dylib
    #rcodesign sign --p12-file ~/.p12/rustdesk-developer-id.p12 --p12-password-file ~/.p12/.cert-pass --code-signature-flags runtime ./target/release/bundle/osx/RustDesk.app
    # goto "Keychain Access" -> "My Certificates" for below id which starts with "Developer ID Application:"
    codesign -s "Developer ID Application: {0}" --force --options runtime  ./target/release/bundle/osx/RustDesk.app/Contents/MacOS/*
    codesign -s "Developer ID Application: {0}" --force --options runtime  ./target/release/bundle/osx/RustDesk.app
    '''.format(pa))
                system2(
                    'create-dmg "RustDesk %s.dmg" "target/release/bundle/osx/RustDesk.app"' % version)
                os.rename('RustDesk %s.dmg' %
                          version, 'rustdesk-%s.dmg' % version)
                if pa:
                    system2('''
    # https://pyoxidizer.readthedocs.io/en/apple-codesign-0.14.0/apple_codesign.html
    # https://pyoxidizer.readthedocs.io/en/stable/tugger_code_signing.html
    # https://developer.apple.com/developer-id/
    # goto xcode and login with apple id, manager certificates (Developer ID Application and/or Developer ID Installer) online there (only download and double click (install) cer file can not export p12 because no private key)
    #rcodesign sign --p12-file ~/.p12/rustdesk-developer-id.p12 --p12-password-file ~/.p12/.cert-pass --code-signature-flags runtime ./rustdesk-{1}.dmg
    codesign -s "Developer ID Application: {0}" --force --options runtime ./rustdesk-{1}.dmg
    # https://appstoreconnect.apple.com/access/api
    # https://gregoryszorc.com/docs/apple-codesign/stable/apple_codesign_getting_started.html#apple-codesign-app-store-connect-api-key
    # p8 file is generated when you generate api key (can download only once)
    rcodesign notary-submit --api-key-path ../.p12/api-key.json  --staple rustdesk-{1}.dmg
    # verify:  spctl -a -t exec -v /Applications/RustDesk.app
    '''.format(pa, version))
                else:
                    print('Not signed')
            else:
                # build deb package
                system2(
                    'mv target/release/bundle/deb/rustdesk*.deb ./rustdesk.deb')
                system2('dpkg-deb -R rustdesk.deb tmpdeb')
                system2('mkdir -p tmpdeb/usr/share/rustdesk/files/systemd/')
                system2('mkdir -p tmpdeb/usr/share/icons/hicolor/256x256/apps/')
                system2('mkdir -p tmpdeb/usr/share/icons/hicolor/scalable/apps/')
                system2(
                    'cp res/rustdesk.service tmpdeb/usr/share/rustdesk/files/systemd/')
                system2(
                    'cp res/128x128@2x.png tmpdeb/usr/share/icons/hicolor/256x256/apps/rustdesk.png')
                system2(
                    'cp res/scalable.svg tmpdeb/usr/share/icons/hicolor/scalable/apps/rustdesk.svg')
                system2(
                    'cp res/rustdesk.desktop tmpdeb/usr/share/applications/rustdesk.desktop')
                system2(
                    'cp res/rustdesk-link.desktop tmpdeb/usr/share/applications/rustdesk-link.desktop')
                os.system('mkdir -p tmpdeb/etc/rustdesk/')
                os.system('cp -a res/startwm.sh tmpdeb/etc/rustdesk/')
                os.system('mkdir -p tmpdeb/etc/X11/rustdesk/')
                os.system('cp res/xorg.conf tmpdeb/etc/X11/rustdesk/')
                os.system('cp -a DEBIAN/* tmpdeb/DEBIAN/')
                os.system('mkdir -p tmpdeb/etc/pam.d/')
                os.system('cp pam.d/rustdesk.debian tmpdeb/etc/pam.d/rustdesk')
                system2('strip tmpdeb/usr/bin/rustdesk')
                system2('mkdir -p tmpdeb/usr/share/rustdesk')
                system2('mv tmpdeb/usr/bin/rustdesk tmpdeb/usr/share/rustdesk/')
                system2('cp libsciter-gtk.so tmpdeb/usr/share/rustdesk/')
                md5_file_folder("tmpdeb/")
                system2('dpkg-deb -b tmpdeb rustdesk.deb; /bin/rm -rf tmpdeb/')
                os.rename('rustdesk.deb', 'rustdesk-%s.deb' % version)


def md5_file(fn):
    md5 = hashlib.md5(open('tmpdeb/' + fn, 'rb').read()).hexdigest()
    system2('echo "%s  /%s" >> tmpdeb/DEBIAN/md5sums' % (md5, fn))

def md5_file_folder(base_dir):
    base_path = Path(base_dir)
    for file in base_path.rglob('*'):
        if file.is_file() and 'DEBIAN' not in file.parts:
            relative_path = file.relative_to(base_path)
            md5_file(str(relative_path))


if __name__ == "__main__":
    main()
