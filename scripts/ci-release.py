#!/usr/bin/env python3
"""Own signing credentials only for the lifetime of a hosted release job."""
import base64
import os
from pathlib import Path
import shlex
import signal
import subprocess
import sys
import tempfile


def cancelled(signum, frame):
    raise KeyboardInterrupt


def run(arguments, environment, capture=True):
    process = subprocess.Popen(arguments, env=environment, start_new_session=True, text=True,
                               stdout=subprocess.PIPE if capture else None,
                               stderr=subprocess.PIPE if capture else None)
    try:
        output, _ = process.communicate()
    except BaseException:
        try:
            os.killpg(process.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            pass
        # The leader exiting does not mean its descendants have stopped.
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        process.wait()
        raise
    if process.returncode:
        # security diagnostics and exception argv can contain credential material.
        raise RuntimeError(f'{Path(arguments[0]).name} {arguments[1]} failed.')
    return output


def main():
    if len(sys.argv) != 2:
        raise ValueError('Usage: ci-release.py VERSION')
    environment = dict(os.environ)
    if any(environment.get(key) != value for key, value in
           [('GITHUB_ACTIONS', 'true'), ('RUNNER_ENVIRONMENT', 'github-hosted'), ('RUNNER_OS', 'macOS')]):
        raise ValueError('CI signing requires a GitHub-hosted macOS runner.')
    keys = ['DEVELOPER_ID_P12_BASE64', 'DEVELOPER_ID_P12_PASSWORD', 'KEYCHAIN_PASSWORD',
            'NOTARY_KEY_P8', 'NOTARY_KEY_ID', 'NOTARY_ISSUER_ID']
    if not all(environment.get(key) for key in keys) or not environment.get('RUNNER_TEMP'):
        raise ValueError('CI signing secrets are incomplete.')
    secrets = {key: environment.pop(key) for key in keys[:4]}
    certificate = base64.b64decode(secrets['DEVELOPER_ID_P12_BASE64'], validate=True)
    if not certificate:
        raise ValueError('Signing certificate is empty.')
    original = shlex.split(run(['security', 'list-keychains', '-d', 'user'], environment))
    if not original:
        raise ValueError('Cannot snapshot the original keychain search list.')
    with tempfile.TemporaryDirectory(prefix='bopify-signing-', dir=environment['RUNNER_TEMP']) as directory:
        root = Path(directory)
        keychain = root / 'signing.keychain-db'
        p12 = root / 'certificate.p12'
        p8 = root / 'notary.p8'
        cleanup_failed = False
        try:
            p12.write_bytes(certificate)
            p8.write_text(secrets['NOTARY_KEY_P8'])
            p12.chmod(0o600)
            p8.chmod(0o600)
            password = secrets['KEYCHAIN_PASSWORD']
            run(['security', 'create-keychain', '-p', password, str(keychain)], environment)
            run(['security', 'set-keychain-settings', '-lut', '21600', str(keychain)], environment)
            run(['security', 'unlock-keychain', '-p', password, str(keychain)], environment)
            run(['security', 'import', str(p12), '-P', secrets['DEVELOPER_ID_P12_PASSWORD'],
                 '-T', '/usr/bin/codesign', '-t', 'cert', '-f', 'pkcs12', '-k', str(keychain)], environment)
            run(['security', 'set-key-partition-list', '-S', 'apple:', '-s', '-k', password,
                 str(keychain)], environment)
            run(['security', 'list-keychains', '-d', 'user', '-s', str(keychain), *original], environment)
            environment['NOTARY_KEY_PATH'] = str(p8)
            run([str(Path(__file__).resolve().with_name('release.sh')), sys.argv[1]], environment, capture=False)
        finally:
            signal.signal(signal.SIGTERM, signal.SIG_IGN)
            signal.signal(signal.SIGINT, signal.SIG_IGN)
            for arguments in [['security', 'list-keychains', '-d', 'user', '-s', *original],
                              *([['security', 'delete-keychain', str(keychain)]] if keychain.exists() else [])]:
                try:
                    run(arguments, environment)
                except (RuntimeError, OSError):
                    cleanup_failed = True
                    print('ERROR: Signing keychain cleanup failed.', file=sys.stderr)
        if cleanup_failed:
            raise RuntimeError('Signing cleanup must succeed before publishing.')


if __name__ == '__main__':
    signal.signal(signal.SIGTERM, cancelled)
    signal.signal(signal.SIGINT, cancelled)
    try:
        main()
    except KeyboardInterrupt:
        print('ERROR: CI release cancelled.', file=sys.stderr)
        sys.exit(1)
    except (ValueError, RuntimeError, OSError):
        print('ERROR: CI signing or release failed; check setup and release evidence.', file=sys.stderr)
        sys.exit(1)
