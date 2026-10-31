#!/usr/bin/env python3
"""Run native vinyl screenshots from a host with Screen Recording permission.

XCTest may lack that permission even when its launching terminal has it. This
helper captures only windows owned by the selected Xcode's XCTest agent. Images
stay in /tmp/bopify-vinyl-validation; no application credentials are accessed.
Pass --all to run the full native suite with screenshot coverage enabled.
"""

import argparse
import ctypes
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import tempfile
import threading


def verify_keyboard(repo):
    with tempfile.TemporaryDirectory(prefix='bopify-vinyl-keyboard-') as temporary:
        root = Path(temporary)
        app = root / 'VinylKeyboardTests.app'
        contents = app / 'Contents'
        (contents / 'MacOS').mkdir(parents=True)
        (contents / 'Resources').mkdir()
        sources = [
            'Packages/BopifyCore/Sources/BopifyPlayback/ArtworkPalette.swift',
            'Packages/BopifyCore/Sources/BopifyDomain/BopifyLog.swift',
            'Bopify/Bopify/Views/VinylDesign.swift', 'Bopify/Bopify/Views/VinylDesignPalette.swift',
            'Bopify/Bopify/Views/VinylDesignPickerModel.swift',
            'Bopify/Bopify/Views/VinylPressingView.swift', 'Bopify/Bopify/Views/PlayerSurface.swift',
            'Bopify/Bopify/Views/VinylDesignPicker.swift',
            'Bopify/Bopify/MenuBar/VinylDesignWindowController.swift',
            'scripts/fixtures/VinylKeyboardHost.swift',
        ]
        source = '\n'.join((repo / path).read_text().replace('import BopifyPlayback\n', '').replace('import BopifyDomain\n', '') for path in sources)
        (root / 'Host.swift').write_text(source)
        (contents / 'Info.plist').write_bytes(plistlib.dumps({
            'CFBundleIdentifier': 'dev.bopify.VinylKeyboardTests', 'CFBundleExecutable': 'VinylKeyboardTests',
            'CFBundleName': 'Vinyl keyboard tests', 'CFBundlePackageType': 'APPL', 'CFBundleVersion': '1',
            'CFBundleDevelopmentRegion': 'en', 'NSPrincipalClass': 'NSApplication',
        }))
        resources = Path('/tmp/bopify-vinyl-tests/Build/Products/Debug/BopifyAppTests.xctest/Contents/Resources')
        shutil.copy(resources / 'default.metallib', contents / 'Resources/default.metallib')
        shutil.copytree(resources / 'en.lproj', contents / 'Resources/en.lproj')
        subprocess.run(['xcrun', 'swiftc', '-O', '-swift-version', '6', '-parse-as-library', str(root / 'Host.swift'),
                        '-o', str(contents / 'MacOS/VinylKeyboardTests')], check=True)
        subprocess.run(['codesign', '--force', '--sign', '-', str(app)], check=True)
        subprocess.run(['open', '-n', '-W', str(app)], check=True, timeout=20)
        result = json.loads((root / 'keyboard-results.json').read_text())
        print('Native keyboard checks:', json.dumps(result), flush=True)
        if result != {'keyboardStyle': 'bloom', 'returnStyle': 'rhapsody', 'escapeCloses': True, 'reusesWindow': True, 'windowWasKey': True}:
            raise ValueError('Native chooser keyboard checks failed')


def window_owner(window):
    cg = ctypes.CDLL('/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics')
    cf = ctypes.CDLL('/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation')
    cg.CGWindowListCopyWindowInfo.argtypes = [ctypes.c_uint32, ctypes.c_uint32]
    cg.CGWindowListCopyWindowInfo.restype = ctypes.c_void_p
    cf.CFPropertyListCreateData.argtypes = [ctypes.c_void_p, ctypes.c_void_p, ctypes.c_long, ctypes.c_ulong, ctypes.c_void_p]
    cf.CFPropertyListCreateData.restype = ctypes.c_void_p
    cf.CFDataGetLength.argtypes = [ctypes.c_void_p]
    cf.CFDataGetLength.restype = ctypes.c_long
    cf.CFDataGetBytePtr.argtypes = [ctypes.c_void_p]
    cf.CFDataGetBytePtr.restype = ctypes.c_void_p
    cf.CFRelease.argtypes = [ctypes.c_void_p]
    windows = cg.CGWindowListCopyWindowInfo(8, window)
    if not windows:
        raise ValueError('Window is not available')
    data = None
    try:
        data = cf.CFPropertyListCreateData(None, windows, 100, 0, None)
        if not data:
            raise ValueError('Cannot inspect window ownership')
        info = plistlib.loads(ctypes.string_at(cf.CFDataGetBytePtr(data), cf.CFDataGetLength(data)))
        return next(item['kCGWindowOwnerPID'] for item in info if item['kCGWindowNumber'] == window)
    finally:
        if data:
            cf.CFRelease(data)
        cf.CFRelease(windows)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--all', action='store_true', help='Run the entire app test suite')
    args = parser.parse_args()
    repo = Path(__file__).resolve().parents[1]
    output = Path('/tmp/bopify-vinyl-validation')
    output.mkdir(mode=0o700, exist_ok=True)
    if output.is_symlink() or output.stat().st_uid != os.getuid():
        raise ValueError('Artifact directory must belong to the current user')
    requests = output / 'capture-requests'
    if requests.exists() or requests.is_symlink():
        raise ValueError('A capture helper is already running or left capture-requests behind')
    requests.mkdir(mode=0o700)
    developer = Path(subprocess.check_output(['xcrun', '--find', 'xcodebuild'], text=True).strip()).parents[2]
    agent = developer / 'Platforms/MacOSX.platform/Developer/Library/Xcode/Agents/xctest'
    stop = threading.Event()

    def capture_requests():
        while not stop.wait(0.02):
            for request in requests.glob('*.request'):
                status = 'invalid capture request'
                try:
                    if request.is_symlink() or request.stat().st_size > 4096:
                        raise ValueError('Invalid request file')
                    payload = json.loads(request.read_text())
                    window, pid, name = payload['window'], payload['pid'], payload['file']
                    if type(window) is not int or window <= 0 or type(pid) is not int or pid <= 0:
                        raise ValueError('Invalid window or process')
                    if not isinstance(name, str) or not re.fullmatch(r'[A-Za-z0-9_.-]+\.png', name):
                        raise ValueError('Invalid screenshot filename')
                    executable = subprocess.check_output(['ps', '-p', str(pid), '-o', 'comm='], text=True).strip()
                    if Path(executable).resolve() != agent.resolve() or window_owner(window) != pid:
                        raise ValueError('Only XCTest-owned windows may be captured')
                    destination = output / name
                    if destination.is_symlink():
                        raise ValueError('Screenshot destination cannot be a symlink')
                    # Capture into our own temporary file, then replace the named artifact.
                    with tempfile.NamedTemporaryFile(dir=output, suffix='.png') as temporary:
                        result = subprocess.run(['/usr/sbin/screencapture', '-x', '-o', '-l', str(window), temporary.name], capture_output=True, text=True, timeout=5)
                        if result.returncode:
                            raise ValueError(result.stderr.strip() or 'Window capture failed')
                        os.replace(temporary.name, destination)
                        Path(temporary.name).touch()  # NamedTemporaryFile owns cleanup of this path.
                    status = 'ok'
                except (ValueError, KeyError, OSError, StopIteration, subprocess.SubprocessError) as error:
                    status = str(error)
                response = request.with_suffix('.response')
                temporary_response = request.with_suffix('.response-writing')
                temporary_response.write_text(status)
                temporary_response.replace(response)
                request.unlink(missing_ok=True)

    worker = threading.Thread(target=capture_requests, daemon=True)
    try:
        worker.start()
        (requests / 'ready').touch()
        command = ['xcodebuild', '-quiet', '-project', 'Bopify/Bopify.xcodeproj', '-scheme', 'BopifyAppTests',
                   '-destination', 'platform=macOS,arch=arm64', '-derivedDataPath', '/tmp/bopify-vinyl-tests', 'CODE_SIGNING_ALLOWED=NO']
        if not args.all:
            command += ['-only-testing:BopifyAppTests/VinylRenderingTests']
        status = subprocess.call(command + ['test'], cwd=repo)
        if status == 0:
            verify_keyboard(repo)
        return status
    finally:
        stop.set()
        worker.join(timeout=6)
        shutil.rmtree(requests)


if __name__ == '__main__':
    raise SystemExit(main())
