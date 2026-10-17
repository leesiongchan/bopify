# Bopify quiet lyric ribbon design

Status: proposed native design for review. The refined appearance of direction A is approved.

## Purpose and scope

Let a listener glance at the current words, hold a passage to reread it and return to the current cue while music continues. The approved visual reference is the [clean retro quiet ribbon](../../mockups/lyric-ribbon-retro.html): warm charcoal, ivory text, a small vinyl mark and rounded controls that fit Bopify's record player.

The proposed next increment is a native interaction study using original timed-text fixtures and a simulated playback input. It validates macOS focus, placement, text layout and reading behavior before connecting a lyric service or Spotify playback. The native display and timeline should accept normalized documents so a later permitted source can supply them without changing reading behavior. The study remains a development preview, with no release menu item or automatic display during real music playback.

A live release has a separate dependency: permission to display the supplied lyrics and to synchronize them with the playback platform. Spotify currently lists synchronization of its recordings with lyrics among disallowed use cases. Public lyric API access does not resolve that restriction. This design does not choose a live provider or claim a permitted Spotify integration. [Spotify Compliance Tips](https://developer.spotify.com/compliance-tips), checked October 17, 2026.

Translation, AI interpretation, generated lyrics, word highlighting, line-to-seek, audio processing, a full lyrics reader and global shortcuts are outside this increment.

## Appearance and layout

Use the approved visual hierarchy: small record mark and track identity across the top, the previous cue in secondary text, the current cue as the brightest element, and reading controls along the bottom. The timestamp always represents the current playback input, including while text is held.

Start with a 448-point width, approximately 23-point current text, 14-point previous text and a 24-point continuous corner radius. These are design starting values, not fixed platform requirements. Use system typography, tabular time digits and a sufficiently opaque content material. Warm ivory and charcoal are palette goals; native semantic colors and tested contrast take priority over literal browser hex values. The record mark carries the vinyl detail; keep the lyric area free of grooves, grain and animated decoration.

The surface should look related to [PlayerSurface](../../../Bopify/Bopify/Views/PlayerSurface.swift), [VinylPressingView](../../../Bopify/Bopify/Views/VinylPressingView.swift) and [PlayerControlButtonStyle](../../../Bopify/Bopify/Views/PlayerControlButtonStyle.swift). Do not alter those existing components merely to implement the ribbon. Standard materials suit content; reserve glass effects for controls where useful. [Apple Materials guidance](https://developer.apple.com/design/human-interface-guidelines/materials).

Allow cues to wrap. Determine the text viewport height once for each document and text-size choice from its largest previous/current cue pair, bounded by the screen's available height. Keep this height stable during playback. If a passage exceeds the available height, allow vertical scrolling within the text area; Hold text preserves its scroll position, and Back to live resets to the current cue. Keep metadata and controls outside the scrolling area. Do not use horizontal marquees or silently ellipsize lyric text.

Use opaque surfaces for Reduce Transparency and stronger boundaries for Increase Contrast. Follow the layout direction of the text, including right-to-left cues. Cue changes should be direct initially; add no recurring movement, animated blur or record rotation. Larger text may increase the panel's reserved height. [Apple Typography](https://developer.apple.com/design/human-interface-guidelines/typography), [Apple Motion](https://developer.apple.com/design/human-interface-guidelines/motion).

## Reading behavior

| Event | Required result |
| --- | --- |
| Show the ribbon | Present the cue for the current input position in Live mode |
| Hover or keyboard focus | Reveal controls without changing reading mode |
| Hold text | Freeze the visible cue occurrences and text scroll position |
| Input advances while held | Keep the passage fixed; advance the timestamp |
| Back to live | Display the current cue immediately, skipping missed cue transitions |
| Pause or resume | Retain reading mode; advance time only while playing |
| Explicit seek | Clear hold and display the resulting current cue |
| Routine timing correction | Update the live projection; retain a held passage |
| New playback occurrence or session | Clear hold and discard the old passage before showing new content |
| Hide | Clear hold, cancel presentation work and retain the saved window position |
| Reopen | Recompute from current input rather than restoring stale reading text |

Live-mode controls appear on hover or keyboard focus without shifting layout. In Reading mode, show “Reading · music continues” when playing, or “Reading · music paused” when paused; keep Back to live visible. Holding, scrolling, returning to live and closing the ribbon must never issue playback commands.

Before the first cue, show a neutral “Lyrics start soon” state. An explicit empty cue clears the current words until the next cue. Without an explicit end or empty cue, retain a line until the next timestamp; a gap alone cannot identify when singing ended. When playback reaches its reported duration, show “End of lyrics” rather than leaving a Live status that implies progression. Do not treat the last cue's start as playback end. A held passage remains readable until Back to live or another transition clears it.

## Native panel and focus

Give the ribbon its own controller and panel. Its visibility is independent of the record player's visibility. The existing [StatusPanel](../../../Bopify/Bopify/MenuBar/StatusPanel.swift) deliberately becomes key on player clicks and implements media shortcuts; reuse its controller-owned hosting pattern, not its player-specific behavior.

Default to a movable panel near the lower center of the current screen, inside its visible frame and above the Dock. Dragging the header moves it; dragging or selecting text does not move the panel. Save its frame separately from the record player and clamp it to a reachable screen when displays change. Do not reopen it automatically after app launch. It stays visible when another application becomes active and when the main player closes. The study should evaluate ordinary and fullscreen Spaces rather than promising visibility above every system window.

Opening, hovering, dragging and clicking reading controls must preserve the front application's keyboard focus. Provide an explicit Focus Ribbon action in the development preview to enter keyboard interaction. In that mode, Tab reaches the reading and hide controls; Escape hides the ribbon. Leaving keyboard interaction does not itself hide the ribbon. Native validation must establish this behavior before adopting the panel configuration: a nonactivating style alone does not establish all focus behavior. [NSPanel becomesKeyOnlyIfNeeded](https://developer.apple.com/documentation/appkit/nspanel/becomeskeyonlyifneeded).

Give VoiceOver intentional access to the track, displayed cues, reading status and controls. Do not automatically announce each timed cue. Expose Hold text as a toggle with an accessible state. Provide an explicit Hide Ribbon action rather than requiring a precise window gesture.

## State and data boundaries

Use three focused responsibilities, without adding a generic plugin or provider framework:

| Responsibility | Input | Output and ownership |
| --- | --- | --- |
| Document input | Original fixture, recording identity and request generation | Normalized timed cues or a distinct content outcome |
| Timeline projection | Document and position in milliseconds | Current and previous cue occurrences, or an interval state |
| Ribbon presentation | Timeline result, playback snapshot and user actions | Live or held passage, visibility and layout state |

Each cue occurrence has its own identity, start time and text. Preserve repeated text and multiple timestamp occurrences. Group simultaneous cues for display in their stable source order; the previous group is the preceding distinct timestamp. Reject negative or invalid timestamps when normalizing a fixture. Test normalization separately from projection so rendering never guesses at malformed input.

The playback snapshot contains a session identity, occurrence identity, position, duration, playing state and an explicit-seek revision. The study controls these values directly. A new document or occurrence clears held text before applying new metadata. A result may be applied only when its request generation and occurrence still match; cancellation alone is insufficient protection against a late result.

Represent loading, timed content, plain text only, instrumental, no match and load failure separately. Plain text has ordinary scrolling and no Live label or Hold text action. Loading and unavailable states do not retain lyrics under a different track title. The study exercises these outcomes with fixtures; it adds no network calls, credentials, persistence of lyric text or service dependency.

Run a modest display clock only while visible and the input is advancing. Recompute the text when the cue group changes; the elapsed timestamp may update once per second. Cancel the clock when hidden and restart from the authoritative current position on show. Do not tie cue accuracy to Reduce Motion. Log visibility, reading transitions and input-generation changes using the project's existing logging idiom; omit lyric bodies from logs.

## Later integration with the player

These boundaries describe the later live adapter and do not expand the native study's scope. [AppEnvironment](../../../Bopify/Bopify/AppEnvironment.swift) owns stable services and is the appropriate lifecycle owner. A released Show or Hide Lyrics Ribbon action belongs in [StatusItemController.showMenu](../../../Bopify/Bopify/MenuBar/StatusItemController.swift), the existing agent-app command surface; the app has no implemented Settings window or global shortcut registry.

Observe [PlayerModel](../../../Packages/BopifyCore/Sources/BopifyPlayback/PlayerModel.swift) and read `displayPositionMs(at:)` and `isPositionAdvancing`. Do not subscribe independently to engine events. The existing player folds explicit seeks and position corrections into the same state update, so a later adapter requires a small explicit-seek signal to implement the reading rules reliably.

An engine epoch plus the local queue-entry identity can distinguish local occurrences when available. A URI alone cannot identify every repeated playback. Mirrored playback currently lacks a reliable same-song occurrence identifier; the first live adapter must not claim remote-repeat correctness without extending that input. This spec does not infer seeks or new occurrences from arbitrary clock jumps. Account sign-out, player detachment and app termination must clear content and cancel pending work.

## Acceptance checks

1. Use original fixtures with repeated choruses, simultaneous cues, long wrapped passages, a late first line, explicit empty intervals, plain text and instrumental outcomes. Verify current and previous groups at timestamp boundaries.
2. Hold at 1:12, advance to 1:27 and return to live. Verify the passage stays fixed while held, the clock advances and catch-up displays only the current group. Assert that reading actions call no playback operation.
3. Exercise pause, explicit seek, timing correction, new occurrence with the same URI, hidden/reopened state and a stale asynchronous result. Verify each transition in the reading table.
4. Type continuously in another app while opening, hovering, dragging and clicking Hold text and Back to live. Verify the insertion point and keyboard focus remain in that app. Separately verify explicit keyboard interaction and VoiceOver navigation.
5. Compare native screenshots with the approved study on light and dark desktops. Check larger text, right-to-left text, reduced transparency, increased contrast, display removal and Dock clearance. Confirm cue changes do not resize or move the panel.
6. Verify that hiding the panel leaves no running presentation clock and that the development study does not fetch lyrics, attach to Spotify playback or expose an unfinished release command.

The deliverable for this proposed increment is a native, fixture-driven interaction study plus focused timeline and state tests. Live lyric sourcing and playback integration require a separate design decision after the native experience and a permitted integration path are established.
