# Soloist feasibility probe

An opt-in developer tool for the first two gates in the [Soloist design](../../docs/superpowers/specs/2026-11-06-soloist-playback-design.md). It is separate from Bopify and does not enable a new playback engine in the app.

## Build and offline checks

From the repository root:

```sh
./scripts/build-rust.sh
swift test --package-path tools/SoloistFeasibility
swift run --package-path tools/SoloistFeasibility soloist-feasibility --help
```

The existing `artifacts/BopifyCoreFFI.xcframework` is required to configure the local BopifyCore dependency. Dependencies follow the existing exact pins. These tests use fixtures and owned short-lived system processes; passing them does not establish live Spotify integration.

## Live prerequisites

- An Apple Silicon Mac running macOS 26 or newer, Spotify Premium, and Spotify on the same network.
- No executable download or path selection is required. The tool automatically downloads the latest macOS arm64 build directly from [Spotify](https://developer.spotify.com/documentation/soloist/reference/downloads-and-updates), validates its Spotify signature, and installs it privately without administrator access.
- Your own Soloist API key in a regular, user-owned `0600` file, without embedded whitespace. Do not paste the key into commands or chat. The file must already exist; this tool does not write or erase it.
- Your public developer client ID, with `http://127.0.0.1:8898/callback` registered and your account permitted. A running app may already occupy that port; stop it yourself before probing if necessary.

Before opening a browser, the probe installs/reuses the signed player and compiles the Rust test with Cargo's locked dependencies. It discovers that test executable from Cargo's JSON artifact output, then opens two fresh OAuth grants using existing BopifyAuth primitives: streaming and playback observation/control. Both remain in memory, separate from Bopify's stored credentials. No production Keychain entry is read, modified, or revoked. If either `/me` response lacks immutable `account_id`, the identity gate remains inconclusive; legacy usernames are not substituted.

```sh
swift run --package-path tools/SoloistFeasibility soloist-feasibility \
  --key-file /absolute/path/to/private-key-file \
  --client-id YOUR_PUBLIC_CLIENT_ID \
  --report /absolute/path/to/new-report.json
```

`--report` is optional. An existing file is never overwritten. JSON on stdout contains fixed verdicts, counts, versions and status codes, excluding account/device IDs, tokens, key material and content. Progress on stderr includes the generated device name so you can select it. Soloist itself requires its key as a child-process argument; private file storage does not hide that argument from local process inspection.

`--soloist PATH` remains an optional developer override; its executable is checked against the same Spotify signing requirement. It is not part of normal setup.

## Automatic installation and updates

To install and validate the official build without a key, OAuth, pairing, or playback:

```sh
swift run --package-path tools/SoloistFeasibility soloist-feasibility --install-only
```

The shared `BopifyPlayback.SoloistInstaller` stores binaries and private current/pending metadata under `~/Library/Application Support/com.leesiongchan.bopify/Soloist`. HTTPS downloads are bounded to 80 MiB, archive expansion to 160 MiB/64 entries. Extraction uses macOS libarchive and rejects traversal, links, special files, duplicates and missing executables. Supplied notices stay with the binary.

Before execution, the installer verifies arm64 Mach-O and the intact Apple-issued signature for Spotify's `com.spotify.soloist`, team `2FNC3A47ZF`, then reads `--version` with a deadline. It never re-signs the binary, clears quarantine, or disables OS policy. App-bundle `spctl` assessment is not used for this standalone command-line program. A local SHA-256 digest detects changes to cached files; it is not a separately published Spotify checksum.

Valid builds are reused between daily checks. A newer build goes into a separate immutable directory. Runtime callers pass `canActivateUpdate: false` while a child owns playback, including a paused queue; the update remains pending. Before launching a stopped child, the caller activates the pending build. The installer itself never stops audio or changes the session-data directory. The full player will own periodic checks when integrated; a command-line invocation checks on startup. Builds expire 90 days after build time; expired/corrupt caches force a fresh download. Failed updates retain a valid installed build and expose the update error.

Concurrent calls coalesce only when activation and forced-check policies agree; otherwise the caller receives `installationBusy` and can retry later. If activation is blocked and no current build remains usable, the installer stages renewal and reports `activationRequired`, preserving the current pointer until the caller explicitly permits activation. Quarantine attributes on the download or retained archive entries propagate to extracted files.

The 2026-11-06 live install-only run downloaded and validated official version `1.3.10.50`; a second run reused it without another download. Playback-account correlation and data coexistence remain unverified.

Select the unique `Bopify probe <UUID>` device in Spotify, play a track, and choose the volume there. The probe starts muted and never sends a play/transfer/volume command. It compares fresh Web API and local playback observations and device appearance under its owned process lifecycle. A matching name alone is insufficient. It restarts its own Soloist process once with the same private session directory and requires fresh correlation afterward. You may need to select it and start music again.

Individual operations are bounded to 30 seconds; each sign-in/pairing window is five minutes. Ctrl-C cancels the run and waits for owned-process cleanup. A WebSocket/HTTP failure is incomplete evidence, not proof that the audio stopped. No alternate audio player is launched. Temporary data/cache and authentication directories created by this run are removed after the owned process stops; the selected binary and key file remain untouched.

## Interpreting results

After restart correlation succeeds, the runner starts the compiled Rust test directly through a private stdin pipe. The token is not passed in arguments, environment variables, or files. The test constructs a librespot `Session` with no cache or credential storage and performs existing lyric/radio/artist requests without creating a player, mixer, Spirc, or Connect registration. Only service outcomes and counts cross back through a private result file, removed on completion. This direct child is stopped and joined on cancellation.

Soloist's state, account playback, and device list are observed for at least 30 seconds and through the entire companion operation, followed by a fresh observation after the child terminates. The WebSocket receiver stays active between queries so queued invalidations are processed promptly rather than acquiring a new read-time timestamp. Once local ownership has been observed, a takeover, re-pairing, lost observation, or new Connect device ends the attempt; the probe never takes playback back. Either side's failure cancels and joins the other. Each service must actually return data for `companion` to pass. Missing lyrics or a missing radio mix remain an accurate absent result; choose another suitable track for a later run rather than treating absence as success.

In normal mode, exit `0` means correlation, restart correlation, and companion state observations all passed. In `--install-only` mode, exit `0` means installation/signature/version checks passed; playback gates stay explicitly unrun. Exit `2` means failed/inconclusive observations, an unavailable service, or invalid input. An HTTP 429 stops playback observations and reports the available retry delay; it is never retried early. Request a new run after the delay. Neither status certifies audible continuity; record that listening observation separately.

The Rust live entry is explicitly ignored during normal tests. To precompile it without signing in:

```sh
cargo test --manifest-path rust/Cargo.toml --locked -p bopify-core --lib \
  soloist_feasibility::live_data_session --no-run
```

Run live through the Swift tool, which manages the private input/output channel. Never put a real token into a shell command or the result file. The Rust test's exit status alone is insufficient: the runner checks the structured service outcomes and concurrent ownership observations.

Even passing observations are experimental correlation evidence, not a cryptographic identity attestation. Record the Soloist version, procedure, actual outcomes and remaining limits in the design before claiming a supported association. Data-only companion coexistence, audible continuity, remote takeover and loss-of-observation cases must also be checked live before planning the shipping feature. No authenticated playback results have been recorded yet.
