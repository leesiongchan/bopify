#!/usr/bin/env python3
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import sys
import uuid

TEAM = '6RS6K2N242'
CAPABILITIES = {'com.apple.security.app-sandbox', 'com.apple.security.network.client',
                'com.apple.security.network.server', 'com.apple.security.files.user-selected.read-only'}


def require(condition, message):
    if not condition:
        raise ValueError(message)


def run(*args):
    return subprocess.run(args, capture_output=True, text=True, check=True)


def identity():
    selected = os.environ.get('SIGN_IDENTITY', 'Developer ID Application')
    for line in run('security', 'find-identity', '-v', '-p', 'codesigning').stdout.splitlines():
        match = re.fullmatch(r'\s*\d+\)\s+([0-9A-Fa-f]{40})\s+"(.+)"\s*', line)
        if match:
            fingerprint, subject = match.groups()
            if subject.startswith('Developer ID Application:') and subject.endswith(f'({TEAM})'):
                if selected in ['Developer ID Application', fingerprint, subject]:
                    print(fingerprint)
                    return
    raise ValueError(f'No usable Developer ID Application signing identity for team {TEAM}; install it before releasing.')


def export(app, version, build, ad_hoc=False):
    app = Path(app)
    run('codesign', '--verify', '--deep', '--strict', str(app))
    require(run('lipo', '-archs', str(app / 'Contents/MacOS/Bopify')).stdout.strip() == 'arm64', 'Export must be arm64 only.')
    signature = run('codesign', '--display', '--verbose=4', str(app)).stderr
    if ad_hoc:
        require('Signature=adhoc\n' in signature, 'Free release must use an ad-hoc signature.')
        require('TeamIdentifier=not set\n' in signature and not re.search(r'^Authority=', signature, re.MULTILINE), 'Ad-hoc release must not claim a signing team or authority.')
    else:
        require(re.search(r'^Authority=Developer ID Application:', signature, re.MULTILINE), 'Export must use Developer ID Application signing.')
        require(f'TeamIdentifier={TEAM}\n' in signature, 'Export team identity changed.')
    require(re.search(r'flags=0x[0-9A-Fa-f]+\([^)]*\bruntime\b', signature), 'Export is missing hardened runtime.')
    rights = plistlib.loads(run('codesign', '--display', '--entitlements', '-', '--xml', str(app)).stdout.encode())
    require(all(rights.get(key) is True for key in CAPABILITIES), 'Export lost a required sandbox or network capability.')
    identity_keys = set() if ad_hoc else {'com.apple.application-identifier', 'com.apple.developer.team-identifier'}
    require(not (set(rights) - CAPABILITIES - identity_keys), 'Export contains unapproved entitlements, including possible debugger/runtime exceptions.')
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    require(info['CFBundleIdentifier'] == 'com.leesiongchan.bopify', 'Export bundle identity changed.')
    require(info.get('LSMinimumSystemVersion') == '26.0', 'Export must declare the macOS 26.0 minimum.')
    require(info['CFBundleShortVersionString'] == version and info['CFBundleVersion'] == build, 'Export version does not match requested release.')
    report = {'bundle': info['CFBundleIdentifier'], 'version': version, 'build': build,
              'architecture': 'arm64', 'minimum_macos': '26.0', 'team': None if ad_hoc else TEAM, 'runtime': True,
              'entitlements': rights, 'signing': 'ad-hoc' if ad_hoc else 'developer-id'}
    if ad_hoc:
        report['notarized'] = False
    print(json.dumps(report, indent=2))


def notary(submission_path, log_path, artifact_path):
    submission = json.loads(Path(submission_path).read_text())
    log = json.loads(Path(log_path).read_text())
    identifier = str(uuid.UUID(submission['id']))
    require(submission['status'] == 'Accepted', 'Notarization was not accepted.')
    require(log['jobId'] == identifier and log['status'] == 'Accepted' and log['statusCode'] == 0, 'Notarization log does not confirm this accepted submission.')
    require(log['issues'] is None or log['issues'] == [], 'Notarization log contains unresolved warnings or errors.')
    digest = hashlib.sha256()
    with Path(artifact_path).open('rb') as artifact:
        for chunk in iter(lambda: artifact.read(1024 * 1024), b''):
            digest.update(chunk)
    require(log['sha256'] == digest.hexdigest(), 'Notarization log belongs to a different artifact.')
    print(f'Accepted notarization verified: {identifier}')


try:
    mode, *arguments = sys.argv[1:]
    if mode == 'identity' and not arguments:
        identity()
    elif mode in ['export', 'adhoc'] and len(arguments) == 3:
        export(*arguments, ad_hoc=mode == 'adhoc')
    elif mode == 'notary' and len(arguments) == 3:
        notary(*arguments)
    else:
        raise ValueError('Usage: verify-release.py identity | export/adhoc APP VERSION BUILD | notary SUBMISSION LOG DMG')
except (ValueError, KeyError, OSError, plistlib.InvalidFileException, subprocess.CalledProcessError) as error:
    print(f'ERROR: {error}', file=sys.stderr)
    sys.exit(1)
