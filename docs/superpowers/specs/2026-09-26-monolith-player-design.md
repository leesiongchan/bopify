# Monolith vinyl player

Date: 2026-09-26

Status: Written spec approved on 2026-09-27; implementation planning authorized.

## Intent and approved direction

Bopify should feel like a small artistic music object on the desktop: a vinyl record at rest, becoming a complete player when engaged. The user requested Liquid Glass, more dramatic and fluid motion, and the fewest possible unattended elements. They selected Monolith over Eclipse and Liquid Orbit, then approved its refined resting, focused, and queue layouts.

The user explicitly chose **hover reveals controls; click or keyboard focus keeps them open**. Focus here means engagement with the player, not whether Bopify is the frontmost application.

The [approved interactive study](assets/2026-09-26-monolith-study.html) is a standalone visual reference with original sample artwork. It demonstrates proportions and choreography, not production playback or native glass rendering. This spec defines behavior where the browser study simplifies it.

Success means the resting player is recognizable as a vinyl record, the focused controls are immediately usable, opening and closing feel like one continuous transformation, and neither animation nor window resizing disrupts input.

## Form and layout

| State | Visible composition | Initial native geometry target |
| --- | --- | --- |
| Resting | Vinyl, center artwork, fine rim and soft shadow | 118 pt record; tight window bounds with shadow allowance |
| Focused | Larger vinyl protruding from the left of one glass sleeve; complete controls on the right | 182 pt record; approximately 460 × 240 pt content envelope |
| Queue | Same record and controls; sleeve extends below them with a scrolling queue | Same width; approximately 400 pt total content height, constrained to the screen |

The record center stays at the same screen coordinate during transitions whenever screen bounds permit. The focused record grows around that center. The sleeve unfolds to the right from behind it; the queue extends downward. Near screen edges, translate the whole object only as far as needed to keep controls reachable. The record remains at that adjusted position on returning to rest. Do not mirror the layout or repeatedly reposition it while interacting.

These are layout targets, not reasons to compress text or targets. Native typography, localization, accessibility, and shadow padding can increase the envelope. Primary transport targets are at least 40 pt, play/pause 48 pt, secondary controls at least 28 pt, and secondary text approximately 12 pt. Truncate long track/artist names with accessible full text and tooltips; do not continuously marquee them.

The vinyl uses a dark graphite surface, subtle radial grooves, a restrained reflection, and a circular artwork label. The artwork itself stays upright. While playing, a low-contrast reflection makes one slow revolution in approximately 24 seconds. Pausing gently settles the reflection; loading, buffering, stopped, hidden, and reduced-motion states do not run this ambient animation. No persistent adjacent album covers, app title, expand/collapse buttons, rectangular outer window surface, or separate glass transport capsule remain in the signed-in player.

The sleeve is the single main glass surface. Use native regular Liquid Glass on macOS 26+, system material on older supported macOS versions, and an opaque semantic surface for reduced transparency. Controls and queue rows do not each acquire another glass backing. Artwork supplies a restrained accent; legibility must not depend on a particular album color or wallpaper.

## Controls and queue

The sleeve contains track and artist, favorite status, previous/play-pause/next, elapsed and total time, then shuffle, repeat, volume/mute, and queue. Keep-on-top, sign-out, and quit remain available from the status-item menu; move keep-on-top there from the existing player header menu when removing that header. Keep-on-top is independent of focus retention.

All playback actions use existing `PlayerModel` commands and authoritative playback events. Preserve disabled states for inactive devices, unavailable next/previous, buffering, and nonseekable content. Repeat retains all three existing states: off, context, track. Preserve `FavoriteButton` authorization, loading, retry, and unavailable-media behavior rather than replacing it with an optimistic heart toggle.

Volume moves from the options menu to the focused sleeve. Mute sends volume zero and remembers the last positive confirmed volume for the current player session. Unmute restores that value; when no positive value has been observed, use 0.5. The volume icon follows confirmed volume, including external changes. A positive slider adjustment clears mute. Do not persist mute or remembered volume as a new playback preference. This requires presentation state and tests but no engine API change.

The focused record rim doubles as progress and seek control. Start progress at twelve o'clock and move clockwise, matching the study; update angle conversion and wraparound tests together. Preserve the existing deliberate 250 ms hold before radial dragging, commit one seek on release, and provide keyboard/VoiceOver adjustment in five-second increments. A center click acquires focus without changing playback. The center label can serve as a window drag region after normal drag slop; remove the old album-drag-to-next gesture so dragging the object has one meaning. Keep ring seeking separate from center dragging.

Queue extends within the same sleeve, preserving the record, track details, and transport positions. Reuse existing queue metadata loading, current-entry indication, upcoming-entry order, generation-safe selection, and command notices. It scrolls independently and contains no second compact player. Show available upcoming entries; two rows in the study are illustrative, not a limit. No reordering or queue editing is added.

On queue selection, remain open until playback confirms the selected occurrence. Then close the queue extension and show the new track; if the command fails or becomes stale, leave the queue and its notice visible. Queue dismissal cancels no playback commands. Closing after full disengagement resets the queue to closed for the next reveal.

## Attention and input rules

Attention is transient, distinct from playback, visibility, and keep-on-top. The presentation model owns pointer presence, key/accessibility focus, active interaction, queue expansion, and one cancellable collapse deadline.

| Event | Required behavior |
| --- | --- |
| Pointer enters resting record | Begin reveal immediately, without activating the app or taking keyboard focus |
| Pointer traverses sleeve, controls, or open queue | Remain revealed; include the path between record and sleeve in the active region |
| Click record/control or acquire keyboard/accessibility focus | Keep revealed while that focus belongs to the player |
| Pointer leaves but focus remains | Stay revealed |
| Focus leaves but pointer remains | Stay revealed |
| Both leave | Collapse after a 280 ms grace period |
| Pointer/focus returns during delay or collapse | Cancel the old deadline; reverse continuously from the current presentation |
| Seek, volume drag, window drag, or player-owned menu/popover | Hold presentation stable for that interaction; re-evaluate attention when it ends |
| Panel hides, signs out, or its content is replaced | Cancel timers and gestures; clear transient engagement and queue state |

Use actual panel key/focus callbacks rather than app activation alone: Bopify is an `LSUIElement` app with a nonactivating panel. A click into another app must remain available while Bopify is resting. Hidden controls must neither intercept events nor remain in keyboard/accessibility navigation. VoiceOver focus on the record reveals the controls and announces the track and playback state.

Preserve Space, arrow seeking, and Command-arrow transport shortcuts, respecting controls' native key handling. Escape closes a player-owned popover first, then the queue, then hides the panel, preserving the current queue-before-dismiss convention. Clicking the status item opens and focuses the sleeve; clicking it while visible hides the panel as today. Merely losing focus leaves the small record visible, subject to normal window stacking and the existing keep-on-top setting.

## Motion

| Transition | Starting choreography |
| --- | --- |
| Reveal | Record grows around its spindle; sleeve unfolds from behind it; labels settle into place; approximately 600–680 ms total |
| Recede | Labels leave first and sleeve contracts into the record; approximately 450–550 ms after the attention grace period |
| Queue | Sleeve extends downward while existing controls stay fixed; approximately 450–550 ms |
| Confirmed track change | Outgoing artwork/record tilts and recedes as the incoming one settles on the same spindle; approximately 600–650 ms |
| Button feedback | Immediate highlight/press response, approximately 120–160 ms |

Use a restrained spring settle rather than repeated bouncing. Controls become interactive as soon as visible; playback commands never wait for animation completion. Animate track replacement only after confirmed playback/queue state, using occurrence identity to distinguish duplicate tracks. Ambiguous replacements fade rather than inventing a direction. Rapid next/previous commands replace the in-flight visual destination without replaying stale animations. Artwork loading must not cause the whole object to disappear or resize.

All attention and queue transitions must reverse from their current geometry. Keep a shared artwork owner and interruption-aware transition state; adapt the current `ArtworkMorphState`/artwork cache rather than creating competing animation timelines. Do not stack the existing lens distortion on top of the new depth transition unless native visual verification shows a specific need.

Reduced Motion uses short opacity changes (approximately 120–160 ms), no ambient rotation, no tilt/parallax, and immediate window geometry changes without a spring. Reduce Transparency and Increase Contrast preserve the same layout and affordances with system colors and stronger boundaries.

## Native architecture and integration

Keep the existing SwiftUI/AppKit split and playback/backend boundaries. No new package dependency is required.

- `PlayerPresentation.swift`: own the attention rules, queue engagement, and deterministic target geometry; expose state transitions that can be tested without a window. Retain `PlayerMode` raw values for compatibility, mapping compact to resting, expanded to focused, and queue to the extended sleeve. Remove manual mode selection from the player UI; native events drive effective presentation.
- `StatusPanel.swift` and `StatusItemController.swift`: own pointer/key/window lifecycle integration, screen-space record anchoring, frame sizing, clamping, and persistence. Update the old 340–430 pt width and 88/560–800 pt height constraints for the new state geometry.
- `MiniPlayerView.swift`, `PlayerSurface.swift`, and record/artwork views: compose one stable record and one sleeve. Adapt existing artwork loading and the shared artwork overlay. Small record and sleeve views may be extracted when they have distinct responsibilities; no generic design system is needed.
- `TransportControls.swift`, `RadialProgressView.swift`, `FavoriteButton.swift`, and `QueueView.swift`: reuse command and state behavior in the new layout. Remove the queue's duplicate compact transport and old carousel presentation where made obsolete by this redesign.
- `AppEnvironment.swift`: retain auth/player composition and favorite refresh behavior; stop treating the saved manual mode as the source of engagement.

The window needs an animation envelope large enough for the moving material and shadows, then tight settled bounds. Transparent remnants of the focused window must not swallow clicks in other apps after collapse. Synchronize AppKit frame changes with the SwiftUI transition; independent resizing animations that drift or clip the record are unacceptable. This native behavior must be demonstrated early in the implementation with a window probe; the browser study cannot verify it.

Persist the settled record center and keep-on-top preference, not pointer/key focus or a pending collapse. Add a dedicated record-center preference. If it is absent, use the midpoint of the legacy saved window frame as the initial center and clamp to the current screen; retain the old values for compatibility. When neither preference exists, place the player below the status item using the existing first-open behavior. Legacy `player.mode` values remain readable but do not reopen an unattended full player. After initial placement, dragging persists the new settled anchor. Monitor removal and resolution changes clamp the entire object to a visible display. Queue height shrinks into a scrollable region before relocating the player unnecessarily.

Signed-out, authenticating, and signed-in-without-a-track views retain their existing actionable presentation and do not collapse into an unexplained empty record. Their lifecycle remains outside the Monolith listening-state reducer. This redesign does not implement the separate startup-restore plan or alter auth, Spotify integration, or the Rust bridge.

## State, errors, and observability

Playback and queue state remain authoritative in `PlayerModel`; favorite state remains in `FavoriteModel`; artwork remains in `ArtworkStore`. Views derive their rendering from those owners. Presentation animations do not manufacture playback success or mutate queue identity.

Missing artwork uses a neutral center label with the existing music-note fallback, preserving record geometry. During loading/buffering the focused sleeve shows a compact status near track details and honors current control gating. Inactive-device and playback errors remain actionable in the focused sleeve. When unattended, use a small nonflashing rim indication and an accessible status description; do not steal focus or open a large error panel. Existing command/favorite notices remain visible in the focused layout without overlapping controls.

Use existing `BopifyLog.playback`/library logging for presentation changes and their causes, interaction cancellation, and screen clamping. Do not log every animation frame, pointer movement, or artwork/title data. Preserve existing command boundary and failure logs.

## Verification and acceptance

1. Extend `PlayerPresentationTests` with pointer/focus combinations, cancellable grace periods, interaction holds, queue closure, Escape ordering, legacy placement, and screen-edge geometry. Exercise time deterministically rather than sleeping in unit tests.
2. Preserve existing `PlayerModelTests` for capability guards, authoritative command updates, duplicate queue occurrences, and stale selection. Add meaningful mute/restore boundary tests where the new state lives. Test radial twelve-o'clock mapping and wraparound without jumps.
3. Use native window probes and before/after captures for resting, focused, queue, and interrupted transitions. Verify pointer reveal without focus theft, click/keyboard/VoiceOver retention, drag/seek separation, focus loss during a gesture, and hit testing outside the resting record. Existing probes under `docs/superpowers/verification/` are the starting point.
4. Visually check real artwork, long titles, missing artwork, queue hydration/failure, buffering, inactive playback, and favorites authorization/errors on light and dark wallpapers. Exercise reduced motion/transparency, increased contrast, screen edges, display removal, and constrained screen sizes.
5. Record motion while repeatedly entering/leaving and issuing rapid track changes. There must be no snap to an old target, clipped sleeve/record, stale title/artwork pairing, displaced controls under a pointer, or delayed playback command. Confirm ambient rendering stops when paused or the window is hidden.
6. Run the Swift package suite and macOS app build. Review the diff for scope and inspect the final native screenshots/video; passing model tests alone does not establish this design is complete.

These checks are implementation acceptance criteria, not a claim that the native redesign has been built. Browser verification already demonstrated the selected layout, hover reveal, focus retention/release, queue expansion/selection, and narrow-page layout; native material, performance, and window behavior remain to be verified during implementation.

## Research informing the design

- Use glass sparingly for functional controls, with a clear distinction from content: [Apple — Materials](https://developer.apple.com/design/human-interface-guidelines/materials), consulted 2026-09-26.
- Native glass containers combine rendering and support related shape transitions: [Apple — Applying Liquid Glass to custom views](https://developer.apple.com/documentation/SwiftUI/Applying-Liquid-Glass-to-custom-views), consulted 2026-09-26.
- Responsiveness and interruptibility are central to fluid interaction: [Apple — Designing Fluid Interfaces](https://developer.apple.com/videos/play/wwdc2018/803/), WWDC18.
- Spring motion can preserve continuity when a target changes: [Apple — Animate with springs](https://developer.apple.com/videos/play/wwdc2023/10158/), WWDC23.
- Honor accessibility preferences in custom motion: [Apple — Motion](https://developer.apple.com/design/human-interface-guidelines/motion), consulted 2026-09-26.
- Moving between peripheral and focused attention motivates the resting/revealed relationship: [Weiser and Brown — Designing Calm Technology](https://calmtech.com/papers/designing-calm-technology), 1995.

This spec supersedes the player layout and manual presentation-mode decisions in `2026-09-24-liquid-glass-mini-player-design.md`. It preserves existing playback correctness, accessibility obligations, favorites behavior, and unrelated startup-restore work.
