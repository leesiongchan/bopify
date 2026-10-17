# Lyric ribbon research

Research date: October 17, 2026. Status: the clean retro refinement of direction A, [native design](superpowers/specs/2026-10-17-lyric-ribbon-design.md) and [implementation plan](superpowers/plans/2026-10-17-lyric-ribbon.md) are approved. The Debug study is implemented; see [native validation](lyric-ribbon-native-validation.md).

The lyric ribbon would let a listener glance at the words and reread a passage while music continues. The value to test is whether it fits working on a Mac without taking keyboard focus or demanding attention. The primary use remains a choice between persistent background display, a brief shortcut peek and deliberate close reading.

## Three possible experiences

| Approach | Useful when | Main tradeoff |
| --- | --- | --- |
| Small persistent ribbon | Lyrics should remain available while working | Must stay readable without becoming distracting or obstructing content |
| Shortcut peek | The listener occasionally checks a line | Disappearing on key release conflicts with lingering over a passage unless explicitly pinned |
| Reader inside the player | The listener intentionally reads a larger passage | Provides context but requires opening the player and occupies more attention |

For background listening, the persistent ribbon is the leading recommendation. For occasional glances, peek is the better starting point. A full reader is a different emphasis and should not be built alongside both by default.

Floating lyrics alone are established territory: Lyric Fever already advertises menu bar lyrics, a persistent popup, fullscreen lyrics and translation. Its existence supports studying the interaction, not assuming Bopify's source access or that this behavior is unique. [Lyric Fever project](https://github.com/aviwad/LyricFever).

## The reading interaction

The recommended compact view shows the current cue prominently and the previous cue with lower emphasis. Two logical cues provide context for something just heard. Long cues need wrapping and stable height; continuously moving horizontal text would work against rereading. Exact placement and geometry need a visual comparison after the main use is chosen.

Hover reveals controls but does not freeze anything. The listener explicitly chooses Hold text. The displayed passage remains in place, a Reading label makes the mode visible, and music keeps advancing normally. Back to live immediately projects the current playback position onto the lyric timeline; it does not animate through all missed lines.

Holding text must never send pause, seek or volume commands. Entering reading mode should also never be confused with clicking a lyric to seek; line navigation is a separate candidate in [the ideas list](ideas.md#find-a-line-and-return-to-it).

For example, the listener holds the text at 1:12 and reads for fifteen seconds. The music reaches 1:27. Back to live shows the cue for 1:27 immediately. Neither entering nor leaving reading mode rewinds the song.

Recommended behavior for the cases that could otherwise be confusing:

| Event | Proposed result |
| --- | --- |
| Pointer passes over the ribbon | Reveal controls; continue following playback |
| Hold text | Freeze the displayed cue window; continue observing playback |
| Back to live | Show the cue at the authoritative current position |
| Music pauses | Playback clock stops; retain the existing reading mode |
| Deliberate local seek | Return to live at the resulting playback position |
| New song or a new occurrence of the same song | Clear the held passage and bind to the new occurrence |
| Ribbon is hidden | Clear reading hold and stop display updates; reopen at the live position |
| Lyrics are unavailable | Show an honest unavailable state without affecting playback |
| Only unsynced lyrics exist | Offer ordinary reading; do not manufacture a live highlight |

These are proposed defaults. An older song's held passage would need an explicit previous-song reader if that becomes a requirement; silently leaving it under the new song's identity would be misleading.

## Focus motion and accessibility

Passive display must preserve the front application's keyboard focus. AppKit's nonactivating panel style prevents app activation, but keyboard focus is a separate concern: panels can still become key. Apple's `becomesKeyOnlyIfNeeded` documentation explains how controls participate in that behavior. [NSPanel becomesKeyOnlyIfNeeded](https://developer.apple.com/documentation/appkit/nspanel/becomeskeyonlyifneeded).

Bopify's [StatusPanel](../Bopify/Bopify/MenuBar/StatusPanel.swift) currently becomes key when its interactive player region is clicked. A ribbon cannot inherit that behavior and claim that all interactions preserve focus. Simple reading controls and keyboard-accessible close reading need deliberately defined focus paths.

Prefer restrained cue changes. Respect Reduce Motion without making cue accuracy depend on the animation setting. Do not automatically announce every changing line through VoiceOver; expose readable text and controls for intentional navigation. Apple's guidance recommends avoiding large animations when Reduce Motion is enabled. [SwiftUI accessibilityReduceMotion](https://developer.apple.com/documentation/swiftui/environmentvalues/accessibilityreducemotion).

A persistent ribbon should have stable placement and explicit hide control. A click-through option would make its reading controls inaccessible by pointer, so it should not be an assumed first-version behavior. Screen sharing, multiple displays and fullscreen applications need evaluation before promising that it stays visible or private in every context.

## Modern visual design directions

The [interactive visual study](mockups/lyric-ribbon-directions.html) compares three proposed surfaces on a simulated desktop. It uses original sample text and a manually advanced playback clock, with no audio or lyric service. Browser effects approximate native materials; this is a design artifact rather than an implemented ribbon.

| Direction | Initial study size | Visual emphasis | Tradeoff |
| --- | --- | --- | --- |
| A Quiet ribbon | About 448 by 157 points | Dark, rounded, left-aligned, current and previous cues | Leading candidate for background listening; long cues need larger-text and wrapping tests |
| B Caption strip | About 648 by 139 points | Wider, centered, two-cue presentation | Gives phrases more horizontal room but occupies more of the desktop |
| C Reading card | About 350 by 263 points | Warm, opaque surface with previous, current and next cues | More useful reading context, with a substantially larger vertical presence |

These sizes are exploration choices, not platform requirements or final geometry. A is the current recommendation for persistent use. Carry Bopify's rounded shapes, system typography and semantic text hierarchy into the design. Keep album identity small so the lyric text remains the focus.

The user selected A and requested a clean retro appearance that matches the app. The [refined quiet ribbon study](mockups/lyric-ribbon-retro.html) uses warm charcoal, ivory lyric text, a small grooved record mark and a muted paper-label accent for the held-reading action. The shape follows Bopify's soft surfaces and capsule controls; lyrics retain system typography and an undecorated background. These choices draw on [PlayerSurface](../Bopify/Bopify/Views/PlayerSurface.swift), [VinylPressingView](../Bopify/Bopify/Views/VinylPressingView.swift) and [PlayerControlButtonStyle](../Bopify/Bopify/Views/PlayerControlButtonStyle.swift). The browser study starts with controls visible for review; its toggle demonstrates the quieter hover/focus reveal. Selecting this visual direction does not settle panel behavior, source access or the native implementation design.

Apple's current material guidance distinguishes standard materials for content from Liquid Glass for controls and navigation. The initial recommendation was a sufficiently opaque standard material for lyrics, with glass used sparingly on functional controls. Thicker materials can improve contrast for text. A browser blur or a glass-heavy appearance alone would not establish conformity with that guidance. The user subsequently approved a single glass shell with a contrast-preserving charcoal fill; see the [native validation](lyric-ribbon-native-validation.md) for actual backdrop captures and accessibility fallback coverage. [Apple Human Interface Guidelines Materials](https://developer.apple.com/design/human-interface-guidelines/materials).

The study starts A with roughly 23-point primary lyric text and 14-point preceding text, plus smaller track metadata and controls. Those sizes need testing at actual desktop viewing distance and with larger text. Prefer semantic system colors over artwork-derived lyric colors, and provide opaque backgrounds when transparency is reduced. [Apple Human Interface Guidelines Typography](https://developer.apple.com/design/human-interface-guidelines/typography).

Keep the surface's size and position stable as cues change. If animation is retained, begin with a brief opacity transition and validate comfort; avoid recurring blur, bouncing or large scrolling movement around a peripheral desktop overlay. Reduce Motion should simplify presentation without degrading cue timing. This follows Apple's recommendation to use motion purposefully and make its experience optional. [Apple Human Interface Guidelines Motion](https://developer.apple.com/design/human-interface-guidelines/motion).

The reading state should remain explicit in every direction: Reading plus music continues, and an always-visible Back to live action. Live-mode controls can reveal on hover or keyboard focus without shifting the text. An initial location near the lower screen edge should remain movable and clear of the Dock; do not follow the pointer or jump between screens automatically.

Apple's Live Captions provides a related native precedent for movable, resizable text windows, customizable text appearance and an option to keep the window onscreen. This supports giving the listener placement and legibility control, rather than treating a lyric overlay as fixed decoration. [Get captions of spoken and computer audio on Mac](https://support.apple.com/guide/mac-help/get-captions-of-spoken-and-computer-audio-mchldd11f4fd/mac).

The browser study verifies the held-text/catch-up interaction and preserves workspace-theme choices when switching directions. Native focus, system materials, true larger-text behavior, screen placement and playback integration still require separate validation after a direction is chosen.

The subsequent [Spotify lyric probe](spotify-lyrics-probe.md) confirms that the pinned librespot dependency already provides a lyric request. After explicit consent for a normal Keychain prompt, the probe retrieved two live line-synced responses with 60 and 59 lines through the existing method. Both passed the pinned parser, and every returned start timestamp parsed successfully. The document records the request/reply pattern to reuse; the ribbon remains fixture-backed until the bridge and playback adapter are implemented.

## Timing and matching determine trust

Bopify already exposes interpolated local or mirrored playback position through [PlayerModel](../Packages/BopifyCore/Sources/BopifyPlayback/PlayerModel.swift). A lyric projection can read that position without changing the playback engine. Reading state must stay separate from playback state.

The display must use recording identity, duration and provider results carefully. Similar titles do not establish that a studio recording, live performance and radio edit have the same lyric timing. LRCLIB accepts title and artist and recommends album and duration for more precise matching. Its documented duration check accepts records within two seconds of the supplied duration; that is a provider filter, not proof of a correct version. [LRCLIB API Documentation](https://lrclib.net/docs).

Line-start timestamps support cue changes, not reliable word highlighting or precise vocal endings. A long gap before the next line does not by itself establish when singing stops. Use explicit end or empty cues when provided; do not infer silence or vocal activity from the audio for this first scope. Preserve repeated and simultaneous cue occurrences rather than treating equal text as one unique lyric.

Show distinct states for loading, no match, instrumental, plain text only and timed lyrics. Discard an old request's result after a track change. If matching is uncertain, a missing lyric is better than confidently presenting the wrong recording's words.

## Fit with the existing code

Three small responsibilities describe the candidate boundary:

- A loader owns recording matching, cancellation and provider outcomes. Existing generation checks in [RecentsModel](../Packages/BopifyCore/Sources/BopifyLibrary/RecentsModel.swift) provide a project pattern for stale results.
- A pure timeline projection maps a parsed document and playback position to cue occurrences. It has no network access or playback commands.
- A ribbon model owns visible position, reading hold and presentation. It observes the existing player rather than consuming the engine's event stream independently.

A separate ribbon panel is a candidate for persistent display because the main player's [window controller](../Bopify/Bopify/MenuBar/PlayerWindowController.swift) owns record-and-sleeve geometry and interaction regions. Adding a ribbon inside that panel would require coordinated resizing and hit-region changes. This panel choice should follow the chosen experience rather than precede it.

The ribbon needs its own visibility gate: it may be open while the main player is closed. Stop display work when hidden and avoid making network requests on animation ticks. Bopify's [PlaybackClockSchedule](../Bopify/Bopify/Views/PlaybackClockSchedule.swift) currently uses periodic ticks with a reduced-motion variant. A lyric-only display should update for cue changes, with any timing strategy checked for accuracy and idle cost. No claim of lower resource use has been measured.

## Source access remains unresolved

LRCLIB is a technical data candidate; its API accessibility does not establish all rights needed for display, caching or transformation. LyricFind offers static, line-by-line and word-by-word display products under a licensing offering. Catalog coverage, use permission and price would need to be established for Bopify. [LyricFind Lyric Display](https://www.lyricfind.com/products/lyric-display).

Separately, Spotify's published compliance guidance lists synchronizing its recordings with lyrics as a disallowed use case. A permitted Spotify integration must be established before treating live synchronization as shippable. A third-party lyric license does not settle this playback-platform restriction. [Spotify Compliance Tips](https://developer.spotify.com/compliance-tips).

The browser studies use original synthetic text and a simulated playback clock without Spotify access or copyrighted lyric excerpts. No native playback-connected prototype has been built.

## What would establish that the idea works

Use a small original timed-text fixture containing long cues, repeated choruses, simultaneous cues, a late first line and an explicit empty interval. Validate hold and catch-up against known timestamps. Exercise a track switch while a fetch is pending and while text is held, including repeat playback of the same URI.

Check focus by typing continuously in another app while opening, reading and dismissing the ribbon. Evaluate fullscreen use, display changes, larger text, right-to-left layout and VoiceOver navigation. Verify that hiding the ribbon stops its display work and that a late or failed lyric load never interrupts music.

Product success is that someone can glance, hold a passage and return to live without losing their place in either work or music. The approved visual direction is the compact quiet ribbon with clean retro styling. The native study implements the original-fixture scope to validate focus, placement and reading behavior before live integration. Live sourcing remains unselected.
