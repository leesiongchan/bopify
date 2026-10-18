# Lyric ribbon research

Research dates: October 17–18, 2026. The live native ribbon is implemented; see [live validation](live-lyric-ribbon-validation.md). The selected sleeve is implemented natively with compact geometry; browser studies below record the design exploration. See the current [validation record](live-lyric-ribbon-validation.md). Older exploration and the original [native design](superpowers/specs/2026-10-17-lyric-ribbon-design.md) remain as historical context.

The lyric ribbon would let a listener glance at the words and reread a passage while music continues. The value to test is whether it fits working on a Mac without taking keyboard focus or demanding attention. The primary use remains a choice between persistent background display, a brief shortcut peek and deliberate close reading.

## Three-row native sleeve revision

The user approved a fixed three-row viewport after the initial native version diverged from the concept and retained too much space. The revised panel is **448 × 156 points**, with a 94-point reading viewport. A consistent line height makes three physical rows fit in both following and manual modes; long cues wrap inside this boundary and can displace an adjacent cue. Larger text scales the reading viewport, bounded by the display. The 96-point record is rendered as a complete circle behind the sleeve, with half naturally concealed by its opaque warm olive-charcoal surface and a subtle sleeve lip. The existing pressing, artwork and rotation components are reused.

The footer and Live/Reading labels are removed. Provider credit shares the artist metadata line. Only manual reading shows the text-only native glass **Sync** capsule in the header; contrast/transparency settings retain the bordered fallback. The main player gets a matching lyric toggle immediately before Playlist, and the status-menu lyric entries are removed. Control–Option–L remains global; the icon's context menu retains deliberate Focus Lyrics access.

In manual mode only the playback-current cue is highlighted. Native temporary foreground attributes update without replacing text, changing metrics, moving the viewport or discarding selection. Timestamp links use NSTextView's own mouse tracking, with custom link colors/tooltips suppressed. Actual testing found a separate click recognizer did not complete alongside the text view's tracking loop, so it was removed. Native short and long selection drags were checked separately from clicks. [Apple: clicked(onLink:at:)](https://developer.apple.com/documentation/appkit/nstextview/clicked(onlink:at:)), [TN3212: AppKit gesture tracking compatibility](https://developer.apple.com/documentation/technotes/tn3212-adopting-gesture-recognizers-for-sidecar-touch-support) (checked October 18, 2026).

Clicks reuse PlayerModel.seek(to:) and preserve playback's paused/playing state. The live session rejects stale rendered occurrences and unknown/untimed cues; seek dispatch now also rejects occurrence changes while waiting behind another command. The public playback API is unchanged. See the [current native validation and captures](live-lyric-ribbon-validation.md#three-row-sleeve-refinement).

## Initial compact native sleeve

The user approved the sleeve interactions and emphasized compact, comfortable sizing. The native version uses a **448 × 226-point** panel including the 20-point record overhang. Its reading viewport stays at 132 points at normal scale, regardless of document length, playback tick, reading mode or source-credit presence. Current words use 25-point medium system text; previous/next cues use 15 points. Manual reading uses 17-point text throughout the full document. At 320 points wide, the same viewport fits the original sample's wrapped current cue and both neighbors. Larger preview text scales the viewport subject to display bounds; long or simultaneous cues remain scrollable instead of enlarging the panel indefinitely.

The visible design is SwiftUI with a standard charcoal content material and a native glass Sync button. The native text view and nonactivating panel retain full text selection, scrolling, font fallback and deliberate keyboard focus. Vinyl rendering, artwork loading/palette extraction, record rotation and artwork transitions reuse the main player's existing components. Line transitions animate the native clip view's bounds; manual scroll/selection cancels the animation at its visible position. The reader retains its identity through song changes. Sync clears SwiftUI control focus before deferred, guarded native reader focus; it never activates a passive panel.

The shortcut uses the maintained KeyboardShortcuts package rather than a second Carbon hotkey implementation. The app target pins 3.1.0 and registers Control–Option–L independently of ribbon visibility; the existing menu action remains available. The pinned manifest has no external dependencies, plugins or binary targets. Public advisories showed none published when checked, which is a scoped dependency check rather than proof of no vulnerabilities. [KeyboardShortcuts 3.1.0 release](https://github.com/sindresorhus/KeyboardShortcuts/releases/tag/3.1.0), [manifest](https://github.com/sindresorhus/KeyboardShortcuts/blob/3.1.0/Package.swift), [public advisories](https://github.com/sindresorhus/KeyboardShortcuts/security/advisories) (checked October 18, 2026).

Native captures exposed a custom scroller falling back to legacy layout and clipping the right edge of long text. A hosted regression reproduced the lost width; declaring overlay compatibility retained the native overlay scroller and full text-container width. [Apple: isCompatibleWithOverlayScrollers](https://developer.apple.com/documentation/appkit/nsscroller/iscompatiblewithoverlayscrollers), [preferredScrollerStyle](https://developer.apple.com/documentation/appkit/nsscroller/preferredscrollerstyle) (checked October 18, 2026).

The [normal capture](mockups/lyric-sleeve-native-live.png), [narrow capture](mockups/lyric-sleeve-native-narrow.png) and [reading capture](mockups/lyric-sleeve-native-reading.png) use only original words and artwork. The earlier sizes and behavior notes below describe their respective proposal stages.

## Selected sleeve: revised reading and motion

The user selected the sleeve and requested less chrome, scroll-to-read behavior, and three cues. The [revised interactive study](mockups/lyric-ribbon-sleeve-interactions.html) and [capture](mockups/lyric-ribbon-sleeve-interactions.png) demonstrate the proposed behavior with original fixtures.

1. Remove the X from the surface. Add a global show/hide shortcut, proposed as Control–Option–L, while retaining the existing menu action for discoverability and a pointer fallback. The shipped app currently has no global lyric shortcut: the menu action has an empty key equivalent, and Escape dismisses only when the panel has keyboard focus. The browser shortcut is explicitly page-local; it does not register a system shortcut.
2. Remove Hold text. Intentional wheel, trackpad, scrollbar or keyboard scrolling enters manual reading of the full document. Playback continues, and subsequent cue updates must not move the manual viewport. Show Sync lyrics only in this mode, in a reserved footer slot so the panel does not resize. There is no automatic snap-back. Scrolling is reading, not seeking; new-song changes clear manual mode. This follows the interaction requested by the user. Spotify's support documents time-synced lyrics but does not specify all of these manual-mode details. [Spotify: View lyrics](https://support.spotify.com/article/lyrics/) (checked October 18, 2026).
3. Show previous/current/next logical cues in live mode, with the current cue brightest and larger, and both neighbors quieter. A cue can wrap onto multiple physical lines. A stable, bounded viewport and manual reading handle unusually long passages. Before the first cue or after the last, do not invent missing neighbors. Native `LyricProjection` currently exposes previous/current only; the next cue and full-document reader require implementation.
4. Rotate the vinyl while playback is running, including during manual reading. Pause it with playback, stop rendering work when hidden, and stop rotation with Reduce Motion. Reuse Bopify's existing `RecordRotation` and vinyl/artwork components: its cruise rate is π/6 radians per second, or one turn every 12 seconds. The browser demonstrates that rate with CSS; it does not replace the native motor behavior.
5. On an ordinary cue change, move the passage upward into its next position and transfer emphasis to the current cue. Target a brief transition around 220–280 milliseconds, without bounce, word highlighting or a moving panel. Browser smooth scrolling has browser-controlled timing. Manual scrolling remains under the reader's control; Sync returns directly to the current cue instead of animating through all missed cues.
6. On a known next/previous song change, keep the sleeve frame fixed, introduce the title and lyric content with a small directional movement, and crossfade the record label and accent. The study uses a 9-pixel movement over 280 milliseconds and a 350-millisecond label fade. For unknown direction, prefer a crossfade. In native integration, use authoritative occurrence identity and the existing player direction when available; never combine the new title with old lyrics while loading. Reuse the player's artwork transition rather than introducing a second morphing system.

Motion remains optional: Reduce Motion removes rotation and sliding; short fades or immediate updates can retain state clarity. These timings and distances are Bopify proposals, not Apple-prescribed values. [Apple HIG: Motion](https://developer.apple.com/design/human-interface-guidelines/motion) (current page checked October 18, 2026; change log September 9, 2025).

Study verification: actual keyboard scrolling entered manual mode; a cue advance preserved its scroll position; Sync restored following and hid itself; three short live cues fit the viewport. Play/pause controlled rotation; next/previous changed recording identity; Reduce Motion disabled rotation. Narrow, dark, no-artwork manual mode retained its source credit and Sync control without horizontal overflow. The wheel handler passed an event-level check. A CLI wheel attempt targeted desktop coordinate (0, 0), so it was discarded as a pointer test. Native trackpad momentum, global shortcut registration, focus preservation, long/multilingual cues, loading states, and interrupted transitions still need production validation. No native UI or playback code changed in this revision.

## October 18 art-direction reassessment

The user found the released refinement boring. The previous research established a useful platform foundation, but it did not establish a compelling visual identity. Material and typography guidelines cannot identify a universally “best” lyric ribbon. Aesthetic preference and glance reading still require evaluating the actual composition.

Local inspection found a mismatch: Bopify's main player has an asymmetric record-and-sleeve silhouette, artwork-centered vinyl, grooves and restrained colour. The ribbon reduces that identity to a small record mark inside a conventional rounded card. Metadata, lyric context, current lyric, provider and status occupy separate bands. Similar grey tones and unused vertical space make those bands feel like a status panel.

The revised brief is a clean retro companion for background listening, with charcoal behind the words and glass on controls. Make the composition recognizably related to Bopify while retaining the existing focus, hold/catch-up and line-timing behavior. The [interactive visual comparison](mockups/lyric-ribbon-art-directions.html) and [comparison capture](mockups/lyric-ribbon-art-directions.png) show three alternatives using original words and artwork.

Primary-source findings, checked October 18, 2026:

- Lyric Fever explicitly separates fullscreen lyrics from a persistent karaoke popup; its published menu-bar screenshot illustrates a third, very compact presentation. This supports comparing attention levels, not copying a fullscreen karaoke composition into a work companion. [Lyric Fever README and published screenshots](https://github.com/aviwad/LyricFever).
- AMLL provides lyric rendering and fluid-background components aimed at an Apple Music-like experience. Its official playground exposes separate lyric, audio and artwork inputs. This is a useful reference for separating content from presentation, not evidence that continuous fluid backgrounds suit a peripheral ribbon. [AMLL project](https://github.com/amll-dev/applemusic-like-lyrics), [official playground](https://amll.dev/playground/).
- Spotify describes its bespoke variable typeface as a combination of classic and contemporary forms. Our interpretation: typography can carry music identity beyond default interface styling. The liner-note study tests a native serif/system-text contrast; it does not use Spotify's proprietary font. [Introducing Spotify Mix](https://newsroom.spotify.com/2024-05-22/introducing-spotify-mix-our-new-and-exclusive-font/) (May 22, 2024).
- Teenage Engineering's Field System page presents compact physical audio objects with restrained colour, precise controls and strong silhouettes. Our visual interpretation informs the broadcast strip's identity rail and single accent mark; the mockup adds no fake audio meters or knobs. [Field System](https://teenage.engineering/products/field-system).
- Apple's material guidance remains the constraint for the reading surface and controls. Glass is a material decision, not sufficient art direction. [Apple HIG: Materials](https://developer.apple.com/design/human-interface-guidelines/materials).

| Study | Default browser size | What changes | Tradeoff |
| --- | --- | --- | --- |
| Record sleeve — recommended | 476 × 199 CSS pixels, including a 448-pixel surface | Partly exposed artwork-centered record, asymmetric sleeve, muted spine, consolidated credit/status footer | Strongest connection to the existing player; a little extra width |
| Broadcast strip | 540 × 179 CSS pixels | Compact identity rail, fine cue mark, lyrics in a separate horizontal field | Shorter silhouette, greater desktop width; tight at 320 pixels |
| Liner note | 420 × 227 CSS pixels | Editorial serif lyric, system metadata, warm spine and fine rules | Stronger typographic contrast; taller and needs native multilingual font-fallback evaluation |

These are visual studies, not production implementations or final native measurements. None requires a new rendering framework. Artwork and colour in the studies are original, fixed fixtures; a native artwork-connected version would need to reuse Bopify's existing artwork store and palette path. A neutral label is the no-artwork fallback. The charcoal lyric background and ivory lyric colour remain stable.

Motion is limited to a manually triggered, short cue-level transition and respects reduced motion. There is no simulated word timing, continuously moving backdrop, or decorative audio animation. Each study independently holds its displayed passage while the simulated song advances, then catches up with Back to live. The small source credit remains visible, including at narrow widths. Long current lyrics scroll in a stable viewport; preceding context is deliberately abbreviated in these composition studies, so production must retain the existing full document/reading behavior.

Browser verification: hold isolation and catch-up, hide/restore, default dimensions, and 320-pixel long-text geometry passed scripted assertions. Narrow lyrics had vertical overflow without horizontal overflow; controls and source credit stayed inside their surfaces. Normal and narrow/dark/no-artwork captures were inspected. This verifies the study's interactions and layout, not native Liquid Glass, focus preservation, or subjective reading comfort. Those remain native validation requirements after a direction is selected. The production UI is unchanged by this study.

## October 18 refinement for the released ribbon

The user requested a modern UI/UX refinement while retaining Bopify's clean retro identity, and selected a charcoal reading surface with Liquid Glass controls. The alternative was to keep the previous full glass shell and refine only typography and controls. The selected direction gives the words a steadier backdrop while preserving native material on the interactive layer.

Research informed these choices:

- Keep the reading surface on a standard material with a restrained charcoal fill; reserve Liquid Glass for the native reading toggle and dismiss button. Apple's current guidance places glass on controls/navigation and standard materials behind content. [Apple HIG: Materials](https://developer.apple.com/design/human-interface-guidelines/materials) (Liquid Glass guidance updated September 9, 2025; checked October 18, 2026).
- Use system typography with a clearer hierarchy: 25-point current lyrics, 15-point preceding lyrics, distinct title and artist, and 11–12-point secondary information and controls. These are Bopify's design choices, informed by Apple's legibility and hierarchy guidance; they are not platform-mandated lyric sizes. [Apple HIG: Typography](https://developer.apple.com/design/human-interface-guidelines/typography) (checked October 18, 2026).
- Use the platform's glass button style and group its effects with `GlassEffectContainer`; keep native bordered controls and an opaque surface in the existing transparency/contrast fallback. No shader, glass simulation or new package is needed. [Apple: Applying Liquid Glass to custom views](https://developer.apple.com/documentation/swiftui/applying-liquid-glass-to-custom-views) (checked October 18, 2026).
- Preserve a clear distinction between timed lyrics and ordinary full-text reading. The action holds the words without changing audio; unsynced text has no invented live highlight. [Apple Music: See lyrics on Mac or PC](https://support.apple.com/en-us/108960) (checked October 18, 2026).

Local inspection supplied the remaining UX decisions. Hold text and Back to live stay visible, with a persistent header close control outside the drag region. A short Reading status and its explanatory help distinguish frozen words from continuing playback. Metadata has a full-identity tooltip. Long cues use a viewport capped at 180 points at normal lyric scale, subject to the available display height; the cap scales with lyric text size. Panel geometry stays constant through ordinary cue and hold changes.

An overflow regression showed that resetting to the start of a long preceding cue could hide the active lyric. The refined passage marks the current range and uses native TextKit line geometry to place it below one line of context on a cue reset. Trailing document space permits that placement even for a short current cue. Ordinary clock updates preserve manual scrolling and selection. [Apple NSLayoutManager lineFragmentRect](https://developer.apple.com/documentation/appkit/nslayoutmanager/linefragmentrect(forglyphat:effectiverange:)) (checked October 18, 2026).

Native screenshots and final verification are recorded in the [live validation record](live-lyric-ribbon-validation.md). Fixtures contain original sample words and use no live audio. Existing playback, source attribution and Release availability remain in scope; no provider or playback behavior changes are part of this refinement.

## Three possible experiences

The sections from here onward record the original exploration. References to fixture-only implementation or unresolved live integration describe that earlier stage; the current implementation status is in the [live validation record](live-lyric-ribbon-validation.md).

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
