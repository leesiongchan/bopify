# Vinyl hitch diagnosis

Date: 2026-10-11. Follow-up to [optimized GPU profiling](2026-10-11-vinyl-gpu-profile.md).

**The captures narrow the steady-animation issue to commit/display scheduling, but do not establish its exact cause. No production fix or AppKit/SwiftUI architecture change is justified by these results.** Hitches reproduce with a minimal SwiftUI rotating rectangle, without the vinyl shader, artwork, palette, or playback model. A System Trace recording shows normal event-loop waiting inside long app-update markers, rather than a corresponding long burst of player CPU work. Later recordings also contain occasional long callback gaps and long SwiftUI wall intervals; those require separate interpretation below.

## Protocol and limits

Same Mac mini M4 Pro / 16 GPU cores / 48 GB, macOS 27.0.1 (26A434), Xcode 27.0 (27A266a), Swift 6.4 as the GPU report. Full-player fixtures use its pinned before (`9a1ba22b2a848173acc415be866ba568e3ae6859`) and after (`9bb79967ddbff26037a6e4a78df0fcc1673bb14f`) sources and identical optimized Debug package objects. The native expanded scene stays at 182 pt, dark appearance, 2×, preview1 artwork, window `(80,80,484,360)`, physical display ID 3. Diagnostic changes exist only in temporary source copies. No live Spotify session runs.

The original SwiftUI capture uses trace `[2,12)` seconds. The other recordings last 20 seconds and are analyzed over `[5,15)`. App-scoped SwiftUI, Time Profiler, and System Trace recordings attach to the exact child PID; the Animation Hitches comparison records all processes, then filters target-PID app hitches and top-level updates. Secondary-display updates remain in the evidence; tables have no individual-window provenance. Display 3 counts below are associated update markers, not an independently measured displayed-frame rate.

Timestamped fixtures warm up five seconds after readiness, then append monotonic TimelineView callback timestamps for approximately ten seconds and collect process CPU time via `getrusage`. CPU percentages are normalized to actual elapsed duration and one CPU core. No per-frame stdout logging runs. Callback measurement and recorder time have different origins, without an exact saved alignment anchor. CPU sample weights describe sampled stacks, not calibrated utilization. No-recorder captures cannot establish hitch-free presentation.

The desktop was not isolated. Actual activation changed in several runs; later readiness thermal states include nominal and fair. The historical system-wide run began while the preceding SwiftUI trace was finalizing, so it is exploratory evidence, not a controlled recorder-effect comparison. No capture was discarded for reporting hitches. Raw traces/TOCs remain local because they can include process environment values.

## What the measurements establish

### Steady bodies and callback cadence

In the original after SwiftUI recording, Instruments reports 145 app hitches, each 16.667583 ms. All 38,280 SwiftUI update intervals are below 0.358 ms. RadialProgressView has 300 body evaluations totaling 17.425 ms (max 0.0775 ms); MorphingArtworkView has 300 totaling 15.187 ms (max 0.0908 ms). Long app-update markers contain short sampled CPU bursts near their start and next display cycle, with a roughly 15 ms unsampled gap. A long marker alone therefore does not identify expensive view-body work.

The timestamped SwiftUI repeats report 18 hitches after versus zero before, with approximately 300 evaluations of each body and short callback gaps. Their body evaluations are about 16.4 ms apart, whereas the original bodies were nearly coalesced. A CPU-only after recording predominantly samples AttributeGraph/framework work; sampled own work includes TimelineView closures (71 ms inclusive), radial progress (40 ms), record closure (35 ms), and display-position interpolation (9 ms). Timestamp collection accounts for 3 ms inclusive sample weight. These values are not independent additive costs.

Without a recorder:

| Run | Process CPU, one core | Motor callbacks | Motor p95 / max gap ms | Progress callbacks | Progress p95 / max gap ms |
| --- | ---: | ---: | ---: | ---: | ---: |
| After 1 | 19.78% | 305 | 33.953 / 34.801 | 305 | 33.879 / 34.308 |
| Before 1 | 20.24% | 306 | 33.954 / 45.960 | 305 | 33.766 / 34.093 |
| After 2 | 15.54% | 302 | 47.105 / 47.720 | 302 | 34.176 / 34.403 |
| Before 2 | 5.84% | 300 | 33.495 / 34.504 | 300 | 33.535 / 34.624 |

None of these four runs has a callback gap over 50 ms. That supports generally regular callbacks in these runs, not displayed-frame parity or absence of visual hitches. Apple documents a TimelineView schedule and cadence, not guaranteed presentation frequency: [TimelineView](https://developer.apple.com/documentation/SwiftUI/TimelineView) and [AnimationTimelineSchedule](https://developer.apple.com/documentation/swiftui/animationtimelineschedule), checked 2026-10-11.

### System Trace: the long marker contains idle waiting

The after scheduler capture reports 270 app hitches. Over its ten-second window, the main thread spends 946.944 ms Running, 9044.300 ms Blocked, 3.438 ms Runnable, 3.717 ms Interrupted, and 1.601 ms Preempted. The 240 Display 3 update markers longer than 10 ms cover a union of 4480.884 ms: 3724.208 ms Blocked and 751.524 ms Running. During the hitch ranges, 4197.110 of 4500.247 ms is Blocked.

Context-switch stacks match 8998.488 ms of main-thread blocking to ordinary `mach_msg` / `__CFRunLoopServiceMachPort` event-loop waiting. Verification-output fsync accounts for 0.024 ms; WindowServer ordering queries for 0.125 ms; 45.664 ms remains unmatched. Runnable/preempted time is small, so this capture does not support CPU starvation, a long application lock, or synchronous artwork I/O as the explanation for its repeated steady hitches.

The first 19.398 ms marker starts at 5.016732 s. The main thread runs briefly, waits normally from 5.017790 to 5.033318 s, then resumes work. Its associated compositor render starts at 5.050081 s (3.872 ms), with GPU work at 5.053591 s (1.386 ms). Across 269 joined Display 3 GPU intervals, mean GPU duration is 1.377 ms and max is 1.779 ms; render mean is 3.957 ms and max is 5.805 ms. This illustrates a commit spanning display cycles; it does not isolate the internal timer/scheduling cause or shader cost. The scheduler records timer-class kernel wakeups but does not identify the specific SwiftUI/AppKit API responsible.

This investigation follows Apple's distinction between CPU work and waiting: [Profile, fix, and verify: Improve app responsiveness with Instruments](https://developer.apple.com/videos/play/wwdc2026/268/), WWDC26. Apple's [Understanding hitches in your app](https://developer.apple.com/documentation/xcode/understanding-hitches-in-your-app), checked 2026-10-11, describes the commit/render/GPU deadline pipeline; marker duration should not be substituted for CPU execution time.

### Hypotheses tested without changing production

| Diagnostic condition | App hitches | Display 3 top-level updates |
| --- | ---: | ---: |
| Full player, timestamped SwiftUI | 18 | 283 |
| Before shader, timestamped SwiftUI | 0 | 308 |
| Full player, system-wide Hitches (exploratory startup overlap) | 163 | 179 |
| Motor only, progress clock paused | 200 | 265 |
| Progress only, motor clock paused | 209 | 218 |
| Ablation control, both clocks | 135 | 230 |
| Minimal SwiftUI, 30 Hz requested | 195 | 245 |
| Minimal SwiftUI, 60 Hz requested | 5 | 562 |
| Minimal SwiftUI, accessory policy, 30 Hz | 64 | 63 |
| Minimal SwiftUI, accessory policy, 60 Hz | 0 | 104 |
| Minimal AppKit timer, 30 Hz requested | 1 | 188 |

Pausing either full-player clock still reproduces hitches. The minimal rotating rectangle demonstrates that vinyl-specific work is not necessary to reproduce this symptom on this machine. It retains the unchanged StatusPanel, so it does not eliminate every shared window/framework factor. Higher requested cadence reports fewer hitches in these particular recordings, but activation differs and linked update counts vary. The production 30 Hz cap is a spec requirement and remains intact. The AppKit timer achieves approximately 19 callbacks/s rather than the requested 30, so this is not evidence for an AppKit performance advantage.

The original fixture explicitly requests regular activation, while production uses `LSUIElement=YES`. Accessory activation is Apple's corresponding policy: [NSApplication.ActivationPolicy.accessory](https://developer.apple.com/documentation/appkit/nsapplication/activationpolicy-swift.enum/accessory), checked 2026-10-11. An initial accessory full-player run has zero hitches, but repeated same-binary regular/accessory runs report 3/0 and 0/1 respectively. Policy alone is not a repeatable cause.

Accessory-policy normal/floating window pairs report 13/0 and then 1/1 hitches. Bounding-rectangle checks at readiness, measurement start, and end find zero above-window overlap in all four runs. This does not support occlusion as the cause, but it is not continuous pixel-level coverage verification. Apple's `.visible` flag means at least part of a window is visible: [NSWindow.OcclusionState](https://developer.apple.com/documentation/appkit/nswindow/occlusionstate-swift.struct), checked 2026-10-11. Window queries run only at boundaries, outside CPU timing, and retain no other window names or owner identifiers.

### Later long callback gaps

Activation-regular-1 records a maximum motor callback gap of 178.909 ms and progress gap of 134.429 ms. Visibility-normal-1 records 253.745 ms and 335.256 ms respectively. These are real timestamped callback gaps; they should not be hidden by the steadier earlier runs.

The activation trace's longest SwiftUI interval is 3.824 ms, with zero main-thread CPU samples inside it. The visibility trace has a 73.711 ms animation-filter interval with one main-thread sample (0.1 ms weight); its maximum unsampled span is 73.671 ms. A 44.600 ms preference interval contains zero samples, and a 38.344 ms MorphingArtwork body interval contains two samples (0.2 ms weight). These are long wall intervals with sparse sampled CPU evidence, not proof of corresponding CPU execution or blocked-state duration. Only the separate System Trace capture supports the quantified waiting conclusion above.

The visibility trace includes mouse-event ancestry through StatusPanel and PlayerHostingView into framework responder/hover traversal. The application overrides only forward events and check pointer containment; the fixture's pointer-change callback is unset. No sampled palette extraction or artwork-decoder hotspot explains these intervals. That does not establish the cause of the gaps. The body timestamp patterns resemble the callback gaps, but their time alignment is inferred, not an exact recorded clock mapping. [Long-interval analysis](assets/vinyl-hitches-2026-10-11/visibility-normal-1-long-swiftui-analysis.json) retains per-interval sample counts and unsampled spans. A scheduler capture aligned to these particular gaps is still needed.

## Saved evidence and verification

[Summary of all 27 runs](assets/vinyl-hitches-2026-10-11/summary.json), [scheduler states and matched blocked stacks](assets/vinyl-hitches-2026-10-11/after-scheduler-1-scheduler-analysis.json), [associated compositor intervals](assets/vinyl-hitches-2026-10-11/after-scheduler-1-associated.json), and [CPU-only sampled stacks](assets/vinyl-hitches-2026-10-11/after-cpu-1-cpu-analysis.json) preserve the measurements and their scope. [Reproduction guide](assets/vinyl-hitches-2026-10-11/reproduce.md) includes temporary source patches, parsers, source/binary hashes, and exact capture modes. The original regular-policy minimal binaries were replaced when policy selection was added; their hashes were not recorded. The retained source reproduces that requested policy, not byte-identical old binaries.

All diagnostic variants compiled successfully. Six source patches were applied independently and compared byte-for-byte with the built source copies. Python parser syntax, all 27 runs’ exported-XML hashes, retained recorded binary hashes, fixture manifests, and reproduction shell syntax were checked. Nine analysis JSON files reproduce byte-for-byte under two different Python hash seeds after deterministic ranking was added; absent target PIDs are rejected by the CPU and scheduler reducers. The long-interval reducer sorts samples and body timestamps explicitly. Independent read-only review recomputed all 27 run counts and callback statistics, representative CPU/body figures, scheduler states and blocked-stack classifications, compositor joins, hashes, and the pinned-source patch chain. It found no remaining Critical, Important, or Minor issue; it did not rerun native builds or recordings or infer the unresolved cause.

No production sources changed, so the application tests were not rerun for this documentation-only follow-up. The earlier feature/build verification remains historical evidence, not a fresh result. GPU intervals still belong to shared compositor frames; record-only GPU timing and a general no-regression verdict remain unverified. No architecture rewrite is supported. A bounded next investigation is the saved minimal reproduction under an idle controlled desktop and another OS/Xcode build, with an exact trace/callback time anchor and scheduler capture for any longer gaps. That would distinguish repeatable framework scheduling from desktop/event interference before proposing a production fix.
