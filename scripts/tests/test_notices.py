import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]


class NoticeGenerationTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        (self.root / 'scripts').mkdir()
        (self.root / 'rust').mkdir()
        (self.root / 'bin').mkdir()
        for name in ['gen-notices.sh', 'release-tool.sh']:
            if (ROOT / 'scripts' / name).is_file():
                shutil.copy2(ROOT / 'scripts' / name, self.root / 'scripts' / name)
        (self.root / 'rust/about.toml').write_text('accepted = ["MIT"]\n')
        (self.root / 'rust/about.hbs').write_text('unused boundary fixture\n')
        self.environment = dict(os.environ, PATH=str(self.root / 'bin') + os.pathsep + os.environ['PATH'])
        self.output = self.root / 'notices.html'
        self.output.write_text('previous valid notices')
        self.tool('cargo-about', '''if [ "$1" = --version ]; then
  printf 'cargo-about %s\n' "${PROBE_VERSION:-0.9.2}"
  exit 0
fi
case " $* " in *' --locked '*) ;; *) exit 51 ;; esac
case " $* " in *' --fail '*) ;; *) exit 52 ;; esac
printf '<html><h1>Dependency notices</h1><pre>license text</pre></html>\n'
exit "${PROBE_GENERATE_EXIT:-0}"
''')
        self.tool('cargo', 'exit 13\n')

    def tool(self, name, source):
        path = self.root / 'bin' / name
        path.write_text('#!/bin/sh\n' + source)
        path.chmod(0o755)

    def run_generator(self, **environment):
        return subprocess.run(['bash', str(self.root / 'scripts/gen-notices.sh'), str(self.output)],
                              env=self.environment | environment, capture_output=True, text=True)

    def test_success_replaces_notices_using_locked_fail_on_unknown_generation(self):
        result = self.run_generator()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('<pre>license text</pre>', self.output.read_text())

    def test_generation_failure_keeps_previous_complete_output(self):
        result = self.run_generator(PROBE_GENERATE_EXIT='7')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.output.read_text(), 'previous valid notices')

    def test_wrong_tool_version_and_failed_install_cannot_generate(self):
        result = self.run_generator(PROBE_VERSION='0.9.0')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.output.read_text(), 'previous valid notices')


if __name__ == '__main__':
    unittest.main()
