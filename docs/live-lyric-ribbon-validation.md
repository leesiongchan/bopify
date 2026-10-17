# Live lyric ribbon validation

Validated October 18, 2026 on macOS with Xcode 27, arm64. The implementation is local-playback-only and available from the Debug status-item menu. Release has no ribbon entry point. Full manual acceptance remains open for the cases listed below.

## Automated checks

- `swift test --package-path Packages/BopifyCore`: 386 tests passed across the four package test executables (193, 60, 32 and 101). Confirmed playback and seek revisions are covered without adding another engine-event consumer.
- Full `BopifyAppTests` Debug run: 74 tests in 10 suites passed. New tests cover typed lyric conversion, source metadata, RTL, bounded attribution layout, same-URI repeat without Loading, queue/metadata ordering, request cancellation and late completion, visible-only 100 ms sampling, hold/seek/end behavior, current-engine routing, recovery, sign-out and quit.
- Debug and Release app builds passed with `CODE_SIGNING_ALLOWED=NO SWIFT_EMIT_LOC_STRINGS=NO`, using `build/lyric-ribbon-study` as DerivedData.
- Release symbols inspected with `xcrun nm -j` and `xcrun swift-demangle`: no `LiveLyricRibbonSession`, `LyricRibbon` UI types or live-menu action symbols. Release menu construction excludes the actions with `#if DEBUG`; a second normal playback engine was not launched for menu inspection.
- `git diff --check` passed. The existing main localization catalog was preserved byte-for-byte, SHA-256 `71c74a02edb45dfd615de06551204c6fced3f6f85ffb25da32d6125243238cd3`, and excluded from staging.

Existing non-failing diagnostics: AppIntents metadata extraction is skipped because the app has no AppIntents dependency; native tests report a `com.apple.linkd.autoShortcut` connection error (4097). No Rust, authentication, dependency, generated bridge or session-configuration changes were needed.

## Native fixture checks

All saved captures contain original sample words. The 448-point [before](mockups/live-lyric-ribbon-before.png), [after with attribution](mockups/live-lyric-ribbon-after.png) and [RTL](mockups/live-lyric-ribbon-rtl.png) captures preserve the charcoal/ivory shell, vinyl mark and native Liquid Glass treatment.

Additional native captures inspected:

- [250-point long attribution with opaque fallback](mockups/live-lyric-ribbon-narrow-opaque.png): caption truncates within its reserved row, with full attribution retained in Help/accessibility; footer stays inside the panel.
- [Plain text](mockups/live-lyric-ribbon-plain.png): original unsynced lines wrap in the selectable passage.
- [Neutral playback message](mockups/live-lyric-ribbon-idle.png) and [lyrics unavailable](mockups/live-lyric-ribbon-unavailable.png): readable messages without stale attribution.

Temporary fixture-only settings supplied source metadata, a 250-point width, a paused clock and the existing opaque rendering branch. They were removed and the affected Debug build rerun. These captures check the rendering branch; they do not claim that macOS's system accessibility settings were changed.

An owned TextEdit scratch document retained activation and received typing after a passive click in the fixture passage. The explicit Focus action followed by Space entered held reading; Tab/Space and Escape each hid the ribbon. The document and preview were closed afterward. Existing native window tests also cover passive focus, keyboard routing, screen changes and reachable geometry. The standalone preview remains fixture-only.

## Normal Debug app with Spotify playback

Used the normal app, its existing saved session and the native status-item menu. No credential export or alternate authentication runner was used. Only header, clock, attribution and status fields were inspected; no real lyric words, raw responses or live screenshots were saved.

Observed:

- Show Lyrics opened the ribbon with Musixmatch attribution for the current local track.
- The clock advanced with playback and showed Live.
- Hold changed status to Reading while music continued. Pausing preserved held reading and showed Reading · music paused.
- A confirmed five-second seek released held reading and adopted the new position.
- Resume returned to advancing playback; skip replaced the recording metadata and loaded attribution for the next track.
- The repeat setting was changed from Off through Repeat All to Repeat Track during an attempted boundary check, then restored to Off. Paused playback and restored Off were confirmed before quitting.

Remaining manual gaps: a completed same-track repeat boundary while holding text, live hide/reopen freshness, and a normal recovery/reconnect during playback. Their deterministic session/app tests pass, but those results do not replace live verification. Broader VoiceOver, Spaces/full-screen and physical display/accessibility-setting coverage also remain outside this validation. The feature is implemented for Debug evaluation; full live acceptance and public release are not claimed.

## Review

One fresh whole-change code review is required before pushing. Its outcome and any fixes are recorded here after review.
