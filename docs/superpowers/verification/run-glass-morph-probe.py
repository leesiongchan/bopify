# Builds a separate app using the production SwiftUI views; never starts Spotify.
from pathlib import Path
import subprocess, shutil, sys
root = Path(__file__).resolve().parents[3]
products = Path(sys.argv[1]).resolve() / 'Build/Products/Debug'
probe = Path(sys.argv[2]).resolve()
app = probe / 'GlassProbe.app/Contents'
(app / 'MacOS').mkdir(parents=True, exist_ok=True)
(app / 'Resources').mkdir(exist_ok=True)
sources = [str(p) for p in (root / 'Bopify/Bopify').rglob('*.swift') if p.name != 'BopifyApp.swift']
args = ['swiftc', '-parse-as-library', '-D', 'DEBUG', '-swift-version', '6', '-default-isolation', 'MainActor', '-target', 'arm64-apple-macos26.0', '-I', str(products), '-I', str(root / 'Packages/BopifyCore/Sources/CBopifyCore/include'), '-L', str(products), '-lbopify_core', '-liconv', '-lobjc']
for framework in ['AudioToolbox', 'CoreAudio', 'IOKit', 'CoreFoundation', 'Foundation', 'SystemConfiguration', 'Security']:
    args += ['-framework', framework]
args += sources + [str(root / 'docs/superpowers/verification/NativeGlassMorphProbe.swift')] + [str(products / (name + '.o')) for name in ['BopifyDomain', 'BopifyPlayback', 'BopifyAuth', 'BopifyLibrary', 'CBopifyCore']]
args += ['-o', str(app / 'MacOS/GlassProbe')]
subprocess.run(args, check=True)
for source in (products / 'Bopify.app/Contents/Resources').iterdir():
    if source.is_file(): shutil.copy2(source, app / 'Resources' / source.name)
(app / 'Info.plist').write_text('<plist version="1.0"><dict><key>CFBundleExecutable</key><string>GlassProbe</string><key>CFBundleIdentifier</key><string>com.leesiongchan.bopify.glass-probe</string><key>CFBundlePackageType</key><string>APPL</string></dict></plist>')

print(app / "MacOS/GlassProbe")
