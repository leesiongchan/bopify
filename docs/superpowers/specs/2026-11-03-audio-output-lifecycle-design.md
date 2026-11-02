# Audio output lifecycle

Status: design approved by the user on 2026-11-03; awaiting review of this written spec. Fourth of four reliability specs. It reuses `playbackNotice` from `2026-11-03-refused-audio-keys-design.md`.

## Intent and scope

A paused Bopify holds no audio device, and audio follows the macOS default output. A missing, unplugged or stalled device recovers without a Spotify re-login, and never panics the player.

Verified causes, in the fork's rodio backend and its locked dependencies (rodio 0.21.1, cpal 0.16.0):

- **The device opens at login and never pauses.** The player calls `sink_builder()` when its thread starts, during engine creation. rodio's `OutputStream::open` starts the cpal stream and offers no way to pause it, and the fork's `stop` pauses only the rodio `Sink`. So the CoreAudio I/O callback runs from login until quit, including while paused or while only mirroring another device.
- **The stream never follows the default device.** cpal 0.16 pins the resolved device ID at open, and on macOS it registers no disconnect listener for default devices. The fork's error signal therefore never fires on an unplug or a default change.
- **Waits are unbounded.** The fork's `wait_for_output` has no deadline. If the I/O callback stops pulling without an error, `write` back-pressure and `stop`'s drain spin forever and the player thread wedges. This is inferred from the code.
- **Open failures panic.** `create_sink(...).unwrap()` panics the player thread when no output opens. The event channel then closes, which is misreported as `PlayerChannelClosed` and triggers engine rebuilds.
- **Any cpal error escalates.** Any cpal error sets `output_failed`. `supervise_audio_output` turns it into `SessionLost{AudioOutputFailed}` within 50 ms, and Swift then rebuilds the whole engine, even though the Spotify session is healthy.

librespot's sink contract: `start` and `stop` must never return an error (`stop` errors call `exit(1)`). A `write` error pauses the player cleanly and emits `Paused`.

Out of scope:
- discarding stale buffered audio on seek or skip (needs a player hook);
- volume ramps and the Cubic volume curve;
- an audio cache;
- an `NSProcessInfo` activity, to be added later only if the manual pmset/App Nap checks show a problem;
- reverting the fork's now-unused rodio patch.

## Approaches

**Recommended:** a Bopify-owned `Sink` in bopify-core, handed to librespot's `Player` through the existing `sink_builder` closure. This is the pattern Spotifast uses. It keeps the fork near upstream, and puts the macOS-specific device handling where it belongs. It can be fully unit-tested behind a fake device opener.

Rejected alternatives:
- **Patching the fork's rodio backend in place:** it grows the fork diff in a file upstream changes, rodio 0.21 cannot pause its stream, and macOS listeners do not fit a cross-platform backend.
- **A native CoreAudio backend:** duplicates format and resampling work.
- **Adopting fastframe-audio:** it requires crmne's cpal 0.18 fork, a second cpal beside the locked 0.16.

## `OutputSink` (bopify-core, new `output` module)

- **Contract.** Implements `librespot_playback::audio_backend::Sink`. `start` and `stop` are infallible. `write` returns an error only when no output can be opened.
- **Stream.** Owns a cpal output stream at 44.1 kHz stereo f32 (CoreAudio's output unit converts), feeding a `rodio::mixer::mixer` and a `rodio::Sink`. Device opening goes through an injectable opener so tests need no hardware.
- **Dependencies.** Direct bopify-core dependencies pinned to versions already locked: `rodio = "=0.21.1"`, `cpal = "=0.16.0"`, `objc2-core-audio = "=0.3.2"` with `AudioHardware`. The plan verifies the lockfile gains no packages. Drop `librespot-playback`'s `rodio-backend` feature.

Lifecycle:

- **Open lazily** on the first `start` or `write`.
- **`stop`:**
  1. Drain queued audio for at most 2 s.
  2. Pause the rodio sink.
  3. `stream.pause()`, which stops the I/O callback.
- **`start`:** resumes with `stream.play()`.
- **Release after 5 minutes paused,** dropping the stream. The next `start` reopens.
- **Maintenance worker.** A small sink-owned worker handles changes that arrive while librespot makes no calls: it releases the stream when the timer expires, and when the default device changes while paused. The plan chooses between a dedicated thread and a runtime task, based on whether cpal's macOS `Stream` is `Send`. `start`, `stop`, `write` and the worker serialize their access to the device state.
- **Follow the default device:**
  - A CoreAudio property listener on `kAudioHardwarePropertyDefaultOutputDevice`, using the C-callback `AudioObjectAddPropertyListener` (no block or dispatch dependencies), sets an atomic flag.
  - While playing, the next `write` or `start` reopens on the new default. While paused, the stream is released instead.
  - The listener is removed when the sink drops.
- **Stall watchdog:**
  - While running, the stream callback advances a frame counter. If it has not moved for 2 s when `write` checks, reopen.
  - A gap of 2 s or more between checks counts as sleep and resets the timer.
- **Reopen safely:**
  1. Drop the old rodio `Sink` and stream.
  2. Open the new stream.
  3. Connect a fresh `Sink`.

  Never append to or clear a rodio `Sink` whose stream is gone or paused: rodio's `append` and `clear` block on its queue with no timeout.
- **Bounded waits.** Back-pressure waits in `write` are bounded, and each loop runs the device checks above.

## Engine and Swift

- **Remove the escalation path.** Delete the coupling that turns output errors into session loss:
  - `supervise_audio_output`;
  - the `output_failed` flag and its `EngineReporter` handling;
  - `SessionLossReason::AudioOutputFailed`.

  Remove the reason from Rust, `contracts/session-loss-reasons.json` and the Swift enum together.
- **Report output health without fatal events.** The sink reports to the engine's event sink with two new events:
  - `{"type":"outputUnavailable"}` when an open fails;
  - `{"type":"outputRestored"}` when a later open succeeds.
- **Show the notice.** Swift shows "No audio output available" through `playbackNotice`, which clears on `.playing`.
- **Keep the session.** The Spotify session and Connect presence stay up, and the next Play retries the open.

## Verification

Tests are written first, using the fake opener and an injected clock:

- `start` and `stop` never fail.
- The device opens lazily, exactly once.
- `stop` pauses the stream once, with a drain bounded at 2 s.
- The stream is released after 5 minutes paused, and reopened by `start`.
- A default-device change reopens while playing and releases while paused.
- A stall reopens, and a sleep-sized gap does not.
- A failed open makes `write` return an error without panicking, emits `outputUnavailable` once, and emits `outputRestored` on recovery.
- No append reaches an orphaned rodio sink.
- The contract tests cover the loss-reason list without `audioOutputFailed`, and the new event decoding in Swift.

Run `scripts/test-native.sh`, the Swift package tests, the app tests, clippy and a Release build.

Manual hardware checks, run by the user in the real app:
- Switch to and from AirPods, while playing and while paused.
- Unplug an HDMI or USB DAC that is the default output.
- Sleep and wake, while playing and while paused.
- `sudo killall coreaudiod`.
- While paused: `pmset -g assertions` shows no audio assertion from Bopify, and Activity Monitor shows Bopify idle.

## Research

- cpal 0.16.0 `host/coreaudio/macos/mod.rs`: the disconnect listener is added only `if !self.is_default`, and the stream pins `kAudioOutputUnitProperty_CurrentDevice`.
- rodio 0.21.1 `stream.rs`: `OutputStream::open` calls `stream.play()`, and there is no pause API.
- Spotifast v0.16.0 ([crmne/spotifast@3767d53](https://github.com/crmne/spotifast/tree/3767d53)) `src/sink.rs` and fastframe-audio v0.15.4 ([crmne/fastframe](https://github.com/crmne/fastframe/tree/v0.15.4)) are the reference for:
  - lazy open;
  - pause on stop and release after 5 minutes;
  - 2 s default-device and stall checks;
  - no-device handling (`starting_without_a_device_is_an_error_not_a_panic`).

  fastframe's README cites about 1 % of a core for an unpaused output on a Mac.
