# Reproduce the optimized scene comparison

Run from the repository root on macOS with Xcode 27. The fixture requires a 2× backing display and uses `NSScreen.screens[0]`. The recorded machine used display ID 3, 3840×2160. Keep artwork, geometry, display and desktop activity consistent between variants. The commands below build fixture copies only; production sources remain untouched.

The baseline includes the completed motor and palette/cache work immediately before the shader change (`9a1ba22b2a848173acc415be866ba568e3ae6859`). The after source is merged main with the reviewed opaque backing (`9bb79967ddbff26037a6e4a78df0fcc1673bb14f`). Their package sources are identical. Both link the same optimized package objects and shader library; the baseline view does not call the pressing shader.

~~~sh
vinyl_profile_dir=$(mktemp -d /private/tmp/bopify-vinyl-gpu.XXXXXX)
vinyl_evidence="$PWD/docs/superpowers/verification/assets/vinyl-gpu-2026-10-11"
for vinyl_variant in before after; do
  case "$vinyl_variant" in
    before) vinyl_revision=9a1ba22b2a848173acc415be866ba568e3ae6859 ;;
    after) vinyl_revision=9bb79967ddbff26037a6e4a78df0fcc1673bb14f ;;
  esac
  mkdir "$vinyl_profile_dir/$vinyl_variant"
  git archive "$vinyl_revision" Bopify/Bopify Packages/BopifyCore/Sources/CBopifyCore/include | tar -x -C "$vinyl_profile_dir/$vinyl_variant"
  ln -s "$PWD/artifacts" "$vinyl_profile_dir/$vinyl_variant/artifacts"
  git show 9bb7996:docs/superpowers/verification/VinylPressingProbe.swift > "$vinyl_profile_dir/$vinyl_variant/VinylPressingProbe.swift"
  patch -p1 -d "$vinyl_profile_dir/$vinyl_variant" < "$vinyl_evidence/gpu-fixture.patch"
done
git show 9bb7996:docs/superpowers/verification/run-monolith-probe.py > "$vinyl_profile_dir/build-fixture.py"
patch -p1 -d "$vinyl_profile_dir" < "$vinyl_evidence/gpu-runner.patch"
xcodebuild -quiet -project Bopify/Bopify.xcodeproj -scheme Bopify -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath "$vinyl_profile_dir/build" build CODE_SIGNING_ALLOWED=NO SWIFT_OPTIMIZATION_LEVEL=-O SWIFT_COMPILATION_MODE=wholemodule
for vinyl_variant in before after; do
  python3 "$vinyl_profile_dir/build-fixture.py" --derived-data "$vinyl_profile_dir/build" --output "$vinyl_profile_dir/$vinyl_variant-fixture" --probe pressing --source-root "$vinyl_profile_dir/$vinyl_variant" --build-only
done
~~~

Debug is intentional: `PlayerModel.applyPreviewEvents` and sample artwork helpers are under `#if DEBUG`; Release package objects omit the required entry point. Both the fixture compiler and package/app build use `-O`. This is optimized Debug verification, not a production Release executable. There is no `MONOLITH_MEASURE`, tick counter or per-frame logging.

Run one variant at a time and allow each export to finish before starting the next capture. Alternate variants across repeated runs. Output directories must be new; the helper refuses to overwrite a capture.

~~~sh
python3 docs/superpowers/verification/run-vinyl-gpu-capture.py --binary "$vinyl_profile_dir/after-fixture/MonolithProbe.app/Contents/MacOS/MonolithProbe" --output "$vinyl_profile_dir/after-1"
python3 docs/superpowers/verification/run-vinyl-gpu-capture.py --binary "$vinyl_profile_dir/before-fixture/MonolithProbe.app/Contents/MacOS/MonolithProbe" --output "$vinyl_profile_dir/before-1"
vinyl_probe_pid=$(bat --style=plain --color=never "$vinyl_profile_dir/after-1/pid.txt")
python3 docs/superpowers/verification/analyze-vinyl-gpu-trace.py --updates "$vinyl_profile_dir/after-1/hitches-updates.xml" --gpu "$vinyl_profile_dir/after-1/hitches-gpu.xml" --renders "$vinyl_profile_dir/after-1/hitches-renders.xml" --hitches "$vinyl_profile_dir/after-1/hitches.xml" --pid "$vinyl_probe_pid" --start 2 --end 12 > "$vinyl_profile_dir/after-1/associated.json"
~~~

The helper launches the exact executable, checks its readiness PID, captures Animation Hitches system-wide for 12 seconds, and exports five tables. The fixture takes its screenshot before readiness and before recording. Analysis selects top-level target-process updates, resolves XML references, deduplicates `(display, swap-id, surface-id)`, and joins top-level GPU/render intervals with starts in `[2,12)` seconds. Read `device-display-info.xml` to map trace display labels to the physical display logged by the fixture. Do not substitute CPU update times for GPU duration, sum overlapping Metal encoder channels, or compare unfiltered desktop GPU totals.

The output is shared compositor-frame GPU time associated with the player's updates. It includes other desktop composition in those frames. It does not identify which GPU operations evaluate the pressing shader; caching can also make steady-state cost differ from first rendering. Hitch counts describe only the measured steady-playing windows; repeated captures recorded hitches in both variants.

Raw traces stay local: their metadata can include process environment values. The checked-in JSON contains filtered measurements and hardware/build controls, and excludes that environment metadata.
