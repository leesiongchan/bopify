# Record scale, breathing Aurora, and missing-device follow-up

User request: keep later setup steps visually full, add a breathing background, and investigate why Spotify still cannot see the device. Preserve the original design, show a demo before visual edits, run only related tests, and do not relaunch an existing player automatically.

## Preview and implementation

Preview shown before app edits: `build/onboarding-breathing-demo/index.html`, with previous-version comparison and Reduce Motion. The original welcome record scale is retained through library authorization, playback preparation, pairing, and completion. The form continues to scroll in smaller windows. Changing form density or adding filler would change the approved design, so those alternatives were excluded.

The Aurora has an eight-second background-only breath: 0–3.5% expansion and 90–100% opacity, retaining existing independent color drift. Foreground content stays still. Reduce Motion and hidden presentation stop breathing; solid accessibility surfaces remain solid. This is a small refinement of the existing design, not a new onboarding composition.

## Discovery evidence

Read-only inspection of the running signed app found Soloist listening on IPv4 wildcard for pairing HTTP and loopback for its WebSocket. Native Bonjour publication succeeded. A separate dns-sd browse resolved the Bopify service, correct `/zc` TXT path and port, and the Mac hostname's LAN IPv4 plus IPv6 addresses. Categorized logs contained the app's validation getInfo, but no subsequent Spotify login request. This proves local registration and listening, not Spotify client reachability.

Later inspection found neither Bopify nor Soloist running, so the endpoint could no longer be probed. Do not attribute that observed exit solely to the code timeout: the entire app had also exited. macOS firewall is disabled. Spotify's own Local Network permission is unverified. The user was asked whether the device menu was on this Mac or another device, and to keep Bopify on its pairing step for a live check. No keys, stored sessions, process arguments, or account tokens were read; no playback or transfer commands were issued.

Two independent production defects were reproduced and fixed:

- Healthy pairing was arbitrarily limited to 300 seconds. It now stays available until successful pairing, cancellation, or actual process/discovery failure. The existing ten-second missing-server deadline remains.
- Production relied only on unsolicited initial auth state before publishing, unlike the runtime check. Each new socket now queries `get_auth_state` once. Send failures use existing connection recovery. There is no periodic auth polling and no relaxation of account proof or auth-revision invalidation.

## Primary references

- [Spotifast managed Soloist lifecycle](https://github.com/crmne/spotifast/blob/58ec45608a5a2bb7f18c08afd63e4b931d2f6ba0/src/soloist/mod.rs): same SDK process arguments, initial authentication query, indefinite user-driven first pairing. It does not provision Soloist with librespot credentials or login5 tokens.
- [Spotifast pairing UI](https://github.com/crmne/spotifast/blob/58ec45608a5a2bb7f18c08afd63e4b931d2f6ba0/src/ui/soloist.rs#L542): first pairing still requires selecting the device in Spotify on the same network.
- [Apple Local Network access](https://support.apple.com/en-sg/guide/mac-help/mchla4f49138/27/mac/27): each application's access is separately controlled under Privacy & Security.
- [Spotify Connect support](https://support.spotify.com/no-en/article/spotify-connect/): initial same-network discovery and Spotify app Local Network access are relevant to visibility.

## Verification

- The record-size regression failed for all eight later setup states before the fix.
- Pairing regressions failed for elapsed301s waiting/cancellation/process failure and bootstrap-driven publication before the fixes.
- **30 tests in five affected app suites passed**: record sizing, native layouts/input/accessibility, startup shell, window anchor and native handoff. Log: `/tmp/bopify-size-breathing-green.log`.
- **27 Soloist engine tests passed**, including lifetime, cancellation, child exit, publication, auth bootstrap and account/companion proof coverage. Log: `/tmp/bopify-pairing-final.log`.
- Native captures: `build/test-artifacts/onboarding-composited/353D8A38-18C4-4753-AD19-5C1A2071BEC8/key-entry.png` and `193594A0-26CE-48A7-B967-EEC8804BF930/{completion,handoff,player}.png`.
- Browser preview: record bounds remain unchanged between breath trough and peak; breathing reaches scale1.035 / opacity1 at half-cycle, and both breath/drift animations are absent with Reduce Motion. The key field fits the 380px viewport horizontally.
- No full app/package/Rust suite ran. Live Spotify visibility/pairing remains unverified and is not claimed fixed by these fixture tests.

Signed arm64 Release build succeeded and strict deep signature verification passed. Artifact: `build/onboarding-breathing-release-20261107/Build/Products/Release/Bopify.app`. Build log: `/tmp/bopify-breathing-release.log`. The app was not launched automatically; the original test build remains intact. Live device visibility still requires a running setup and the user’s Spotify-client/permission check.
