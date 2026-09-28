#!/usr/bin/env python3
"""Real GPG/APT integration tests; no system source lists or packages are changed."""
import argparse
from functools import partial
import hashlib
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import pwd
import shutil
import subprocess
import tempfile
import threading

PUBLISHER = Path(__file__).with_name('publish_linux.py').resolve()


def command(*args, ok=True, cwd=None):
    result = subprocess.run(args, cwd=cwd, text=True, errors='replace', stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    if (result.returncode == 0) != ok:
        raise AssertionError(f'Unexpected exit {result.returncode}: {args}\n{result.stdout}')
    return result.stdout


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def make_deb(root, version, content='payload', name='mdesk', arch='amd64'):
    package = root / f'package-{version}-{name}-{arch}'
    (package / 'DEBIAN').mkdir(parents=True, exist_ok=True)
    (package / 'usr/share/mdesk-test').mkdir(parents=True, exist_ok=True)
    (package / 'DEBIAN/control').write_text(
        f'Package: {name}\nVersion: {version}\nArchitecture: {arch}\n'
        'Maintainer: Publisher Test <test@example.invalid>\nDescription: Disposable publisher fixture\n')
    (package / 'usr/share/mdesk-test/data').write_text(content)
    deb = root / f'{name}-{version}-{arch}.deb'
    command('dpkg-deb', '--root-owner-group', '-b', str(package), str(deb))
    return deb


class Handler(SimpleHTTPRequestHandler):
    requests = []

    def log_message(self, *_):
        pass

    def do_GET(self):
        self.requests.append(self.path)
        super().do_GET()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--real-deb', type=Path)
    parser.add_argument('--windows-test-directory', type=Path)
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix='mdesk-publish-test-') as temporary:
        root = Path(temporary)
        home = root / 'gnupg'
        home.mkdir(mode=0o700)
        try:
            command('gpg', '--homedir', str(home), '--batch', '--pinentry-mode', 'loopback',
                    '--passphrase', '', '--quick-generate-key', 'Disposable MDesk Test', 'ed25519', 'sign', '1d')
            listing = command('gpg', '--homedir', str(home), '--with-colons', '--list-secret-keys')
            fingerprint = next(line.split(':')[9] for line in listing.splitlines() if line.startswith('fpr:'))
            config = root / 'config.json'
            settings = dict(wslDistribution='Ubuntu', wslUser=pwd.getpwuid(os.getuid()).pw_name,
                            baseUrl='https://787.kr/linux', suite='noble', architecture='amd64',
                            outputDirectory=str(root / 'output'), gpgHome=str(home),
                            signingKey=fingerprint, keyIdentity='Disposable MDesk Test')
            config.write_text(json.dumps(settings))

            auto_home = root / 'auto-gnupg'
            auto_config = root / 'auto-config.json'
            auto_settings = dict(settings, signingKey='', gpgHome=str(auto_home), outputDirectory=str(root / 'auto-output'))
            auto_config.write_text(json.dumps(auto_settings))

            def publish(deb, ok=True):
                return command('python3', str(PUBLISHER), '--config', str(config), '--deb', str(deb), ok=ok)

            def current():
                state = json.loads((root / 'output/latest.json').read_text())
                return root / 'output' / state['repository']

            deb1 = make_deb(root, '1.0.0')
            publish(deb1)
            repo1 = current()
            command('bash', '-n', str(repo1 / 'install-mdesk.sh'))
            command('gpgv', '--keyring', str(repo1 / 'mdesk-archive-keyring.gpg'),
                    str(repo1 / 'dists/noble/Release.gpg'), str(repo1 / 'dists/noble/Release'))
            command('sha256sum', '--check', '--quiet', 'SHA256SUMS', cwd=repo1)
            assert not list(repo1.rglob('private-keys-v1.d'))
            print('PASS: real GPG signatures, exported public key, checksums and installer syntax', flush=True)

            web = root / 'web'
            web.mkdir()
            (web / 'linux').symlink_to(repo1, target_is_directory=True)
            server = ThreadingHTTPServer(('127.0.0.1', 0), partial(Handler, directory=str(web)))
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            try:
                def apt_state(label):
                    state = root / label
                    for path in ('lists/partial', 'cache/archives/partial', 'log', 'downloads'):
                        (state / path).mkdir(parents=True)
                    source = state / 'sources.list'
                    source.write_text(f'deb [signed-by={repo1 / "mdesk-archive-keyring.gpg"}] '
                                      f'http://127.0.0.1:{server.server_port}/linux noble main\n')
                    opts = ['-o', f'Dir::State::lists={state / "lists"}',
                            '-o', f'Dir::State::status={state / "status"}',
                            '-o', f'Dir::Cache={state / "cache"}', '-o', f'Dir::Log={state / "log"}',
                            '-o', f'Dir::Etc::sourcelist={source}', '-o', 'Dir::Etc::sourceparts=-',
                            '-o', f'APT::Sandbox::User={pwd.getpwuid(os.getuid()).pw_name}',
                            '-o', 'Acquire::Languages=none', '-o', 'APT::Update::Error-Mode=any']
                    return state, opts

                state, opts = apt_state('apt-good')
                command('apt-get', *opts, 'update')
                command('apt-get', *opts, 'download', 'mdesk=1.0.0', cwd=state / 'downloads')
                assert digest(next((state / 'downloads').glob('*.deb'))) == digest(deb1)
                requests = [path for path in Handler.requests if '/by-hash/' in path]
                assert requests, Handler.requests
                assert all((repo1 / path.removeprefix('/linux/')).is_file() for path in requests), requests
                print('PASS: real APT over HTTP validates InRelease, fetches by-hash, downloads exact .deb', flush=True)

                inrelease = repo1 / 'dists/noble/InRelease'
                signed = inrelease.read_bytes()
                inrelease.write_bytes(signed.replace(b'Origin: MDesk', b'Origin: Other', 1))
                _, bad_opts = apt_state('apt-bad-signature')
                failure = command('apt-get', *bad_opts, 'update', ok=False)
                assert 'BADSIG' in failure or 'invalid' in failure.lower(), failure
                inrelease.write_bytes(signed)
                package = next((repo1 / 'pool').rglob('*.deb'))
                original = package.read_bytes()
                package.write_bytes(original[:-1] + bytes([original[-1] ^ 1]))
                state, opts = apt_state('apt-bad-package')
                command('apt-get', *opts, 'update')
                failure = command('apt-get', *opts, 'download', 'mdesk=1.0.0', cwd=state / 'downloads', ok=False)
                assert 'Hash Sum mismatch' in failure, failure
                package.write_bytes(original)
                print('PASS: APT rejects modified signed metadata and same-size modified package bytes', flush=True)

                old_pool = {path.relative_to(repo1): digest(path) for path in (repo1 / 'pool').rglob('*.deb')}
                old_hashes = {path.relative_to(repo1): digest(path) for path in repo1.glob('dists/**/by-hash/*/*')}
                publish(make_deb(root, '1.0.1'))
                repo2 = current()
                for path, expected in {**old_pool, **old_hashes}.items():
                    assert digest(repo2 / path) == expected
                (web / 'linux').unlink()
                (web / 'linux').symlink_to(repo2, target_is_directory=True)
                state, opts = apt_state('apt-upgrade')
                command('apt-get', *opts, 'update')
                info = command('apt-cache', *opts, 'policy', 'mdesk')
                assert 'Candidate: 1.0.1' in info, info
                command('apt-get', *opts, 'download', 'mdesk=1.0.0', cwd=state / 'downloads')
                print('PASS: updated APT candidate, old version download and old by-hash retention', flush=True)
            finally:
                server.shutdown()
                server.server_close()
                thread.join(timeout=5)

            pointer = (root / 'output/latest.json').read_bytes()
            failure = publish(make_deb(root, '1.0.1', content='different content'), ok=False)
            assert 'Increment the package Version' in failure, failure
            assert 'Increment the package Version' in publish(make_deb(root, '1.0.1-0'), ok=False)
            assert 'Refusing downgrade' in publish(deb1, ok=False)
            assert 'Expected Package' in publish(make_deb(root, '2.0.0', name='other'), ok=False)
            assert 'Expected Package' in publish(make_deb(root, '2.0.0', arch='arm64'), ok=False)
            assert (root / 'output/latest.json').read_bytes() == pointer
            print('PASS: overwrite/equivalent APT version, downgrade, wrong package and wrong architecture rejected; prior release preserved', flush=True)

            command('python3', str(PUBLISHER), '--config', str(auto_config), '--auto-key', '--deb', str(deb1))
            automatic_key = json.loads(auto_config.read_text())['signingKey']
            assert len(automatic_key) == 40
            command('python3', str(PUBLISHER), '--config', str(auto_config), '--auto-key', '--deb', str(deb1))
            assert json.loads(auto_config.read_text())['signingKey'] == automatic_key
            assert (root / 'auto-output/upload/linux/dists/noble/InRelease').is_file()
            assert (auto_home.stat().st_mode & 0o777) == 0o700
            print('PASS: automatic key creation/reuse, private-home permissions and stable upload folder', flush=True)

            if args.real_deb:
                original_hash = digest(args.real_deb)
                publish(args.real_deb)
                command('sha256sum', '--check', '--quiet', 'SHA256SUMS', cwd=current())
                assert digest(args.real_deb) == original_hash
                print(f'PASS: existing release packaged without changes: {args.real_deb.name} SHA256={original_hash}', flush=True)

            if args.windows_test_directory:
                # Exercise Windows -> WSL with non-ASCII names and spaces on DrvFS.
                target = args.windows_test_directory.resolve() / root.name / '한글 경로'
                target.mkdir(parents=True, exist_ok=True)
                win_settings = dict(settings, outputDirectory=str(target / 'output'))
                win_config = target / 'publish test.json'
                win_config.write_text(json.dumps(win_settings))
                win_deb = target / 'MDesk test.deb'
                shutil.copyfile(deb1, win_deb)
                win_path = lambda path: command('wslpath', '-w', str(path)).strip()
                wrapper = PUBLISHER.with_name('publish-linux.ps1')
                command('powershell.exe', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', win_path(wrapper),
                        '-Config', win_path(win_config), '-Deb', win_path(win_deb))
                assert (target / 'output/latest.json').exists()
                print('PASS: Windows PowerShell launcher -> WSL signing, spaces/Unicode paths and DrvFS output lock', flush=True)
                batch = PUBLISHER.parents[2] / 'publish-linux.bat'
                batch_args = ('cmd.exe', '/d', '/c', win_path(batch), '-Config', win_path(win_config), win_path(win_deb))
                command(*batch_args)
                build_output = target / 'build-output'
                build_output.mkdir()
                shutil.copyfile(win_deb, build_output / 'latest.deb')
                (build_output / 'latest.json').write_text(json.dumps(dict(file='latest.deb', sha256=digest(win_deb),
                    sourceDirectory=str(PUBLISHER.parents[2]))))
                win_settings['buildOutputDirectory'] = str(build_output)
                win_config.write_text(json.dumps(win_settings))
                automatic_args = ('cmd.exe', '/d', '/c', win_path(batch), '-Config', win_path(win_config))
                command(*automatic_args)
                assert (target / 'output/upload/linux/dists/noble/InRelease').exists()
                (build_output / 'latest.deb').write_bytes(b'tampered build')
                failure = command(*automatic_args, ok=False)
                assert 'Last build checksum changed' in failure, failure
                win_settings['signingKey'] = '0' * 40
                win_config.write_text(json.dumps(win_settings))
                failure = command(*batch_args, ok=False)
                assert 'Publish failed' in failure, failure
                print('PASS: .bat forwarding, automatic latest-build selection, tampered-build refusal and failure exit propagation', flush=True)
        finally:
            command('gpgconf', '--homedir', str(home), '--kill', 'gpg-agent')
            if (root / 'auto-gnupg').exists():
                command('gpgconf', '--homedir', str(root / 'auto-gnupg'), '--kill', 'gpg-agent')
    print('ALL CHECKS PASSED. Disposable private key removed; no system packages installed.', flush=True)


if __name__ == '__main__':
    main()
