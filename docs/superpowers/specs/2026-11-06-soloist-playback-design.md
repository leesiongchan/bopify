# Soloist preferred playback with librespot support

Date: 2026-11-06
Status: Approved by the user on 2026-11-06 for feasibility planning. Live feasibility remains unverified.

## Intent and decisions

Use Soloist whenever possible, with librespot filling gaps. Preserve Bopify's existing player, library, lyrics, queue, shortcuts, and Spotify Connect behavior as far as the selected providers can faithfully support them.

The user selected the recommended hybrid approach: Soloist produces audio and handles its supported controls, librespot supplies missing services and playback fallback, and Spotify's Web API assists controls that can keep audio on Soloist. The user subsequently approved this document and planning its initial feasibility checks. Broader implementation remains gated on the results.

The routing, recovery, installation, and queue policies below are the author's proposed defaults. They must not be represented as separately requested user decisions.

## Goals and boundaries

- Prefer Soloist for playback after setup; existing users continue listening through librespot until Soloist is ready.
- Resolve lyrics, radio, and artist information through librespot without activating a second audio player.
- Retain one stable `PlayerModel`, authoritative observed playback state, saved volume, and media controls across provider changes.
- Recover from sleep, connectivity loss, daemon failure, and expired Soloist builds without stealing playback from another device.
- Keep normal listening independent of provider choices. Explain a fallback or an action that cannot safely be completed.

This is a macOS Apple Silicon feature within Bopify's existing macOS 26 minimum. It does not expand Free-account support, add remote Soloist servers, replace the library Web API, reverse engineer Soloist, or introduce new content types. It does not promise uninterrupted audio across process failures, exact cross-engine queue migration, verified lossless output, or undocumented audio-setting controls.

Failures include two audible engines, lyrics requests changing the active Connect device, fabricated queue identities, silently replacing a queue to make a click work, silently downgrading a still-working Soloist session, and late callbacks overwriting the selected engine's state.

## Current implementation

`PlaybackEngine` is the domain command/event interface. `ManagedPlaybackEngine` adds shutdown. `LibrespotEngine` implements both through Rust FFI. `PlayerModel` already survives engine replacement and guards events with engine epochs.

`AppEnvironment` currently constructs librespot and binds application sign-in to its OAuth credentials. `PlaybackRecoveryCoordinator` always obtains a streaming token before creating an engine, applies a 20-second readiness deadline, and recreates engines after session loss. Soloist cannot be fitted into that lifecycle by pretending its key is a streaming token.

Rust `Engine::new` currently creates the session, mixer, audio player, Connect participant, and startup restoration together. Lyrics, radio, and artist lookups use its `Session`, but obtaining them through today's engine constructor also creates a playback device. The services must be separated before using librespot as a companion.

Queue selection currently addresses an occurrence through engine epoch, queue generation, and an index. Its confirmation depends on that exact occurrence. A URI alone is not an equivalent contract.

Inspection of the pinned librespot fork confirms that `SelectQueue` rejects an inactive local player and `Load` activates its own player. Neither method can silently control Soloist's queue remotely.

## Approaches

| Approach | Tradeoff | Decision |
| --- | --- | --- |
| Hybrid with Web API assistance | Most actions retain Soloist audio; requires playback OAuth scopes and careful provider routing. | Selected after recommendation. |
| Soloist plus librespot only | Fewer control transports; more unsupported actions would need an audio handoff. | Rejected in favor of continuity. |
| Replace librespot entirely | Smaller runtime eventually, but loses existing services and the requested fallback. | Incompatible with the request. |

## Service boundaries

Introduce a small hybrid playback service behind the existing domain interface. Keep provider details out of views. Split missing data services from audio lifecycle rather than forcing every provider to implement unsupported lookups as placeholders.

Responsibilities:

- **Soloist adapter:** owned process, loopback WebSocket, decoded snapshots/events, supported local controls, queue observations, and shutdown.
- **Librespot data session:** independently authenticated session for lyrics, radio, and artist requests. It creates no audio player, mixer, Connect advertisement, or startup restoration. Its failure cannot invalidate healthy Soloist playback.
- **Librespot playback adapter:** existing audio engine, created only when it owns playback or a fallback is being prepared without activation.
- **Web API playback client:** available-device discovery, remote playback observation, targeted context playback, and transfer where supported.
- **Hybrid coordinator:** provider choice, active audio ownership, command serialization, fallback eligibility, state normalization, and epochs. Adapt the existing recovery coordinator to accept provider-specific authentication/startup; do not run competing retry loops for the same failure.

Use Foundation process and WebSocket facilities and existing HTTP/auth infrastructure. No new dependency is proposed. Keep the current pinned librespot fork unless implementation demonstrates a necessary change.

## Routing policy

| Operation | Preferred route | Fallback and constraints |
| --- | --- | --- |
| Resume, pause, next/previous, seek, volume, shuffle, repeat | Active engine; Soloist WebSocket when Soloist owns audio | Retry only with confirmed state; do not switch audio because one control request fails. |
| Start a track or context at its default start | Soloist `play` | Use librespot playback if Soloist is unavailable and fallback is ready. |
| Start an album/playlist at a chosen item or position | Web API explicitly targeting the verified Soloist device | If unavailable before dispatch, start the requested context on librespot when the request itself replaces playback. Preserve exact occurrence when known; never substitute the first URI match for an ambiguous duplicate. |
| Lyrics, radio resolution, artist songs, missing metadata | Librespot data session | Report service-specific failure; keep the current audio running. Play a resolved radio context through the normal playback route. |
| Queue observation | Active provider | Fetch Soloist's full available queue; do not mistake its ten-entry broadcast for the full queue. |
| Select an upcoming queue occurrence | Exact selection supported by the active provider | Apply the queue policy below; unsupported exact selection is not a license to rebuild or skip through the queue. |
| Observe another active device | Web API account playback state | Mirror it without activating a local engine; retain existing librespot mirroring while librespot owns that connection. |
| Play here | Verified transfer/activation to the preferred ready engine | Require observed local ownership before reporting success; do not issue a new track load merely to claim the device. |

Supplement the existing library consent with `user-read-playback-state` and `user-modify-playback-state`. Preserve the registered redirect URI and client ID. Existing credentials without these scopes remain valid for their existing uses; request extra consent when enabling hybrid playback. Declining it leaves setup incomplete and preserves existing librespot playback. Do not enable an unverified mix of Soloist audio and another account's companion services. Soloist-only operation without these scopes is outside this initial design.

Discover and retain the actual Soloist Connect device ID through authenticated device discovery. Never identify it by display name alone or send a targeted command with `device_id` omitted. When identity cannot be established, the assisted route is unavailable.

Ensure the Soloist pairing, data-session credentials, and Web API credentials refer to the same account before combining their state. The WebSocket `auth_state` does not itself expose a user ID. Establishing a supported, reliable account/device correlation is the first feasibility milestone, before planning or building the rest of the feature. Investigate the owned process's pairing lifecycle against authenticated Web API device/playback observations, and compare the two OAuth account identities. A display-name match or user confirmation alone is insufficient proof. If this milestone cannot establish correlation, hybrid mode stays disabled and the design must be revised; do not mix private data, send assisted commands, or substitute an undocumented session-file parser.

## Queue correctness

Soloist queue UIDs are optional and may fall back to URI. Keep a local generation and assign observation-scoped occurrence IDs for rendering, including repeated URIs. These IDs must not be represented as remotely selectable UIDs.

Only expose a selectable target when the provider can address that exact occurrence under the observed generation. Web API album/playlist offsets can serve an explicit context-load request whose context index is known; they do not generally select an occurrence in a mixed manual/autoplay queue.

On librespot, retain current exact queue selection. On Soloist, refresh the queue and reject stale or unsupported exact selection with an actionable explanation; retain basic next/previous. Do not issue repeated skips, restart a track by URI, or switch engines and reconstruct a guessed queue. If parity cannot be demonstrated, the interface must explain that exact queue selection currently requires librespot and offer an explicit switch for subsequent playback. That switch does not pretend to migrate the existing queue.

This is a deliberate initial limitation. Unsupported behavior must be visible in the design approval and release documentation. A later verified targeted Connect implementation may remove it, but is not assumed here.

## Audio ownership, fallback, and recovery

Maintain these states: preparing Soloist, Soloist ready, Soloist active, recovering Soloist control, librespot active, remote active, and stopped. Readiness, authentication, and active-device ownership are separate facts.

- On launch, prefer configured Soloist. Otherwise keep the current librespot experience and expose optional setup.
- A WebSocket disconnect first reconnects to the existing process and requests fresh auth, playback, and queue snapshots. Audio may still be playing. Do not launch librespot immediately.
- Missing/expired binaries, invalid configuration, or confirmed process death may trigger librespot fallback. Reuse existing bounded recovery timing; distinguish unrecoverable setup from transient network failure.
- Before any automatic local takeover, obtain fresh account ownership state and verify the former owner is Bopify's local device. If another device owns playback or ownership is unknown, remain inactive and offer Play here. An explicit local load/Play here supplies the user's takeover intent.
- For a confirmed dead local engine, restore the current item/context, observed playing intent, estimated position, volume, shuffle, and repeat only where representable. Do not silently claim to restore manual queue entries, history, or shuffle order that the destination cannot reproduce. If continuing requires discarding known queue edits, stop and present an explicit continuation action describing the loss.
- Before changing audio owner, stop/deactivate the outgoing owned player and confirm it cannot emit audio; then activate the destination. Teardown failure blocks activation until resolved. Shut down only processes Bopify owns.
- An accepted command or HTTP success is not playback confirmation. Confirm through authoritative observations. On an ambiguous timeout, refresh state before deciding whether to retry; never replay next/previous, queue additions, or a load on another engine blindly.
- Web API rate limits honor `Retry-After`; a `429`, denied scope, or data-service error does not cause an audio handoff.
- Once automatic fallback is active, return to Soloist on the next explicit new playback load, Play here/retry, or next app launch after Soloist is ready. An explicit Use librespot for this session action holds that choice until Retry Soloist or next launch. Do not automatically switch mid-track or at an unrequested track boundary.

Retain the stable player, record/artwork, Now Playing integration, and visible connection feedback throughout. Normalize Soloist's 0–100 volume to the domain's 0–1 scale and preserve saved mute/volume before activation. Keep repeat's two Soloist flags mutually consistent. Use position timestamps and playback speed for local interpolation, and stop advancing a stale disconnected clock.

## Installation, credentials, and lifecycle

Spotify's documentation says each user supplies their own key and the binary must not be redistributed. Initial implementation opens Spotify's official download page and imports the user's downloaded macOS executable/archive through Bopify. It does not bundle, mirror, silently download, or re-sign Soloist. This guided import is the author's conservative distribution choice; fully automatic installation requires a clarified supported distribution path.

Validate the selected artifact before execution: regular executable, Mach-O arm64, expected archive structure, bounded extraction, and platform signature/Gatekeeper checks. Do not clear quarantine, use shell execution, or bypass a failed trust check. Record version/build timestamp from a bounded `--version` process. If metadata is missing/unparseable, treat freshness as unknown and use the setup/update path rather than guessing. Stage replacements without overwriting the running executable; retain the previously working artifact until the replacement passes startup checks.

Store the API key in a dedicated Keychain namespace. Pass it directly to the child at runtime, with arguments and child logs redacted. The documented CLI requires an API-key argument; Keychain storage does not eliminate local process-argument exposure. Do not claim otherwise.

Use private Bopify-specific persistent data and bounded cache directories. Keep Soloist identity/session data across ordinary restarts and application updates. Launch only one child per data directory, bind `127.0.0.1:0`, and discover the actual endpoint from its runtime files. Validate loopback address, port, and owned-process lifecycle before connecting. A random port provides collision avoidance, not client authentication; Soloist's API has no built-in client authentication or Origin protection.

First pairing uses Spotify's app on the same local network; show progress from `auth_state` and complete only when paired and usable. The user does not have to keep Spotify open afterward. Existing sign-in/library behavior stays usable if setup is canceled.

Check build freshness on launch and no more than daily using local version metadata. Warn seven days before the documented 90-day expiry and link the official update page; do not interrupt healthy playback to replace a build. Exit code 10 offers update/import and librespot fallback. Do not promise unattended updates in this version.

Sign-out stops owned audio and background tasks, cancels in-flight requests, clears OAuth and the Soloist Keychain key, and removes Bopify-owned stored Soloist authentication/device data so a later launch cannot silently restore the old account. Extend the persisted logout-intent cleanup mechanism to cover those resources; fail visibly if cleanup is incomplete. Preserve imported binaries. Quit stops owned processes without erasing credentials. Sleep/wake and output-device changes are verified on Core Audio rather than inferred from Linux behavior.

## Verification and feasibility gates

The first implementation plan is limited to proving account/device correlation and a data-only companion alongside real Soloist on an Apple Silicon Mac. Approval of this design permits planning those feasibility checks; it does not establish that they have passed. Plan the remaining implementation only after both checks pass. The supported correlation mechanism and observed evidence must be added to this document before it is treated as a settled implementation contract. If either check fails, return with the findings and revise the design before proceeding.

The complete acceptance checks are:

1. A data-only librespot session can fetch lyrics/radio/artist data while Soloist plays, without advertising or stealing playback.
2. The intended account and Soloist device can be correlated, targeted Web API context/offset/position commands work, and Play here preserves expected playback intent.
3. Snapshot/event ordering, duplicate queue rendering, active-device changes, output switching, sleep/wake, socket loss with continuing audio, process death, invalid key, and expired-build handling behave as designed.
4. Automatic fallback never starts audio over a remote owner or a still-audible local process. Unsupported queue transfers are disclosed and require the explicit continuation described above.

### Feasibility progress, 2026-11-06

The separate developer probe is implemented under `tools/SoloistFeasibility`. Its offline Swift boundary tests, the Rust data-session boundary tests, the existing native Clippy/test script, and the native framework rebuild pass. The only shared Rust source change registers a test-only module; the shipping playback engine, FFI, dependency pins and app authorization remain unchanged.

Both live feasibility gates remain **unverified**. No Soloist binary was downloaded or executed, no production credentials were read, and no Spotify sign-in/pairing or real data lookup was attempted. Live execution requires the user's selected Soloist executable path, a private key-file path, their public developer client ID, and interactive pairing. Broader engine implementation remains gated.

The account probe uses the current `/me.account_id` field for OAuth account linkage; it does not substitute usernames or `/me.id`. Process/device association is still an experimental hypothesis based on fresh owned-process lifecycle and simultaneous playback observations. Actual live results must establish or reject it before it becomes the product's identity contract.

For cancellation safety, the runner compiles the Rust test before sign-in, discovers the locked test artifact from Cargo's JSON output, and then runs that test executable directly with a private stdin pipe. This replaces the plan's initial Cargo-child invocation; it gives cleanup direct ownership of the authenticated process. Reports distinguish absent services, failures and unrun gates from actual retrievals. State observations do not certify audible continuity.

Independent review identified and regression coverage now checks restart directory reuse, monitoring through the companion's full lifetime with a final observation, prompt sibling cancellation, terminal ownership/authentication changes after selection, and continuously received WebSocket state. The corrected probe has 35 passing offline Swift tests. One minor reporting distinction remains: the CLI labels an account mismatch inconclusive even though it rejects the mismatch; the pure evaluator labels it failed. This does not permit mixed-account requests.

Use the user's own installed binary and authorized interactive account setup for live checks. Do not read stored credentials opportunistically, embed a key, download or run a binary for a design-only exercise, or use mocked results as evidence of live integration. If a gate fails, revise the design before claiming parity; do not add an unverified fallback.

Add meaningful regression coverage for routing, isolated provider failures, command confirmation/ambiguity, stale epochs, queue duplicates, exact-selection rejection, permission migration, lifecycle cancellation, ownership races, secret redaction, artifact validation, logout cleanup, and volume/repeat conversion. Verify native setup/player behavior through app tests and before/after native screenshots, including keyboard access; this is a native app, not a browser UI.

Implementation checks follow CI: `./scripts/test-native.sh`, `./scripts/build-rust.sh`, `swift test --package-path Packages/BopifyCore`, and the `BopifyAppTests` Xcode scheme on macOS arm64. Run formatting checks appropriate to changed files. Record live build/version and actual outcomes separately from automated checks.

## Builder discretion

The builder may choose internal type/file names, test fixtures, small protocol extractions, and diagnostic wording following repository conventions. Provider routing, queue limitations, distribution policy, ownership rules, account isolation, and fallback interruption behavior are requirements of this proposed design, not open implementation choices. No product code, dependency installation, or prototype has been authorized by approval of the approach alone.

## Builder review

A fresh native macOS/Rust reviewer identified two consequential questions. The session-only librespot override now resolves fallback preference duration. Account/device identity remains an explicitly unproven technical prerequisite, so the initial plan is limited to proving it and companion-session coexistence; declining the necessary consent retains librespot rather than enabling a partial unverified hybrid. No live feasibility checks have run.

## Research basis

Official sources reviewed 2026-11-06. Documented-surface gaps are not proof that an internal capability is impossible.

- [Soloist overview](https://developer.spotify.com/documentation/soloist): supported desktop platform, per-user key, redistribution restriction, and build lifetime.
- [Downloads and updates](https://developer.spotify.com/documentation/soloist/reference/downloads-and-updates): macOS arm64 archive, build identification, and replacement procedure.
- [Authentication](https://developer.spotify.com/documentation/soloist/concepts/authentication): separate API key and Connect session, initial pairing, persistent session.
- [Command line](https://developer.spotify.com/documentation/soloist/reference/command-line): Core Audio, storage, loopback dynamic port, startup volume, and exit codes. A running process may lack a working WebSocket listener.
- [WebSocket API](https://developer.spotify.com/documentation/soloist/reference/websocket-api): auth/snapshot events, asynchronous command dispatch, queue UID limitations, queue broadcast limits, commands, and local API security omissions. No documented exact queue selection, context offset, lyrics/radio/artist endpoints, or quality-setting controls.
- [Basic integration](https://developer.spotify.com/documentation/soloist/howtos/basic-integration): snapshot/event observation and position interpolation.
- [Soloist repository](https://github.com/spotify/soloist): advertised lossless, mixing, and normalization capabilities; these do not establish configurable or delivered audio quality in Bopify.
- [Start/Resume Playback](https://developer.spotify.com/documentation/web-api/reference/start-a-users-playback): explicit device targeting, album/playlist offset, position, Premium requirement, and playback scope.
- [Transfer Playback](https://developer.spotify.com/documentation/web-api/reference/transfer-a-users-playback): target device and playing-intent behavior; ordering with other Player endpoints is not guaranteed.
- [Available Devices](https://developer.spotify.com/documentation/web-api/reference/get-a-users-available-devices) and [User's Queue](https://developer.spotify.com/documentation/web-api/reference/get-queue): device discovery and the absence of a remotely addressable queue-occurrence identifier in Web API queue entries.
- [Pinned librespot Connect implementation](https://github.com/leesiongchan/librespot/blob/80f49d50bf46ac454255f02c2fe0ed46ddf01fa6/connect/src/spirc.rs#L1008): current queue selection and context loading operate on librespot's own player.
