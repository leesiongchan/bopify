# Live lyric ribbon validation

Validated October 18, 2026 on macOS with Xcode 27, arm64. The implementation is local-playback-only and available from the Debug status-item menu. Release has no ribbon entry point. Full manual acceptance remains open for the cases listed below.

## Automated checks

- `swift test --package-path Packages/BopifyCore`: 386 tests passed across the four package test executables (193, 60, 32 and 101). Confirmed playback and seek revisions are covered without adding another engine-event consumer.
- Full `BopifyAppTests` Debug run after the queue-occurrence regression follow-up: 76 tests in 10 suites passed. New tests cover typed lyric conversion, source metadata, RTL, bounded attribution layout, same-URI repeat without Loading, queue/metadata ordering, request cancellation and late completion, visible-only 100 ms sampling, hold/seek/end behavior, current-engine routing, recovery, sign-out and quit.
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

Follow-up checks on October 18 confirmed the native accessibility roles and labels `Lyrics` (read-only text area), `Hold text` (toggle) and `Hide Ribbon` (button). This is structural AX inspection, not verification of VoiceOver speech/navigation.

The unmodified fixture ribbon also remained visible and reachable above an owned 1920 × 1080 full-screen TextEdit window, then followed the return to the desktop Space. Its original full-screen state was restored and the scratch document closed. The [full-screen fixture capture](mockups/live-lyric-ribbon-full-screen.png) contains only original sample words. The off-Space preview control window could not be used to invoke Focus; this fixture capture alone does not establish keyboard behavior.

A later normal-app check used the actual Debug status-item menu over an owned full-screen TextEdit window. Focus Lyrics followed by Space entered held reading while the full-screen editor remained visible; Tab followed by Space hid the ribbon without leaving that Space. Recording and paused playback position stayed unchanged. The editor's starting non-full-screen state was restored after every pass.

Full-screen Escape and reopen remain unverified. Subsequent automation could not reliably reach the auto-hidden status-item menu: native hit-testing identified the underlying TextEdit text area instead. No product code was changed for this probe, and the successful partial checks are not evidence that the remaining paths pass. [Apple's full-screen guidance](https://support.apple.com/guide/mac-help/use-apps-in-full-screen-mchl9c21d2be/mac) describes revealing the menu bar from the top of the screen; the probe attempted that but did not reliably recover menu access.

## Normal Debug app with Spotify playback

Used the normal app, its existing saved session and the native status-item menu. No credential export or alternate authentication runner was used. Only header, clock, attribution and status fields were inspected; no real lyric words, raw responses or live screenshots were saved.

Observed:

- Show Lyrics opened the ribbon with Musixmatch attribution for the current local track.
- The clock advanced with playback and showed Live.
- Hold changed status to Reading while music continued. Pausing preserved held reading and showed Reading · music paused.
- A confirmed five-second seek released held reading and adopted the new position.
- Resume returned to advancing playback; skip replaced the recording metadata and loaded attribution for the next track.
- A follow-up hide/reopen check held text at 3:04, hid during advancing playback, and reopened at 3:18 with current attribution and Live status instead of the held passage.
- A completed repeat-one check held text at 3:27 of a 3:47 track with Repeat Track confirmed. The same recording naturally restarted; the ribbon returned to its opening time (0:05 observed) and Live status, clearing held reading.
- The starting settings were paused playback and repeat Off. Both were restored and confirmed after the follow-up checks, then the normal app was quit.

Remaining manual gaps: normal recovery/reconnect during playback, spoken VoiceOver navigation, full-screen Escape/reopen, and broader physical display/accessibility-setting/Spaces configurations. Healthy playback has no UI action that forces session recovery; Retry now is a no-op while ready. No machine-wide connectivity or credential disruption was introduced to force a failure. Deterministic recovery tests pass, but they do not replace live verification. The feature remains implemented for Debug evaluation; full live acceptance and public release are not claimed.

## Review

A fresh, read-only review of `9ec3a24..ecf70dd` found no Critical or Important issues. The minor coverage gap from that review is now closed: `consecutiveSameRecordingEntriesReplaceReading` exercises different consecutive queue entries with the same recording URI in both metadata/queue arrival orders, with either a completed or pending intermediate lyric request (four cases). It verifies hold/source invalidation, final occurrence identity, and rejection of a stale intermediate response. Deliberately dropping either queue identity or playback revision made the new cases fail; the original product source was restored exactly, then all 76 native tests passed. No runtime behavior changed for this follow-up.

A separate final check reproduced AppKit overriding the lyric menu items' disabled state after sign-out and quit. The regression test failed for both paths before the fix and passed after adding native `NSMenuItemValidation`. Unrelated actions such as Quit stay enabled. [Apple NSMenuItem.isEnabled](https://developer.apple.com/documentation/appkit/nsmenuitem/isenabled) documents why direct enabled-state assignment is insufficient with automatic menu validation.

Review scope decisions:

| Decision | Reason | Cost if wrong |
| --- | --- | --- |
| Commit/push directly to main | Standing project instruction and approved plan | Rollback requires a revert. |
| Public-release suitability and Spotify synchronization permissions remain separate | This increment is Debug-only and makes no release-readiness claim | Public shipping would lack a separate suitability/permissions review. |
| Remote lyric following/repeat identity remain excluded | Local eligibility rejects remote playback | Remote listening has no ribbon and needs separate identity work. |
| Audible continuity is not measured | No audio-pipeline changes; separate acceptance scope | Existing audio artifacts could remain undetected. |
| Broader accessibility/display coverage remains partial | Native labels, the full-screen/desktop transition and full-screen Focus/Space/Tab were checked; spoken VoiceOver, full-screen Escape/reopen and broader configurations were not | Accessibility/window edge cases may remain undiscovered. |
