# Live lyric ribbon validation

Validated October 18, 2026 on macOS with Xcode 27, arm64. The implementation follows local playback and is available from the status-item menu in Debug and Release. The original Debug evaluation remains recorded below; the Release follow-up supersedes its compilation restrictions. Manual limits remain listed explicitly.

## Compact sleeve refinement

The approved sleeve is now native, at **448 × 226 points** including its vinyl overhang. The 132-point reading viewport is independent of lyric length and reading mode. It presents previous/current/next cues; longer cues wrap or remain scrollable. Original fixtures at 320 points wide retain all three cues when the current line wraps. The 1.5 text-scale fixture is 306 points tall, subject to display bounds. Source credit shares the footer, and Sync appears only during manual reading.

Wheel/trackpad, scrollbar interaction, selection and reader navigation enter manual reading of the full document. Playback projection continues while scroll position, selection and text metrics stay stable. Sync returns directly to the latest cue without playback commands. Deliberate seek, new occurrence/session, hide and replacement content restore following. The standalone preview supports original sample artwork and previous/next recording actions.

The native implementation reuses the main player's record rotation, artwork cache/palette and vinyl rendering. Cue following uses a brief native clip-layer transition that is cancelled at its presentation position before manual input. Track transitions preserve the native text-view identity and therefore keyboard reading. Control–Option–L toggles the ribbon globally through KeyboardShortcuts 3.1.0; the menu remains a fallback. The ribbon has no X or Hold action. Focus Lyrics enables reading keys, Tab reaches Sync while reading, Return activates it, and Escape hides the focused ribbon.

Regression evidence:

- The compact-layout and manual-projection expectations failed against the previous implementation, then passed after geometry and reading state were separated from content length and playback projection.
- A native Tab → Sync → Return test reproduced focus falling back to the panel when SwiftUI removed the focused button. Deferred focus restoration checks current keyboard intent and the existing key window; it restores the reader without activating a passive panel. The test also preserves the same reader through a recording change.
- Actual app captures exposed a legacy scrollbar gutter clipping long lines. A hosted regression reproduced both the legacy style and text-container/content-width mismatch. Overlay compatibility fixed both assertions; wrapping and the clean overlay appearance were recaptured.
- Late queue artwork metadata initially failed to update the sleeve. The live session now uses the matching queue track for display, following the main player's pattern. Its regression verifies updated artwork, one lyric request, preserved manual reading and no playback commands.
- Full-document, neighbor visibility, manual anchor/selection preservation, layout caching, stale-result/session resets and native keyboard/window boundaries are covered by the app suites.

Final verification with temporary capture code removed: **97 Debug app tests**, **66 Release app tests**, and **386 core tests** passed. Core counts were 193, 60, 32 and 101 across its four executables. Both Debug and Release app builds succeeded. Commands used `CODE_SIGNING_ALLOWED=NO SWIFT_EMIT_LOC_STRINGS=NO`.

A final native check used the unmodified offline preview and an owned TextEdit scratch document. Global hide/show, actual wheel input entering Reading, and a pointer click at the Sync control’s native bounds all passed while TextEdit remained foreground. Foreground application and owned document identity were asserted before all five typing markers; all markers appeared in the scratch document. The document was closed without saving and the owned preview quit. Earlier automation attempts used an unresolved AX button lookup or unreliable synthetic pointer timing and are discarded; they did not require product changes.

| Native capture | Observation |
| --- | --- |
| [Previous version](mockups/lyric-ribbon-refinement-live.png) | Prior rounded card with separate source row, close and Hold controls. |
| [Following](mockups/lyric-sleeve-native-live.png) | Compact sleeve, existing vinyl styling, previous/current/next hierarchy and quiet footer. The fixture is paused for capture. |
| [Reading](mockups/lyric-sleeve-native-reading.png) | Full document with a clear native glass Sync action and Reading state. |
| [320-point width](mockups/lyric-sleeve-native-narrow.png) | Current lyric wraps while both neighbors remain visible at the same panel height. |
| [Larger text](mockups/lyric-sleeve-native-large.png) | Scaled viewport and type remain bounded and readable. |
| [RTL](mockups/lyric-sleeve-native-rtl.png) | Native shaping and paragraph direction with both context cues. |
| [Long cue](mockups/lyric-sleeve-native-long.png) | Long words wrap at the actual content width and scroll within the compact viewport. |

Captures came from the actual Debug app over an owned backdrop, using original words/artwork and no authentication or audio. An app-less test-host capture attempt lacked the app's shader library and is discarded. Temporary capture hooks and harnesses were removed afterward. Earlier refinement and release records below are historical; the user's VoiceOver skip remains unchanged.

## UI/UX refinement

The user selected a charcoal reading surface with native Liquid Glass controls. The [research notes](lyric-ribbon-research.md#october-18-refinement-for-the-released-ribbon) record the current Apple guidance and the design tradeoff. The refined view retains the vinyl mark, system typography and warm Reading accent, separates title and artist, keeps the close action outside header dragging, and makes Hold text/Back to live persistent. Native glass button styles share a `GlassEffectContainer`; the existing transparency/contrast fallback uses native bordered controls on an opaque surface.

Long passages now scroll inside a viewport capped at 180 points at normal lyric scale, bounded by display space and scaled with lyric text size. The current range is marked in the attributed passage and positioned using native TextKit line geometry. Extra document space allows a short current cue to remain near its reading position even after a very long previous cue. Ordinary clock ticks preserve scroll and selection.

The regressions reproduced excessive panel height and the hidden-current-cue behavior before the changes. Native screenshots then exposed `NSTextView` resizing away the extra document space after attachment. A hosted `NSHostingView`/`NSPanel` regression failed for that sequence and passed after the coordinator became the sole owner of document height. Existing measurement-cache, reading-state and native keyboard/window tests remain in place.

Native captures inspected, all with original sample words:

| Capture | Observation |
| --- | --- |
| [Before](mockups/lyric-ribbon-refinement-before.png) | Original offline preview with hidden controls and a single metadata line; this older fixture has no source credit. |
| [Live](mockups/lyric-ribbon-refinement-live.png) | Clear current/previous hierarchy, title/artist, source credit and visible native actions on charcoal. |
| [Reading](mockups/lyric-ribbon-refinement-reading.png) | Warm Reading marker and a readable Back to live action. |
| [250-point Reading](mockups/lyric-ribbon-refinement-narrow.png) | Wrapped current cue, bounded metadata and credit, with both actions inside the panel. |
| [Large text](mockups/lyric-ribbon-refinement-large.png) | Lyric scale 1.5 wraps and reserves space without cutting words or losing controls. |
| [RTL](mockups/lyric-ribbon-refinement-rtl.png) | Native Arabic shaping, paragraph direction and wrapping. |
| [Long previous cue](mockups/lyric-ribbon-refinement-long-previous.png) | Current cue remains below one line of context instead of disappearing below the viewport. |
| [Opaque fallback](mockups/lyric-ribbon-refinement-opaque.png) | Opaque reading surface and bordered actions remain readable in narrow Reading mode. |
| [Bright backdrop](mockups/lyric-ribbon-refinement-light.png) | Charcoal reading content and native controls remain legible over an owned white backdrop. |

The capture harness instantiated the actual view/layout with fixed fixture state, width and lyric scale. Its opaque case selected the existing rendering branch locally; it did not change system accessibility settings. The temporary harness, launch hook, opaque override and geometry instrumentation were removed afterward. No real lyrics, credentials or audio were used. The user's VoiceOver skip remains unchanged.

After removing the temporary code, the complete Debug suite passed **80 tests / 98 cases**, and Release passed **50 tests / 65 cases**, with no failures. Both app configurations built successfully with `CODE_SIGNING_ALLOWED=NO SWIFT_EMIT_LOC_STRINGS=NO`. Final review found no Critical, Important or actionable Minor issues. No playback engine, API or dependency changes were needed.

A final pointer check used the normal offline preview and an owned TextEdit scratch document. The first attempt lacked a verified foreground app and is discarded. In the completed check, TextEdit was activated and its foreground identity and document name were asserted before each typing marker. Actual pointer clicks on Hold text, Back to live and the header close button left all four markers in the scratch document. The native checkbox reported held value 1 after Hold text. The owned document was closed without saving and the preview quit afterward.

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
