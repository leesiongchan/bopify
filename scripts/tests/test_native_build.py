import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class NativeBuildTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name)
        for name in ['scripts','rust','bin']:(self.root/name).mkdir()
        for name in ['build-rust.sh','release-tool.sh']:
            shutil.copy2(ROOT/'scripts'/name,self.root/'scripts'/name)
        self.tool('cargo', '''case "$1" in
  install) exit 13 ;;
  build|rustc)
    if [ "${REQUIRE_LOCK:-1}" = 1 ]; then
      case " $* " in *' --locked '*) ;; *) exit 51 ;; esac
    fi
    if [ "$1" = rustc ] && [ "${FAIL_RUSTC:-0}" = 1 ]; then exit 7; fi
    mkdir -p rust/target/aarch64-apple-darwin/release
    printf 'native library' > rust/target/aarch64-apple-darwin/release/libbopify_core.a
    printf 'native-static-libs: framework inputs\n' >&2 ;;
esac
''')
        self.tool('cbindgen', '''if [ "$1" = --version ]; then
  printf 'cbindgen %s\n' "${TOOL_VERSION:-0.29.4}"
else
  while [ "$1" != --output ]; do shift; done
  printf 'header' > "$2"
fi
''')
        self.tool('xcodebuild', 'mkdir -p artifacts/BopifyCoreFFI.xcframework\n')
        (self.root/'scripts/prepare-librespot.sh').write_text('#!/bin/sh\nexit 0\n')
        (self.root/'scripts/prepare-librespot.sh').chmod(0o755)
        self.environment=dict(os.environ,PATH=str(self.root/'bin')+os.pathsep+os.environ['PATH'])

    def tool(self,name,text):
        path=self.root/'bin'/name
        path.write_text('#!/bin/sh\n'+text)
        path.chmod(0o755)

    def run_script(self,name,**changes):
        return subprocess.run(['bash',str(self.root/'scripts'/name)],cwd=self.root,
                              env=self.environment|changes,capture_output=True,text=True)

    def test_native_build_passes_locked_inputs_to_both_cargo_calls(self):
        result=self.run_script('build-rust.sh')
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertTrue((self.root/'artifacts/BopifyCoreFFI.xcframework').is_dir())

    def test_native_linker_diagnostic_failure_is_not_hidden(self):
        result=self.run_script('build-rust.sh',REQUIRE_LOCK='0',FAIL_RUSTC='1')
        self.assertNotEqual(result.returncode,0)

    def test_wrong_header_tool_and_install_failure_cannot_generate_header(self):
        result=self.run_script('build-rust.sh',TOOL_VERSION='0.28.0')
        self.assertNotEqual(result.returncode,0)
        self.assertFalse((self.root/'artifacts/include/bopify_core.h').exists())


class ReleaseToolInstallationTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name)
        (self.root / 'scripts').mkdir()
        (self.root / 'bin').mkdir()
        shutil.copy2(ROOT / 'scripts/release-tool.sh', self.root / 'scripts/release-tool.sh')
        cargo = self.root / 'bin/cargo'
        cargo.write_text('''#!/usr/bin/env python3
import os
from pathlib import Path
import sys
args = sys.argv[1:]
assert args[0] == 'install' and '--locked' in args
name = args[1]
if name == 'cargo-about':
    assert '--features' in args and 'cli' in args[args.index('--features') + 1].split(',')
root = Path(args[args.index('--root') + 1])
version = args[args.index('--version') + 1]
if not os.environ.get('SKIP_BINARY'):
    binary = root / 'bin' / name
    binary.parent.mkdir(parents=True, exist_ok=True)
    binary.write_text('#!/bin/sh\\nprintf "' + name + ' ' + version + '\\\\n"\\n')
    binary.chmod(0o755)
'''.replace('#!/usr/bin/env python3', '#!' + sys.executable, 1))
        cargo.chmod(0o755)
        self.environment = dict(os.environ, PATH=str(self.root / 'bin') + ':/usr/bin:/bin:/usr/sbin:/sbin')

    def install(self, name, **changes):
        return subprocess.run(['bash', str(self.root / 'scripts/release-tool.sh'), name],
                              env=self.environment | changes, capture_output=True, text=True)

    def test_fresh_install_produces_the_pinned_executable_for_each_tool(self):
        for name, version in [('cbindgen', '0.29.4'), ('cargo-about', '0.9.2')]:
            with self.subTest(name=name):
                result = self.install(name)
                self.assertEqual(result.returncode, 0, result.stderr)
                binary = Path(result.stdout.strip())
                self.assertTrue(binary.is_file(), result.stdout)
                self.assertEqual(subprocess.check_output([str(binary), '--version'], text=True).strip(), name + ' ' + version)

    def test_install_without_an_executable_fails_at_the_installer(self):
        result = self.install('cbindgen', SKIP_BINARY='1')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, '')


class LibrespotPreparationTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name)
        self.source = self.root / '.build/librespot-939dc5e'
        self.source.mkdir(parents=True)
        (self.root / 'scripts').mkdir()
        (self.root / 'rust/patches').mkdir(parents=True)
        self.environment = dict(os.environ, GIT_CONFIG_GLOBAL='/dev/null', GIT_CONFIG_NOSYSTEM='1')
        self.git('init', '--quiet')
        self.file = self.source / 'fixture.txt'
        self.file.write_text('a\nb\nc\na\nb\nb\na\n')
        self.git('add', 'fixture.txt')
        self.git('-c', 'user.name=Test', '-c', 'user.email=test@example.com', 'commit', '--quiet', '-m', 'fixture')
        revision = self.git('rev-parse', 'HEAD').stdout.strip()
        self.file.write_text('c\nb\na\nb\na\nc\n')
        patch = self.git('diff', '--no-ext-diff', '--binary', '--diff-algorithm=histogram', 'HEAD').stdout
        (self.root / 'rust/patches/librespot-queue-selection.patch').write_text(patch)
        self.git('checkout', '--', 'fixture.txt')
        script = (ROOT / 'scripts/prepare-librespot.sh').read_text()
        (self.root / 'scripts/prepare-librespot.sh').write_text(
            script.replace('939dc5ee9d833e1980f9495241219d9d4868a061', revision))

    def git(self, *arguments):
        return subprocess.run(['git', '-C', str(self.source), *arguments], env=self.environment,
                              capture_output=True, text=True, check=True)

    def prepare(self):
        return subprocess.run(['bash', str(self.root / 'scripts/prepare-librespot.sh')],
                              env=self.environment, capture_output=True, text=True)

    def test_fresh_preparation_and_rerun_work_with_default_git_configuration(self):
        for _ in range(2):
            result = self.prepare()
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(self.file.read_text(), 'c\nb\na\nb\na\nc\n')

    def test_unexpected_modifications_are_rejected_and_preserved(self):
        result = self.prepare()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.file.write_text('unexpected local changes\n')
        result = self.prepare()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.file.read_text(), 'unexpected local changes\n')


if __name__=='__main__':unittest.main()
