import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
DMG = b'controlled disk image boundary'

FAKE_TOOL = r'''import json,os,plistlib,shutil,sys
from pathlib import Path
name=Path(sys.argv[0]).name
args=sys.argv[1:]
label='archive' if name=='xcodebuild' else name
if name=='codesign':label='sign' if '--sign' in args else 'codesign'
with Path(os.environ['TRACE']).open('a') as log:log.write(json.dumps({'stage':label,'args':args})+'\n')
if os.environ.get('FAIL_STAGE')==label:sys.exit(7)
if name=='git':
    if 'rev-list' in args:print('123')
    elif 'status' in args and os.environ.get('DIRTY'):print(' M source.swift')
elif name=='cargo-about':
    if args==['--version']:
        print('cargo-about '+os.environ.get('TOOL_VERSION','0.9.2'))
    else:
        assert args[0]=='generate' and '--locked' in args and '--fail' in args
        if not os.environ.get('EMPTY_NOTICES'):print('<html>test third party licenses</html>')
        sys.exit(int(os.environ.get('NOTICE_EXIT','0')))
elif name=='cargo':sys.exit(13)
elif name=='xcodebuild':
    assert 'ARCHS=arm64' in args and 'CODE_SIGN_IDENTITY=-' in args
    assert 'CODE_SIGN_STYLE=Manual' in args and 'DEVELOPMENT_TEAM=' in args
    app=Path(args[args.index('-archivePath')+1])/'Products/Applications/Bopify.app/Contents'
    (app/'MacOS').mkdir(parents=True)
    (app/'MacOS/Bopify').write_bytes(b'controlled binary boundary')
    info={'LSMinimumSystemVersion':os.environ.get('MINIMUM_MACOS','26.0'),'CFBundleIdentifier':os.environ.get('BUNDLE_ID','com.leesiongchan.bopify'),'CFBundleShortVersionString':os.environ.get('APP_VERSION',next(a.split('=',1)[1] for a in args if a.startswith('MARKETING_VERSION='))),'CFBundleVersion':os.environ.get('APP_BUILD',next(a.split('=',1)[1] for a in args if a.startswith('CURRENT_PROJECT_VERSION=')))}
    (app/'Info.plist').write_bytes(plistlib.dumps(info))
    shutil.copytree(Path.cwd()/'Bopify/Bopify/Resources',app/'Resources')
elif name=='lipo':print(os.environ.get('ARCHITECTURES','arm64'))
elif name=='codesign':
    if '--entitlements' in args:
        rights={'com.apple.security.app-sandbox':True,'com.apple.security.network.client':True,'com.apple.security.network.server':True,'com.apple.security.files.user-selected.read-only':True}
        if os.environ.get('DEBUGGER'):rights['com.apple.security.get-task-allow']=True
        if os.environ.get('NO_NETWORK'):rights.pop('com.apple.security.network.client')
        if os.environ.get('RUNTIME_EXCEPTION'):rights['com.apple.security.cs.disable-library-validation']=True
        sys.stdout.buffer.write(plistlib.dumps(rights))
    elif '--display' in args:
        print('Signature='+os.environ.get('ADHOC_SIGNATURE','adhoc'),file=sys.stderr)
        print('TeamIdentifier='+os.environ.get('ADHOC_TEAM','not set'),file=sys.stderr)
        if os.environ.get('AUTHORITY'):print('Authority='+os.environ['AUTHORITY'],file=sys.stderr)
        print('CodeDirectory flags='+ ('0x0' if os.environ.get('NO_RUNTIME') else '0x10000(runtime)'),file=sys.stderr)
elif name=='hdiutil':Path(args[-1]).write_bytes(b'controlled disk image boundary')
else:sys.exit(97)
'''


class ReleasePipelineTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name)
        (self.root / 'scripts').mkdir()
        (self.root / 'bin').mkdir()
        (self.root / 'Bopify/Bopify').mkdir(parents=True)
        (self.root / 'LICENSE').write_text('test project license')
        for name in ['release.sh', 'verify-release.py', 'release-tool.sh']:
            if (ROOT / 'scripts' / name).is_file():
                shutil.copy2(ROOT / 'scripts' / name, self.root / 'scripts' / name)
        (self.root / 'scripts/build-rust.sh').write_text('#!/bin/sh\nexit "${FAIL_BUILD:-0}"\n')
        (self.root / 'scripts/build-rust.sh').chmod(0o755)
        for name in ['git', 'security', 'xcodebuild', 'codesign', 'lipo', 'hdiutil', 'cargo-about', 'cargo']:
            path = self.root / 'bin' / name
            path.write_text('#!' + sys.executable + '\n' + FAKE_TOOL)
            path.chmod(0o755)
        self.trace = self.root / 'trace.jsonl'
        self.final = self.root / 'build/release/Bopify-0.1.0-rc.1.dmg'
        self.environment = dict(os.environ, PATH=str(self.root / 'bin') + os.pathsep + os.environ['PATH'], TRACE=str(self.trace), BUILD_NUMBER='123')

    def release(self, version='0.1.0-rc.1', **changes):
        return subprocess.run(['bash', str(self.root / 'scripts/release.sh'), version], cwd=self.root,
                              env=self.environment | changes, capture_output=True, text=True, timeout=30)

    def stages(self):
        return [json.loads(line)['stage'] for line in self.trace.read_text().splitlines()] if self.trace.exists() else []

    def test_success_verifies_before_promotion_and_keeps_prerelease_filename(self):
        result = self.release()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.final.read_bytes(), DMG)
        stages = self.stages()
        self.assertLess(stages.index('codesign'), stages.index('hdiutil'))
        infos = list((self.root / 'build').rglob('Bopify.app/Contents/Info.plist'))
        self.assertTrue(infos)
        self.assertTrue(all(plistlib.loads(info.read_bytes())['CFBundleShortVersionString']=='0.1.0' for info in infos))
        self.assertTrue(all((info.parent/'Resources/Third-Party Licenses.html').is_file() for info in infos))

    def test_old_macos_minimum_cannot_promote_release(self):
        result = self.release(MINIMUM_MACOS='14.0')
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.final.exists())
        self.assertNotIn('sign', self.stages())

    def test_release_uses_ad_hoc_signing_by_default(self):
        result = self.release()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.final.read_bytes(), DMG)
        calls = [json.loads(line) for line in self.trace.read_text().splitlines()]
        stages = self.stages()
        self.assertNotIn('security', stages)
        archive = next(call['args'] for call in calls if call['stage'] == 'archive')
        self.assertIn('CODE_SIGN_IDENTITY=-', archive)
        self.assertIn('DEVELOPMENT_TEAM=', archive)
        signed = next(call['args'] for call in calls if call['stage'] == 'sign')
        self.assertEqual(signed[signed.index('--sign') + 1], '-')
        self.assertIn('--timestamp=none', signed)
        policies = list((self.root / 'build').rglob('export-check.json'))
        self.assertEqual(len(policies), 1)
        policy = json.loads(policies[0].read_text())
        self.assertEqual(policy['signing'], 'ad-hoc')
        self.assertFalse(policy['notarized'])
        self.assertIn('not notarized', result.stdout)
        self.assertTrue((policies[0].parent / 'export/Bopify.app/Contents/Resources/Third-Party Licenses.html').is_file())

    def test_ad_hoc_signature_capability_and_packaging_failures_block_promotion(self):
        cases = [{'ADHOC_SIGNATURE':'cms'}, {'ADHOC_TEAM':'6RS6K2N242'}, {'AUTHORITY':'Developer ID Application: Test'},
                 {'NO_RUNTIME':'1'}, {'DEBUGGER':'1'}, {'NO_NETWORK':'1'}, {'RUNTIME_EXCEPTION':'1'},
                 {'ARCHITECTURES':'arm64 x86_64'}, {'FAIL_BUILD':'7'}, {'FAIL_STAGE':'archive'},
                 {'FAIL_STAGE':'hdiutil'}, {'FAIL_STAGE':'sign'}, {'FAIL_STAGE':'codesign'}]
        for case in cases:
            with self.subTest(case=case):
                if self.trace.exists():self.trace.unlink()
                result = self.release(**case)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(self.final.exists())

    def test_restrictive_umask_keeps_all_shipped_notices_publicly_readable(self):
        previous = os.umask(0o077)
        try:
            result = self.release()
        finally:
            os.umask(previous)
        self.assertEqual(result.returncode, 0, result.stderr)
        notices = list((self.root / 'build').rglob('LICENSE.txt'))
        notices += list((self.root / 'build').rglob('Third-Party Licenses.html'))
        self.assertTrue(notices)
        for notice in notices:
            self.assertEqual(notice.stat().st_mode & 0o444, 0o444, str(notice))

    def test_invalid_version_cannot_create_build_output(self):
        for version in ['../escape','1.2','1.2.3/../../escape','1.2.3\nextra']:
            with self.subTest(version=version):
                result = self.release(version)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse((self.root / 'build').exists())

    def test_existing_release_is_preserved(self):
        self.final.parent.mkdir(parents=True)
        self.final.write_bytes(b'previous reviewed artifact')
        result = self.release()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.final.read_bytes(), b'previous reviewed artifact')

    def test_failed_or_empty_notice_generation_preserves_previous_output(self):
        output = self.root / 'Bopify/Bopify/Resources/Third-Party Licenses.html'
        output.parent.mkdir(parents=True)
        output.write_text('previous complete notices')
        for changes in [{'NOTICE_EXIT':'7'}, {'EMPTY_NOTICES':'1'}, {'TOOL_VERSION':'0.9.0'}]:
            with self.subTest(changes=changes):
                result = self.release(**changes)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(output.read_text(), 'previous complete notices')
                self.assertFalse(self.final.exists())
                self.assertNotIn('archive', self.stages())

    def test_exported_metadata_must_match_release(self):
        for changes in [{'APP_VERSION':'9.9.9'}, {'APP_BUILD':'999'}, {'BUNDLE_ID':'wrong.app'}]:
            with self.subTest(changes=changes):
                result = self.release(**changes)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(self.final.exists())

    def test_dirty_checkout_stops_before_build_output(self):
        result = self.release(DIRTY='1')
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.root / 'build').exists())


if __name__ == '__main__':
    unittest.main()
