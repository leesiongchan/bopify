# Playback feedback implementation plan

**Goal:** Combine the selected vinyl punch and music-note burst, and establish why Recents can contain about 12 songs.

**Design:** Keep the existing 48-point Play/Pause control and playback commands. Squash and tilt on press, spring back on release, and emit a ring plus five notes over 0.6 seconds on activation. Restart the short effect on repeated clicks without queued tasks. Disable moving feedback with Reduce Motion; decorations do not receive input or accessibility focus.

**Approaches:** A stronger bounce alone was simpler but less expressive. A note burst alone lacked the physical press response. The user selected both vinyl punch and music-note burst.

**Architecture:** Use SwiftUI ButtonStyle for the press and keyframeAnimator for the burst. No dependencies or playback-engine changes. Retain the current Recents behavior and add count-only diagnostics rather than guessing at the account's response.

**Tech stack:** SwiftUI, AppKit, Swift Testing, os.Logger.

- [x] Verify 50 distinct Recents items and repeated plays; log API item, valid-track, and distinct-track counts in SpotifyLibraryClient.swift and RecentsModel.swift.
- [x] Add playback-specific feedback in TransportControls.swift and PlayerControlButtonStyle.swift.
- [x] Capture static before/after and Reduce Motion images with a native hosted view; verify effects disappear when reduced and at rest.
- [x] Run Swift library tests, macOS app tests, shipping app build, diff checks, and a final review. Passed: 119 library tests, 189 app tests, app build, and diff checks; review found no blockers.

**Constraints:** Preserve launch/menu/onboarding edits already in this workspace. No history persistence, new dependencies, audible effects, or changes to command timing.
