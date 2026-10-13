#!/usr/bin/env python3
"""Exercise app-owned lifecycle and artwork code without launching the app."""
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]
BUILD = ROOT / 'build/production-gaps'
PRODUCTS = BUILD / 'Build/Products/Debug'
FIXTURES = ROOT / 'docs/superpowers/verification'
OUTPUT = BUILD / 'boundary-tests'
OUTPUT.mkdir(parents=True, exist_ok=True)

subprocess.run(['xcodebuild', '-project', str(ROOT / 'Bopify/Bopify.xcodeproj'), '-scheme', 'Bopify',
                '-configuration', 'Debug', '-destination', 'platform=macOS,arch=arm64',
                '-derivedDataPath', str(BUILD), '-onlyUsePackageVersionsFromResolvedFile',
                'CODE_SIGNING_ALLOWED=NO', 'build'], cwd=ROOT, check=True)

common = ['swiftc', '-parse-as-library', '-D', 'DEBUG', '-swift-version', '6',
          '-default-isolation', 'MainActor', '-warnings-as-errors',
          '-target', 'arm64-apple-macosx14.0', '-module-cache-path', str(OUTPUT / 'module-cache'),
          '-I', str(PRODUCTS), '-I', str(ROOT / 'Packages/BopifyCore/Sources/CBopifyCore/include'),
          '-L', str(PRODUCTS), '-lbopify_core', '-liconv', '-lobjc']
for framework in ['AudioToolbox', 'CoreAudio', 'IOKit', 'CoreFoundation', 'Foundation', 'SystemConfiguration', 'Security']:
    common += ['-framework', framework]
objects = [str(PRODUCTS / (name + '.o')) for name in ['BopifyDomain', 'BopifyAuth', 'BopifyPlayback', 'BopifyLibrary', 'CBopifyCore']]
checks = [
    ('LogoutAcceptance', [ROOT / 'Bopify/Bopify/AppEnvironment.swift',
                          ROOT / 'Packages/BopifyCore/Tests/PlaybackTests/RecoveryStubEngine.swift'], [str(OUTPUT)]),
    ('ArtworkCacheProbe', [ROOT / 'Bopify/Bopify/ArtworkStore.swift'], []),
    ('ArtworkBoundaryProbe', [ROOT / 'Bopify/Bopify/ArtworkStore.swift'], ['--cooldown']),
]
for name, sources, arguments in checks:
    binary = OUTPUT / name
    dependencies = objects + ([str(PRODUCTS / 'Nuke.o')] if name.startswith('Artwork') else [])
    command = common + [str(FIXTURES / (name + '.swift'))] + [str(path) for path in sources] + dependencies + ['-o', str(binary)]
    subprocess.run(command, cwd=ROOT, check=True)
    subprocess.run([str(binary)] + arguments, cwd=ROOT, check=True, timeout=180)
