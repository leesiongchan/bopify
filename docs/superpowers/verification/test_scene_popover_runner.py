import importlib.util
from pathlib import Path
import unittest

path = Path(__file__).with_name('run-swiftui-scene-popover-probe.py')
spec = importlib.util.spec_from_file_location('scene_runner', path)
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)


def output(mode='binding', diagnostics=0, valid=True):
    events = ['started', 'window-shown', 'control-observed', 'collection-requested'] if mode == 'control' else [
        'started', 'window-shown', 'show-requested', 'content-appeared', 'did-show',
        'close-requested', 'did-close', 'content-disappeared', 'collection-requested']
    logs = '\n'.join('LOG: time bopify.validation/test fixture ' + event for event in events)
    return logs + f'\nRESULT: mode={mode} lifecycleValidated={str(valid).lower()} diagnostics={diagnostics} invalidTransactions={min(1, diagnostics)}\n'


class SceneEvidenceTests(unittest.TestCase):
    def test_valid_clean(self):
        self.assertEqual(runner.classify(0, output(), 'binding'), 'valid_clean')
        self.assertEqual(runner.classify(0, output('control'), 'control'), 'valid_clean')

    def test_valid_reproduction(self):
        self.assertEqual(runner.classify(1, output(diagnostics=6), 'binding'), 'reproduced')

    def test_invalid_lifecycle_or_missing_evidence(self):
        for code, text in [(2, output()), (0, ''), (0, output(valid=False)),
                           (0, output().replace('fixture did-close', 'unrelated')),
                           (0, output().replace('mode=binding', 'mode=outside')),
                           (0, output(diagnostics=6)), (1, output()),
                           (0, output() + output()), (-9, output())]:
            with self.subTest(code=code, text=text):
                self.assertEqual(runner.classify(code, text, 'binding'), 'invalid')

    def test_timeout_is_invalid_even_with_a_result(self):
        self.assertEqual(runner.classify(0, output(), 'binding', timed_out=True), 'invalid')

    def test_unavailable_is_never_clean(self):
        self.assertEqual(runner.classify(77, 'UNAVAILABLE: no input permission', 'outside'), 'unavailable')

    def test_summary_preserves_failure_precedence(self):
        self.assertEqual(runner.summary_exit(['valid_clean']), 0)
        self.assertEqual(runner.summary_exit(['valid_clean', 'reproduced']), 1)
        self.assertEqual(runner.summary_exit(['valid_clean', 'unavailable', 'reproduced']), 77)
        self.assertEqual(runner.summary_exit(['unavailable', 'invalid', 'reproduced']), 2)
        self.assertEqual(runner.summary_exit([]), 2)


if __name__ == '__main__':
    unittest.main()
