# Onboarding viewport and completion follow-up

User requirements: fix clipped native corners/header, fit all onboarding steps without scrolling, keep steps consistent, remove Done, and advance automatically after a brief completion confirmation. Preserve the existing Aurora, breathing motion, vinyl artwork and readable native controls; preview layout changes first and run only related checks.

## Diagnosis and reproduced failures

The root applied a cached startupSize as a fixed frame to every startup screen. After a larger player/previous window resized smaller, the fixed child kept the SwiftUI root oversized; measuring the root fed the stale size back. The native panel then cropped the header and the rounded corners. A real NSPanel regression reproduces 500×700 →430×660: header and embedded form extend beyond the viewport, while the secure field remains inside. This explains why the earlier field-only checks missed the bug.

The scroll-based form also retained a content offset when focusing the editor, allowing the library heading to scroll beneath the fixed artwork. Increasing artwork size made this more apparent.

Healthy Setup reopening set a requested section but did not arm completion or change hasUsablePlayback. It therefore never triggered the readiness observer, leaving Done as the sole escape. Repeated opening during handoff could also reinsert a section after it had been cleared. Library consent previously armed presentation only when playback was not configured.

RED: `/tmp/bopify-viewport-completion-red.log`, five tests with seven expected failures covering native viewport/scroll and completion/library acknowledgement.

## Preview and final implementation

Preview shown/opened before layout edits: `build/onboarding-fit-demo/index.html`. It demonstrates the standard and shorter layouts, separate registration-help page, and automatic completion. All prototype stages fit their bounds without a scrolling form.

The implementation keeps the centered composition. The default startup window is 680 pt tall. GeometryReader supplies actual native viewport size; cached sizing applies only during the outgoing handoff. A plain NSHostingView preserves native text entry/accessibility while replacing the NSScrollView/document/clip-view hierarchy. Header and form are bounded to the actual viewport.

Every step reserves the same 312 pt form area. Artwork retains welcome scale in the standard window and adapts uniformly to shorter viewports, with no step-specific shrinking. Controls keep their readable size. Registration instructions replace the library form temporarily instead of expanding it; returning preserves the typed Client ID. Saved-key context replaces the redundant privacy footer to retain room for actionable failures.

Done and its unused string are removed, as is the duplicate Ready label. Healthy playback setup immediately arms and feeds actual readiness. Repeated requests preserve an active completion/handoff. Successful library consent explicitly arms acknowledgement and synchronizes readiness. Manual library editing is not dismissed before an operation succeeds. Existing generation, cancellation, reduced-motion and actual-readiness guards remain; no new playback commands or auth/proof changes.

Alternatives excluded: shrinking later steps again would break visual consistency; scrolling would violate the new requirement; expanding registration help inside the form would recreate overflow. A separate short help page retains the same window, artwork and visual hierarchy.

## Verification

- First focused run: 56/57 tests passed; one new help assertion inspected the outgoing editor before its 200 ms fade ended. The fixture now waits for the actual incoming scene and complete removal of the outgoing field, rather than an arbitrary 100 ms delay.
- Final focused run: all 8 native/completion/guide tests passed, including a new native library/help fit regression. The first run's other passing checks cover presentation/reduced motion, auth cancellation, secure entry/keyboard, light/dark/compact/high contrast, no-scroll fit, record sizing and startup shell. Logs: `/tmp/bopify-fit-completion-green.log`, `/tmp/bopify-fit-native-final.log`.
- Updated previous scroll assertions to require no NSScrollView and full title/input/primary-action bounds within the viewport. Help navigation verifies accessible URI/Copy/Back, no hidden continuing editor, and typed draft preservation on return.
- Inspected seven composited native captures. All four outer corners have alpha 0 after the exact reproducing resize and on completion. The ready screen has one confirmation and no Done button.
- Captures: `build/test-artifacts/onboarding-composited/D3DC898B-CC5B-4037-A66C-BAB20371B08F/resized.png`; `BFA71520-2DFA-441A-AF8B-6A5AFB725302/{library,library-help}.png`; `93C123AA-363D-48CA-99FB-7DF6030E2958/{completion,handoff,player}.png`.
- One focused read-only review found no material regression. No full app/package/Rust suites ran. Native fixtures are offline; no keys/tokens were read, real playback changed or running app relaunched. The fixture host lacks the production Metal grain library; the app build contains it.

Signed arm64 Release build succeeded and strict deep signature verification passed. Artifact: `build/onboarding-fit-release-20261107/Build/Products/Release/Bopify.app`; build log `/tmp/bopify-fit-release.log`.
