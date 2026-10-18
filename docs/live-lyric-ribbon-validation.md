# Live lyric ribbon validation

Validated October 18, 2026 on macOS with Xcode 27, arm64. The implementation follows local playback and is available from the status-item menu in Debug and Release. The original Debug evaluation remains recorded below; the Release follow-up supersedes its compilation restrictions. Manual limits remain listed explicitly.

## Release follow-up

At the user's request, removed the development suffix from Show Lyrics, Hide Lyrics and Focus Lyrics and enabled the runtime, menu actions, native menu validation and teardown in Release. Standalone fixture launches and SwiftUI previews remain Debug-only. Existing window-frame preferences are retained.

- `swift test --package-path Packages/BopifyCore`: 386 tests passed (193, 60, 32 and 101).
- Complete Debug app suite: 77 tests, 95 cases including parameterized runs, passed with no failures.
- Complete Release app suite: 47 tests, 62 cases including parameterized runs, passed with no failures. Production lyric test files now compile in both configurations; app-environment injection and preview tests remain Debug-only. Before enabling the runtime, the Release test build failed because its lyric types were excluded.
- Final Debug and Release app builds passed with `CODE_SIGNING_ALLOWED=NO SWIFT_EMIT_LOC_STRINGS=NO`.
- Release symbol inspection confirmed the live session and menu actions are present, while `LyricRibbonPreviewSession` and `previewLyricRibbon` are absent.
- A focused review found a quit interleaving: lyric actions could reopen a panel while engine shutdown was suspended. A regression reproduced enabled actions and session recreation before the fix. Quit preparation now sets its flag before any suspension; menu validation and both entry points reject reopening. The full Debug suite passed afterward; follow-up review found no remaining issues.

The actual Release menu was checked with the normal saved session. [Before](mockups/lyric-menu-before.png) and [after](mockups/lyric-menu-after.png) captures show the same native menu treatment with the Debug suffix removed and the menu width reduced. Show Lyrics was enabled and opened the ribbon; reopening the menu exposed Hide Lyrics and Focus Lyrics. Rapid scripted Focus/Escape/reopen attempts did not reliably reach the subsequent menu and are not counted as passes; the native keyboard tests and earlier user-confirmed full-screen check remain the evidence for keyboard behavior. Both temporary normal-app instances were quit through their menu. No playback controls were used or lyric words captured.

Attribution remains response-driven: `SessionLyrics` calls librespot's `Lyrics::get`, the Rust bridge preserves `provider` and `provider_display_name`, and `LyricSourceMetadata` displays the supplied name with the provider ID as fallback. Musixmatch is a returned content credit, not a second client or API integration. [Librespot lyric implementation](https://github.com/librespot-org/librespot/blob/dev/metadata/src/lyrics.rs).

Security boundary inspection confirmed existing request deadlines, line/text limits, plain-text rendering, session/occurrence guards and no lyric disk cache. `cargo-audit` checked 359 dependencies and reported the pre-existing `rsa 0.9.10` advisory [RUSTSEC-2023-0071](https://github.com/RustSec/advisory-db/blob/main/crates/rsa/RUSTSEC-2023-0071.md), with no patched version listed. Dependency tracing found RSA only through librespot-core; its handshake uses `RsaPublicKey::verify` for Spotify's server signature, with no RSA private-key operation. The advisory concerns private-key timing disclosure, so this use does not expose the affected operation. No ignore rule or dependency change was added; the audit still exits nonzero for that advisory.

Release availability is a technical change, not a claim that live reconnect has been manually exercised or distribution permissions established. The previous live playback checks, deterministic reconnect tests and user-requested VoiceOver skip still apply.

## Initial Debug evaluation: automated checks

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

Spoken VoiceOver navigation was skipped at the user's request and is removed from the remaining checklist.

The unmodified fixture ribbon also remained visible and reachable above an owned 1920 × 1080 full-screen TextEdit window, then followed the return to the desktop Space. Its original full-screen state was restored and the scratch document closed. The [full-screen fixture capture](mockups/live-lyric-ribbon-full-screen.png) contains only original sample words. The off-Space preview control window could not be used to invoke Focus; this fixture capture alone does not establish keyboard behavior.

A later normal-app check used the actual Debug status-item menu over an owned full-screen TextEdit window. Focus Lyrics followed by Space entered held reading while the full-screen editor remained visible; Tab followed by Space hid the ribbon without leaving that Space. Recording and paused playback position stayed unchanged. The editor's starting non-full-screen state was restored after every pass.

Automated full-screen Escape/reopen attempts could not reliably reach the auto-hidden status-item menu; no product code was changed for that probe. The user subsequently completed the guided check through the normal Debug menu and confirmed that Escape hid the focused ribbon and Show Lyrics reopened it while TextEdit stayed in full-screen. These outcomes are user-confirmed, rather than automated observations. [Apple's full-screen guidance](https://support.apple.com/guide/mac-help/use-apps-in-full-screen-mchl9c21d2be/mac) describes revealing the menu bar from the top of the screen.

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

Remaining manual gaps: normal recovery/reconnect during playback and broader physical display/accessibility-setting/Spaces configurations. Healthy playback has no UI action that forces session recovery; Retry now is a no-op while ready. No machine-wide connectivity or credential disruption was introduced to force a failure. Deterministic recovery tests pass, but they do not replace live verification. Release availability is now verified as recorded above; complete manual coverage is not claimed.

## Review

A fresh, read-only review of `9ec3a24..ecf70dd` found no Critical or Important issues. The minor coverage gap from that review is now closed: `consecutiveSameRecordingEntriesReplaceReading` exercises different consecutive queue entries with the same recording URI in both metadata/queue arrival orders, with either a completed or pending intermediate lyric request (four cases). It verifies hold/source invalidation, final occurrence identity, and rejection of a stale intermediate response. Deliberately dropping either queue identity or playback revision made the new cases fail; the original product source was restored exactly, then all 76 native tests passed. No runtime behavior changed for this follow-up.

A separate final check reproduced AppKit overriding the lyric menu items' disabled state after sign-out and quit. The regression test failed for both paths before the fix and passed after adding native `NSMenuItemValidation`. Unrelated actions such as Quit stay enabled. [Apple NSMenuItem.isEnabled](https://developer.apple.com/documentation/appkit/nsmenuitem/isenabled) documents why direct enabled-state assignment is insufficient with automatic menu validation.

Review scope decisions:

| Decision | Reason | Cost if wrong |
| --- | --- | --- |
| Commit/push directly to main | Standing project instruction and approved plan | Rollback requires a revert. |
| Distribution suitability and Spotify synchronization permissions remain separate | Release compilation and technical validation do not establish distribution permissions | Public shipping would lack a separate suitability/permissions review. |
| Remote lyric following/repeat identity remain excluded | Local eligibility rejects remote playback | Remote listening has no ribbon and needs separate identity work. |
| Audible continuity is not measured | No audio-pipeline changes; separate acceptance scope | Existing audio artifacts could remain undetected. |
| Broader accessibility/display coverage remains partial | Native labels, the full-screen transition and Focus/Space/Tab were checked; the user confirmed full-screen Escape/reopen. Spoken VoiceOver was skipped at the user's request; broader configurations remain unverified | Accessibility/window edge cases may remain undiscovered. |
