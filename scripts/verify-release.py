#!/usr/bin/env python3
import json
from pathlib import Path
import plistlib
import re
import subprocess
import sys

CAPABILITIES = {'com.apple.security.app-sandbox', 'com.apple.security.network.client',
                'com.apple.security.network.server', 'com.apple.security.files.user-selected.read-only'}


def require(condition, message):
    if not condition:
        raise ValueError(message)


def run(*args):
    return subprocess.run(args, capture_output=True, text=True, check=True)


def verify(app, version, build):
    app = Path(app)
    run('codesign', '--verify', '--deep', '--strict', str(app))
    require(run('lipo', '-archs', str(app / 'Contents/MacOS/Bopify')).stdout.strip() == 'arm64', 'Export must be arm64 only.')
    signature = run('codesign', '--display', '--verbose=4', str(app)).stderr
    require('Signature=adhoc\n' in signature, 'Release must use an ad-hoc signature.')
    require('TeamIdentifier=not set\n' in signature and not re.search(r'^Authority=', signature, re.MULTILINE), 'Ad-hoc release must not claim a signing team or authority.')
    require(re.search(r'flags=0x[0-9A-Fa-f]+\([^)]*\bruntime\b', signature), 'Export is missing hardened runtime.')
    rights = plistlib.loads(run('codesign', '--display', '--entitlements', '-', '--xml', str(app)).stdout.encode())
    require(all(rights.get(key) is True for key in CAPABILITIES), 'Export lost a required sandbox or network capability.')
    require(not (set(rights) - CAPABILITIES), 'Export contains unapproved entitlements, including possible debugger/runtime exceptions.')
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    require(info['CFBundleIdentifier'] == 'com.leesiongchan.bopify', 'Export bundle identity changed.')
    require(info.get('LSMinimumSystemVersion') == '26.0', 'Export must declare the macOS 26.0 minimum.')
    require(info['CFBundleShortVersionString'] == version and info['CFBundleVersion'] == build, 'Export version does not match requested release.')
    report = {'bundle': info['CFBundleIdentifier'], 'version': version, 'build': build,
              'architecture': 'arm64', 'minimum_macos': '26.0', 'team': None, 'runtime': True,
              'entitlements': rights, 'signing': 'ad-hoc', 'notarized': False}
    print(json.dumps(report, indent=2))


try:
    require(len(sys.argv) == 4, 'Usage: verify-release.py APP VERSION BUILD')
    verify(*sys.argv[1:])
except (ValueError, KeyError, OSError, plistlib.InvalidFileException, subprocess.CalledProcessError) as error:
    print(f'ERROR: {error}', file=sys.stderr)
    sys.exit(1)
