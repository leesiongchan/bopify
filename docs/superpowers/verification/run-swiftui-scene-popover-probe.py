#!/usr/bin/env python3
"""Build and run an account-free declarative SwiftUI popover matrix."""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import re
import subprocess
import time


def classify(returncode, stdout, mode, timed_out=False):
    if timed_out:
        return 'invalid'
    if returncode == 77 and 'UNAVAILABLE:' in stdout:
        return 'unavailable'
    results = re.findall(r'^RESULT: mode=(\S+) lifecycleValidated=(true|false) diagnostics=(\d+) invalidTransactions=(\d+)$', stdout, re.M)
    if len(results) != 1 or returncode not in (0, 1):
        return 'invalid'
    found_mode, valid, diagnostics, transactions = results[0]
    diagnostics, transactions = int(diagnostics), int(transactions)
    ordered = ['started', 'window-shown', 'control-observed', 'collection-requested'] if mode == 'control' else [
        'started', 'window-shown', 'show-requested', 'did-show', 'close-requested']
    if mode == 'binding':
        ordered += ['binding-dismiss-requested']
    elif mode == 'outside':
        ordered += ['outside-click-posted', 'outside-click-delivered']
    if mode != 'control':
        ordered += ['did-close', 'collection-requested']
    required = ordered if mode == 'control' else ordered + ['content-appeared', 'content-disappeared']
    markers = re.findall(r'^LOG: .* bopify\.validation/\S+ fixture (\S+)$', stdout, re.M)
    if (found_mode != mode or valid != 'true' or transactions > diagnostics
            or any(markers.count(event) != 1 for event in required)
            or (returncode == 0) != (diagnostics == 0)):
        return 'invalid'
    positions = [markers.index(event) for event in ordered]
    if positions != sorted(positions) or mode == 'control' and markers != ordered:
        return 'invalid'
    if mode != 'control' and not (markers.index('show-requested') < markers.index('content-appeared') < markers.index('close-requested')
            and markers.index('close-requested') < markers.index('content-disappeared') < markers.index('collection-requested')):
        return 'invalid'
    return 'reproduced' if diagnostics else 'valid_clean'


def summary_exit(statuses):
    if not statuses or any(s not in ('valid_clean', 'reproduced', 'unavailable') for s in statuses):
        return 2
    if 'unavailable' in statuses:
        return 77
    return 1 if 'reproduced' in statuses else 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', required=True, type=Path)
    options = parser.parse_args()
    out = options.output.resolve()
    out.mkdir(parents=True, exist_ok=True)
    source = Path(__file__).with_name('SwiftUIScenePopoverTransactionRepro.swift')
    contents = out / 'ScenePopoverFixture.app/Contents'
    (contents / 'MacOS').mkdir(parents=True, exist_ok=True)
    binary = contents / 'MacOS/ScenePopoverFixture'
    (contents / 'Info.plist').write_bytes(plistlib.dumps({
        'CFBundleExecutable': binary.name, 'CFBundleIdentifier': 'com.leesiongchan.bopify.scene-popover-fixture',
        'CFBundlePackageType': 'APPL', 'LSMinimumSystemVersion': '14.0'}))
    command = ['xcrun', 'swiftc', '-parse-as-library', '-swift-version', '6', '-default-isolation', 'MainActor',
               '-warnings-as-errors', '-target', 'arm64-apple-macosx14.0', '-module-cache-path', str(out / 'module-cache'),
               str(source), '-o', str(binary)]
    with (out / 'build.log').open('w') as log:
        subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, check=True)
    report = {'source_sha256': hashlib.sha256(source.read_bytes()).hexdigest(),
              'os': subprocess.check_output(['sw_vers'], text=True),
              'compiler': subprocess.check_output(['xcrun', 'swiftc', '--version'], text=True, stderr=subprocess.STDOUT), 'runs': []}
    for mode in ['control', 'binding', 'outside']:
        for index in range(1, 7):
            timed_out = False
            stem = f'{mode}-{index}'
            stdout_path, stderr_path = out / (stem + '.stdout'), out / (stem + '.stderr')
            with stdout_path.open('w') as stdout_log, stderr_path.open('w') as stderr_log:
                process = subprocess.Popen([str(binary), '--' + mode], stdout=stdout_log, stderr=stderr_log)
                try:
                    deadline = time.monotonic() + 5
                    while process.poll() is None and 'READY:' not in stdout_path.read_text() and time.monotonic() < deadline:
                        time.sleep(0.02)
                    code = process.wait(timeout=30)
                except subprocess.TimeoutExpired:
                    code, timed_out = None, True
                finally:
                    if process.poll() is None:
                        process.kill()
                        process.wait()
            stdout = stdout_path.read_text()
            status = classify(code, stdout, mode, timed_out)
            report['runs'].append({'mode': mode, 'iteration': index, 'exit_code': code, 'timed_out': timed_out, 'status': status})
            (out / 'summary.json').write_text(json.dumps(report, indent=2) + '\n')
            print(f'{stem}: {status} exit={code}', flush=True)
    return summary_exit([row['status'] for row in report['runs']])


if __name__ == '__main__':
    raise SystemExit(main())
