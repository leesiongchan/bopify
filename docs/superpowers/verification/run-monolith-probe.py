# Builds a separate app using the production SwiftUI views; never starts Spotify.
from pathlib import Path
import subprocess, shutil, sys, argparse
parser = argparse.ArgumentParser()
parser.add_argument("--derived-data", required=True)
parser.add_argument("--output", required=True)
parser.add_argument("--probe", choices=["window", "visual", "artwork", "composition", "mirror", "surface", "library", "library-client", "live-library", "refinement", "input-routing", "recovery", "credentials", "artwork-cache", "pressing"], required=True)
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
        marker = 'paused: !isMoving || !isVisible || reduceMotion || isScrubbing)) { _ in'
        assert source.count(marker) == 1, 'ambient probe instrumentation marker changed'
        source = source.replace(marker, marker + '\n            let _ = MonolithAmbientProbe.tick()')
        source += '\n@MainActor enum MonolithAmbientProbe { static var ticks = 0; static func tick() { ticks += 1 } }\n'
        if options.probe == 'pressing':
            marker = '.accessibilityHidden(true)'
            assert source.count(marker) == 1, 'contrast instrumentation marker changed'
            source = source.replace(marker, marker + '\n        .onChange(of: contrast, initial: true) { _, value in MonolithPressingProbe.contrast = value }')
    if options.probe == 'composition':
        assert source.count('.onChange(of: occurrenceID) { _, _ in') == 1, 'navigation probe instrumentation marker changed'
        source = source.replace('.onChange(of: occurrenceID) { _, _ in',
            '.onChange(of: occurrenceID) { _, _ in\n            MonolithNavigationProbe.samples.append((occurrenceID, direction))')
        source += '\n@MainActor enum MonolithNavigationProbe { static var samples: [(String, CarouselDirection)] = [] }\n'
    instrumented.write_text(source)
    sources[sources.index(str(original))] = str(instrumented)
if options.measure_ambient and options.probe == 'pressing':
    original = root / 'Bopify/Bopify/Views/RecordPlayerView.swift'
    measured = probe / 'InstrumentedRecordPlayerView.swift'
    source = original.read_text()
    marker = 'isCoasting = request == .brake && rotation.isMoving(at: time)'
    assert source.count(marker) == 1, 'motor anchor instrumentation marker changed'
    source = source.replace(marker, marker + '\n        MonolithMotorProbe.samples.append((request, rotation.angle(at: time), rotation.speed(at: time)))')
    marker = 'displayedPressing = ready'
    assert source.count(marker) == 1, 'pressing publication instrumentation marker changed'
    source = source.replace(marker, marker + '\n            MonolithPressingProbe.samples.append((ready.seed, ready.palette))')
    source += '\n@MainActor enum MonolithMotorProbe { static var samples: [(RecordMotorRequest, Double, Double)] = []; static var seeks: [Int64] = [] }\n'
    source += '\n@MainActor enum MonolithPressingProbe { static var samples: [(Float, ArtworkPalette)] = []; static var layers = 0; static var contrast: ColorSchemeContrast = .standard }\n'
    measured.write_text(source)
    sources[sources.index(str(original))] = str(measured)
    original = root / 'Bopify/Bopify/Views/VinylPressingView.swift'
    measured = probe / 'InstrumentedVinylPressingView.swift'
    source = original.read_text()
    marker = '.frame(width: diameter, height: diameter)'
    assert source.count(marker) == 1, 'pressing layer instrumentation marker changed'
    measured.write_text(source.replace(marker, marker + '\n        .onAppear { MonolithPressingProbe.layers += 1 }\n        .onDisappear { MonolithPressingProbe.layers -= 1 }'))
    sources[sources.index(str(original))] = str(measured)
    original = root / 'Bopify/Bopify/Views/PreviewPlaybackEngine.swift'
    measured = probe / 'InstrumentedPreviewPlaybackEngine.swift'
    source = original.read_text()
    marker = 'func seek(to milliseconds: Int64) async throws {'
    assert source.count(marker) == 1, 'seek instrumentation marker changed'
    measured.write_text(source.replace(marker, marker + '\n        await MainActor.run { MonolithMotorProbe.seeks.append(milliseconds) }'))
    sources[sources.index(str(original))] = str(measured)
args = ['swiftc', '-parse-as-library', '-D', 'DEBUG', '-swift-version', '6', '-default-isolation', 'MainActor', '-target', 'arm64-apple-macos26.0', '-I', str(products), '-I', str(root / 'Packages/BopifyCore/Sources/CBopifyCore/include'), '-L', str(products), '-lbopify_core', '-liconv', '-lobjc']
if options.measure_ambient: args += ['-D', 'MONOLITH_MEASURE']
for framework in ['AudioToolbox', 'CoreAudio', 'IOKit', 'CoreFoundation', 'Foundation', 'SystemConfiguration', 'Security']:
    args += ['-framework', framework]
args += sources + [str(root / 'docs/superpowers/verification' / {'window': 'MonolithWindowProbe.swift', 'visual': 'MonolithVisualProbe.swift', 'artwork': 'ArtworkMorphProbe.swift', 'composition': 'MonolithCompositionProbe.swift', 'mirror': 'MonolithMirrorProbe.swift', 'surface': 'MonolithSurfaceProbe.swift', 'library': 'MonolithLibraryProbe.swift', 'library-client': 'LibraryClientIntegrationProbe.swift', 'live-library': 'MonolithLiveLibraryProbe.swift', 'refinement': 'MonolithRefinementProbe.swift', 'input-routing': 'MonolithInputRoutingProbe.swift', 'recovery': 'PlaybackRecoveryProbe.swift', 'credentials': 'PlaybackRecoveryProbe.swift', 'artwork-cache': 'ArtworkCacheProbe.swift', 'pressing': 'VinylPressingProbe.swift'}[options.probe])] + [str(products / (name + '.o')) for name in ['BopifyDomain', 'BopifyPlayback', 'BopifyAuth', 'BopifyLibrary', 'CBopifyCore']]
if options.probe == 'library':
    args += [str(root / 'Packages/BopifyCore/Tests/PlaybackTests/StubPlaybackEngine.swift')]
args += ['-o', str(app / 'MacOS/MonolithProbe')]
subprocess.run(args, check=True)
if instrumented: instrumented.unlink()
for source in (products / 'Bopify.app/Contents/Resources').iterdir():
    if source.is_file(): shutil.copy2(source, app / 'Resources' / source.name)
    elif source.is_dir(): shutil.copytree(source, app / 'Resources' / source.name, dirs_exist_ok=True)
if options.probe == 'pressing':
    assert (products / 'Bopify.app/Contents/Resources/default.metallib').is_file(), 'app shader library missing'
    assert (app / 'Resources/default.metallib').is_file(), 'fixture shader library missing'
(app / 'Info.plist').write_text('<plist version="1.0"><dict><key>CFBundleExecutable</key><string>MonolithProbe</string><key>CFBundleIdentifier</key><string>com.leesiongchan.bopify.monolith-probe</string><key>CFBundlePackageType</key><string>APPL</string></dict></plist>')

print(app / "MacOS/MonolithProbe")

result = subprocess.run([str(app / "MacOS/MonolithProbe"), str(probe)] + (["--credentials-only"] if options.probe == "credentials" else []))
print("Report/captures:", probe)
sys.exit(result.returncode)
