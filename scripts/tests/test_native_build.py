import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class NativeBuildTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name)
        for name in ['scripts','rust','bin']:(self.root/name).mkdir()
        for name in ['build-rust.sh','gen-header.sh','release-tool.sh']:
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
        result=self.run_script('gen-header.sh',TOOL_VERSION='0.28.0')
        self.assertNotEqual(result.returncode,0)
        self.assertFalse((self.root/'artifacts/include/bopify_core.h').exists())


if __name__=='__main__':unittest.main()
