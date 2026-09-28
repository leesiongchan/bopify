# Paused startup restore verification

Checked 2026-09-26 on macOS 27 / Xcode 27 against the user's own Spotify account and iPhone. Branch `feat/startup-restore` at `a652a8a`. Spec: [2026-09-26-startup-restore-design.md](../specs/2026-09-26-startup-restore-design.md).

## Build

```sh
./scripts/build-rust.sh
xcodebuild -project Bopify/Bopify.xcodeproj -scheme Bopify -destination 'platform=macOS,arch=arm64' -derivedDataPath /private/tmp/bopify-startup-restore build
/usr/bin/log stream --style compact --level debug --predicate 'subsystem == "my.snsoft.bopify"'
```

The app was launched from `/private/tmp/bopify-startup-restore/Build/Products/Debug/Bopify.app`, with one instance at a time. At `a652a8a`: bopify-core 29 tests, librespot-connect 23 + 1 doc test, Swift package 110 tests, app build succeeded.

From the second restore run onward, the app used a diagnostic build. That build's only change was a local, uncommitted edit to `logging.rs`: librespot logged at `Debug`, in a public category, so its cluster updates could be read. That edit was reverted before this commit (`git status` clean). The artifacts and app were rebuilt from `a652a8a`.

## Scenarios

Times are local. Track titles and device IDs are left out on purpose; the user confirmed each track on screen.

| # | Setup | Expected | Observed | User confirmation | Result |
| --- | --- | --- | --- | --- | --- |
| 4 | Phone playing, then launch | `outcome=remote`, "Playing on <phone>", phone keeps playing | 21:51:57.409 connect, .704 `startup resolved outcome=remote`; no load or phase change, no device name in the log | Panel named the phone; phone never paused | Pass |
| 1 | Phone paused, Spotify closed everywhere, then launch | `outcome=restored`, `loading → paused`, right track, position and Up Next | Run 1, 21:54:47: `outcome=restored`, `idle → loading → paused` in ~1 s. At 21:55:31 a cluster update made Bopify inactive (`Stopped`, `paused → idle`), so Play did nothing and Up Next was empty; see Deviations. Run 2, 22:10:08: `outcome=restored`, `Load(…, false, 197748)`, Liked Songs context (342 tracks), `EmitSetQueueEvent(2, …, 80, 2)` 0.4 s later, `loading → paused` at 22:10:09.994. No cluster update for 105 s. When the phone app was opened at 22:12:37, two cluster updates (`DEVICE_NEW_CONNECTION`, `DEVICE_STATE_CHANGED`) kept Bopify as the active device | Run 1: right track and position, no paste view. Run 2: phone showed "listening on Bopify"; Play and Pause worked; Up Next listed tracks | Pass (run 2) |
| 6 | Watch the panel during launch in scenario 1 | Loading disc, then the track; never the "Nothing playing" paste view | As scenario 1 | "yes" | Pass |
| 5 | Play 26 s, pause at 3:43, Quit from the menu, relaunch | `outcome=restored` at the same position, paused | 22:16:48 `outcome=restored`, `Load(…, false, 224150)` = 3:44.1, queue 80, `loading → paused` in 0.7 s | Same track, paused at 3:43–3:44 | Pass |
| 2 | Play about 25 s, `kill -9` at 22:18:14, relaunch right away | `outcome=restored`, paused, at or before the last reported position; not `outcome=remote` naming Bopify | The first track ended at 22:18:11.8 and the next Liked Songs track started, so the kill came about 2.2 s into it. 22:18:23 `outcome=restored`, `Load(<next track>, false, 214)`, i.e. its last reported position, paused; queue 80. No `outcome=remote` | Next track, paused near 0:00 | Pass |
| 3 | Throwaway first line `return self.load_liked_songs().await;` in `resolve_startup`, built without the prepare check | `outcome=likedSongs`, `loading → paused`, a Liked Songs track | 22:20:22 collection resolved (342 tracks), `EmitSetQueueEvent(1, …collection, 80, 0)`, `Load(…, false, 0)`, 22:20:23.067 `outcome=likedSongs`, `loading → paused` at 23.420 | A Liked Songs track, paused at 0:00 | Pass |

The scenario 3 edit was removed by hand, not with `git checkout`. After that, `prepare-librespot.sh` printed `Pinned librespot queue patch verified.`, and `build-rust.sh` and the app build were run again.

## Recheck after the final-review fix

`b084c8e` makes `resolve_startup` report `restored` only when the transfer ended in a paused load, and otherwise falls back to Liked Songs. The app was rebuilt with that change, with no diagnostic logging, and relaunched on a last session left by Bopify itself (a Liked Songs track, paused at 0:00). At 22:53:02 `connect succeeded`, 0.46 s later `startup resolved outcome=restored`, then `idle → loading → paused` at 22:53:03.540. The user confirmed the same track, paused. Pass.

## Preview renders

[Loading](assets/startup-loading.png), [another device playing](assets/startup-remote.png), [last resort paste view](assets/startup-last-resort.png), [control: playing](assets/startup-control-playing.png). Rendered with Xcode's RenderPreview from this worktree's project. The control differs from the older `expanded-final.png` because of `2016578` (two-ring glass player), which predates this branch.

## Deviations and observed risks

- **The phone took the session back in restore run 1.** About 45 s after the restore, the user opened Spotify on the phone. The phone then showed its own track instead of "listening on Bopify", and a cluster update deactivated Bopify. Run 2 used the same code (the diagnostic build changes logging only), and opening the phone app there left Bopify active. So this is phone-side behaviour, and run 1's logs (librespot lines redacted) can't show why. The likeliest cause, unconfirmed, is that the phone app had only been backgrounded rather than fully closed, and reclaimed its session when brought to the front. After such a takeover, Bopify keeps showing the track while Play and every other control are no-ops (`PlayerModel.togglePlayPause` is gated on `isActiveDevice`). That frozen inactive state predates this branch and is phase 2 scope. Run 1's empty Up Next was first opened at 21:56:13, after the deactivation; run 2 shows the queue filling within 0.4 s of a restore.
- **The device ID is random on every launch.** `SessionConfig::default()` (engine.rs) generates a new ID each time, which predates this branch. A killed instance therefore never matches the new instance's ID. If the server still lists it as active with a track, the startup decision reports `remote` naming "Bopify" (the spec's ghost-instance risk). Scenario 2 relaunched 9 s after the kill and didn't hit this, so the server had already dropped the killed device. Longer or different timings were not tried.
- **One harmless librespot warning per restore:** "couldn't load context info because: context is not available. type: Default". It's logged before the context resolves, and the context then resolves normally.

## Limits

Not exercised: a session old enough that Spotify no longer returns `transfer_data`; a Liked Songs library that is actually empty; a whole context that can't play (`Unavailable`/`Stopped`, still dropped by the event translation); a network failure during startup. A real Nothing outcome was never reached, so the paste view was only checked in preview.

## Phase 2: mirror and play here (2026-09-27)

Checked 2026-09-27 to 2026-09-28 against the user's own Spotify account and iPhone. Branch `feat/remote-mirror`, first at `8febc7b`, then at `26f26b3` after two fixes found in this run (see Deviations).

```sh
./scripts/build-rust.sh
xcodebuild -quiet -project Bopify/Bopify.xcodeproj -scheme Bopify -destination 'platform=macOS,arch=arm64' -derivedDataPath /private/tmp/bopify-mirror-build build
/usr/bin/log stream --style compact --level debug --predicate 'subsystem == "my.snsoft.bopify"' > /private/tmp/bopify-mirror.log
```

The run used a diagnostic build. The only change was the same local, uncommitted `logging.rs` edit as in phase 1: librespot logged at `Debug`, in a public category, so dealer and transfer lines were visible. That edit was reverted by hand before this commit (`git status` clean), and the library and app were rebuilt without it. The app was launched from `/private/tmp/bopify-mirror-build/Build/Products/Debug/Bopify.app`, one instance at a time, and quit through AppleScript between launches. Times are local. Device names, device IDs and track titles are left out on purpose.

| # | Setup | Expected | Observed | User confirmation | Result |
| --- | --- | --- | --- | --- | --- |
| 1 | Phone playing, then launch; then skip on the phone | `outcome=remote`; the mirror follows the skip; the phone keeps playing | 23:53:12.953 `outcome=remote`, mirror in Swift 66 ms later. Skip: cluster update 23:54:36.773, mirror 101 ms later | Phone's track, "Playing on <device>", moving ring, time within about 1 s of the phone, only Play usable, no heart, no rim; the mirror followed | Pass |
| 2 | Click Play on a playing mirror | `loading → playing`, the phone stops, same track at about the same position | 23:55:55.906 `play here: decision=remote`; the server's transfer arrived 96 ms after the request; `idle → loading → playing` 0.5 s after the press; `update position to 0:00` | Same track, almost immediately, player stayed open; **position reset to 0:00** | Fail, fixed (see Deviations) |
| 2 | After a pause and resume on the phone, double-click Play | One takeover, no restart | One `command enqueued command=playHere`; transfer +66 ms; `Load(…, true, 68188)`, i.e. 1:08 kept. The second click came after `loading` (175 ms), which disables Play | No restart or jump, the phone stopped | Pass |
| 2 | Pause the phone, then click Play within a minute | Bopify plays, not paused | 00:09:28 `decision=remote`, `play here: playing the transferred session`, `Load(…, false, 115533)` then `loading → playing` 0.58 s after the press | As expected | Pass |
| 2 | After fixes: skip on the phone, about 30 s untouched, then Space | Takeover at about 0:30 | 00:50:33.968 `command enqueued command=playHere` (from Space), `decision=remote`, `update position to 0:30`, `Load(…, true, 30598)`, playing 0.9 s after Space | As expected | Pass |
| 3 | While Bopify plays, pick the phone in its device picker | Mirror "Playing on <device>", no rim, no frozen track | Cluster update 00:00:35.183, `EmitSessionDisconnectedEvent` and `playing → idle` 0.22 s later, mirror 0.62 s after that; no `Playing` after going inactive | As expected; same-track record transition looked right | Pass |
| 3 | Same, with Up Next open | The Up Next button can close the queue; no heart | `Player presentation: queue` 00:51:44, takeover 00:51:55.993, mirror 00:51:56.626, `expanded` at 00:52:08 via the button | As expected | Pass |
| 4 | After scenario 3: pause the phone, wait until it leaves the cluster, click Play | Same track restored here, playing from its last reported position | Phone left the cluster 126 s after the pause (`remote playback present=false`); `decision=restore`, `Load(…, false, 41702)`, `loading → playing`; positions 0:41 → 0:42, no jump | As expected | Pass |
| 4 | Launch while the phone plays (Bopify has no track of its own), pause the phone, close Spotify there, press Space | Same, and Space acts as Play | Phone left the cluster 9 s after Spotify was closed; Space → `decision=restore`, `Load(…, false, 91884)`, playing 0.8 s later; 1:31 → 1:32 | As expected | Pass |
| 5 | Read the logs of scenario 2's takeovers | No "Request disconnect", no failed transfer reply, no new connection (run 5 had all three) | Across three play-heres in one process: none of them; no `play here: transfer replied` warning; the transfer arrived 65–96 ms after the request (run 5: 3.2 s) | n/a | Pass |
| — | After a play-here from a paused phone, move playback back to the phone, pause, then hand the paused session to Bopify from the phone's picker | Loads paused (the play-here flag is gone) | Transfer from the phone, no `play here: playing the transferred session`, `Load(…, false, 54085)`, `loading → paused` | As expected | Pass |

Native probe captures (the Monolith player replaced previews with probes) come from `python3 docs/superpowers/verification/run-monolith-probe.py --derived-data /private/tmp/bopify-mirror-build --output <dir> --probe mirror`. It writes `mirror-playing.png`, `mirror-paused.png`, `stale-mirror.png`, `stale-own.png`, `active-paused.png` and `error.png`. With the Mac left idle, the composition probe passed 3 of 3 runs at `26f26b3`, each started from a cleared `my.snsoft.bopify.monolith-probe` defaults domain.

### Deviations

- **Play here after a skip restarted the track at 0:00.**
  - **Cause.** Upstream `handle_transfer` added the time since the report only when the reported position was above 0. A phone playing through a playlist reports 0:00 at each track start and nothing after that, so a takeover 79 s later loaded at 0:00. A pause and resume on the phone makes it report its real position, and play here then kept 1:08. That contrast confirmed the cause. Phone-picker transfers took the same path.
  - **Fix.** `c830f30` moved the calculation into a tested `transfer_position` that also extrapolates a reported 0, clamped at 0. The restore path still forces paused, so it never extrapolates.
  - **Rerun.** After the fix, the rerun took over at 0:30.
- **Space did nothing on the mirror.** Space was gated on an active device by design. The user decided during this run that Space should play and pause in every state. `26f26b3` makes Space follow the Play button's rules, and the mirror probe presses Space. It was verified live in scenarios 2 and 4.
- **Keyboard focus could not reach Play.** Tab didn't land on Play. With Space fixed, the keyboard path no longer depends on it.
- **The double-press guard was not exercised live.** Play disables itself once `loading` arrives, 175 ms after a press, so the second click never reached Spirc. The 10 s guard in `handle_play_here` covers presses inside that window, and has no live evidence.

### Observed, not caused by this branch

- **Favourites were rate-limited all session.** All 29 library requests returned HTTP 429, starting with the first launch before any scenario, so the heart reported "too many requests". The mirror doesn't use the Web API.
- **The server closed the session once.** At 00:16:09 the user pressed Next, and half a second later librespot logged `Connection to server closed`. It invalidated the session, and the next track's audio key timed out. The player then decoded without a key and failed, and the engine reported `playbackSessionLost`. Nothing recovers a lost session automatically. No play-here or state update came before it.
- **A paused phone left the cluster.** It went 126 s after being paused. After Spotify was closed on the phone, it went within 9 s. Either way the mirror became the stale state, as specified.
