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

## Preview renders

[Loading](assets/startup-loading.png), [another device playing](assets/startup-remote.png), [last resort paste view](assets/startup-last-resort.png), [control: playing](assets/startup-control-playing.png). Rendered with Xcode's RenderPreview from this worktree's project. The control differs from the older `expanded-final.png` because of `2016578` (two-ring glass player), which predates this branch.

## Deviations and observed risks

- **The phone took the session back in restore run 1.** About 45 s after the restore, the user opened Spotify on the phone. The phone then showed its own track instead of "listening on Bopify", and a cluster update deactivated Bopify. Run 2 used the same code (the diagnostic build changes logging only), and opening the phone app there left Bopify active. So this is phone-side behaviour, and run 1's logs (librespot lines redacted) can't show why. The likeliest cause, unconfirmed, is that the phone app had only been backgrounded rather than fully closed, and reclaimed its session when brought to the front. After such a takeover, Bopify keeps showing the track while Play and every other control are no-ops (`PlayerModel.togglePlayPause` is gated on `isActiveDevice`). That frozen inactive state predates this branch and is phase 2 scope. Run 1's empty Up Next was first opened at 21:56:13, after the deactivation; run 2 shows the queue filling within 0.4 s of a restore.
- **The device ID is random on every launch.** `SessionConfig::default()` (engine.rs) generates a new ID each time, which predates this branch. A killed instance therefore never matches the new instance's ID. If the server still lists it as active with a track, the startup decision reports `remote` naming "Bopify" (the spec's ghost-instance risk). Scenario 2 relaunched 9 s after the kill and didn't hit this, so the server had already dropped the killed device. Longer or different timings were not tried.
- **One harmless librespot warning per restore:** "couldn't load context info because: context is not available. type: Default". It's logged before the context resolves, and the context then resolves normally.

## Limits

Not exercised: a session old enough that Spotify no longer returns `transfer_data`; a Liked Songs library that is actually empty; a whole context that can't play (`Unavailable`/`Stopped`, still dropped by the event translation); a network failure during startup. A real Nothing outcome was never reached, so the paste view was only checked in preview.
