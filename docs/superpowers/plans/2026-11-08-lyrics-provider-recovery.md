# Lyrics provider recovery

User approved correcting authentication routing and adding Spotify/cache/LRCLIB recovery. Preserve the lyrics design, Soloist-only audio, earlier uncommitted work, and run only related checks. No live credentials, playback, app replacement, or provider requests during implementation.

Architecture: Web API profile and device requests use only the user's registered app. The library profile must contain immutable `account_id`; its `id` is used only as a transient expected native-session username, not as a replacement account-link identifier. The native metadata session verifies its authenticated username before publishing any service. Token replacement, suspension and logout still invalidate pending work. Lyrics loading gets the current Track metadata and independently resolves cached positives, Spotify, LRCLIB exact/search, then stale positive data during outages. Provider attribution and the existing rendering stay intact.

Alternatives: retrying the desktop-token Web API profile cannot address its throttling; removing identity checks would weaken account isolation. A separate native identity check plus an independent public-lyrics fallback addresses both failures without adding an audio engine or another onboarding action.

- [x] Native services: encode expectedUsername; reject invalid or mismatched authenticated identities before exposing a services-only session; focused Rust/Swift regression checks.
- [x] Web routing: never send the streaming token to `/me`; retain required account_id and native username proof. Test first-party-token rejection, missing identity, mismatch, replacement, logout and concurrent warmup.
- [x] LyricsResolver: validated bounded HTTPS requests, conservative version matching, timed/plain lyrics, honest LRCLIB attribution, positive caching and stale recovery; do not persist failures as absence. Cancellation and superseded tracks must not publish replies.
- [x] Integrate resolver with current Track snapshot and session lifecycle. Verify fallback during Spotify failure, matching, attribution, line seeking and cancellation without live provider access.
- [x] Review the final scoped change; build the native static library and signed app; report related check results and remaining live verification.

Sources: Spotifast `b99170f234fe3e2e7f6473ff549d4dd3ed45d4c7`, `src/api/client.rs`, `src/backend.rs`, `src/lyrics.rs`; https://spotifast.rocks/how-it-connects/ ; https://spotifast.rocks/soloist/ ; https://lrclib.net/docs ; https://developer.spotify.com/documentation/web-api/reference/get-current-users-profile .


## Results

- Routing RED: `/tmp/bopify-lyrics-routing-red.log` reproduces `.unavailable` when a streaming-client Web API profile is refused. This ran against a separate temporary source snapshot, leaving modified workspace files intact. GREEN: `/tmp/bopify-lyrics-routing-green.log`, 52 tests in SoloistEngineTests, LibrespotServicesTests and SoloistRateLimitTests passed. The existing missing-account_id, mismatch, replacement, authorization suspension and logout checks remain enforced. Only the library/Web API grant now reaches `/me`.
- Native identity RED/GREEN is recorded in `/tmp/bopify-native-identity-red.log` and `/tmp/bopify-native-identity-green.log`: six services-focused checks passed; ten recovery-option checks also passed in `/tmp/bopify-native-recovery-green.log`; Rust library Clippy with warnings denied passed. The new Swift adapter always requires expectedUsername; legacy native callers without the JSON field remain compatible. The native release was rebuilt and copied into the existing arm64 XCFramework slice without directory deletion or ABI/header changes; packaged/source SHA-256 match `274e701a0e8f954529db6a9a462304951f65b813bb2a4c5e9322acb28c0c8127`.
- LyricsResolver: 19 final focused tests passed (`/tmp/bopify-lyrics-fallback-final.log`). Includes positive persistent cache, stale recovery, exact/search outage recovery, wrong artist/version/duration rejection, malformed LRC/plain fallback, multi-timestamp cues, oversized bodies, metadata bounds, long/short Retry-After, timeout, cancellation and no cache poisoning. Failures never become cached absence. Public LRCLIB requests contain no Spotify credentials, disable redirects/cookies and identify Bopify in User-Agent. No dependency was added.
- App RED: `/tmp/bopify-lyrics-app-red.log` demonstrates that Spotify failure never reached fallback attribution before wiring the resolver. GREEN: `/tmp/bopify-lyrics-app-green.log`, 48 tests in four related app/session/presentation/native-controls suites passed. A further hide-cancellation regression verifies cancellation of an actual in-flight URLSession fixture request. Final app integration suite: 11 tests passed (`/tmp/bopify-lyrics-app-final.log`), including provider attribution, synchronized cue seeking and unchanged playback/session ownership. Preview/test environments remain offline by default unless a resolver is explicitly supplied.
- Source review found no production correctness, security or lifecycle blocker in scope. `git diff --check` passed. No lyrics UI redesign.
- Signed Release 1.6.0 (472) built successfully at `build/lyrics-provider-recovery-test-20261108/Build/Products/Release/Bopify.app`; `codesign --verify --deep --strict` passed. The app was not launched or installed over the running app.
- Live Spotify/native login and live LRCLIB matching remain unverified. No user credentials or live playback/provider requests were used. Spotify's real quota is not bypassed; independent fallback remains available if profile verification or native metadata is unavailable.


## Follow-up: timestamped LRCLIB text and original presentation

User screenshot showed raw LRC timestamps and static plain-text styling. Read-only inspection of the app's lyric cache confirmed one LRCLIB version-1 entry marked unsynced with 28 lines, all carrying valid leading timestamps. No user credentials, live provider requests or playback commands were used; lyric text was not logged.

The provider supplied timing in the plain field, which the resolver treated as unsynced. Its fresh cache then preserved that classification. New regression cases reproduced this for absent/malformed synced fields and for fresh/stale legacy cache entries (`/tmp/bopify-lrclib-timing-red.log`: two parameterized tests, four cases, 12 failing assertions).

The resolver now recovers fully timestamped LRCLIB plain text into the existing line-synced TrackLyrics model at both the response and cache-read boundaries. Cache age and provider attribution are preserved; user cache entries are not deleted or forcibly refreshed. Genuinely untimed content remains plain. Renderer, fonts, colors, layout and interaction source are unchanged.

Review identified that the old LRC parser accepted any letter-led bracket as metadata and could drop ordinary words while coercing mixed content. Two mixed-content cases reproduced this (`/tmp/bopify-lrclib-mixed-timing-red.log`); metadata now requires a recognized colon tag with no trailing sung words. The cases remain unsynced with their complete original text. Focused re-review confirmed the finding resolved.

Verification: all 22 resolver tests passed (`/tmp/bopify-lrclib-timing-final.log`). All 59 tests in four related app/session/reader/presentation suites passed (`/tmp/bopify-lrclib-timing-app.log`); after the final metadata guard, the 11-test app integration suite passed again (`/tmp/bopify-lrclib-timing-app-final.log`). Integration coverage parameterizes the actual LRCLIB response field, verifies current-cue advancement from 1s to 2s, original 14pt secondary previous line /19pt emphasized current line, timestamp-free displayed words, and the original line-seek link. Existing reader checks cover following, manual scrolling, highlight/selection preservation and return-to-live behavior.

Signed Release 1.6.0 (473) built successfully; strict signature verification passed at `build/lyrics-timing-repair-test-20261108/Build/Products/Release/Bopify.app`. No automatic app launch or replacement. Live visual/playback behavior remains for user verification in the new build.


## Open follow-up: fresh Soloist discovery after build 473

User reports Bopify missing from Spotify during fresh pairing. No production source has been changed for this report yet. Read-only process/log evidence identified build 473 running as PID40786. It restored Soloist and created native metadata services successfully at 16:35, then explicit sign-out at 16:36 removed the saved session. Subsequent fresh setups reached waitingForLogin, SDK pairing server/mDNS ready, verified loopback getInfo and Bopify's native Bonjour publication observed by itself. No loginRequested appeared. This does not prove the Spotify client saw or could reach the service.

Builds472/473 have identical bundle identifiers, Local Network purpose, Bonjour service declarations and entitlements. The473 source change affects lyrics parsing/cache normalization and tests, not Soloist launch/pairing/publication. No explicit Local Network denial was found in the scoped diagnostics. The root cause of Spotify not listing a fresh device remains unconfirmed.

The user closed Bopify at16:38; later read-only checks found SpotifyDesktop running but no Bopify/Soloist process or endpoint. Temporary diagnostic Bonjour browsers were stopped. Asked which Spotify client is affected and asked the user to reopen473 at the connection step. Await response/live endpoint before attempting a correction. No credentials/session files were read, reset, or removed; no playback, launch, network configuration or permissions were changed.


User subsequently authorized building and opening the app. Incremental signed build473 succeeded (`/tmp/bopify-build-open-473.log`) and strict signature verification passed. An existing requested-bundle process43815 was stopped (stateT) and absent from LaunchServices; initial open returned-600. Resuming that verified process with SIGCONT and reopening the bundle succeeded; one visible window was confirmed. No process was killed, credentials reset or permissions changed.

Live follow-up: Soloist44664 listens on all IPv4 addresses at56161, awaiting login. Native Bonjour lists `Bopify A15361D8` and Soloist's SDK UUID advertisement on en1. Both resolve to the same pairing server. Read-only getInfo succeeds over loopback, the Mac hostname and the SDK hostname/LAN address; only nonsecret status/name/device-type flags were printed. The SDK TXT includes Stack=SP while Bopify's wrapper has VERSION/CPath; that difference is observed, not yet proven causal. No explicit Spotify LocalNetwork/PolicyDenied log was found. Stop temporary diagnostic browsers before ending the turn. Fresh pairing from Spotify itself remains unverified; keep the user app running for the next check.


## Live discovery check continued

User confirms device remains absent in Spotify. Current live state remains Bopify43815, Soloist44664 at56161, Spotify44699. Window-only screenshot confirms SpotifyDesktop1.2.98.301 has its Connect panel open, displays its own computer and a TV but not Bopify, and is paused at0:02. Bopify/Soloist remain running; no loginRequested or keyRejected.

Both public getInfo forms (with/without version2.10.0) return HTTP200 application/json and the SDK's full field set; only schema/nonsecret booleans were logged. Both ads resolve to the reachable server on en1. Primary Spotify ZeroConf docs and current librespot source do not establish Stack=SP as required; do not speculate that adding it is a fix. Source recon also found Spotifast's stable name vs Bopify's per-controller name, but no demonstrated causal connection. Spotifast's zeroconf.rs is controller-side discovery/credential transfer, not a publisher to copy.

Read-only Spotify AX inspection did not expose its web controls. Automatic approval rejected setting AXManualAccessibility/AXEnhancedUserInterface because it mutates Spotify state; no attributes were changed. Used an authorized window-only screenshot instead. Header-only TCP SYN capture for the owned port was unavailable (OS denied pktap interface creation); no packet capture occurred. No credentials or auth payloads were read. Do not escalate capture or mutate app preferences merely to get diagnostics.

Concrete onboarding issue: pairing copy said `Select this device, then play a song.` Spotifast's Soloist guide instructs playing a song before selecting the device and notes visibility may depend on it. Corrected only that string to `Play a song in Spotify, then choose this device.` The English string catalog parses and diffcheck passes. Build474 succeeded and strict signature verification passed in the existing test-artifact path; no app restart was performed, preserving current pairing state. No unrelated suites ran for this text correction.

Asked user to start playback and reopen Connect, with explicit choices for appeared/still missing. No answer received yet; latest screenshot still shows pause. Root cause and successful fresh Spotify pairing are NOT established. Need the playback/discovery check before changing protocol or auth code.

## Discovery investigation and merge checkpoint

The user subsequently confirmed that playing first did not resolve discovery. A read-only capture of the actual macOS Local Network page showed Spotify and every listed Bopify entry enabled. The earlier Accessibility match for `Bopify.xcodeproj` belonged to Recent Items, not the permission list, and is discarded as evidence. No permissions, credentials, or saved sessions were changed.

Repeated `getInfo` messages were previously deduplicated, so Bopify's own endpoint probe obscured later controller requests. Diagnostics now count those requests without retaining payloads, logging the first sixteen and powers of two through 1024; history remains bounded. The self-check has a separate completion marker. Related diagnostics/process verification passed: 16 tests (`/tmp/bopify-discovery-counter-green.log`). No diagnostic build was launched before the user changed the task to merging into main. Fresh Spotify discovery remains unresolved.

The user explicitly requested a local merge into `main`. Preserve the root checkout's staged AGENTS.md edit and uncommitted record-appearance/font changes; they are separate user work. Keep the Soloist worktree while its test builds are still used for live diagnosis.
