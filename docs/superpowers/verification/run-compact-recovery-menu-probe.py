#!/usr/bin/env python3
"""Check recovery-menu layout and local accessibility; input is covered by run-recovery-menu-ui-tests.py."""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import shutil
import subprocess
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--derived-data', required=True, type=Path)
parser.add_argument('--output', required=True, type=Path)
parser.add_argument('--candidate-source', type=Path, help='Throwaway copy of the status/menu source; never modifies production')
args = parser.parse_args()
root = Path(__file__).resolve().parents[3]
products = args.derived_data.resolve() / 'Build/Products/Debug'
out = args.output.resolve()
contents = out / 'CompactRecoveryMenuProbe.app/Contents'
(contents / 'MacOS').mkdir(parents=True, exist_ok=True)
resources = contents / 'Resources'
resources.mkdir(exist_ok=True)
for item in (products / 'Bopify.app/Contents/Resources').iterdir():
    if item.is_file(): shutil.copy2(item, resources / item.name)
    elif item.is_dir(): shutil.copytree(item, resources / item.name, dirs_exist_ok=True)
binary = contents / 'MacOS/CompactRecoveryMenuProbe'
(contents / 'Info.plist').write_bytes(plistlib.dumps({'CFBundleExecutable': binary.name,
    'CFBundleIdentifier': 'com.leesiongchan.bopify.compact-menu-probe', 'CFBundlePackageType': 'APPL', 'LSMinimumSystemVersion': '26.0'}))
command = ['xcrun', 'swiftc', '-parse-as-library', '-swift-version', '6', '-default-isolation', 'MainActor',
    '-warnings-as-errors', '-target', 'arm64-apple-macosx26.0', '-module-cache-path', str(out / 'module-cache'),
    '-I', str(products), '-I', str(root / 'Packages/BopifyCore/Sources/CBopifyCore/include'),
    '-L', str(products), '-lbopify_core', '-liconv', '-lobjc']
for framework in ['AudioToolbox', 'CoreAudio', 'IOKit', 'CoreFoundation', 'Foundation', 'SystemConfiguration', 'Security']:
    command += ['-framework', framework]
source = args.candidate_source.resolve() if args.candidate_source else root / 'Bopify/Bopify/Views/PlaybackConnectionStatusView.swift'
fixture = root / 'docs/superpowers/verification/CompactRecoveryMenuProbe.swift'
compiled_source, compiled_fixture = out / ('Compiled' + source.name), out / ('Compiled' + fixture.name)
shutil.copy2(source, compiled_source)
shutil.copy2(fixture, compiled_fixture)
command += [str(compiled_source), str(compiled_fixture)]
command += [str(products / (name + '.o')) for name in ['BopifyDomain', 'BopifyPlayback', 'CBopifyCore']]
command += ['-o', str(binary)]
with (out / 'build.log').open('w') as log:
    subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, check=True)
with (out / 'runtime.log').open('w') as log:
    process = subprocess.Popen([str(binary), str(out)], stdout=log, stderr=subprocess.STDOUT)
    try:
        deadline = time.monotonic() + 5
        while process.poll() is None and 'READY:' not in (out / 'runtime.log').read_text() and time.monotonic() < deadline:
            time.sleep(0.02)
        code = process.wait(timeout=90)
    finally:
        if process.poll() is None:
            process.kill()
            process.wait()
(out / 'run-metadata.json').write_text(json.dumps({'exit_code': code,
    'source': str(source), 'source_sha256': hashlib.sha256(compiled_source.read_bytes()).hexdigest(),
    'fixture_sha256': hashlib.sha256(compiled_fixture.read_bytes()).hexdigest(),
    'os': subprocess.check_output(['sw_vers'], text=True), 'minimum_target': 'macOS 26.0'}, indent=2) + '\n')
print(f'menu fixture exit={code}; evidence: {out}', flush=True)
raise SystemExit(code)
