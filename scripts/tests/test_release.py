import hashlib
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
JOB = '11111111-2222-4333-8444-555555555555'
DMG = b'controlled disk image boundary'

FAKE_TOOL = r'''import hashlib,json,os,plistlib,shutil,sys
from pathlib import Path
name=Path(sys.argv[0]).name
args=sys.argv[1:]
label=name
if name=='xcodebuild':label='export' if '-exportArchive' in args else 'archive'
if name=='xcrun':label=args[1]
if name=='codesign':label='sign' if '--sign' in args else 'codesign'
if name=='spctl':label='assess'
with Path(os.environ['TRACE']).open('a') as log:log.write(json.dumps({'stage':label,'args':args})+'\n')
failure=os.environ.get('FAIL_STAGE')==label
if failure and label!='submit':sys.exit(7)
if name=='git':
    if 'rev-list' in args:print('123')
    elif 'rev-parse' in args:print('a'*40)
elif name=='security':
    if not os.environ.get('MISSING_ID'):
        print('  1) '+ 'A'*40 +' "Developer ID Application: Test (6RS6K2N242)"')
elif name=='xcodebuild':
    def option(key):return args[args.index(key)+1]
    if label=='archive':
        assert 'ARCHS=arm64' in args
        app=Path(option('-archivePath'))/'Products/Applications/Bopify.app/Contents'
        (app/'MacOS').mkdir(parents=True)
        (app/'MacOS/Bopify').write_bytes(b'controlled binary boundary')
        info={'CFBundleIdentifier':'com.leesiongchan.bopify','CFBundleShortVersionString':next(a.split('=',1)[1] for a in args if a.startswith('MARKETING_VERSION=')),'CFBundleVersion':next(a.split('=',1)[1] for a in args if a.startswith('CURRENT_PROJECT_VERSION='))}
        (app/'Info.plist').write_bytes(plistlib.dumps(info))
        shutil.copytree(Path.cwd()/'Bopify/Bopify/Resources',app/'Resources')
    else:
        options=plistlib.loads(Path(option('-exportOptionsPlist')).read_bytes())
        assert options['method']=='developer-id' and options['teamID']=='6RS6K2N242'
        destination=Path(option('-exportPath'))
        destination.mkdir(parents=True)
        shutil.copytree(Path(option('-archivePath'))/'Products/Applications/Bopify.app',destination/'Bopify.app')
elif name=='lipo':print(os.environ.get('ARCHITECTURES','arm64'))
elif name=='codesign':
    if '--entitlements' in args:
        rights={'com.apple.security.app-sandbox':True,'com.apple.security.network.client':True,'com.apple.security.network.server':True,'com.apple.security.files.user-selected.read-only':True}
        if os.environ.get('DEBUGGER'):rights['com.apple.security.get-task-allow']=True
        if os.environ.get('NO_NETWORK'):rights.pop('com.apple.security.network.client')
        if os.environ.get('RUNTIME_EXCEPTION'):rights['com.apple.security.cs.disable-library-validation']=True
        sys.stdout.buffer.write(plistlib.dumps(rights))
    elif '--display' in args:
        print('Authority='+os.environ.get('AUTHORITY','Developer ID Application: Test (6RS6K2N242)'),file=sys.stderr)
        print('TeamIdentifier=6RS6K2N242',file=sys.stderr)
        print('CodeDirectory flags='+ ('0x0' if os.environ.get('NO_RUNTIME') else '0x10000(runtime)'),file=sys.stderr)
elif name=='hdiutil':Path(args[-1]).write_bytes(b'controlled disk image boundary')
elif name=='xcrun':
    if label=='submit':
        if os.environ.get('MALFORMED_SUBMIT'):print('{broken')
        else:print(json.dumps({'id':'11111111-2222-4333-8444-555555555555','status':os.environ.get('NOTARY_STATUS','Accepted'),'name':Path(args[2]).name,'message':'Processing complete'}))
        if failure:sys.exit(7)
    elif label=='log':
        data={'logFormatVersion':1,'jobId':'11111111-2222-4333-8444-555555555555','status':'Accepted','statusSummary':'Ready for distribution','statusCode':0,'archiveFilename':'Bopify-0.1.0-rc.1.dmg','uploadDate':'2026-10-13T00:00:00Z','sha256':hashlib.sha256(b'controlled disk image boundary').hexdigest(),'ticketContents':[],'issues':None}
        if os.environ.get('WRONG_JOB'):data['jobId']='00000000-0000-0000-0000-000000000000'
        if os.environ.get('WRONG_HASH'):data['sha256']='0'*64
        if os.environ.get('NOTARY_WARNING'):data['issues']=[{'severity':'warning','code':1,'path':'Bopify.app','message':'unresolved warning','docUrl':None,'architecture':'arm64'}]
        Path(args[3]).write_text(json.dumps(data))
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
        for name in ['release.sh', 'verify-release.py', 'ExportOptions.plist']:
            if (ROOT / 'scripts' / name).is_file():
                shutil.copy2(ROOT / 'scripts' / name, self.root / 'scripts' / name)
        (self.root / 'scripts/build-rust.sh').write_text('#!/bin/sh\nexit "${FAIL_BUILD:-0}"\n')
        (self.root / 'scripts/build-rust.sh').chmod(0o755)
        (self.root / 'scripts/gen-notices.sh').write_text('#!/bin/sh\nprintf "<html>test third party licenses</html>\\n" > "$1"\n')
        (self.root / 'scripts/gen-notices.sh').chmod(0o755)
        for name in ['git', 'security', 'xcodebuild', 'codesign', 'lipo', 'hdiutil', 'xcrun', 'spctl']:
            path = self.root / 'bin' / name
            path.write_text('#!' + sys.executable + '\n' + FAKE_TOOL)
            path.chmod(0o755)
        self.trace = self.root / 'trace.jsonl'
        self.final = self.root / 'build/release/Bopify-0.1.0-rc.1.dmg'
        self.environment = dict(os.environ, PATH=str(self.root / 'bin') + os.pathsep + os.environ['PATH'], TRACE=str(self.trace), BUILD_NUMBER='123')
        for key in ['NOTARY_KEY_PATH','NOTARY_KEY_ID','NOTARY_ISSUER_ID','SIGN_IDENTITY']:
            self.environment.pop(key, None)

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
        self.assertLess(stages.index('export'), stages.index('submit'))
        self.assertLess(stages.index('log'), stages.index('staple'))
        self.assertLess(stages.index('staple'), stages.index('validate'))
        self.assertLess(stages.index('validate'), stages.index('assess'))
        infos = list((self.root / 'build').rglob('Bopify.app/Contents/Info.plist'))
        self.assertTrue(infos)
        self.assertTrue(all(plistlib.loads(info.read_bytes())['CFBundleShortVersionString']=='0.1.0' for info in infos))
        self.assertTrue(all((info.parent/'Resources/Third-Party Licenses.html').is_file() for info in infos))

    def test_invalid_version_cannot_create_build_output(self):
        for version in ['../escape','1.2','1.2.3/../../escape','1.2.3\nextra']:
            with self.subTest(version=version):
                result = self.release(version)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse((self.root / 'build').exists())

    def test_missing_identity_stops_before_build_output(self):
        result = self.release(MISSING_ID='1')
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.root / 'build').exists())

    def test_existing_release_is_preserved(self):
        self.final.parent.mkdir(parents=True)
        self.final.write_bytes(b'previous reviewed artifact')
        result = self.release()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.final.read_bytes(), b'previous reviewed artifact')

    def test_pre_submission_failures_never_upload(self):
        cases=[{'FAIL_BUILD':'7'},{'FAIL_STAGE':'archive'},{'FAIL_STAGE':'export'}, {'ARCHITECTURES':'arm64 x86_64'}, {'AUTHORITY':'Apple Development: Test'}, {'NO_RUNTIME':'1'}, {'DEBUGGER':'1'}, {'NO_NETWORK':'1'}, {'RUNTIME_EXCEPTION':'1'}]
        for case in cases:
            with self.subTest(case=case):
                if self.trace.exists():self.trace.unlink()
                result=self.release(**case)
                self.assertNotEqual(result.returncode,0)
                self.assertNotIn('submit',self.stages())
                self.assertFalse(self.final.exists())

    def test_submission_and_log_failures_never_staple_or_promote(self):
        cases=[{'FAIL_STAGE':'submit'}, {'MALFORMED_SUBMIT':'1'}, {'NOTARY_STATUS':'Invalid'}, {'NOTARY_STATUS':'In Progress'}, {'FAIL_STAGE':'log'}, {'WRONG_JOB':'1'}, {'WRONG_HASH':'1'}, {'NOTARY_WARNING':'1'}]
        for case in cases:
            with self.subTest(case=case):
                if self.trace.exists():self.trace.unlink()
                result=self.release(**case)
                self.assertNotEqual(result.returncode,0)
                self.assertNotIn('staple',self.stages())
                self.assertFalse(self.final.exists())

    def test_post_notary_failures_cannot_promote(self):
        for stage in ['staple','validate','assess']:
            with self.subTest(stage=stage):
                result=self.release(FAIL_STAGE=stage)
                self.assertNotEqual(result.returncode,0)
                self.assertFalse(self.final.exists())


if __name__ == '__main__':
    unittest.main()
