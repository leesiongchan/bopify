import importlib.util
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest

spec = importlib.util.spec_from_file_location("menu_runner", Path(__file__).with_name("run-recovery-menu-ui-tests.py"))
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)


@unittest.skipUnless(sys.platform == "darwin", "macOS UI runner process ownership")
class OwnedUICleanup(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve()
        self.fixture_binary = self.make_sleeper("owned/fixture")
        self.other_binary = self.make_sleeper("unrelated/fixture")
        self.automation_binary = self.make_sleeper("automation/xcode-fixture")
        self.fixture = self.start(self.fixture_binary)
        self.other = self.start(self.other_binary)

    def make_sleeper(self, name):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        subprocess.run(["xcrun", "clang", "-x", "c", "-", "-o", str(path)],
            input="#include <unistd.h>\nint main(void) { sleep(30); return 0; }\n", text=True,
            capture_output=True, check=True)
        return path

    def start(self, path):
        process = subprocess.Popen([str(path), "30"], start_new_session=True)
        def cleanup():
            if process.poll() is None:
                process.kill()
            process.wait()
        self.addCleanup(cleanup)
        return process

    def assert_owned_stopped(self):
        deadline = time.monotonic() + 3
        while self.fixture.poll() is None and time.monotonic() < deadline:
            time.sleep(0.02)
        self.assertIsNotNone(self.fixture.poll(), "Owned fixture survived automation cleanup")
        self.assertIsNone(self.other.poll(), "An unrelated executable with the same basename was terminated")

    def test_completion_cleans_owned_fixture_only(self):
        with (self.root / "normal.log").open("w") as log:
            code = runner.run_ui_tests(["/usr/bin/true"], log, [self.fixture_binary], timeout=1)
        self.assertEqual(code, 0)
        self.assert_owned_stopped()

    def test_timeout_cleans_owned_fixture_only(self):
        with (self.root / "timeout.log").open("w") as log:
            code = runner.run_ui_tests([str(self.automation_binary), "30"], log, [self.fixture_binary], timeout=0.05)
        self.assertEqual(code, 124)
        self.assert_owned_stopped()

    def test_interruption_cleans_automation_and_owned_fixture(self):
        log = self.root / "interrupt.log"
        script = """import importlib.util,sys
from pathlib import Path
s=importlib.util.spec_from_file_location('r',sys.argv[1]);r=importlib.util.module_from_spec(s);s.loader.exec_module(r)
with open(sys.argv[2],'w') as output:r.run_ui_tests([sys.argv[3],'30'],output,[Path(sys.argv[4])],timeout=30)
"""
        process = subprocess.Popen([sys.executable, "-c", script, str(Path(runner.__file__)), str(log), str(self.automation_binary), str(self.fixture_binary)], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        automation_pid = None
        try:
            deadline = time.monotonic() + 3
            while time.monotonic() < deadline:
                if log.exists() and "UI_AUTOMATION_PID=" in log.read_text():
                    automation_pid = int(log.read_text().split("UI_AUTOMATION_PID=", 1)[1].splitlines()[0])
                    break
                time.sleep(0.02)
            self.assertIsNotNone(automation_pid)
            process.send_signal(signal.SIGINT)
            process.communicate(timeout=5)
            self.assertNotEqual(process.returncode, 0)
            self.assert_owned_stopped()
            status = subprocess.run(["/bin/ps", "-p", str(automation_pid), "-o", "stat="], capture_output=True, text=True).stdout.strip()
            self.assertTrue(not status or status.startswith("Z"), "Automation survived interruption")
        finally:
            if process.poll() is None:
                process.kill(); process.communicate()
            if automation_pid is not None:
                try: os.kill(automation_pid, signal.SIGKILL)
                except ProcessLookupError: pass
