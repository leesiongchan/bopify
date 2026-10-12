import base64
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[2]
SECRETS = {'DEVELOPER_ID_P12_BASE64': base64.b64encode(b'synthetic-p12').decode(),
           'DEVELOPER_ID_P12_PASSWORD': 'synthetic-p12-password',
           'KEYCHAIN_PASSWORD': 'synthetic-keychain-password', 'NOTARY_KEY_P8': 'synthetic-p8',
           'NOTARY_KEY_ID': 'synthetic-key-id', 'NOTARY_ISSUER_ID': 'synthetic-issuer'}

SECURITY = r'''import json,os,sys
from pathlib import Path
args=sys.argv[1:]
with Path(os.environ['TRACE']).open('a') as f:f.write(json.dumps(args)+'\n')
if args[0]=='list-keychains' and '-s' not in args:
    print('    "/original/login keychain-db"\n    "/original/other.keychain-db"')
if args[0]=='create-keychain':Path(args[-1]).write_bytes(b'isolated keychain')
if args[0]=='delete-keychain':Path(args[-1]).unlink()
if os.environ.get('FAIL_STAGE')==args[0]:
    print(os.environ['KEYCHAIN_PASSWORD'] if 'KEYCHAIN_PASSWORD' in os.environ else 'sensitive-tool-output',file=sys.stderr)
    sys.exit(7)
'''

RELEASE = r'''import json,os,stat,sys,time
from pathlib import Path
p=Path(os.environ['NOTARY_KEY_PATH'])
assert p.read_text()=='synthetic-p8'
assert stat.S_IMODE(p.stat().st_mode)==0o600
assert not any(k in os.environ for k in ['DEVELOPER_ID_P12_BASE64','DEVELOPER_ID_P12_PASSWORD','KEYCHAIN_PASSWORD','NOTARY_KEY_P8'])
with Path(os.environ['TRACE']).open('a') as f:f.write(json.dumps(['release',sys.argv[1]])+'\n')
if os.environ.get('WAIT_RELEASE'):
    Path(os.environ['READY']).write_text('ready')
    time.sleep(30)
sys.exit(int(os.environ.get('RELEASE_EXIT','0')))
'''


class CICredentialTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name)
        for name in ['scripts', 'bin', 'runner']:
            (self.root / name).mkdir()
        source = ROOT / 'scripts/ci-release.py'
        if source.exists():
            shutil.copy2(source, self.root / 'scripts/ci-release.py')
        for path, text in [(self.root / 'bin/security', SECURITY), (self.root / 'scripts/release.sh', RELEASE)]:
            path.write_text('#!' + sys.executable + '\n' + text)
            path.chmod(0o755)
        self.trace = self.root / 'trace.jsonl'
        self.env = dict(os.environ, **SECRETS, GITHUB_ACTIONS='true', RUNNER_ENVIRONMENT='github-hosted',
                        RUNNER_OS='macOS', RUNNER_TEMP=str(self.root / 'runner'), TRACE=str(self.trace),
                        PATH=str(self.root / 'bin') + os.pathsep + os.environ['PATH'])

    def run_release(self, **changes):
        return subprocess.run([sys.executable, str(self.root / 'scripts/ci-release.py'), '0.1.0-rc.1'],
                              cwd=self.root, env=self.env | changes, capture_output=True, text=True, timeout=15)

    def calls(self):
        return [json.loads(line) for line in self.trace.read_text().splitlines()] if self.trace.exists() else []

    def assert_clean(self, result):
        self.assertEqual(list((self.root / 'runner').iterdir()), [])
        for secret in SECRETS.values():
            self.assertNotIn(secret, result.stdout + result.stderr)
        calls = self.calls()
        self.assertEqual(calls[-2], ['list-keychains', '-d', 'user', '-s', '/original/login keychain-db', '/original/other.keychain-db'])
        self.assertEqual(calls[-1][0], 'delete-keychain')

    def test_success_restores_exact_search_list_and_erases_private_material(self):
        result = self.run_release()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assert_clean(result)
        calls = self.calls()
        self.assertEqual(calls[0], ['list-keychains', '-d', 'user'])
        imported = next(call for call in calls if call[0] == 'import')
        self.assertNotIn('-A', imported)
        self.assertEqual(imported[imported.index('-T') + 1], '/usr/bin/codesign')
        self.assertFalse(any(call[0] == 'default-keychain' for call in calls))

    def test_partial_setup_and_release_failures_cleanup_without_success(self):
        for changes in [{'FAIL_STAGE': stage} for stage in ['create-keychain','unlock-keychain','import','set-key-partition-list']] + [{'RELEASE_EXIT': '7'}]:
            with self.subTest(changes=changes):
                if self.trace.exists(): self.trace.unlink()
                result = self.run_release(**changes)
                self.assertNotEqual(result.returncode, 0)
                self.assert_clean(result)

    def test_missing_secrets_and_non_hosted_invocation_have_no_side_effects(self):
        for changes in [{'KEYCHAIN_PASSWORD': ''}, {'GITHUB_ACTIONS': ''}, {'RUNNER_ENVIRONMENT': 'self-hosted'}, {'DEVELOPER_ID_P12_BASE64': '!invalid!'}]:
            with self.subTest(changes=changes):
                result = self.run_release(**changes)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(self.calls(), [])
                self.assertEqual(list((self.root / 'runner').iterdir()), [])

    def test_sigterm_stops_child_and_cleans_signing_material(self):
        ready = self.root / 'ready'
        with subprocess.Popen([sys.executable, str(self.root / 'scripts/ci-release.py'), '0.1.0-rc.1'],
                              cwd=self.root, env=self.env | {'WAIT_RELEASE': '1', 'READY': str(ready)},
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True) as process:
            deadline = time.monotonic() + 5
            while not ready.exists() and process.poll() is None and time.monotonic() < deadline:
                time.sleep(0.02)
            if not ready.exists():
                out, err = process.communicate(timeout=5)
                self.fail('Release child never started: ' + out + err)
            process.terminate()
            out, err = process.communicate(timeout=7)
            self.assertNotEqual(process.returncode, 0)
            self.assert_clean(subprocess.CompletedProcess([], process.returncode, out, err))


if __name__ == '__main__':
    unittest.main()
