import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location("menu_runner", Path(__file__).with_name("run-recovery-menu-ui-tests.py"))
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)


class UIQualificationResults(unittest.TestCase):
    def summary(self, **changes):
        return dict(totalTestCount=7, passedTests=7, skippedTests=0, failedTests=0, expectedFailures=0, result="Passed") | changes

    def test_complete_run_is_qualified(self):
        self.assertEqual(runner.qualification_exit(0, self.summary(), 7), 0)

    def test_build_failure_cannot_pass(self):
        self.assertEqual(runner.qualification_exit(65, self.summary(), 7), 65)

    def test_skipped_keyboard_is_incomplete(self):
        self.assertEqual(runner.qualification_exit(0, self.summary(passedTests=6, skippedTests=1), 7), 77)

    def test_zero_tests_cannot_pass(self):
        self.assertEqual(runner.qualification_exit(0, self.summary(totalTestCount=0, passedTests=0), 7), 2)

    def test_missing_results_cannot_pass(self):
        self.assertEqual(runner.qualification_exit(0, {}, 7), 2)

    def test_failed_or_expected_failure_cannot_pass(self):
        for changes in [dict(passedTests=6, failedTests=1), dict(passedTests=6, expectedFailures=1)]:
            with self.subTest(changes=changes):
                self.assertEqual(runner.qualification_exit(0, self.summary(**changes), 7), 2)

    def test_wrong_count_and_inconsistent_totals_cannot_pass(self):
        for changes in [dict(totalTestCount=6, passedTests=6), dict(passedTests=6), dict(skippedTests=-1, passedTests=8)]:
            with self.subTest(changes=changes):
                self.assertEqual(runner.qualification_exit(0, self.summary(**changes), 7), 2)
