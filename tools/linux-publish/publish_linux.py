#!/usr/bin/env python3
"""Prepare a static, signed MDesk APT repository. Never upload secret keys."""
import argparse
import base64
from contextlib import contextmanager
from datetime import datetime, timezone
import email.utils
import fcntl
import gzip
import hashlib
import html
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import uuid
from urllib.parse import urlsplit


def run(*args, cwd=None, capture=True):
    return subprocess.run(args, cwd=cwd, check=True, text=True,
                          stdout=subprocess.PIPE if capture else None).stdout


def sha256(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def write(path, content):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content, encoding='utf-8', newline='\n')


def require(condition, message):
    if not condition:
        raise ValueError(message)


def render_index(base_url, version, filename, fingerprint):
    """Keep the static download page aligned with the public MDesk landing page."""
    directory = Path(__file__).parent
    logo = base64.b64encode((directory / 'assets/mdesk-logo.png').read_bytes()).decode('ascii')
    origin = urlsplit(base_url)
    values = {
        'HOME_URL': f'{origin.scheme}://{origin.netloc}',
        'BASE_URL': base_url,
        'VERSION': version,
        'DISPLAY_VERSION': version.split('+', 1)[0],
        'FILENAME': filename,
        'FINGERPRINT': fingerprint,
    }
    page = (directory / 'index.html.in').read_text(encoding='utf-8')
    for name, value in values.items():
        page = page.replace(f'@{name}@', html.escape(value, quote=True))
    return page.replace('@LOGO_DATA_URL@', 'data:image/png;base64,' + logo)


def load_settings(path):
    settings = json.loads(path.read_text(encoding='utf-8-sig'))
    # These are inserted in shell/APT templates, so keep values unambiguous.
    base = settings['baseUrl'].rstrip('/')
    require(re.fullmatch(r'https://[a-zA-Z0-9.-]+(?::[0-9]+)?(?:/[a-zA-Z0-9_-]+)+', base),
            'baseUrl must be HTTPS with a dedicated path, e.g. https://787.kr/linux')
    require(settings['suite'] == 'noble' and settings['architecture'] == 'amd64',
            'The repository uses the Ubuntu 24.04 build baseline: suite noble, architecture amd64.')
    settings['baseUrl'] = base
    home = Path(settings['gpgHome']).expanduser()
    require(home.is_absolute(), 'gpgHome must be an absolute WSL path or start with ~/')
    require(not str(home).startswith('/mnt/'), 'Keep the private key on the WSL Linux filesystem, outside /mnt/.')
    settings['gpgHome'] = str(home)
    output = Path(settings['outputDirectory']).expanduser()
    settings['outputDirectory'] = str((path.parent / output).resolve())
    fingerprint = settings['signingKey'].replace(' ', '').upper()
    require(not fingerprint or re.fullmatch(r'[A-F0-9]{40}', fingerprint),
            'signingKey must be the complete 40-character primary fingerprint.')
    settings['signingKey'] = fingerprint
    return settings


def gpg(settings, *args, capture=True):
    return run('gpg', '--homedir', settings['gpgHome'], *args, capture=capture)


def fingerprints(listing):
    result = []
    primary = False
    for line in listing.splitlines():
        fields = line.split(':')
        if fields[0] in ('sec', 'pub'):
            primary = True
        elif fields[0] in ('ssb', 'sub'):
            primary = False
        elif fields[0] == 'fpr' and primary:
            result.append(fields[9])
            primary = False
    return result


def check(settings):
    for command in ('gpg', 'gpgv', 'dpkg-deb', 'dpkg', 'apt-ftparchive'):
        require(shutil.which(command), f'Missing {command}. In WSL run: sudo apt-get install python3 gnupg apt-utils')
    require(settings['signingKey'], 'No signing key. Run publish-linux.bat -InitKey once, or set signingKey in the local JSON.')
    require(Path(settings['gpgHome']).is_dir(), 'GPG home is missing. Restore your signing key backup or run -InitKey.')
    listing = gpg(settings, '--batch', '--with-colons', '--list-secret-keys', settings['signingKey'])
    require(fingerprints(listing) == [settings['signingKey']], 'Configured private signing key was not found.')
    print(f"Tools/key OK. Target: {settings['baseUrl']}/  Key: {settings['signingKey']}", flush=True)


def init_key(settings, config):
    require(shutil.which('gpg'), 'Install GnuPG in WSL first: sudo apt-get install gnupg')
    require(not settings['signingKey'], 'A signing key is already configured. Reuse it for updates; do not regenerate it.')
    home = Path(settings['gpgHome'])
    home.mkdir(parents=True, exist_ok=True, mode=0o700)
    home.chmod(0o700)
    old_keys = fingerprints(gpg(settings, '--batch', '--with-colons', '--list-secret-keys'))
    require(not old_keys, f'Existing private keys found: {", ".join(old_keys)}. Set signingKey in {config}; no new key created.')
    print('Create the repository signing key. Choose a strong passphrase in the GPG prompt.\n'
          'Keep a private offline backup of this WSL GPG home; never upload it.', flush=True)
    gpg(settings, '--quick-generate-key', settings['keyIdentity'], 'ed25519', 'sign', '2y', capture=False)
    keys = fingerprints(gpg(settings, '--batch', '--with-colons', '--list-secret-keys'))
    require(len(keys) == 1, 'Could not determine the new primary fingerprint.')
    original = json.loads(config.read_text(encoding='utf-8-sig'))
    original['signingKey'] = keys[0]
    temporary = config.with_suffix('.json.tmp')
    write(temporary, json.dumps(original, ensure_ascii=False, indent=2) + '\n')
    temporary.replace(config)
    print(f'Saved signingKey: {keys[0]}\nPrivate key location (DO NOT UPLOAD): {home}\n'
          'Key expires in two years; extend it and republish the public key before expiry.', flush=True)


def ensure_key(settings, config):
    """Reuse a configured key, or create the dedicated unattended local key once."""
    if settings['signingKey']:
        return
    require(shutil.which('gpg'), 'Missing GnuPG in WSL.')
    home = Path(settings['gpgHome'])
    home.mkdir(parents=True, exist_ok=True, mode=0o700)
    home.chmod(0o700)
    with release_lock(home):
        keys = fingerprints(gpg(settings, '--batch', '--with-colons', '--list-secret-keys'))
        require(len(keys) <= 1, 'Multiple private keys exist. Set signingKey to the intended fingerprint.')
        state = Path(settings['outputDirectory']) / 'latest.json'
        previous_key = json.loads(state.read_text())['signingKey'] if state.exists() else None
        require(not previous_key or keys == [previous_key],
                'Existing repository key is missing or different. Restore the original private key; do not rotate silently.')
        if not keys:
            print('Creating the local automation signing key (WSL home, no passphrase prompt).', flush=True)
            gpg(settings, '--batch', '--pinentry-mode', 'loopback', '--passphrase', '',
                '--quick-generate-key', settings['keyIdentity'], 'ed25519', 'sign', '2y', capture=False)
            keys = fingerprints(gpg(settings, '--batch', '--with-colons', '--list-secret-keys'))
        require(len(keys) == 1, 'Could not select the automation signing key.')
        original = json.loads(config.read_text(encoding='utf-8-sig'))
        original['signingKey'] = settings['signingKey'] = keys[0]
        temporary = config.with_suffix('.json.tmp')
        write(temporary, json.dumps(original, ensure_ascii=False, indent=2) + '\n')
        temporary.replace(config)
        print(f'Automation key ready: {keys[0]} (private key stays in {home})', flush=True)


@contextmanager
def release_lock(output):
    output.mkdir(parents=True, exist_ok=True)
    with (output / '.publish.lock').open('a') as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as error:
            raise ValueError('Another publisher is running for this output directory.') from error
        yield


def publish(settings, deb):
    require(deb.is_file() and deb.suffix == '.deb', 'Select an existing .deb file.')
    package, version, arch = [run('dpkg-deb', '-f', str(deb), field).strip()
                              for field in ('Package', 'Version', 'Architecture')]
    require(package == 'mdesk' and arch == settings['architecture'], 'Expected Package: mdesk, Architecture: amd64.')
    require(re.fullmatch(r'[0-9][A-Za-z0-9.+:~\-]*', version), 'Invalid Debian version.')
    run('dpkg', '--validate-version', version)
    digest = sha256(deb)
    filename = f'mdesk_{version.replace(":", "_")}_{arch}.deb'
    output = Path(settings['outputDirectory'])
    with release_lock(output):
        latest_path = output / 'latest.json'
        previous = None
        if latest_path.exists():
            latest = json.loads(latest_path.read_text(encoding='utf-8'))
            for key in ('baseUrl', 'suite', 'signingKey'):
                require(latest[key] == settings[key], f'{key} changed. Use a separate output directory and plan migration first.')
            previous = (output / latest['repository']).resolve()
            require(previous.is_relative_to((output / 'releases').resolve()) and previous.is_dir(),
                    'Previous release missing/invalid. Restore it before publishing; it preserves older clients/downloads.')
            require(subprocess.run(['dpkg', '--compare-versions', version, 'ge', latest['version']]).returncode == 0,
                    f'Refusing downgrade from {latest["version"]} to {version}.')
            equivalent = subprocess.run(['dpkg', '--compare-versions', version, 'eq', latest['version']]).returncode == 0
            require(not equivalent or (version == latest['version'] and digest == latest['sha256']),
                    f'Version {version} equals the existing APT version. Increment the package Version and rebuild.')
            existing = previous / 'pool/main/m/mdesk' / filename
            require(not existing.exists() or sha256(existing) == digest,
                    f'Version {version} already contains different bytes. Increment the package Version and rebuild.')

        release_id = datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ') + '-' + uuid.uuid4().hex[:8]
        release_dir = output / 'releases' / release_id
        repo = release_dir / 'linux'
        if previous:
            shutil.copytree(previous, repo)
        else:
            repo.mkdir(parents=True)
        # An interrupted run never becomes latest.json, nor changes the prior release.
        pool = repo / 'pool/main/m/mdesk'
        pool.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(deb, pool / filename)
        require(sha256(pool / filename) == digest, 'Input package changed while copying; retry with a finished build.')
        dist = repo / 'dists' / settings['suite']
        index = dist / 'main' / f'binary-{arch}'
        index.mkdir(parents=True, exist_ok=True)
        packages = run('apt-ftparchive', 'packages', 'pool', cwd=repo)
        write(index / 'Packages', packages)
        (index / 'Packages.gz').write_bytes(gzip.compress(packages.encode('utf-8'), mtime=0))
        for name in ('Packages', 'Packages.gz'):
            # APT prefers SHA512 when Release advertises it; provide both.
            for algorithm in ('SHA256', 'SHA512'):
                with (index / name).open('rb') as stream:
                    checksum = hashlib.file_digest(stream, algorithm.lower()).hexdigest()
                by_hash = index / 'by-hash' / algorithm / checksum
                by_hash.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(index / name, by_hash)
        for name in ('Release', 'InRelease', 'Release.gpg'):
            (dist / name).unlink(missing_ok=True)
        release_options = {
            'Origin': 'MDesk', 'Label': 'MDesk', 'Suite': settings['suite'],
            'Codename': settings['suite'], 'Architectures': arch, 'Components': 'main',
            'Acquire-By-Hash': 'yes', 'Description': 'MDesk for Ubuntu 24.04 and 26.04 LTS',
            'Date': email.utils.format_datetime(datetime.now(timezone.utc), usegmt=True),
        }
        options = []
        for key, value in release_options.items():
            options += ['-o', f'APT::FTPArchive::Release::{key}={value}']
        write(dist / 'Release', run('apt-ftparchive', *options, 'release', str(dist)))
        key = settings['signingKey']
        gpg(settings, '--yes', '--local-user', key, '--digest-algo', 'SHA256', '--output',
            str(dist / 'InRelease'), '--clearsign', str(dist / 'Release'), capture=False)
        gpg(settings, '--yes', '--local-user', key, '--digest-algo', 'SHA256', '--armor', '--output',
            str(dist / 'Release.gpg'), '--detach-sign', str(dist / 'Release'), capture=False)
        gpg(settings, '--batch', '--yes', '--export-options', 'export-minimal', '--armor',
            '--output', str(repo / 'mdesk-archive-keyring.asc'), '--export', key, capture=False)
        # A separate exported binary public key is also useful for offline gpgv checks.
        gpg(settings, '--batch', '--yes', '--export-options', 'export-minimal', '--output',
            str(repo / 'mdesk-archive-keyring.gpg'), '--export', key, capture=False)
        run('gpgv', '--keyring', str(repo / 'mdesk-archive-keyring.gpg'), str(dist / 'InRelease'))
        run('gpgv', '--keyring', str(repo / 'mdesk-archive-keyring.gpg'),
            str(dist / 'Release.gpg'), str(dist / 'Release'))
        template = Path(__file__).with_name('install-mdesk.sh.in').read_text(encoding='utf-8')
        installer = template.replace('@BASE_URL@', settings['baseUrl']).replace('@FINGERPRINT@', key)
        write(repo / 'install-mdesk.sh', installer)
        write(repo / 'SIGNING-KEY.txt', key + '\n')
        write(repo / 'mdesk.sources', f'Types: deb\nURIs: {settings["baseUrl"]}\nSuites: noble\n'
              'Components: main\nArchitectures: amd64\nSigned-By: /etc/apt/keyrings/mdesk-archive-keyring.asc\n')
        checksums = ''.join(f'{sha256(path)}  {path.relative_to(repo).as_posix()}\n'
                            for path in sorted(repo.rglob('*')) if path.is_file()
                            and path.name not in ('SHA256SUMS', 'SHA256SUMS.asc', 'index.html'))
        write(repo / 'SHA256SUMS', checksums)
        gpg(settings, '--yes', '--local-user', key, '--digest-algo', 'SHA256', '--armor', '--output',
            str(repo / 'SHA256SUMS.asc'), '--detach-sign', str(repo / 'SHA256SUMS'), capture=False)
        run('gpgv', '--keyring', str(repo / 'mdesk-archive-keyring.gpg'),
            str(repo / 'SHA256SUMS.asc'), str(repo / 'SHA256SUMS'))
        base = settings['baseUrl']
        write(repo / 'index.html', render_index(base, version, filename, key))
        write(release_dir / 'UPLOAD.txt', f'''MDesk Linux release {version}
Public URL: {base}/
Upload ONLY the contents of linux/ to the web directory mapped to that URL.
The .deb is prebuilt; publishing does not rebuild or alter it.

First upload: copy the complete linux/ tree preserving paths.
Updates: retain ALL old pool/ and by-hash/ files. Upload pool/ and by-hash/
first, then Packages/Packages.gz and the other public files. Upload Release
and Release.gpg next, and dists/noble/InRelease LAST using an atomic rename.
Do not delete old files or point the URL at an incomplete upload.
For a file manager without atomic rename, stage the complete tree separately
and have the administrator switch the web directory only after upload finishes.
Keep this local output directory between releases; it retains old packages/hashes.

Serve static files over HTTPS without login, SPA fallback or HTML rewriting.
Use Cache-Control: no-cache for InRelease, Release*, Packages*, key and installer;
long immutable caching is suitable for pool/ and by-hash/.
Test after upload: download install-mdesk.sh from the URL above, install on a
clean Ubuntu 24.04 or 26.04 LTS amd64 machine, then check systemctl is-active rustdesk.
Nothing has been uploaded by this command. No private key is in linux/.
Key fingerprint: {key}
Package SHA256: {digest}
''')
        # Stable Windows-friendly upload location, updated only from a complete release.
        ready = output / 'upload'
        marker = '.mdesk-upload-output'
        require(not ready.exists() or (ready / marker).is_file(), 'Refusing to replace an unmanaged upload folder.')
        staged = output / ('upload.next-' + release_id)
        shutil.copytree(repo, staged / 'linux')
        shutil.copyfile(release_dir / 'UPLOAD.txt', staged / 'UPLOAD.txt')
        write(staged / marker, release_id + '\n')
        backup = output / ('upload.previous-' + release_id)
        if ready.exists():
            try:
                ready.rename(backup)
            except PermissionError as error:
                raise ValueError(f'Cannot replace {ready}. Close Explorer windows/tabs or other programs '
                                 'using the upload folder, then run the publisher again. '
                                 'The previous upload folder was kept.') from error
        try:
            staged.rename(ready)
        except OSError:
            if backup.exists():
                backup.rename(ready)
            raise
        if backup.exists():
            require(backup.resolve().parent == output.resolve() and (backup / marker).is_file(), 'Invalid backup path.')
            shutil.rmtree(backup)
        latest = {key: settings[key] for key in ('baseUrl', 'suite', 'signingKey')}
        latest.update(version=version, sha256=digest, repository=str(repo.relative_to(output)))
        temporary = output / 'latest.json.tmp'
        write(temporary, json.dumps(latest, indent=2) + '\n')
        temporary.replace(latest_path)
        print(f'\nReady to upload: {repo}\nInstructions: {release_dir / "UPLOAD.txt"}\n'
              f'Package: {version}\nSHA256: {digest}\nPublic URL after upload: {base}/\n'
              'Prepared locally only; no server upload was attempted.', flush=True)
        if shutil.which('wslpath'):
            print('Windows upload folder: ' + run('wslpath', '-w', str(ready / 'linux')).strip(), flush=True)


def main():
    require(sys.version_info >= (3, 11), 'Python 3.11+ is required. Use WSL Ubuntu 24.04 or newer.')
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--config', required=True, type=Path)
    parser.add_argument('--auto-key', action='store_true')
    action = parser.add_mutually_exclusive_group(required=True)
    action.add_argument('--check', action='store_true')
    action.add_argument('--init-key', action='store_true')
    action.add_argument('--deb', type=Path)
    args = parser.parse_args()
    if os.isatty(0):
        os.environ['GPG_TTY'] = os.ttyname(0)
    settings = load_settings(args.config.resolve())
    if args.init_key:
        init_key(settings, args.config.resolve())
    else:
        if args.auto_key:
            ensure_key(settings, args.config.resolve())
        check(settings)
        if args.deb:
            publish(settings, args.deb.resolve())


if __name__ == '__main__':
    try:
        main()
    except (ValueError, KeyError, OSError, subprocess.CalledProcessError) as error:
        print(f'Publish failed: {error}', file=sys.stderr)
        sys.exit(1)
