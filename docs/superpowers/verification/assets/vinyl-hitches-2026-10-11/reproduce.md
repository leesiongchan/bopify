# Reproduce the hitch investigation

Checked on macOS 27.0.1 / Xcode 27.0, 2026-10-11. These are diagnostic fixture changes, not production changes. Raw traces can contain process environment values; keep them local and never publish a trace TOC.

First follow the build section in [the GPU reproduction guide](../vinyl-gpu-2026-10-11/reproduce.md), stopping before its capture commands. It creates `vinyl_profile_dir`, pinned `before`/`after` sources, the optimized package build, and `build-fixture.py`. Use a quiet desktop, the same visible 2× display, and no overlapping recordings or exports. Record actual activation and thermal conditions rather than assuming they match.

The paths below are relative to the repository root. `compare.py` locates fixture bundles beside itself, so copy it into the temporary profiling directory.

~~~sh
vinyl_hitch_evidence="$PWD/docs/superpowers/verification/assets/vinyl-hitches-2026-10-11"
cp "$vinyl_hitch_evidence/compare.py" "$vinyl_profile_dir/compare.py"
for vinyl_variant in before after; do
  git -C "$vinyl_profile_dir/$vinyl_variant" apply --unidiff-zero "$vinyl_hitch_evidence/$vinyl_variant-clock.patch"
  python3 "$vinyl_profile_dir/build-fixture.py" --derived-data "$vinyl_profile_dir/build" --output "$vinyl_profile_dir/$vinyl_variant-fixture" --probe pressing --source-root "$vinyl_profile_dir/$vinyl_variant" --build-only
done
for vinyl_variant in ablation accessory activation; do
  cp -R "$vinyl_profile_dir/after" "$vinyl_profile_dir/$vinyl_variant"
  git -C "$vinyl_profile_dir/$vinyl_variant" apply --unidiff-zero "$vinyl_hitch_evidence/$vinyl_variant.patch"
  python3 "$vinyl_profile_dir/build-fixture.py" --derived-data "$vinyl_profile_dir/build" --output "$vinyl_profile_dir/$vinyl_variant-fixture" --probe pressing --source-root "$vinyl_profile_dir/$vinyl_variant" --build-only
done
cp -R "$vinyl_profile_dir/activation" "$vinyl_profile_dir/visibility"
git -C "$vinyl_profile_dir/visibility" apply --unidiff-zero "$vinyl_hitch_evidence/visibility.patch"
python3 "$vinyl_profile_dir/build-fixture.py" --derived-data "$vinyl_profile_dir/build" --output "$vinyl_profile_dir/visibility-fixture" --probe pressing --source-root "$vinyl_profile_dir/visibility" --build-only
~~~

The clock patches also retain a screen-placement adjustment in the inherited probe’s unused detachment-control branch so source hashes match the recorded fixtures. That branch does not run during these captures. The clock patches append monotonic timestamps only during a five-second-warmup/ten-second measurement. CPU time comes from `getrusage`, normalized by actual elapsed duration. No per-frame stdout logging runs. They measure TimelineView closure evaluations, not presentation. The clock measurement and trace `[5,15)` window have different origins: recorder setup begins after readiness, and no exact shared-clock anchor was saved. Do not match individual callback gaps to trace intervals as if their starts were identical.

Examples (each capture directory must be new):

~~~sh
python3 "$vinyl_profile_dir/compare.py" after none after-none-1
python3 "$vinyl_profile_dir/compare.py" before none before-none-1
python3 "$vinyl_profile_dir/compare.py" after cpu after-cpu-1
python3 "$vinyl_profile_dir/compare.py" after swiftui after-swiftui-cadence-1
python3 "$vinyl_profile_dir/compare.py" after system after-system-1
python3 "$vinyl_profile_dir/compare.py" ablation swiftui motor-only-1 progress
python3 "$vinyl_profile_dir/compare.py" ablation swiftui progress-only-1 motor
python3 "$vinyl_profile_dir/compare.py" after scheduler after-scheduler-1
python3 "$vinyl_profile_dir/compare.py" activation swiftui activation-regular-1 regular
python3 "$vinyl_profile_dir/compare.py" activation swiftui activation-accessory-1 accessory
python3 "$vinyl_profile_dir/compare.py" visibility swiftui visibility-normal-1 normal
python3 "$vinyl_profile_dir/compare.py" visibility swiftui visibility-floating-1 floating
~~~

`none` collects callbacks and CPU without Instruments. `system` records Animation Hitches system-wide; `cpu`, `swiftui`, and `scheduler` attach to the exact launched PID (scheduler also adds Hitches). The helper records executable hashes, validates the readiness PID, and terminates only its own child. The system-wide startup in the historical `after-system-1` overlapped the preceding export/finalization; treat that run as exploratory, not a clean recorder-effect comparison.

For the minimal scene, copy the prepared bundle and replace its executable:

~~~sh
cp -R "$vinyl_profile_dir/after-fixture" "$vinyl_profile_dir/minimal-fixture"
swiftc -O -g -parse-as-library -swift-version 6 -default-isolation MainActor -target arm64-apple-macos26.0 "$vinyl_hitch_evidence/Minimal.swift" "$vinyl_profile_dir/after/Bopify/Bopify/MenuBar/StatusPanel.swift" -o "$vinyl_profile_dir/minimal-fixture/MonolithProbe.app/Contents/MacOS/MonolithProbe"
python3 "$vinyl_profile_dir/compare.py" minimal swiftui minimal-swiftui30-1 swiftui30
python3 "$vinyl_profile_dir/compare.py" minimal swiftui minimal-swiftui60-1 swiftui60
python3 "$vinyl_profile_dir/compare.py" minimal swiftui minimal-accessory-swiftui30-1 swiftui30 accessory
python3 "$vinyl_profile_dir/compare.py" minimal swiftui minimal-accessory-swiftui60-1 swiftui60 accessory
python3 "$vinyl_profile_dir/compare.py" minimal swiftui minimal-appkit30-1 appkit30
~~~

This uses the unchanged StatusPanel and a rotating rectangle. It has no vinyl shader, artwork, palette, or playback model. The AppKit timer delivered approximately 19 callbacks/s in the historical run, so it is not a matched-rate architectural benchmark. Regular-policy minimal recordings preceded addition of the policy switch; their binaries were replaced without recording hashes. The current default reproduces the same requested policy, not a byte-identical historical binary.

Export and analyze after each recording finishes:

~~~sh
python3 "$vinyl_hitch_evidence/export.py" "$vinyl_profile_dir/after-cpu-1" time-profile
vinyl_hitch_pid=$(bat --style=plain --color=never "$vinyl_profile_dir/after-cpu-1/pid.txt")
python3 -B "$vinyl_hitch_evidence/analyze-cpu.py" "$vinyl_profile_dir/after-cpu-1" "$vinyl_hitch_pid" 5 15
~~~

~~~sh
python3 "$vinyl_hitch_evidence/export.py" "$vinyl_profile_dir/after-swiftui-cadence-1" time-profile swiftui-updates hitches hitches-updates
vinyl_hitch_pid=$(bat --style=plain --color=never "$vinyl_profile_dir/after-swiftui-cadence-1/pid.txt")
python3 -B "$vinyl_hitch_evidence/analyze-cpu-swiftui.py" "$vinyl_profile_dir/after-swiftui-cadence-1" "$vinyl_hitch_pid" 5 15
python3 -B "$vinyl_hitch_evidence/analyze-long-swiftui.py" "$vinyl_profile_dir/after-swiftui-cadence-1" "$vinyl_hitch_pid"
python3 "$vinyl_hitch_evidence/export.py" "$vinyl_profile_dir/after-scheduler-1" time-profile thread-state context-switch-sample hitches hitches-updates hitches-gpu hitches-renders hitches-frame-lifetimes
vinyl_hitch_pid=$(bat --style=plain --color=never "$vinyl_profile_dir/after-scheduler-1/pid.txt")
python3 -B "$vinyl_hitch_evidence/analyze-scheduler.py" "$vinyl_profile_dir/after-scheduler-1" "$vinyl_hitch_pid"
python3 -B "$vinyl_hitch_evidence/summarize.py" --raw-root "$vinyl_profile_dir" --frame-analyzer docs/superpowers/verification/analyze-vinyl-gpu-trace.py --output "$vinyl_profile_dir/summary.json"
~~~

Historical `after-swiftui-1` predates timestamp instrumentation and alone uses `[2,12)`; its saved original analysis uses that window. All other historical traces use `[5,15)`. For a new timestamped run, choose a different name to avoid that historical special case in `summarize.py`. Run the existing GPU analyzer with `--start 5 --end 15` and exported scheduler GPU/render tables to reproduce `after-scheduler-1-associated.json`.

`summary.json` retains all 27 runs, timestamp arrays, target-PID counts, actual controls, and hashes of exported XML excluding the TOC. `fixture-manifest.json` hashes the patched source files and retained executable binaries. Six patches were applied independently to source copies and compared byte-for-byte with the built fixtures. SwiftUI CPU sample weights are sampling evidence, not calibrated utilization; use the recorded `getrusage` CPU percentage for process CPU consumption. Raw traces remain in `/private/tmp/bopify-vinyl-hitches-20261011` on the recording machine and are not required to compile a new reproduction.
