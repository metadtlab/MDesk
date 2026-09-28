#!/usr/bin/env python3
"""Build current Windows sources on native WSL, then prepare the upload folder."""
import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import tomllib

from publish_linux import check, ensure_key, load_settings, publish, release_lock, require, sha256, write


def run(*args, cwd=None, env=None):
    print('>>> ' + ' '.join(map(str, args)), flush=True)
    subprocess.run(list(map(str, args)), cwd=cwd, env=env, check=True)


def output_path(settings, config):
    return (config.parent / settings.get('buildOutputDirectory', 'dist/linux-build')).resolve()


def latest_build(settings, config, repo):
    output = output_path(settings, config)
    pointer = output / 'latest.json'
    if not pointer.exists():
        return None
    latest = json.loads(pointer.read_text(encoding='utf-8'))
    deb = (output / latest['file']).resolve()
    require(deb.is_relative_to(output) and deb.is_file(), 'Last successful .deb is missing. Run build_linux.bat again.')
    require(latest['sourceDirectory'] == str(repo), 'The last build belongs to another source folder. Run build_linux.bat.')
    require(sha256(deb) == latest['sha256'], 'Last build checksum changed. Run build_linux.bat again.')
    return deb


def environment(settings):
    sdk = Path(settings.get('flutterSdk', '~/flutter_linux_3.41.9_sdk/flutter')).expanduser()
    vcpkg = Path(settings.get('vcpkgRoot', '~/vcpkg-rustdesk')).expanduser()
    cargo = Path.home() / '.cargo/bin'
    require((sdk / 'bin/flutter').is_file(), f'Flutter SDK is missing: {sdk}')
    require((cargo / 'cargo').is_file(), f'Rust is missing: {cargo}')
    require((vcpkg / 'installed/x64-linux/lib/libopus.a').is_file(), f'Linux vcpkg dependencies are missing: {vcpkg}')
    for tool in ('rsync', 'cmake', 'ninja', 'clang', 'pkg-config', 'dpkg-deb', 'ldd'):
        require(shutil.which(tool), f'Missing build tool: {tool}')
    env = dict(os.environ)
    for key in ('CARGO_TARGET_DIR', 'CARGO_BUILD_TARGET', 'RUSTFLAGS', 'VCPKG_INSTALLED_ROOT'):
        env.pop(key, None)
    env.update(PATH=f'{sdk}/bin:{cargo}:/usr/local/bin:/usr/bin:/bin',
               VCPKG_ROOT=str(vcpkg), RUSTUP_TOOLCHAIN=settings.get('rustToolchain', 'stable'),
               CARGO_BUILD_JOBS=str(settings.get('buildJobs', 6)))
    return env


def sync_sources(repo, build):
    # rsync --delete is limited to this marked, disposable build mirror.
    require(build.is_absolute() and build.is_relative_to(Path.home() / 'mdesk-builds')
            and build != Path.home() / 'mdesk-builds', 'buildDirectory must be a dedicated folder below ~/mdesk-builds/.')
    require(not build.is_symlink(), 'Build root must not be a symlink.')
    marker = build / '.mdesk-build-mirror.json'
    if build.exists() and not marker.exists():
        require(not any(build.iterdir()), f'Refusing to reuse an unmarked directory: {build}')
    build.mkdir(parents=True, exist_ok=True)
    if marker.exists():
        require(json.loads(marker.read_text())['source'] == str(repo), 'Build mirror belongs to a different source.')
    else:
        write(marker, json.dumps({'source': str(repo)}) + '\n')
    for directory in ('.cargo', 'src', 'libs', 'flutter', 'res'):
        source, target = repo / directory, build / directory
        require(source.is_dir(), f'Missing source directory: {source}')
        require(target.resolve().is_relative_to(build), f'Build directory escapes mirror: {target}')
        run('rsync', '-a', '--delete', '--exclude=.git', '--exclude=target/', '--exclude=build/',
            '--exclude=.dart_tool/', '--exclude=ephemeral/', '--exclude=.plugin_symlinks/',
            '--exclude=__pycache__/', str(source) + '/', str(target) + '/')
    for filename in ('Cargo.toml', 'Cargo.lock', 'build.rs', 'build_number.txt'):
        shutil.copy2(repo / filename, build / filename)
    # Give the Rust build-date generator a fresh timestamp for this release.
    (build / 'build.rs').touch()


def verify_bundle(build, env):
    bundle = build / 'flutter/build/linux/x64/release/bundle'
    require(sha256(bundle / 'lib/librustdesk.so') == sha256(build / 'target/release/liblibrustdesk.so'),
            'Flutter bundle contains an outdated Rust library.')
    for binary in (bundle / 'rustdesk', *sorted((bundle / 'lib').glob('*.so'))):
        result = subprocess.run(['ldd', str(binary)], env=dict(env, LD_LIBRARY_PATH=str(bundle / 'lib')),
                                text=True, capture_output=True, check=True)
        require('not found' not in result.stdout, f'Missing shared library for {binary.name}: {result.stdout}')
    return bundle


def build_package(settings, config, repo):
    require(Path('/etc/os-release').read_text().find('VERSION_ID="24.04"') >= 0,
            'Build on Ubuntu 24.04 for the noble repository.')
    build = Path(settings.get('buildDirectory', '~/mdesk-builds/linux-release')).expanduser()
    # Resolve only after rejecting symlinks; all rsync destination parents stay in this mirror.
    require(not build.is_symlink(), 'Build directory must not be a symlink.')
    build = build.resolve()
    env = environment(settings)
    output = output_path(settings, config)
    with release_lock(output):
        sync_sources(repo, build)
        base = tomllib.loads((build / 'Cargo.toml').read_text())['package']['version']
        number = (build / 'build_number.txt').read_text().strip()
        require(number.isdigit(), 'build_number.txt must contain a number.')
        stamp = datetime.now(timezone.utc).strftime('%Y%m%d%H%M%S%f')
        version = f'{base}.{number}+linux.{stamp}'
        print(f'Building {version} from {repo}', flush=True)
        run('cargo', 'build', '--locked', '--lib', '--features', 'hwcodec,flutter,unix-file-copy-paste',
            '--release', cwd=build, env=env)
        run('flutter', 'build', 'linux', '--release', '--build-name', base, '--build-number', number,
            cwd=build / 'flutter', env=env)
        bundle = verify_bundle(build, env)
        filename = f'MDesk-{version}-ubuntu24.04-amd64.deb'
        with tempfile.TemporaryDirectory(prefix='mdesk-package-') as temporary:
            temporary_deb = Path(temporary) / filename
            run('bash', Path(__file__).with_name('package_linux.sh'), build, version, temporary_deb, env=env)
            extracted = Path(temporary) / 'verify'
            run('dpkg-deb', '-x', temporary_deb, extracted)
            for path in bundle.rglob('*'):
                if path.is_file():
                    require(sha256(path) == sha256(extracted / 'usr/share/rustdesk' / path.relative_to(bundle)),
                            f'Package differs from the built bundle: {path.name}')
            run('apt-get', '-s', 'install', temporary_deb)
            deb = output / filename
            shutil.copy2(temporary_deb, deb)
        manifest = dict(file=filename, version=version, sha256=sha256(deb), sourceDirectory=str(repo),
                        buildDirectory=str(build), builtAt=datetime.now(timezone.utc).isoformat())
        write(output / 'latest.json.tmp', json.dumps(manifest, indent=2) + '\n')
        (output / 'latest.json.tmp').replace(output / 'latest.json')
        print(f'Build verified: {deb}', flush=True)
        return deb


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--config', type=Path, required=True)
    parser.add_argument('--repo', type=Path, required=True)
    parser.add_argument('--publish-latest', action='store_true')
    parser.add_argument('--build-only', action='store_true')
    args = parser.parse_args()
    config, repo = args.config.resolve(), args.repo.resolve()
    settings = load_settings(config)
    if not args.build_only:
        ensure_key(settings, config)
        check(settings)
    deb = latest_build(settings, config, repo) if args.publish_latest else None
    if deb is None:
        deb = build_package(settings, config, repo)
    if not args.build_only:
        publish(settings, deb)


if __name__ == '__main__':
    try:
        main()
    except (ValueError, KeyError, OSError, subprocess.CalledProcessError) as error:
        print(f'Build/publish failed: {error}', file=sys.stderr)
        sys.exit(1)
