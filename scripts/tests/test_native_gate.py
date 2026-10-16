from pathlib import Path
import unittest
import json
import os
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]


class NativeGateExecutionTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name).resolve()
        for name in ['scripts', 'bin']:
            (self.root / name).mkdir()
        shutil.copy2(ROOT / 'scripts/test-native.sh', self.root / 'scripts/test-native.sh')
        prepare = self.root / 'scripts/prepare-librespot.sh'
        prepare.write_text('#!/bin/sh\nexit "${FAIL_PREPARE:-0}"\n')
        prepare.chmod(0o755)
        cargo = self.root / 'bin/cargo'
        cargo.write_text('#!' + sys.executable + '\n' + r"""import json,os,sys
from pathlib import Path
trace=Path(os.environ['TRACE'])
count=len(trace.read_text().splitlines())+1 if trace.exists() else 1
with trace.open('a') as output:
    output.write(json.dumps({'args':sys.argv[1:],'deployment':os.environ.get('MACOSX_DEPLOYMENT_TARGET'),'target_dir':os.environ.get('CARGO_TARGET_DIR')})+'\n')
if count==int(os.environ.get('FAIL_CALL','0')):sys.exit(101)
""")
        cargo.chmod(0o755)
        self.trace = self.root / 'trace.jsonl'
        self.env = dict(os.environ, PATH=str(self.root / 'bin') + os.pathsep + os.environ['PATH'], TRACE=str(self.trace))

    def run_gate(self, **changes):
        return subprocess.run(['bash', '-c', './scripts/test-native.sh && touch packaged'],
                              cwd=self.root, env=self.env | changes, capture_output=True, text=True)

    def calls(self):
        return [json.loads(line) for line in self.trace.read_text().splitlines()] if self.trace.exists() else []

    def test_selects_locked_unit_and_doc_suites_with_explicit_deployment(self):
        result = self.run_gate()
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = self.calls()
        self.assertEqual(len(calls), 4)
        for index, call in enumerate(calls):
            args = call['args']
            self.assertEqual(args[0], 'test')
            self.assertIn('--locked', args)
            self.assertIn('--lib' if index % 2 == 0 else '--doc', args)
            self.assertNotIn('--tests', args)
            self.assertNotIn('--ignored', args)
            self.assertNotIn('--all-features', args)
            self.assertNotIn('--offline', args)
            self.assertEqual(call['deployment'], '26.0')
            self.assertEqual(call['target_dir'], str(self.root / 'rust/target'))
            packages = [args[i + 1] for i, arg in enumerate(args) if arg == '-p']
            self.assertEqual(packages, ['bopify-core', 'librespot-connect', 'librespot-playback'] if index < 2 else ['librespot-core'])
            manifest = args[args.index('--manifest-path') + 1]
            self.assertEqual(manifest, 'rust/Cargo.toml' if index < 2 else '.build/librespot-939dc5e/Cargo.toml')
        self.assertTrue((self.root / 'packaged').exists())

    def test_every_native_failure_prevents_later_commands_and_packaging(self):
        for stage in range(1, 5):
            with self.subTest(stage=stage):
                if self.trace.exists(): self.trace.unlink()
                result = self.run_gate(FAIL_CALL=str(stage))
                self.assertEqual(result.returncode, 101)
                self.assertEqual(len(self.calls()), stage)
                self.assertFalse((self.root / 'packaged').exists())

    def test_source_preparation_failure_never_runs_cargo_or_packaging(self):
        result = self.run_gate(FAIL_PREPARE='7')
        self.assertEqual(result.returncode, 7)
        self.assertEqual(self.calls(), [])
        self.assertFalse((self.root / 'packaged').exists())
