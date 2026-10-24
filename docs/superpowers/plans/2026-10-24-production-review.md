# Production Review Implementation Plan

> **For agentic workers:** Use focused regression tests for confirmed defects and independently review each change before integration.

**Goal:** Review every existing feature for production reliability, security, readability, and maintainability, and remove tests that provide no useful coverage.

**Architecture:** Preserve the Swift module boundaries, native macOS interface, Rust playback engine, and pinned librespot patch. Fix observed defects at their source; avoid speculative abstractions or feature additions.

**Tech Stack:** Swift 6, SwiftUI/AppKit, Rust 1.99.0, Tokio, librespot.

**Spec:** The user-requested feature-by-feature production review and repository `AGENTS.md`.

## Constraints

- Preserve current public behavior except to fix a demonstrated defect.
- Keep useful boundary, lifecycle, integration, and regression coverage.
- Verify tests before and after changes; report failures without deleting or weakening their assertions.
- No dependency additions or production account changes. The user authorized local integration on `main`; publishing remains outside this review.

## Review and verification

1. Map feature code, callers, and existing tests. Record concrete findings and distinguish automated checks from live-service verification.
2. Reproduce confirmed defects, apply the smallest readable fix, and run the relevant regression tests.
3. Independently review diffs and run package tests, native tests, app tests, Rust formatting, and Clippy.
4. Investigate remaining failures and record any unverified requirements before claiming completion.

## Feature coverage

| Area | Code reviewed | Status |
| --- | --- | --- |
| Playback and library authorization | All `BopifyAuth` sources, authorization callers and tests | Fixed overlapping Client ID mutation and malformed token handling; reviewed independently. |
| Search, Spotify links, saved collections, liked songs, favorites, recents, artists, Explore | All `BopifyLibrary` sources, related domain contracts and UI callers | Verified current endpoint compatibility; fixed view-cancellation lifecycle, partial collection initialization, and favorite invalidation; reviewed independently. |
| Playback, queue, volume, recovery | All `BopifyPlayback` sources, domain contracts, callers and tests | Fixed mute decisions during pending volume updates; reviewed independently. |
| Lyrics, artwork, windows, shortcuts, Now Playing | App controllers, views, models, setup, shortcut reference, rendering and tests | Fixed unsafe seek and Retry-After conversions and indirect lyric-link activation; reviewed independently. Runtime focus/search verification remains incomplete. |
| Native playback and FFI | All wrapper Rust modules, FFI lifetime contract, native source patch | Fixed Tokio dependency advisory and native duplicate-occurrence UID corruption during context updates; reviewed independently. |
| Packaging and release | `scripts/`, release workflow | Static review completed. Packaging has not been rerun against this uncommitted tree. |
| Test usefulness | Existing tests and prior cleanup commit `1796132` | Prior commit removed 20 redundant tests. Removed the additional timing-sensitive SwiftUI interruption test; retained crossfade and transparency checks. Made cover interaction deterministic and synchronized pagination assertions with the controlled request. |

## Baseline evidence (2026-10-24)

- `swift test --package-path Packages/BopifyCore`: 434 tests passed across four test targets (197 playback, 112 library, 37 domain, 88 auth).
- `RUSTUP_TOOLCHAIN=1.99.0 ./scripts/test-native.sh`: passed; one hardware test remains intentionally ignored. Includes wrapper and patched Connect/playback/core unit and documentation tests.
- `RUSTUP_TOOLCHAIN=1.99.0 cargo clippy --manifest-path rust/Cargo.toml -p bopify-core --all-targets --all-features --locked -- -D warnings`: passed.
- `cargo fmt --all -- --check` reports formatting differences in patched dependency files. Check the owned crate separately before changing dependency source or its reproducibility patch.
- Full macOS app baseline: 172 tests, 14 issues. Failures affect cover animation, retained search selection, key-window behavior, and rapid artwork changes. These precede the fixes and remain under investigation.
- Swift/Xcode require access outside the filesystem sandbox for their caches and native test runner. An environment override selected Rust 1.98, so native verification explicitly selected the already-installed pinned compiler.

## Completion gates still open

- [x] Verify and independently review Swift production fixes.
- [x] Finish and independently review the native duplicate-occurrence fix.
- [ ] Resolve or establish the environmental cause of each app baseline failure.
- [x] Run all affected suites against the final tree and record failures.
- [x] Record live Spotify sign-in, playback, hardware, and distribution checks that automated tests cannot prove.

## Verified changes

- Client ID replacements serialize credential cleanup so an old save cannot erase a newer grant. The regression failed with both stale Client ID publication and lost new consent before the fix.
- Token responses reject empty replacement refresh tokens and negative lifetimes. Zero expiry remains valid for immediate renewal.
- Collection, recents, and Explore requests belong to their caches, survive view replacement, and cancel on account/library clearing. Generations suppress stale responses and stale cleanup; shared reveals avoid duplicate requests.
- Collection initialization becomes complete after every initial source succeeds, rather than after playlists alone.
- Favorite selection waits for an active save/remove reconciliation, preserving the membership revision used to refresh Liked Songs. Newer selections and explicit clearing still supersede older work.
- Mute follows displayed volume while engine acknowledgements are pending, preserving the last confirmed positive restore volume.
- Now Playing seek conversion rejects unrepresentable values; Cover Flow countdowns use checked conversion matching search.
- Native lyric links accept indirect activation against the current visible cue while retaining pointer-selection safeguards and session/occurrence validation.
- Native context updates match exact URI/UID identities before assigning remaining metadata to distinct URI occurrences. Empty source UIDs no longer erase an existing occurrence identity. Regressions reproduced the first repeated song receiving the last song's UID and a transfer choosing the wrong queue position; both now pass.
- Removed `PlayerSurfaceTests.rapidSongChangesContinueFromTheVisibleBlend`: its unique assertion tests SwiftUI interruption timing with a 30 ms pixel sample; it fails under suite load and passes isolated. `changingArtworkBlendsOldAndNewColors` and `artworkLetsTheBackdropShowThrough` retain the app's visual-contract coverage.

## Current verification evidence

- Before local integration (2026-10-25), all 442 Swift package tests and the native unit/doc suites passed again; `/tmp/bopify-preintegration-swift.log` and `/tmp/bopify-preintegration-native.log`. One native hardware test remains ignored. The desktop session still reported `screen_locked=1`, so the outstanding app focus/presentation checks remain unverified.
- Swift package after all fixes and the final rebuilt native framework: **442 passed** (199 playback, 117 library, 37 domain, 89 auth); `/tmp/bopify-swift-context-final.log`.
- Rust XCFramework rebuilt successfully with Tokio 1.54.1; `/tmp/bopify-rust-final-build.log`.
- Actual macOS product target built successfully, including its shipping entry point: `xcodebuild -project Bopify/Bopify.xcodeproj -scheme Bopify -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO build`; `/tmp/bopify-product-build-review.log`.
- Native unit/doc suites passed after both the Tokio update and occurrence fix; `/tmp/bopify-context-full-native.log`: wrapper 91, Connect 88, playback 11, core 21, and two documentation tests passed; one hardware test remains ignored. The framework rebuilt successfully afterward; `/tmp/bopify-rust-context-build.log`.
- Clippy with warnings denied and owned-crate formatting passed after all native changes; `/tmp/bopify-clippy-context-final.log`. All shell scripts pass `bash -n`.
- Final full app run: **175 tests, 12 issues**; `/tmp/bopify-app-context-final.log`. The Cover Flow interaction and pagination synchronization now pass. Reader accessibility, Now Playing regressions, and retained artwork crossfade/transparency checks pass. Remaining issues are listed below.
- Isolated search pagination assertion passes after awaiting the fake service's held request; `/tmp/bopify-search-scroll-test.log`.
- The patch now adds only the reviewed native lockfile, context merge, and context resolver regression changes to the existing patch. `scripts/prepare-librespot.sh` verifies the applied source exactly. Newly added blank unified-diff context lines naturally contain a space; check that generated patch with `core.whitespace=-blank-at-eol`, and check other files normally.

## Remaining runtime verification

The hostless app runner starts with `NSApplication` activation policy `.prohibited`. Isolated key-window assertions fail while panels remain visible and eligible for key status. Switching to accessory policy, finishing launch, and explicitly activating did not give the process focus; those diagnostic edits were reverted. A subsequent direct `CGSessionCopyCurrentDictionary` probe reported `session_on_console=1`, `session_login_done=1`, and `screen_locked=1`. The locked desktop explains why activation checks cannot succeed. The user has been asked to unlock the Mac before those tests are rerun. No production window behavior was changed to accommodate the runner.

Native lifecycle instrumentation proved the reopened-search test's synchronous close/show operations were coalesced: no native close notification or second show notification occurred, and the test clicked the original window before its initial show animation completed. The fixture now waits for the concrete old window to hide and locates only popovers attached to its own panel. The pointer test also waits for that owner's next `NSPopover.didShowNotification`, which Apple defines as completion of the show animation. All original interaction assertions remain. With the desktop locked, this presentation-completion check still times out before the synthetic click; production search behavior is unchanged.

Search fixtures now inject local preview artwork, avoiding DNS requests to `preview.invalid`. A separately reproduced fixture race attempted to click a pasted result when the model was loaded but SwiftUI had not created its table; that click now waits for the single visible result row. These test-only lifecycle changes have been independently reviewed. The final targeted run in `/tmp/bopify-search-fixtures-final.log` executed 20 search tests with only the desktop-dependent presentation-completion wait failing. All pasted-link kinds and activation modes passed, and no `preview.invalid` requests appeared in that log. The native focus and completed-presentation checks must be rerun after the Mac is unlocked; no further activation workarounds are being added.

The remaining failed test methods are `typingMultipleCharactersKeepsTheInsertionPointAndArrowKeysSelectResults`, `vinylClickExpandsWithoutTogglingPlayback`, `lyricClicksAndSelectionsPreservePresentationMode`, `syncClickPreservesPresentationMode`, `keyboardReadingAndSyncPreservePresentationMode`, `searchRevealsTheHiddenPlayerAndFocusesTheRetainedQuery`, `playerShortcutHidesSearchAndCanRevealThePlayerAgain`, and `menuBarClickRaisesTheVisiblePlayerAfterAnotherWindowTakesFocus`. Parameterized cases and multiple assertions account for the 12 issues. All assertions remain intact.

Native merge preserves valid distinct occurrence UIDs. It does not sanitize inconsistent source data that duplicates a UID or assigns the same UID to different URIs; that remains an upstream identity limitation. The separate queue tracker still assigns distinct UI occurrence IDs even when UIDs repeat.

Live Spotify authorization, real audio devices/device switching, native VoiceOver invocation, and the packaged app's Gatekeeper/distribution behavior have not been exercised in this review. Packaging requires a clean committed checkout and was not run against the modified tree.

## Dependency audit

The initial RustSec audit reported Tokio 1.53.1's I/O-safety warning and RSA's Marvin timing advisory. Both shipping and patched-native test lockfiles now resolve Tokio **1.54.1**, verified against its official October 21, 2026 release. The native test lockfile also updates Tokio's required `mio`, `socket2`, `libc`, and macro dependencies.

The post-update audit still exits nonzero for **RUSTSEC-2023-0071** (`rsa` 0.9.10); no fixed upstream version exists. Reachability inspection found the only RSA call in `.build/librespot-939dc5e/core/src/connection/handshake.rs` constructs an `RsaPublicKey` and verifies the server signature. No RSA private key operation exists in the checked source, so the advisory's private-key recovery attack does not apply to this call path. This is a source-based assessment; the advisory is recorded and not suppressed.

## References checked

- [Spotify February 2026 Web API changes](https://developer.spotify.com/documentation/web-api/references/changes/february-2026): current search and generic library endpoint contracts.
- [RFC 6749](https://www.rfc-editor.org/rfc/rfc6749.html): token response fields and refresh-token syntax.
- [Spotify refreshing tokens](https://developer.spotify.com/documentation/web-api/tutorials/refreshing-tokens): preserve the previous refresh token when the response omits a replacement.
- [Rustonomicon FFI](https://doc.rust-lang.org/stable/nomicon/ffi.html): asynchronous callbacks must stop before their target storage is destroyed.
- [Tokio JoinSet](https://docs.rs/tokio/latest/tokio/task/struct.JoinSet.html): shutdown aborts and joins owned tasks.
- [Tokio 1.54.1](https://github.com/tokio-rs/tokio/releases/tag/tokio-1.54.1): official stable release on October 21, 2026.
- [Tokio I/O-safety fix](https://github.com/tokio-rs/tokio/pull/8587): unsafe file-descriptor registration contract and safe-constructor deprecations.
- [RSA advisory RUSTSEC-2023-0071](https://rustsec.org/advisories/RUSTSEC-2023-0071): private-key timing leakage; no patched release.
- [Apple activation policy](https://developer.apple.com/documentation/appkit/nsapplication/activationpolicy-swift.enum/prohibited): unbundled executables default to prohibited activation.
- [Apple view display links](https://developer.apple.com/documentation/appkit/nsview/displaylink(target:selector:)): callbacks depend on the view's display availability.
- [Apple popover presentation notification](https://developer.apple.com/documentation/appkit/nspopover/didshownotification): sent after the popover finishes animating onscreen.
- [Apple Window Server session dictionary](https://developer.apple.com/documentation/coregraphics/cgsessioncopycurrentdictionary()): the local probe reads the calling process's desktop-session state.
