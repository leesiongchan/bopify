# Builds a separate app using the production SwiftUI views; never starts Spotify.
from pathlib import Path
import subprocess, shutil, sys, argparse
parser = argparse.ArgumentParser()
parser.add_argument("--derived-data", required=True)
parser.add_argument("--output", required=True)
parser.add_argument("--probe", choices=["window", "visual", "artwork"], required=True)
options = parser.parse_args()
root = Path(__file__).resolve().parents[3]
products = Path(options.derived_data).resolve() / 'Build/Products/Debug'
probe = Path(options.output).resolve()
app = probe / 'MonolithProbe.app/Contents'
(app / 'MacOS').mkdir(parents=True, exist_ok=True)
(app / 'Resources').mkdir(exist_ok=True)
sources = [str(p) for p in (root / 'Bopify/Bopify').rglob('*.swift') if p.name != 'BopifyApp.swift']
args = ['swiftc', '-parse-as-library', '-D', 'DEBUG', '-swift-version', '6', '-default-isolation', 'MainActor', '-target', 'arm64-apple-macos26.0', '-I', str(products), '-I', str(root / 'Packages/BopifyCore/Sources/CBopifyCore/include'), '-L', str(products), '-lbopify_core', '-liconv', '-lobjc']
for framework in ['AudioToolbox', 'CoreAudio', 'IOKit', 'CoreFoundation', 'Foundation', 'SystemConfiguration', 'Security']:
    args += ['-framework', framework]
args += sources + [str(root / 'docs/superpowers/verification' / {'window': 'MonolithWindowProbe.swift', 'visual': 'MonolithVisualProbe.swift', 'artwork': 'ArtworkMorphProbe.swift'}[options.probe])] + [str(products / (name + '.o')) for name in ['BopifyDomain', 'BopifyPlayback', 'BopifyAuth', 'BopifyLibrary', 'CBopifyCore']]
args += ['-o', str(app / 'MacOS/MonolithProbe')]
subprocess.run(args, check=True)
for source in (products / 'Bopify.app/Contents/Resources').iterdir():
    if source.is_file(): shutil.copy2(source, app / 'Resources' / source.name)
    elif source.is_dir(): shutil.copytree(source, app / 'Resources' / source.name, dirs_exist_ok=True)
(app / 'Info.plist').write_text('<plist version="1.0"><dict><key>CFBundleExecutable</key><string>MonolithProbe</string><key>CFBundleIdentifier</key><string>my.snsoft.bopify.monolith-probe</string><key>CFBundlePackageType</key><string>APPL</string></dict></plist>')

print(app / "MacOS/MonolithProbe")

result = subprocess.run([str(app / "MacOS/MonolithProbe"), str(probe)])
print("Report/captures:", probe)
sys.exit(result.returncode)
