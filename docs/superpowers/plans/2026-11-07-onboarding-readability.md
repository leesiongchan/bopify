# Onboarding Readability and Liquid Glass Plan

**Authorization:** The user explicitly requested an overall onboarding refinement, Liquid Design inputs, and readable steps. This is the concrete design within that authorization; no additional approval is pending.

**Design:** Keep the main-window onboarding and animated record. Use an opaque semantic window background for instructional content, with Aurora confined to the record’s decorative area. Use native Liquid Glass only for interactive controls: labeled Client ID and secure key fields plus actions. Preserve native fields, secure cell semantics, focus, Return/Tab, saved values, and stable view identity. Show a readable step name and number, concise numbered registration instructions, and a wrapping/copyable redirect URI. Keep consent and playback behavior unchanged.

**Success criteria:** All stages remain readable with semantic primary/secondary colors and body/callout sizes; long forms scroll vertically on a 320×480 window without horizontal clipping. Both fields have permanent labels and visible focus. High-contrast/reduced-transparency controls have opaque backing; reduced motion retains existing animation policy. No extra windows or engine choices appear.

## Primary-source research

Read 2026-11-07:

- [Apple HIG: Materials](https://developer.apple.com/design/human-interface-guidelines/materials): reserve Liquid Glass for controls/navigation, use it sparingly, and use standard materials for the content layer. The regular variant adjusts background luminosity for legibility. We therefore remove the large glass onboarding surface and keep glass at input/action controls.
- [Apple HIG: Text fields](https://developer.apple.com/design/human-interface-guidelines/text-fields): placeholders disappear while typing; separate labels retain purpose. Sensitive information belongs in secure fields, and Tab order should follow the natural form order. We retain native SecureField and TextField rather than reproducing editors.
- [Apple HIG: Accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility): support larger text, semantic system colors and adequate contrast; macOS defaults are 13 pt. Avoid further opacity on secondary text.
- [Apple WWDC25: Build a SwiftUI app with the new design](https://developer.apple.com/videos/play/wwdc2025/323/): use native glass button styles and regular interactive glass for custom controls. Glass cannot sample other glass, so instructional blocks receive a stable non-glass backing.

- [Spotify Web API: Apps](https://developer.spotify.com/documentation/web-api/concepts/apps) and [Redirect URIs](https://developer.spotify.com/documentation/web-api/concepts/redirect_uri): the registered redirect must match, explicit loopback IP is supported, and the app dashboard supplies Client ID. The numbered guide preserves the current callback URI and existing consent actions.

## Work and verification

- [x] Read existing onboarding, secure-field implementation, native scroll bridge and tests.
- [x] Add regressions for permanent labels, plain secure native fields, Tab identity, high-contrast small-window layout and readable progress.
- [x] Observe red, then implement shared control styling, content backing, headings and registration guide.
- [x] Run focused native/root tests and inspect high-contrast captures. Keep the native NSScrollView bridge.
- [x] Review final diff and document exact results and unverified behavior.

Authentication scopes, consent lifecycle, controller behavior, real playback, credentials and signed app launch are outside this UI task. Native cacheDisplay snapshots can omit GPU glass/blur effects; high-contrast opaque captures and native AX/keyboard checks provide readable evidence without claiming full composited appearance.

## Final evidence

Initial native regression run failed on the old field bezel and missing permanent labels. Final focused verification passed **21 tests across 3 suites**, Xcode exit 0 (`/tmp/bopify-onboarding-readability-final.log`). Coverage includes:

- Plain native secure cell, bullets, permanent labels, Return submission, Tab without submission, and stable native field identity.
- 320×480 layout with requested accessibility text size, visible focus outline, vertical scrolling and no horizontal document overflow.
- Actual opaque background rendering for both Reduce Transparency and Increase Contrast, including alpha assertions against a transparent outside edge. Global system preferences were not modified.
- Light/dark regular and compact high-contrast appearance capture matrix for key and library forms, with top and bottom scroll positions.
- Existing record state, startup panel expansion/return and native accessibility traversal checks.

Inspected copy, labels, privacy text, numbered instructions and the redirect URI wrap without ellipsizing in the tested layouts. Long forms scroll vertically. Field editing and controller progress retain stable identity. The native NSScrollView bridge, consent actions and all auth/controller behavior are unchanged by this UI task.

Capture folders (relative to the worktree):

- Light: `build/test-artifacts/onboarding/139D7688-5A3B-444D-8DBF-E40980BC4EF0/`
- Dark: `build/test-artifacts/onboarding/5897A827-7B14-4390-AA4C-528076E15786/`
- Focused compact secure input: `build/test-artifacts/onboarding/70F05776-6D6B-4BC4-AEF0-70585F74D4B0/high-contrast-key.png`

Each matrix folder contains regular/compact-high-contrast key/library top/bottom PNGs. Root inspected selected light/dark captures too. These are **native cacheDisplay test artifacts, not live composited appearance screenshots**: record scaling, GPU blur and native glass button compositing are omitted or inaccurate. No full-root Reduce Transparency setting was simulated; its actual control background branch was verified with opaque rendering assertions. Root integration owns the full suite, signed build, live playback and composited appearance review after this source freeze.
