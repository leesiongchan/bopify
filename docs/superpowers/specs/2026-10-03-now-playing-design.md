# Media keys and Now Playing

Status: design for review, 2026-10-03. Approved in brainstorming: approach 1 (a pure mapping in `BopifyPlayback`, a thin MediaPlayer adapter in the app), and Bopify claims Now Playing only while it is the device playing.

## Problem and outcome

`PRD.md` lists system media keys and Now Playing as MVP and requires that "Play/pause, previous, next, current metadata, artwork, elapsed time, and duration must stay synchronized with macOS's Now Playing/media-control surface" (acceptance criteria PLAY-09 and PLAY-10). Bopify has no MediaPlayer integration: the keyboard media keys, headphone controls and Control Center's Now Playing module neither show nor control it.

Outcome: while Bopify is the active Spotify device with a current track, macOS shows that track in Now Playing, and the media keys, headphone controls and Control Center's buttons and scrubber control it exactly as Bopify's own buttons do. When another device takes over, or nothing is playing here, Bopify steps aside so the keys reach other apps.

## Components and data flow

**`BopifyPlayback`: `NowPlayingInfo` and `nowPlayingInfo(for:positionMs:)`.** A value type holding what Now Playing shows:

- title, artists joined with ", ", album title, artwork URL and duration in milliseconds
- elapsed position in milliseconds
- whether it is playing
- whether next, previous and seeking are available

The function returns `nil` when Bopify should not claim Now Playing, and otherwise the value for the current state. It takes the position from `PlayerModel.displayPositionMs(at:)`, so the elapsed time matches the time on Bopify's own screen. It is pure, `Equatable` and `Sendable`, with no MediaPlayer import.

**App: `NowPlayingController`.** It owns the system side, holding a `PlayerModel` and the `ArtworkStore`:

- It re-arms `withObservationTracking`, the pattern `StatusItemController` already uses, over the player's state and the artwork store's images. On each change it computes `nowPlayingInfo` and applies it.
- **Applying a value** writes `MPNowPlayingInfoCenter.default().nowPlayingInfo`: title, artist, album, duration, elapsed time, a playback rate of 1 or 0, and artwork. It then sets `playbackState` to `.playing` or `.paused`, and enables or disables the next, previous and change-position commands to match.
- **Applying `nil`** clears `nowPlayingInfo`, sets `playbackState` to `.stopped` and disables every command.
- **Artwork** is built once per URL as `MPMediaItemArtwork` from the image `ArtworkStore` already holds. The record view may not be on screen, so when the current track's artwork URL changes the controller asks the shared store to load it; the store already deduplicates loads.
- **Command routing:** in `MPRemoteCommandCenter`, play, pause, toggle play/pause, next, previous and change position route to the existing `PlayerModel` methods:
  - Play and pause call `togglePlayPause()`, but only when that changes the state; otherwise they return success without acting.
  - Change position calls `seek(to:)` with the event's time.
  - Each handler returns `.success`, or `.commandFailed` when Bopify is not the active device.
- **Lifetime:** `AppEnvironment` creates the controller when it creates a `PlayerModel` and stops it when it stops that player, at sign-out or an engine restart. Stopping removes the command targets and applies `nil`.

## Rules

- **Claims Now Playing:** `isActiveDevice` with a `currentTrack`, in any phase except an error that ended the session. Playing reports `.playing`. Paused, loading, buffering, ended and a recoverable error report `.paused`. Loading and buffering keep the current metadata, following PLAY-07.
- **Steps aside:** not the active device (including while mirroring another device), no current track, `playbackSessionLost`, or signed out.
- **Writes happen on state changes only:** play, pause, seek, a track change, an availability change or arriving artwork. macOS advances the elapsed time itself from the last position and the rate, so nothing is written while a track simply plays.
- **Availability:** next, previous and change position follow `canNext`, `canPrevious` and `canSeek`. Change position also requires a known duration.

## Failure and edge cases

- A command arriving after another device took over returns `.commandFailed` and changes nothing.
- A command Bopify's engine rejects behaves as the on-screen button does: `PlayerModel` shows its notice and the state converges to the engine's.
- Missing artwork leaves the artwork key out and macOS shows its own placeholder. Artwork that arrives later is added when it does.
- Another app taking Now Playing is macOS's decision. Bopify keeps writing its state, and the keys return to it once it plays again.

## Logging

Debug logs in `BopifyLog.playback` record when Bopify claims or releases Now Playing and each remote command received. They don't include track identifiers.

## Verification

- **Package tests** for `nowPlayingInfo`:
  - playing
  - paused
  - loading keeps the metadata
  - a recoverable error reports paused
  - `playbackSessionLost` steps aside
  - mirroring another device steps aside
  - no current track steps aside
  - several artists are joined
  - missing artwork leaves the URL `nil`
  - availability follows `canNext`, `canPrevious` and `canSeek`
- **Build:** the app builds in Debug and Release.
- **Manual,** by the user in the running app:
  - The keyboard play/pause, next and previous keys control Bopify.
  - Control Center's Now Playing shows the title, artist, artwork and a moving progress bar, and its scrubber seeks.
  - Headphone controls work, where available.
  - While Bopify only mirrors another device, the media keys reach Music or a browser instead.

The adapter is not unit-tested, because that would test MediaPlayer itself rather than Bopify's code.

## Sources

- Apple, "MPNowPlayingInfoCenter": https://developer.apple.com/documentation/mediaplayer/mpnowplayinginfocenter
- Apple, "MPRemoteCommandCenter": https://developer.apple.com/documentation/mediaplayer/mpremotecommandcenter
- gumbo issue #229, macOS requires `playbackState` to be set on every start and stop: https://github.com/svoltolini/gumbo/issues/229
- Apple Developer Forums, "MPNowPlayingInfoCenter playbackState fails to update after losing audio focus on macOS": https://developer.apple.com/forums/thread/799691
- Apple Developer Forums, Now Playing and media keys on macOS: https://developer.apple.com/forums/thread/685333
