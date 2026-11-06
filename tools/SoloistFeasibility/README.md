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
- A Soloist macOS arm64 executable downloaded by you from [Spotify](https://developer.spotify.com/documentation/soloist/reference/downloads-and-updates). The probe assesses it with Gatekeeper and never clears quarantine, re-signs it, or bypasses a failed check.
- Your own Soloist API key in a regular, user-owned `0600` file, without embedded whitespace. Do not paste the key into commands or chat. The file must already exist; this tool does not write or erase it.
- Your public developer client ID, with `http://127.0.0.1:8898/callback` registered and your account permitted. A running app may already occupy that port; stop it yourself before probing if necessary.

Before opening a browser, the probe compiles the Rust test with Cargo's locked dependencies and discovers its test executable from Cargo's JSON artifact output. It then opens two fresh OAuth grants using existing BopifyAuth primitives: streaming and playback observation/control. Both remain in memory, separate from Bopify's stored credentials. No production Keychain entry is read, modified, or revoked. If either `/me` response lacks immutable `account_id`, the identity gate remains inconclusive; legacy usernames are not substituted.

```sh
swift run --package-path tools/SoloistFeasibility soloist-feasibility \
  --soloist /absolute/path/to/soloist \
  --key-file /absolute/path/to/private-key-file \
  --client-id YOUR_PUBLIC_CLIENT_ID \
  --report /absolute/path/to/new-report.json
```

`--report` is optional. An existing file is never overwritten. JSON on stdout contains fixed verdicts, counts, versions and status codes, excluding account/device IDs, tokens, key material and content. Progress on stderr includes the generated device name so you can select it. Soloist itself requires its key as a child-process argument; private file storage does not hide that argument from local process inspection.

Select the unique `Bopify probe <UUID>` device in Spotify, play a track, and choose the volume there. The probe starts muted and never sends a play/transfer/volume command. It compares fresh Web API and local playback observations and device appearance under its owned process lifecycle. A matching name alone is insufficient. It restarts its own Soloist process once with the same private session directory and requires fresh correlation afterward. You may need to select it and start music again.

Individual operations are bounded to 30 seconds; each sign-in/pairing window is five minutes. Ctrl-C cancels the run and waits for owned-process cleanup. A WebSocket/HTTP failure is incomplete evidence, not proof that the audio stopped. No alternate audio player is launched. Temporary data/cache and authentication directories created by this run are removed after the owned process stops; the selected binary and key file remain untouched.

## Interpreting results

After restart correlation succeeds, the runner starts the compiled Rust test directly through a private stdin pipe. The token is not passed in arguments, environment variables, or files. The test constructs a librespot `Session` with no cache or credential storage and performs existing lyric/radio/artist requests without creating a player, mixer, Spirc, or Connect registration. Only service outcomes and counts cross back through a private result file, removed on completion. This direct child is stopped and joined on cancellation.

Soloist's state, account playback, and device list are observed for at least 30 seconds during these requests. A different owner, lost observation, or new Connect device invalidates the attempt; the probe never takes playback back. Each service must actually return data for `companion` to pass. Missing lyrics or a missing radio mix remain an accurate absent result; choose another suitable track for a later run rather than treating absence as success.

Exit `0` means correlation, restart correlation, and companion state observations all passed. Exit `2` means failed/inconclusive observations, an unavailable service, or invalid input. An HTTP 429 stops the attempt and reports the available retry delay; it is never retried early. Request a new run after the delay. Neither status certifies audible continuity; record that listening observation separately.

The Rust live entry is explicitly ignored during normal tests. To precompile it without signing in:

```sh
cargo test --manifest-path rust/Cargo.toml --locked -p bopify-core --lib \
  soloist_feasibility::live_data_session --no-run
```

Run live through the Swift tool, which manages the private input/output channel. Never put a real token into a shell command or the result file. The Rust test's exit status alone is insufficient: the runner checks the structured service outcomes and concurrent ownership observations.

Even passing observations are experimental correlation evidence, not a cryptographic identity attestation. Record the Soloist version, procedure, actual outcomes and remaining limits in the design before claiming a supported association. Data-only companion coexistence, audible continuity, remote takeover and loss-of-observation cases must also be checked live before planning the shipping feature. No live results have been recorded yet.
