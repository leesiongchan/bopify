# Builds a separate app using the production SwiftUI views; never starts Spotify.
from pathlib import Path
import subprocess, shutil, sys, argparse
parser = argparse.ArgumentParser()
parser.add_argument("--derived-data", required=True)
parser.add_argument("--output", required=True)
parser.add_argument("--probe", choices=["window", "visual", "artwork", "composition", "mirror"], required=True)
parser.add_argument("--measure-ambient", action="store_true")
options = parser.parse_args()
root = Path(__file__).resolve().parents[3]
products = Path(options.derived_data).resolve() / 'Build/Products/Debug'
probe = Path(options.output).resolve()
app = probe / 'MonolithProbe.app/Contents'
(app / 'MacOS').mkdir(parents=True, exist_ok=True)
(app / 'Resources').mkdir(exist_ok=True)
sources = [str(p) for p in (root / 'Bopify/Bopify').rglob('*.swift') if p.name != 'BopifyApp.swift']
instrumented = None
if options.measure_ambient or options.probe == 'composition':
    original = root / 'Bopify/Bopify/Views/VinylRecordView.swift'
    instrumented = probe / 'InstrumentedVinylRecordView.swift'
    source = original.read_text()
    if options.measure_ambient:
        source = source.replace('paused: !isPlaying || !isVisible || reduceMotion)) { context in',
            'paused: !isPlaying || !isVisible || reduceMotion)) { context in\n                let _ = MonolithAmbientProbe.tick()')
        source += '\n@MainActor enum MonolithAmbientProbe { static var ticks = 0; static func tick() { ticks += 1 } }\n'
    if options.probe == 'composition':
        source = source.replace('.onChange(of: occurrenceID) { _, _ in',
            '.onChange(of: occurrenceID) { _, _ in\n            MonolithNavigationProbe.samples.append((occurrenceID, direction))')
        source += '\n@MainActor enum MonolithNavigationProbe { static var samples: [(String, CarouselDirection)] = [] }\n'
    instrumented.write_text(source)
    sources[sources.index(str(original))] = str(instrumented)
args = ['swiftc', '-parse-as-library', '-D', 'DEBUG', '-swift-version', '6', '-default-isolation', 'MainActor', '-target', 'arm64-apple-macos26.0', '-I', str(products), '-I', str(root / 'Packages/BopifyCore/Sources/CBopifyCore/include'), '-L', str(products), '-lbopify_core', '-liconv', '-lobjc']
if options.measure_ambient: args += ['-D', 'MONOLITH_MEASURE']
for framework in ['AudioToolbox', 'CoreAudio', 'IOKit', 'CoreFoundation', 'Foundation', 'SystemConfiguration', 'Security']:
    args += ['-framework', framework]
args += sources + [str(root / 'docs/superpowers/verification' / {'window': 'MonolithWindowProbe.swift', 'visual': 'MonolithVisualProbe.swift', 'artwork': 'ArtworkMorphProbe.swift', 'composition': 'MonolithCompositionProbe.swift', 'mirror': 'MonolithMirrorProbe.swift'}[options.probe])] + [str(products / (name + '.o')) for name in ['BopifyDomain', 'BopifyPlayback', 'BopifyAuth', 'BopifyLibrary', 'CBopifyCore']]
args += ['-o', str(app / 'MacOS/MonolithProbe')]
subprocess.run(args, check=True)
if instrumented: instrumented.unlink()
for source in (products / 'Bopify.app/Contents/Resources').iterdir():
    if source.is_file(): shutil.copy2(source, app / 'Resources' / source.name)
    elif source.is_dir(): shutil.copytree(source, app / 'Resources' / source.name, dirs_exist_ok=True)
(app / 'Info.plist').write_text('<plist version="1.0"><dict><key>CFBundleExecutable</key><string>MonolithProbe</string><key>CFBundleIdentifier</key><string>my.snsoft.bopify.monolith-probe</string><key>CFBundlePackageType</key><string>APPL</string></dict></plist>')

print(app / "MacOS/MonolithProbe")

result = subprocess.run([str(app / "MacOS/MonolithProbe"), str(probe)])
print("Report/captures:", probe)
sys.exit(result.returncode)
