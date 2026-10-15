# Audio output fault recovery verification

Date: 2026-10-11. Worktree: `/Users/leesiongchan/.codex/worktrees/db27/bopify`.
Branch: `codex/audio-output-recovery`, based on `9bb7996`.

## Scope

Rodio asynchronous stream errors now latch an engine-specific atomic flag on both exact and fallback output builders. The callback performs no logging, allocation, networking, or Swift calls. The joined engine runtime observes the flag, including while paused or idle. The terminal reporter checks the same flag before ordinary events, so a fault-generated pause or end event cannot erase the recovery checkpoint.

Faults interrupt output drain and backpressure waits. Faulted writes stop output and return a fixed error, allowing the native player to pause decoding. Faulted start and stop remain successful: a native start error changes state inside a Playing-only poll branch and can reach process exit. Intentional shutdown suppresses write errors and event delivery. The existing joined runtime teardown and bounded, ownership-aware recovery remain in use.

The native changes are stored in `rust/patches/librespot-queue-selection.patch`; the generated checkout is not the deliverable. No dependency versions or release signing settings changed.

## Regression evidence

| Check | Before implementation / mutation | Final result |
| --- | --- | --- |
| Swift decoding of `audioOutputFailed` | Failed decoding | Passed |
| Fault before ordinary pause | Extra ordinary events reached sink | One terminal loss; subsequent events suppressed |
| Fault without player events | No terminal event | Passed, including early fault and teardown |
| Callback and stalled output waits | Callback did not latch; waits did not cancel | Passed for drain and backpressure |
| Faulted write boundary | Failed expected-error assertion | Passed, including quiet intentional shutdown |
| Actual Rodio sink start/write/stop | Unsafe-start mutation failed `sink.start().is_ok()` | Restored implementation passed |
| Swift recovery checkpoint | New reason handled | Playing/paused intent, identity, volume, and frozen checkpoint preserved |

Red evidence: `/private/tmp/bopify-audio-red-swift.log`, `bopify-audio-red-behavior-rust.log`, `bopify-audio-red-playback.log`, `bopify-audio-red-write.log`, and `bopify-audio-red-real-sink.log` under `/private/tmp`.

## Final verification

| Verification | Result | Evidence under `/private/tmp` |
| --- | --- | --- |
| Owned Rust suite, locked/offline | 57 passed | `bopify-audio-final-rust.log` |
| Patched Connect suite | 85 passed | `bopify-audio-final-native.log` |
| Patched playback suite | 7 passed; device test ignored by default | `bopify-audio-final-native.log` |
| Native doctest | 1 passed | `bopify-audio-final-native.log` |
| Explicit real-output sink test | 1 passed | `bopify-audio-final-real-sink.log` |
| Swift suite | 315 tests passed | `bopify-audio-final-swift.log` |
| Owned strict Clippy, all targets/features | Passed without warnings | `bopify-audio-final-owned-clippy.log` |
| Direct native strict Clippy, Connect/playback | Passed without warnings | `bopify-audio-final-native-clippy.log` |
| Fresh indexed native patch replay | 20 files; byte-identical diff; reverse check passed | `bopify-audio-final-patch-replay.log` |
| Native static library / framework | Passed | `bopify-audio-final-staticlib.log`, `bopify-audio-final-framework.log` |
| Debug app build | Passed | `bopify-audio-final-debug-build.log` |
| Development-signed hardened Release build | Passed | `bopify-audio-final-release-build.log` |
| Release signature verification | Deep/strict verification passed | `bopify-audio-final-signature.log` |

Run the device-dependent contract explicitly with:

```sh
CARGO_TARGET_DIR=rust/target cargo test --manifest-path .build/librespot-939dc5e/Cargo.toml --locked --offline -p librespot-playback faulted_sink -- --ignored
```

Independent review found no critical or important functional issues. Its helper-only test concern was addressed by the real sink test and unsafe-start mutation check. Actual source whitespace checks pass; unified-patch context markers are validated through native source checks and exact replay rather than interpreted as source whitespace.

## Limits and remaining gates

The device-dependent test opens a real output stream and injects its fault signal. It does not physically disconnect hardware, drive the complete player poll loop, or prove audible signed-app recovery. No Spotify grant or live session was used. The Release artifact is development signed, not Developer ID signed or notarized. Physical audio-route/disconnect/sleep-wake testing, signed rejected-token and VoiceOver acceptance, OAuth callback and Keychain corrections, AppKit investigation, and public distribution remain separate gates.

API reference: [Rodio 0.21.1 output stream implementation](https://raw.githubusercontent.com/RustAudio/rodio/v0.21.1/src/stream.rs).
