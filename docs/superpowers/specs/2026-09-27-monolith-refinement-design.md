# Monolith interaction and liked-song Cover Flow refinement

Date: 2026-09-27

Status: Written spec approved on 2026-09-27; implementation planning authorized.

## Intent and approved scope

Refine the existing Monolith into a tactile, minimal music object. The user requested removal of the black outline, reliable focus and window dragging from both panels, fewer volume requests, a genuinely spinning and scrubbable vinyl, a speaker-triggered vertical volume slider, and an iPod-style mini Cover Flow below the controls. They selected individual liked songs for Cover Flow and approved sharing the lower section between Cover Flow and the playback queue.

Keep the original attention rule: hover reveals controls without taking focus; clicking or keyboard focus keeps them open. At rest, show only the vinyl. This spec supersedes the original design's stationary label, reflection-only rotation, record-center window dragging, horizontal volume row, absolute ring-seek gesture, and queue-only lower extension. Other startup, authentication, authoritative playback, and window placement behavior remains in force.

Success means the whole visible player feels consistently clickable and movable, different drag targets have predictable meanings, volume stays responsive without building a command backlog, and liked songs can be browsed without interrupting playback.

## Evidence from the current implementation

- `MonolithPlayerView` explicitly disables hit testing on the sleeve background. Only `RecordDragRegion` explicitly acquires native key focus and moves the listening window.
- Both `MonolithPlayerView` and the shell in `MiniPlayerView` send every slider update directly to `PlayerModel.setVolume`. Each value enters the shared serialized command chain.
- `VinylRecordView` rotates only a faint reflection. The label and record body stay still. `RadialProgressView` requires a stationary 250 ms hold and maps angle to absolute track progress.
- `PlayerSurface` has fallback/accessibility strokes and native Liquid Glass edging; the window also has a shadow. No explicit black rectangular outline around the whole listening window was found. The source of the user's observed line must be reproduced and isolated before selecting the surface fix.
- `LibraryService` supports only saved-track membership and mutations. Browsing needs paginated saved-track retrieval. `PlayerModel.load` already forwards a track/context load to the engine; library browsing must not manufacture generation-sensitive queue entries.

## Composition and material

Retain the left vinyl overlapping one rounded glass sleeve. Keep native Liquid Glass where available and system material on older supported systems. Remove redundant decorative dark outlines; use a soft shadow and restrained material highlight for separation. Preserve accessible contrast using semantic surfaces and boundaries when Increase Contrast or Reduce Transparency requires them.

Before changing the material, capture the actual native window over light and dark backgrounds and isolate explicit strokes, native shadow, and glass edge in a controlled fixture. Remove the demonstrated cause of the hard black contour. If it is intrinsic to native glass and cannot be removed independently, present the verified material alternative before replacing the approved Liquid Glass treatment. A screenshot on a black or transparent canvas alone does not establish the cause.

Focused layout has metadata and transport above a shared lower section. Removing the horizontal volume row creates room in the upper controls. Start native layout verification at approximately 484 × 360 pt with the existing 182 pt focused record and 118 pt resting record. These are layout targets, not permission to clip content or shrink targets.

The lower section always has one occupant: liked-song Cover Flow by default, or the existing scrolling queue. Switching occupants preserves the record spindle, upper controls, and outer window frame. The queue button toggles this section. Escape returns from queue to Cover Flow before hiding the player; confirmed queue selection also returns to Cover Flow. A full collapse resets the lower section to Cover Flow while retaining its selected song for the session.

At narrow widths show three covers instead of five. At short screen heights reduce artwork and the lower viewport before reducing transport targets, retaining at least an 80 pt usable lower viewport where the screen permits. Use the existing screen clamping and anchored transition machinery. Long titles truncate visually with complete accessible names and tooltips.

## Focus, dragging, and input ownership

All visible portions of the sleeve, controls, queue, and Cover Flow acquire actual native panel key focus on click. Hover alone never activates the app. Pointer exit does not collapse a key panel; leaving both pointer and native/accessibility focus uses the existing 280 ms grace period. Transparent space outside the visible object remains available to other apps.

| Target | Click | Drag or scroll |
| --- | --- | --- |
| Empty sleeve/panel background, noninteractive metadata | Focus the player | Move the entire window after 4 pt drag slop |
| Transport/favorite/queue/volume button | Focus and perform its action | Retain normal button cancellation behavior |
| Vinyl surface | Focus, with no playback command | Relative seek within the current track |
| Volume slider | Focus and adjust volume | Adjust volume; never move the window |
| Neighboring Cover Flow item | Center that song | Browse the carousel |
| Centered Cover Flow item | Play that song | Browse; suppress click after a drag |
| Queue row | Use existing queue selection | Preserve scroll/row behavior; never move the window |

Use native focus callbacks rather than adding a persistent synthetic focus flag. Reuse the balanced native window-drag lifecycle for sleeve backgrounds. Route background dragging beneath interactive content so it cannot steal sliders, cover gestures, or queue scrolling. Stop a window drag cleanly on hide, content replacement, or loss of its native window.

Only one player-owned popover is open at a time: opening volume closes favorite details and vice versa. Popover lifetime and slider editing hold attention independently; releasing one hold must not clear another. Escape closes an open popover first. Hide, sign-out, and content replacement dismiss popovers and cancel outstanding gestures.

## Vinyl rotation and scrubbing

Rotate the record body, grooves, and artwork label together clockwise while playback is actually playing. Keep the progress indicator and lighting anchored to the screen so rotation reads as a moving object under fixed light. Start with one revolution per 12 seconds. Preserve angular phase through pause/resume and track-artwork replacement; do not restart from zero. Stop ambient scheduling when paused, buffering, loading, ended, hidden, or inactive.

With Reduce Motion enabled, disable automatic spinning and depth transitions. Seeking remains available with time/progress feedback and keyboard or accessibility adjustment, without requiring animated artwork rotation.

Replace competing center-drag and absolute ring-seek gestures with one relative record scrub:

1. Press focuses the panel and captures the current occurrence, displayed playback position, record angle, and pointer angle. A simple click sends no seek.
2. After 4 pt movement, enter scrubbing and hold the player open. While pressed, suspend automatic visual rotation so the surface follows the hand. The reveal transition must not create a false angle delta: rebase pointer geometry if the record size or center changes.
3. Accumulate signed shortest angular deltas across the zero-degree boundary. Clockwise advances, counterclockwise rewinds. Start with one full revolution corresponding to 60 seconds of track time, independent of song duration.
4. Ignore angular samples inside a 12 pt spindle dead zone; rebase on leaving it to avoid a jump. Clamp preview to track bounds, discard overshoot at a bound, and let reversal move immediately back into the track.
5. Show the preview time and progress immediately. Audio continues normally during the gesture; this is seeking, not pitch manipulation or audio scratching.
6. On release, send exactly one seek to the final preview position. Resume automatic visual rotation from the current angle if still playing. Escape, hide, sign-out, occurrence replacement, duration change, or loss of seek capability cancels without sending a seek.

Keep the progress rim as a display and an accessible adjustable control, with five-second increments. Existing keyboard seek and transport shortcuts remain available outside controls that handle those keys themselves. There is no next/previous-track command from twisting the record.

## Volume presentation and request control

Place the speaker button in the secondary controls row. Clicking it opens a compact vertical slider popover anchored to the icon, positioned to fit the screen. Volume increases upward. Include a percentage and a separate mute/unmute action inside the popover. Keep the existing session-only remembered positive volume and 0.5 fallback.

The slider thumb and percentage follow a local draft immediately while editing. Engine events remain authoritative playback state and update the control when no edit or final command is pending. A failed command settles back to confirmed volume with the existing command notice; do not claim audible success from changing the draft.

Fix the shared model boundary so the shell slider also benefits:

- Coalesce ongoing changes to at most one normal dispatch per 150 ms, keeping only the latest requested value. This provides audible feedback during long drags instead of waiting indefinitely for motion to stop.
- Permit one volume operation in flight and one replaceable pending value. Never append every pointer sample to the transport command chain.
- On release, flush the final value without the normal delay. If an operation is already in flight, send the latest final value as soon as that operation finishes. Do not describe this as canceling a command already sent to the engine.
- Drop duplicate values after clamping to 0…1; reject nonfinite input. Mute/unmute bypasses the normal delay and supersedes stale pending slider values.
- Keep unrelated transport responsive; it must not wait behind a history of obsolete volume values. Session stop or device loss invalidates queued volume work and stale completions. A new gesture supersedes an older unsent final value.
- Normal popover dismissal commits the latest valid draft once. Hide/sign-out/device loss cancels unsent work instead; it does not undo volume already applied.

## Liked-song Cover Flow

Each item represents one liked track, keyed by its Spotify track URI. Songs sharing an album retain separate items, titles, and accessible identities. Show a centered approximately 76 pt square cover, two angled neighbors on each side at normal width, and a subtle fading reflection within the same sleeve. Keep corners modest so album art reads as a cover. Use a roughly 280 ms settling spring after browsing; follow direct dragging without lag. Reduce Motion uses a flat shelf and short fades.

Horizontal dragging and horizontal trackpad scrolling browse with snapping. Clicking a side cover centers it. Clicking the centered cover, or Return when the carousel has keyboard focus, explicitly starts that track using `PlayerModel.load`. Left/right arrows browse only while the carousel owns keyboard focus; otherwise preserve existing player shortcuts. The accessible selection announces song and artist, with an explicit play action.

Scrolling, centering, pagination, hover, and initial loading never issue playback commands. Selected library item and currently playing occurrence are separate state. Show the existing playback notice if a load fails. Starting a song uses the existing single-track load behavior; this refinement does not promise that the remainder of Liked Songs replaces the playback queue or change next/previous semantics.

Load the first page when the shelf is first revealed. Preserve the API's returned ordering. Fetch pages of up to 50 as the user approaches the loaded end, with at most one page request active. Do not download the entire library or its artwork on reveal. Load artwork only for visible and nearby items through `ArtworkStore`.

Retain loaded metadata and selection during the signed-in session. Refresh after a confirmed favorite membership change or successful library consent, preserving selection by URI when possible and otherwise choosing the nearest remaining item. On the first reveal after the shelf has been hidden for at least 60 seconds, refresh from the first page to pick up external changes. Do not periodically poll while idle. Offset pagination is not a snapshot: deduplicate by track URI, retain first-seen order, and reset pagination on refresh.

Provide compact in-place states for initial loading, no liked songs, permission required, unavailable data, and retry. A page error retains already loaded songs. Missing artwork gets a stable cover placeholder. Unavailable or invalid track records are skipped without corrupting pagination; advance using the raw response offset and count. Stop on an empty page or no next page.

## Library boundary and lifecycle

Add a small saved-track browsing contract alongside the existing favorite contract, implemented by `SpotifyLibraryClient`. A page contains validated tracks, optional next offset, and total count; reuse existing `Track`, artwork, URI, and `LibraryError` types where they fit. Do not expand `LibraryService` with unrelated album/playlist APIs or force favorite-only test doubles to implement browsing.

Use `GET /v1/me/tracks` with `user-library-read`. Build pagination requests against the fixed Spotify API endpoint; do not forward bearer tokens to response-supplied URLs. Decode and validate track URIs, metadata, and page bounds at the network boundary. Retain the current redirect rejection and status/error mapping, including `Retry-After` for rate limiting. Rate-limited requests wait until eligible for a user retry; no tight retry loop.

Reuse existing scoped authorization. If the read grant is absent, show an explicit enable action rather than opening a browser on hover. Request only the missing read permission for browsing, retaining already granted scopes. Favoriting continues to use its existing write-consent path. Actual endpoint access for this app's client must be verified; do not treat a documented endpoint as proof that its credentials work.

An observable liked-song model owns pagination, selection, loading, and errors, and is composed in `AppEnvironment`. Cancel and invalidate requests on refresh, sign-out, account/session replacement, and quit. A late result cannot restore data from an earlier session. Hiding the shelf stops artwork prefetch and new page requests; a current metadata request may finish into the session cache.

No new package dependency or Rust/FFI change is planned. Native SwiftUI/AppKit transforms, input, and controls cover the visual requirements. The browsing model remains distinct from queue generation and queue-selection confirmation.

## Integration and observability

Expected areas are `PlayerSurface`, `MonolithPlayerView`, `VinylRecordView`, the progress/seek composition, `StatusPanel`, `MonolithWindowController`, `MonolithLayout`, `PlayerPresentation`, `PlayerModel`, library domain/client/model code, and `AppEnvironment`. Update the remaining shell volume binding to the same volume lifecycle. Preserve existing serialized player-mode raw values and record-center preferences; no saved-preference migration is required.

Use the existing logging categories for page request completion/failure, discarded stale library results, scrub begin/commit/cancel, popover lifecycle where needed to diagnose focus, and volume dispatch/failure. Never log every animation frame or pointer sample. Do not log tokens, response bodies, or library contents; existing private metadata logging remains private.

## Verification and acceptance

1. Capture native before/after surfaces on light and dark backgrounds. Identify the observed black contour's source and demonstrate its removal without clipping shadows, losing accessible contrast, or replacing glass silently.
2. Click blank areas of both lower-section modes and the control panel, then move the pointer away: the panel stays focused. Background dragging moves the window; sliders, covers, queue scrolling, and record scrubbing do not. Transparent exterior pixels remain click-through.
3. With a controllable engine, flood the volume boundary and verify the 150 ms dispatch limit, one in-flight/one pending bound, deduplication, final flush, transport responsiveness, mute supersession, failure recovery, and cancellation on stop/device loss. Exercise both volume entry points.
4. Verify vinyl phase continuity through pause/resume, track transitions, reveal, and scrub. Measure zero ambient ticks when hidden, paused, or Reduce Motion is active. Test angular wraparound, direction reversal, spindle crossing, bounds, geometry changes, and all scrub cancellation paths; a completed gesture sends one seek.
5. Exercise native volume-popover placement, focus, slider dragging beyond its bounds, outside click, and Escape. Verify mutually exclusive popovers and independently balanced interaction holds.
6. Verify saved-track request scopes, fixed-origin pagination, malformed/unavailable items, duplicate pages, empty library, missing artwork, rate limiting, stale refresh/sign-out results, membership refresh, and selection preservation. Browsing generates no playback command; explicit activation loads the selected URI once.
7. Capture focused Cover Flow and queue at normal and narrow widths, long metadata, missing artwork, light/dark appearance, and accessibility settings. Verify keyboard carousel navigation does not steal player shortcuts outside the carousel and accessible play/seek/volume actions are available.
8. Run the relevant package tests and macOS build, then native interaction probes for geometry, click-through, focus, gestures, and composition. Distinguish stubbed engine results from live Spotify playback and real system accessibility checks in the verification report.

## Research

- [Spotify: Get User's Saved Tracks](https://developer.spotify.com/documentation/web-api/reference/get-users-saved-tracks), accessed 2026-09-27: saved-track retrieval requires `user-library-read` and supports offset pagination with a maximum page size of 50.
- [Apple: Sliders](https://developer.apple.com/design/human-interface-guidelines/sliders), accessed 2026-09-27: vertical values increase upward, and live feedback is appropriate for continuous adjustment.
- [Apple: Accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility), accessed 2026-09-27: Reduce Motion should reduce automatic repetitive animation and depth effects; direct interaction must remain usable.
- [Original Monolith spec](2026-09-26-monolith-player-design.md): approved minimal resting state, native focus semantics, spindle anchoring, material fallback, and authoritative playback boundaries.
