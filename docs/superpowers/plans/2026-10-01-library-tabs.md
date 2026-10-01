# Recents, Explore and Liked Tabs Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Put Recents, Explore and Liked tabs above Cover Flow. Explore plays Spotify's own radio mixes, seeded from the user's top tracks and artists and fetched through librespot.

**Architecture:**
- **Rust.** A new `radio.rs` in `bopify-core` is the only code that touches Spotify's internal radio endpoints. Its answer reaches Swift as a `radio` or `radioFailed` JSON event on the existing callback.
- **Swift engine.** `EventBridge` takes those two event types off the playback stream and resumes the caller waiting on the same request ID. `PlaybackEngine.requestRadio(seed:)` is the domain entry point.
- **Swift library.** `BopifyLibrary` gains the two Web API calls, plus `RecentsModel` and `ExploreModel`. Both models conform to a `CoverFlowSource` protocol that `LikedSongsModel` also adopts.
- **App.** The app generalizes the Cover Flow view and adds a `LibraryShelf` that holds the tabs and the chips.

**Tech Stack:**
- Rust 2024 with librespot pinned at `939dc5e`, tokio, serde_json.
- Swift 6 on macOS 14: SwiftUI, Observation and Swift Testing.
- The Spotify Web API.

**Spec:** `docs/superpowers/specs/2026-09-30-library-tabs-design.md`

## Global Constraints

**Platform and dependencies**
- macOS deployment target is 14. Don't use `Synchronization.Mutex` (macOS 15). Use `OSAllocatedUnfairLock` from `os`.
- The Swift package builds in Swift 6 language mode.
- Rust is edition 2024 with `rust-version = "1.85"`. Add no new crates.
- librespot stays at the pinned revision `939dc5e`.
- No new Swift or Rust dependencies.

**Contracts and code style**
- The Rust↔Swift JSON contract (`WireEvent`) and its Swift decoder must agree. Task 1 adds the Rust variants, and Swift sends no radio request before Task 3 adds the decoder, so no radio event can cross early.
- Any file that uses `Logger` privacy interpolation needs `import os`. MemberImportVisibility is on.
- Logging:
  - Swift logs tab changes and cache hits and misses at `.debug` in `BopifyLog.library`.
  - Rust logs each station request's seed type, track count and failure category.
  - Never log track IDs, titles, URIs or tokens at `.public`. Rust never logs identifiers.

**App target**
- The app target uses synchronized folder groups. New Swift files under `Bopify/Bopify/` need no `project.pbxproj` edit.

**Git**
- `Bopify/Bopify.xcodeproj/project.pbxproj` carries the user's uncommitted signing change. Never stage it. Every commit step names explicit paths. Never use `git add -A` or `git add .`.
- Commit messages follow the repo's style:
  - An imperative subject under 72 characters.
  - A body that explains why.
  - No `Co-Authored-By` line (AGENTS.md).

**Commands** (run from the repo root):
- Rust tests: `cargo test --manifest-path rust/Cargo.toml`
- Rebuild the xcframework and header: `./scripts/build-rust.sh`. Swift sees a Rust change only after this.
- Swift package tests: `swift test --package-path Packages/BopifyCore --scratch-path /private/tmp/bopify-library-tabs-tests`
- App build: `xcodebuild -quiet -project Bopify/Bopify.xcodeproj -scheme Bopify -destination 'platform=macOS,arch=arm64' -derivedDataPath /private/tmp/bopify-library-tabs-build build`

**Deviations from the spec**
- **The radio fixture.** The spec's verification line calls for a radio fixture "captured from the 2026-09-30 spike". That spike deliberately never printed response bodies, so no capture exists. Task 1 captures the fixture first, with every identifier replaced.
- **The newest-request rule.** The spec's "only the newest request per seed is honoured" is enforced in `ExploreModel`. It cancels the request in flight when another chip is chosen, and drops results that arrive after cancellation. The bridge itself answers every request ID it issued.

## File Structure

| File | Responsibility |
|---|---|
| `rust/crates/bopify-core/src/radio.rs` (new) | Seed parsing, artist → top track, radio mix lookup, mix tracks → `WireTrack`, failure classification; `RadioSource` trait with the librespot-backed `SessionRadio` |
| `rust/crates/bopify-core/src/fixtures/inspiredby_mix.json` (new) | Redacted capture of one `/inspiredby-mix/v2/seed_to_playlist` response |
| `rust/crates/bopify-core/src/event.rs` | `RadioFailure`, `WireEvent::Radio`, `WireEvent::RadioFailed` |
| `rust/crates/bopify-core/src/engine.rs` | Keeps the `Session`; `Engine::request_radio` |
| `rust/crates/bopify-core/src/ffi.rs` | `bopify_request_radio` |
| `rust/crates/bopify-core/src/lib.rs` | `mod radio;` |
| `Packages/BopifyCore/Sources/BopifyDomain/RadioMix.swift` (new) | `RadioMix`, `RadioFailure`, `RadioReply` decoding |
| `Packages/BopifyCore/Sources/BopifyDomain/PlaybackEngine.swift` | `requestRadio(seed:)` requirement |
| `Packages/BopifyCore/Sources/BopifyDomain/PlaybackEvent.swift` | `decodeTrack` becomes module-internal so `RadioReply` reuses it |
| `Packages/BopifyCore/Sources/BopifyDomain/ListeningHistoryService.swift` (new) | `RecentPlay`, `StationSeed`, `TopItemKind`, `ListeningHistoryService` |
| `Packages/BopifyCore/Sources/BopifyPlayback/EventBridge.swift` | Radio reply correlation by request ID |
| `Packages/BopifyCore/Sources/BopifyPlayback/LibrespotEngine.swift` | `requestRadio(seed:)` over FFI |
| `Packages/BopifyCore/Sources/BopifyLibrary/SpotifyLibraryClient.swift` | `recentlyPlayed()`, `topItems(_:)` |
| `Packages/BopifyCore/Sources/BopifyAuth/SpotifyAuthService.swift` | Two more allowed library scopes |
| `Packages/BopifyCore/Sources/BopifyLibrary/CoverFlowSource.swift` (new) | The protocol Cover Flow renders; `LikedSongsModel` conformance |
| `Packages/BopifyCore/Sources/BopifyLibrary/RecentsModel.swift` (new) | Recents source |
| `Packages/BopifyCore/Sources/BopifyLibrary/ExploreModel.swift` (new) | Chips, stations, Explore source |
| `Packages/BopifyCore/Tests/LibraryTests/LibraryFakes.swift` (new) | Fakes shared by Recents and Explore tests |
| `Bopify/Bopify/Views/CoverFlowView.swift` (renamed from `LikedSongsCoverFlow.swift`) | Cover Flow over any `CoverFlowSource`, with per-source copy |
| `Bopify/Bopify/Views/LibraryShelf.swift` (new) | Tabs, station chips, station failure state |
| `Bopify/Bopify/Views/MonolithPlayerView.swift` | Hosts `LibraryShelf` in the lower frame |
| `Bopify/Bopify/AppEnvironment.swift` | Owns the two new models, the station route, consent and clearing |
| `Bopify/Bopify/Localizable.xcstrings` | New strings; drops the unused `library.title` |
| `docs/superpowers/verification/LibraryTabsLiveProbe.swift` (new) | One live station and Web API request, categories only |
| `docs/superpowers/verification/2026-10-01-library-tabs.md` (new) | Verification report |

---

### Task 1: Rust radio resolution and wire events

**Files:**
- Create: `rust/crates/bopify-core/src/radio.rs`
- Create: `rust/crates/bopify-core/src/fixtures/inspiredby_mix.json`
- Modify: `rust/crates/bopify-core/src/event.rs` (add `RadioFailure` after `WireRemote`; add two variants at the end of `WireEvent`; add tests)
- Modify: `rust/crates/bopify-core/src/lib.rs` (add `mod radio;` after `mod queue;`)
- Modify (gitignored, not committed): `.superpowers/spikes/radio-probe/src/main.rs`

**Interfaces:**
- Consumes: `crate::queue::lookup(session: Session, raw: String) -> Option<WireTrack>`, `crate::event::WireTrack`.
- Produces:
  - `crate::event::RadioFailure { NoTopTrack, NoMix, Unavailable, Network }`, serialised as `"noTopTrack" | "noMix" | "unavailable" | "network"`.
  - `WireEvent::Radio { request_id: u64, seed_uri: String, context_uri: String, tracks: Vec<WireTrack> }`, serialised with the keys `requestID`, `seedURI`, `contextURI` and `tracks`.
  - `WireEvent::RadioFailed { request_id: u64, seed_uri: String, reason: RadioFailure }`, serialised with the keys `requestID`, `seedURI` and `reason`.
  - `crate::radio::Seed::parse(&str) -> Option<Seed>`.
  - `crate::radio::SessionRadio(pub Session)`.
  - `crate::radio::resolve<S: RadioSource>(&S, Seed, u64) -> WireEvent`.

- [ ] **Step 1: Capture the radio response shape as a redacted fixture**

Add a `shape` mode to the throwaway probe. In `.superpowers/spikes/radio-probe/src/main.rs`, insert this right after `let args: Vec<String> = std::env::args().skip(1).collect();`:

```rust
    // "shape <track uri>": the radio response with every identifier and name replaced.
    if args.first().map(String::as_str) == Some("shape") {
        let uri = SpotifyUri::from_uri(&args[1]).expect("track uri");
        let bytes = session.spclient().get_radio_for_track(&uri).await.expect("radio response");
        let json: Value = serde_json::from_slice(&bytes).expect("json");
        println!("{}", serde_json::to_string_pretty(&redact(json)).unwrap());
        return;
    }
```

Add this function at file scope:

```rust
fn redact(value: Value) -> Value {
    match value {
        Value::String(s) if s.starts_with("spotify:playlist:") => {
            Value::String("spotify:playlist:37i9dQZF1E4MIXFIXTURE1".into())
        }
        Value::String(s) if s.starts_with("spotify:") => {
            let kind = s.split(':').nth(1).unwrap_or("item");
            Value::String(format!("spotify:{kind}:redacted"))
        }
        Value::String(_) => Value::String("redacted".into()),
        Value::Array(items) => Value::Array(items.into_iter().map(redact).collect()),
        Value::Object(map) => Value::Object(map.into_iter().map(|(k, v)| (k, redact(v))).collect()),
        other => other,
    }
}
```

Run it from the repo root. The `seeds` mode prints liked-track and artist URIs. `sed 1d` drops the probe's `connected` line.

```bash
mkdir -p rust/crates/bopify-core/src/fixtures
seed=$(swift run -q --package-path .superpowers/spikes/genre-probe GenreProbe seeds | tr ' ' '\n' | rg '^spotify:track:' | head -1)
swift run -q --package-path .superpowers/spikes/genre-probe GenreProbe playback-token \
  | cargo run -q --manifest-path .superpowers/spikes/radio-probe/Cargo.toml -- shape "$seed" \
  | sed 1d > rust/crates/bopify-core/src/fixtures/inspiredby_mix.json
rg -c 'spotify:playlist:37i9dQZF1E4MIXFIXTURE1' rust/crates/bopify-core/src/fixtures/inspiredby_mix.json
```

Expected: the file is valid JSON, and the last command prints a count of at least 1. Open the file to confirm it holds no real identifiers or names.

If either probe prints `BLOCKED`, stop and ask the user to open Bopify and sign in, because both keychain sessions are needed.

- [ ] **Step 2: Write the failing serialisation tests in `event.rs`**

Append inside `mod tests` in `rust/crates/bopify-core/src/event.rs`:

```rust
    #[test]
    fn radio_events_use_the_swift_key_spellings() {
        let mix = WireEvent::Radio {
            request_id: 7,
            seed_uri: "spotify:artist:a".into(),
            context_uri: "spotify:playlist:m".into(),
            tracks: vec![],
        };
        assert_eq!(
            serde_json::to_string(&mix).unwrap(),
            r#"{"type":"radio","requestID":7,"seedURI":"spotify:artist:a","contextURI":"spotify:playlist:m","tracks":[]}"#
        );
        let failed = WireEvent::RadioFailed {
            request_id: 8,
            seed_uri: "spotify:track:t".into(),
            reason: RadioFailure::NoTopTrack,
        };
        assert_eq!(
            serde_json::to_string(&failed).unwrap(),
            r#"{"type":"radioFailed","requestID":8,"seedURI":"spotify:track:t","reason":"noTopTrack"}"#
        );
    }
```

- [ ] **Step 3: Run it to verify it fails**

Run: `cargo test --manifest-path rust/Cargo.toml radio_events`
Expected: compile error, because there is no variant `Radio` and no type `RadioFailure`.

- [ ] **Step 4: Add the wire types**

In `event.rs`, after the `WireRemote` struct:

```rust
/// Why a station could not be built. Swift's `RadioFailure` uses these names as raw values.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum RadioFailure {
    NoTopTrack,
    NoMix,
    Unavailable,
    Network,
}
```

At the end of `enum WireEvent`, after `RemotePlayback { .. },`:

```rust
    /// A radio mix for the request with the same ID; Swift resolves the waiting caller, not the event stream.
    Radio {
        #[serde(rename = "requestID")]
        request_id: u64,
        #[serde(rename = "seedURI")]
        seed_uri: String,
        #[serde(rename = "contextURI")]
        context_uri: String,
        tracks: Vec<WireTrack>,
    },
    RadioFailed {
        #[serde(rename = "requestID")]
        request_id: u64,
        #[serde(rename = "seedURI")]
        seed_uri: String,
        reason: RadioFailure,
    },
```

- [ ] **Step 5: Run it to verify it passes**

Run: `cargo test --manifest-path rust/Cargo.toml radio_events`
Expected: PASS.

- [ ] **Step 6: Write the failing radio tests**

Create `rust/crates/bopify-core/src/radio.rs` containing only the test module for now. Then add `mod radio;` after `mod queue;` in `lib.rs`.

```rust
#[cfg(test)]
mod tests {
    use super::*;
    use librespot_metadata::artist::{CountryTopTracks, TopTracks};
    use librespot_metadata::track::Tracks;
    use std::sync::{Arc, Mutex};

    const SEED_TRACK: &str = "spotify:track:6rqhFgbbKwnb9MLmUQDhG6";
    const SEED_ARTIST: &str = "spotify:artist:6rqhFgbbKwnb9MLmUQDhG6";
    const TOP_TRACK: &str = "spotify:track:5Ohxk2dO5COHF1krpoPigN";
    const MIX: &[u8] = br#"{"mediaItems":[{"uri":"spotify:playlist:37i9dQZF1E4MIXFIXTURE1"}]}"#;

    #[derive(Clone)]
    struct Fake {
        top: Option<&'static str>,
        mix: Result<Vec<u8>, RadioFailure>,
        context: Vec<String>,
        missing: Vec<String>,
        mixed_for: Arc<Mutex<Vec<String>>>,
    }

    impl Fake {
        fn new(context: Vec<String>) -> Self {
            Self { top: None, mix: Ok(MIX.to_vec()), context, missing: vec![], mixed_for: Arc::default() }
        }
    }

    impl RadioSource for Fake {
        async fn top_track(&self, _artist: &SpotifyUri) -> Result<Option<SpotifyUri>, RadioFailure> {
            Ok(self.top.map(|uri| SpotifyUri::from_uri(uri).unwrap()))
        }
        async fn mix(&self, track: &SpotifyUri) -> Result<Vec<u8>, RadioFailure> {
            self.mixed_for.lock().unwrap().push(track.to_uri());
            self.mix.clone()
        }
        async fn context_tracks(&self, _context_uri: &str) -> Result<Vec<String>, RadioFailure> {
            Ok(self.context.clone())
        }
        async fn track(&self, uri: String) -> Option<WireTrack> {
            (!self.missing.contains(&uri)).then(|| WireTrack {
                track_uri: uri.clone(),
                title: uri,
                artists: vec![],
                album_title: None,
                artwork_url: None,
                duration_ms: 1,
            })
        }
    }

    fn uris(count: usize) -> Vec<String> {
        (0..count).map(|i| format!("spotify:track:{i:022}")).collect()
    }

    #[test]
    fn the_captured_response_names_its_mix_playlist() {
        let body = include_bytes!("fixtures/inspiredby_mix.json");
        assert_eq!(mix_uri(body).as_deref(), Some("spotify:playlist:37i9dQZF1E4MIXFIXTURE1"));
    }

    #[test]
    fn bodies_without_a_playlist_have_no_mix() {
        assert_eq!(mix_uri(br#"{"mediaItems":[]}"#), None);
        assert_eq!(mix_uri(b"not json"), None);
    }

    #[test]
    fn seeds_are_tracks_or_artists_only() {
        assert!(matches!(Seed::parse(SEED_TRACK), Some(Seed::Track(_))));
        assert!(matches!(Seed::parse(SEED_ARTIST), Some(Seed::Artist(_))));
        assert!(Seed::parse("spotify:album:6rqhFgbbKwnb9MLmUQDhG6").is_none());
        assert!(Seed::parse("garbage").is_none());
    }

    fn top(lists: &[(&str, &[&str])]) -> CountryTopTracks {
        CountryTopTracks(
            lists
                .iter()
                .map(|(country, tracks)| TopTracks {
                    country: country.to_string(),
                    tracks: Tracks(tracks.iter().map(|t| SpotifyUri::from_uri(t).unwrap()).collect()),
                })
                .collect(),
        )
    }

    #[test]
    fn top_track_prefers_the_session_country_then_any_list() {
        let lists = top(&[("US", &[SEED_TRACK]), ("MY", &[TOP_TRACK])]);
        assert_eq!(pick_top_track(&lists, "MY").map(|u| u.to_uri()).as_deref(), Some(TOP_TRACK));
        assert_eq!(pick_top_track(&lists, "JP").map(|u| u.to_uri()).as_deref(), Some(SEED_TRACK));
        assert_eq!(pick_top_track(&top(&[("MY", &[])]), "MY"), None);
        assert_eq!(pick_top_track(&top(&[]), "MY"), None);
    }

    #[tokio::test]
    async fn a_track_seed_resolves_to_the_first_fifty_mix_tracks_in_order() {
        let mut fake = Fake::new(uris(60));
        fake.missing = vec![uris(60)[3].clone()];
        let event = resolve(&fake, Seed::parse(SEED_TRACK).unwrap(), 41).await;
        let WireEvent::Radio { request_id, seed_uri, context_uri, tracks } = event else {
            panic!("expected Radio, got {event:?}");
        };
        assert_eq!((request_id, seed_uri.as_str()), (41, SEED_TRACK));
        assert_eq!(context_uri, "spotify:playlist:37i9dQZF1E4MIXFIXTURE1");
        let expected: Vec<String> = uris(50).into_iter().filter(|u| u != &uris(60)[3]).collect();
        assert_eq!(tracks.into_iter().map(|t| t.track_uri).collect::<Vec<_>>(), expected);
        assert_eq!(*fake.mixed_for.lock().unwrap(), vec![SEED_TRACK.to_string()]);
    }

    #[tokio::test]
    async fn an_artist_seed_starts_its_mix_from_the_top_track() {
        let mut fake = Fake::new(uris(2));
        fake.top = Some(TOP_TRACK);
        let event = resolve(&fake, Seed::parse(SEED_ARTIST).unwrap(), 1).await;
        assert!(matches!(event, WireEvent::Radio { .. }));
        assert_eq!(*fake.mixed_for.lock().unwrap(), vec![TOP_TRACK.to_string()]);
    }

    async fn failure(fake: Fake, seed: &str) -> RadioFailure {
        match resolve(&fake, Seed::parse(seed).unwrap(), 9).await {
            WireEvent::RadioFailed { request_id: 9, reason, .. } => reason,
            other => panic!("expected RadioFailed, got {other:?}"),
        }
    }

    #[tokio::test]
    async fn every_failure_names_its_category() {
        assert_eq!(failure(Fake::new(uris(2)), SEED_ARTIST).await, RadioFailure::NoTopTrack);
        let mut no_playlist = Fake::new(uris(2));
        no_playlist.mix = Ok(br#"{"mediaItems":[]}"#.to_vec());
        assert_eq!(failure(no_playlist, SEED_TRACK).await, RadioFailure::NoMix);
        assert_eq!(failure(Fake::new(vec![]), SEED_TRACK).await, RadioFailure::NoMix);
        let mut broken = Fake::new(uris(2));
        broken.mix = Err(RadioFailure::Network);
        assert_eq!(failure(broken, SEED_TRACK).await, RadioFailure::Network);
    }
}
```

- [ ] **Step 7: Run them to verify they fail**

Run: `cargo test --manifest-path rust/Cargo.toml radio::`
Expected: compile errors, because `RadioSource`, `Seed`, `mix_uri`, `pick_top_track` and `resolve` are not defined.

- [ ] **Step 8: Implement `radio.rs`**

Put this above the test module:

```rust
//! Spotify's own radio for a seed track or artist. The only code that calls the
//! internal radio endpoints; the Spotify calls sit behind `RadioSource` so the
//! mapping is testable without a network.

use std::{
    future::Future,
    sync::atomic::{AtomicBool, Ordering},
};

use librespot_core::{Session, SpotifyUri, error::ErrorKind};
use librespot_metadata::{Artist, Metadata, artist::CountryTopTracks};
use serde_json::Value;
use tokio::task::JoinSet;

use crate::event::{RadioFailure, WireEvent, WireTrack};

/// Spotify's mixes run to about 50 tracks; Cover Flow shows at most that many.
const MAX_TRACKS: usize = 50;
/// Matches the queue metadata worker's lookup bound.
const CONCURRENT_LOOKUPS: usize = 4;

#[derive(Debug, Clone, PartialEq)]
pub(crate) enum Seed {
    Track(SpotifyUri),
    Artist(SpotifyUri),
}

impl Seed {
    pub(crate) fn parse(raw: &str) -> Option<Self> {
        match SpotifyUri::from_uri(raw).ok()? {
            uri @ SpotifyUri::Track { .. } => Some(Self::Track(uri)),
            uri @ SpotifyUri::Artist { .. } => Some(Self::Artist(uri)),
            _ => None,
        }
    }

    fn kind(&self) -> &'static str {
        match self {
            Self::Track(_) => "track",
            Self::Artist(_) => "artist",
        }
    }

    fn uri(&self) -> String {
        match self {
            Self::Track(uri) | Self::Artist(uri) => uri.to_uri(),
        }
    }
}

pub(crate) trait RadioSource: Clone + Send + Sync + 'static {
    fn top_track(&self, artist: &SpotifyUri) -> impl Future<Output = Result<Option<SpotifyUri>, RadioFailure>> + Send;
    fn mix(&self, track: &SpotifyUri) -> impl Future<Output = Result<Vec<u8>, RadioFailure>> + Send;
    fn context_tracks(&self, context_uri: &str) -> impl Future<Output = Result<Vec<String>, RadioFailure>> + Send;
    fn track(&self, uri: String) -> impl Future<Output = Option<WireTrack>> + Send;
}

#[derive(Clone)]
pub(crate) struct SessionRadio(pub Session);

impl RadioSource for SessionRadio {
    async fn top_track(&self, artist: &SpotifyUri) -> Result<Option<SpotifyUri>, RadioFailure> {
        let artist = Artist::get(&self.0, artist).await.map_err(|e| classify(&e))?;
        Ok(pick_top_track(&artist.top_tracks, &self.0.country()))
    }

    async fn mix(&self, track: &SpotifyUri) -> Result<Vec<u8>, RadioFailure> {
        let body = self.0.spclient().get_radio_for_track(track).await.map_err(|e| classify(&e))?;
        Ok(body.to_vec())
    }

    async fn context_tracks(&self, context_uri: &str) -> Result<Vec<String>, RadioFailure> {
        let context = self.0.spclient().get_context(context_uri).await.map_err(|e| classify(&e))?;
        Ok(context
            .pages
            .iter()
            .flat_map(|page| page.tracks.iter().map(|track| track.uri().to_string()))
            .collect())
    }

    async fn track(&self, uri: String) -> Option<WireTrack> {
        crate::queue::lookup(self.0.clone(), uri).await
    }
}

/// Builds the reply for one request; never fails, because a failure is itself a reply.
pub(crate) async fn resolve<S: RadioSource>(source: &S, seed: Seed, request_id: u64) -> WireEvent {
    let seed_uri = seed.uri();
    let kind = seed.kind();
    match mix_for(source, seed).await {
        Ok((context_uri, tracks)) => {
            log::info!("radio: resolved seed={kind} tracks={}", tracks.len());
            WireEvent::Radio { request_id, seed_uri, context_uri, tracks }
        }
        Err(reason) => {
            log_failure(kind, reason);
            WireEvent::RadioFailed { request_id, seed_uri, reason }
        }
    }
}

async fn mix_for<S: RadioSource>(source: &S, seed: Seed) -> Result<(String, Vec<WireTrack>), RadioFailure> {
    let track = match seed {
        Seed::Track(uri) => uri,
        Seed::Artist(uri) => source.top_track(&uri).await?.ok_or(RadioFailure::NoTopTrack)?,
    };
    let body = source.mix(&track).await?;
    let context_uri = mix_uri(&body).ok_or(RadioFailure::NoMix)?;
    let uris = source.context_tracks(&context_uri).await?;
    let tracks = resolve_tracks(source, uris).await;
    if tracks.is_empty() {
        return Err(RadioFailure::NoMix);
    }
    Ok((context_uri, tracks))
}

/// The response layout is undocumented, so take the first playlist URI wherever it sits.
pub(crate) fn mix_uri(body: &[u8]) -> Option<String> {
    fn find(value: &Value) -> Option<&str> {
        match value {
            Value::String(s) if s.starts_with("spotify:playlist:") => Some(s),
            Value::Array(items) => items.iter().find_map(find),
            Value::Object(map) => map.values().find_map(find),
            _ => None,
        }
    }
    find(&serde_json::from_slice(body).ok()?).map(str::to_owned)
}

/// Top tracks are listed per country: the session's own first, else whichever list Spotify sent.
pub(crate) fn pick_top_track(top: &CountryTopTracks, country: &str) -> Option<SpotifyUri> {
    top.iter()
        .find(|list| list.country == country && !list.tracks.is_empty())
        .or_else(|| top.iter().find(|list| !list.tracks.is_empty()))
        .and_then(|list| list.tracks.first().cloned())
}

/// Looks up to four tracks at once and keeps the mix's order; unresolvable tracks are dropped.
async fn resolve_tracks<S: RadioSource>(source: &S, uris: Vec<String>) -> Vec<WireTrack> {
    let mut pending = uris
        .into_iter()
        .filter(|uri| uri.starts_with("spotify:track:"))
        .take(MAX_TRACKS)
        .enumerate();
    let mut jobs = JoinSet::new();
    let mut found = Vec::new();
    loop {
        while jobs.len() < CONCURRENT_LOOKUPS {
            let Some((index, uri)) = pending.next() else { break };
            let source = source.clone();
            jobs.spawn(async move { (index, source.track(uri).await) });
        }
        match jobs.join_next().await {
            Some(Ok((index, Some(track)))) => found.push((index, track)),
            Some(_) => {}
            None => break,
        }
    }
    found.sort_by_key(|(index, _)| *index);
    found.into_iter().map(|(_, track)| track).collect()
}

fn classify(error: &librespot_core::Error) -> RadioFailure {
    match error.kind {
        ErrorKind::DeadlineExceeded | ErrorKind::Unavailable | ErrorKind::Aborted => RadioFailure::Network,
        _ => RadioFailure::Unavailable,
    }
}

/// Endpoint breakage is reported once at warn so a broken Explore is visible without flooding the log.
static REPORTED_UNAVAILABLE: AtomicBool = AtomicBool::new(false);

fn log_failure(kind: &str, reason: RadioFailure) {
    if reason == RadioFailure::Unavailable && !REPORTED_UNAVAILABLE.swap(true, Ordering::Relaxed) {
        log::warn!("radio: internal endpoints unavailable seed={kind}");
    }
    log::info!("radio: failed seed={kind} reason={reason:?}");
}
```

- [ ] **Step 9: Run the tests to verify they pass**

Run: `cargo test --manifest-path rust/Cargo.toml`
Expected: all tests pass, including the 7 new `radio::tests` and `radio_events_use_the_swift_key_spellings`. If the compiler reports `SessionRadio` or `resolve` as dead code, that is expected until Task 2 uses them; do not silence it.

- [ ] **Step 10: Commit**

```bash
git add rust/crates/bopify-core/src/radio.rs rust/crates/bopify-core/src/fixtures/inspiredby_mix.json \
        rust/crates/bopify-core/src/event.rs rust/crates/bopify-core/src/lib.rs
git commit -m "Resolve Spotify radio mixes for a seed track or artist" -m "Explore needs Spotify's own stations, which only librespot's internal endpoints still serve to this app. The lookup sits behind a trait so seed handling, top-track choice, mix parsing and the 50-track cap are tested against a redacted capture of the real response."
```

---

### Task 2: Engine entry point and FFI

**Files:**
- Modify: `rust/crates/bopify-core/src/engine.rs` (`Engine` struct, `Engine::new`, new `request_radio`)
- Modify: `rust/crates/bopify-core/src/ffi.rs` (new entry point after `bopify_load`; after-destroy test)

**Interfaces:**
- Consumes: `radio::Seed::parse`, `radio::SessionRadio`, `radio::resolve` (Task 1).
- Produces:
  - The C function `int32_t bopify_request_radio(BopifyEngine *handle, const char *seed_uri, uint64_t request_id)`.
  - Its return codes:
    - `0`: queued.
    - `-1`: null or malformed seed, or a seed that is not a track or artist.
    - `-2`: the engine is gone.
  - On a `0` return, the engine emits exactly one `radio` or `radioFailed` event carrying `request_id`.

- [ ] **Step 1: Write the failing FFI test**

In `ffi.rs`'s test module, inside the after-destroy test (the block that contains `assert_eq!(bopify_select_queue(ptr, 1, 0), lost);`), add after that line:

```rust
            assert_eq!(bopify_request_radio(ptr, c"spotify:track:6rqhFgbbKwnb9MLmUQDhG6".as_ptr(), 1), lost);
            assert_eq!(
                bopify_request_radio(ptr, std::ptr::null(), 1),
                BopifyError::InvalidArgument.code()
            );
```

- [ ] **Step 2: Run it to verify it fails**

Run: `cargo test --manifest-path rust/Cargo.toml ffi`
Expected: compile error, because `bopify_request_radio` is not found.

- [ ] **Step 3: Keep the session in `Engine`**

In `engine.rs`, add the field at the end of `pub struct Engine`, after `sink: EventSink,`:

```rust
    /// For radio lookups. Declared after `runtime`, so the runtime still drops (and joins) first.
    session: Session,
```

In `Engine::new`, change `let spirc = runtime.block_on(async {` to `let (spirc, session) = runtime.block_on(async {`. Then replace the end of that async block:

```rust
            tokio::spawn(task);
            supervise_forwarder(events, sink.clone(), session);
            Ok::<_, BopifyError>(spirc)
        })?;
```

with:

```rust
            tokio::spawn(task);
            let radio_session = session.clone();
            supervise_forwarder(events, sink.clone(), session);
            Ok::<_, BopifyError>((spirc, radio_session))
        })?;
```

Then change the constructor:

```rust
        Ok(Self {
            runtime,
            spirc,
            sink,
            session,
        })
```

Add the method after `load`:

```rust
    /// Queues a station lookup. The answer arrives on the sink as `Radio` or
    /// `RadioFailed` carrying `request_id`, and the work ends with the runtime.
    pub fn request_radio(&self, seed_uri: &str, request_id: u64) -> Result<(), BopifyError> {
        let seed = crate::radio::Seed::parse(seed_uri).ok_or(BopifyError::InvalidArgument)?;
        let source = crate::radio::SessionRadio(self.session.clone());
        let sink = self.sink.clone();
        self.runtime.spawn(async move { sink(crate::radio::resolve(&source, seed, request_id).await) });
        Ok(())
    }
```

- [ ] **Step 4: Add the FFI entry point**

In `ffi.rs`, after `bopify_load`:

```rust
/// Asks for Spotify's radio mix for a track or artist URI. Returns once the
/// request is queued; the answer is one `radio` or `radioFailed` event with
/// the same `request_id`.
///
/// # Safety
/// `handle` must be null or a live handle from `bopify_engine_create`, and
/// `seed_uri` must satisfy `str_from`'s contract.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn bopify_request_radio(
    handle: *mut BopifyEngine,
    seed_uri: *const c_char,
    request_id: u64,
) -> i32 {
    log::debug!("ffi: bopify_request_radio request_id={request_id}");
    // SAFETY: the seed pointer satisfies `str_from`'s contract per the header,
    // and the borrow is consumed before this call returns.
    let Some(seed) = (unsafe { str_from(seed_uri) }) else {
        return BopifyError::InvalidArgument.code();
    };
    // SAFETY: forwards this function's own contract to `with_engine`.
    unsafe { with_engine(handle, |engine| engine.request_radio(seed, request_id)) }
}
```

- [ ] **Step 5: Run the Rust tests**

Run: `cargo test --manifest-path rust/Cargo.toml`
Expected: all pass, and there are no dead-code warnings for `radio`.

- [ ] **Step 6: Rebuild the xcframework and check the header**

Run:

```bash
./scripts/build-rust.sh
rg -n "bopify_request_radio" artifacts/include
```

Expected: the build succeeds, and the header declares `int32_t bopify_request_radio(BopifyEngine *handle, const char *seed_uri, uint64_t request_id);`.

- [ ] **Step 7: Commit**

```bash
git add rust/crates/bopify-core/src/engine.rs rust/crates/bopify-core/src/ffi.rs
git commit -m "Expose radio lookups through the engine FFI" -m "The engine now keeps its session so a station lookup can run on its own runtime and end with it. The entry point only queues the work; the answer arrives as an event tagged with the caller's request ID."
```

---

### Task 3: Swift radio request path

**Files:**
- Create: `Packages/BopifyCore/Sources/BopifyDomain/RadioMix.swift`
- Modify: `Packages/BopifyCore/Sources/BopifyDomain/PlaybackEvent.swift` (`private static func decodeTrack` → `static func decodeTrack`)
- Modify: `Packages/BopifyCore/Sources/BopifyDomain/PlaybackEngine.swift` (protocol requirement)
- Modify: `Packages/BopifyCore/Sources/BopifyPlayback/EventBridge.swift`
- Modify: `Packages/BopifyCore/Sources/BopifyPlayback/LibrespotEngine.swift`
- Modify: `Packages/BopifyCore/Tests/PlaybackTests/StubPlaybackEngine.swift`, `Tests/PlaybackTests/PlayerModelTests.swift` (`FailingSelectionEngine`), `Tests/PlaybackTests/PlayerVolumeTests.swift` (`ControlledVolumeEngine`)
- Create: `Packages/BopifyCore/Tests/DomainTests/RadioReplyTests.swift`
- Test: `Packages/BopifyCore/Tests/PlaybackTests/EventBridgeTests.swift`

**Interfaces:**
- Consumes: `bopify_request_radio` (Task 2) and the JSON shapes pinned in Task 1, Step 2.
- Produces:
  - `public struct RadioMix: Hashable, Sendable`, with `contextURI: SpotifyURI` and `tracks: [Track]`, and `init(contextURI:tracks:)`.
  - `public enum RadioFailure: String, Error, Hashable, Sendable`, with cases `noTopTrack`, `noMix`, `unavailable` and `network`.
  - `public enum RadioReply`, with `.mix(requestID:, RadioMix)` and `.failed(requestID:, RadioFailure)`.
  - `PlaybackEngine.requestRadio(seed: SpotifyURI) async throws -> RadioMix`. It throws:
    - `RadioFailure` when Spotify has no station.
    - `PlayerError.playbackSessionLost` when the engine is gone or shuts down mid-request.
    - `CancellationError` when cancelled.

- [ ] **Step 1: Write the failing domain decoding tests**

Create `Packages/BopifyCore/Tests/DomainTests/RadioReplyTests.swift`:

```swift
import Foundation
import Testing
import BopifyDomain

@Suite("RadioReply")
struct RadioReplyTests {
    @Test func decodesAMixInTheRustWireShape() throws {
        let json = #"{"type":"radio","requestID":7,"seedURI":"spotify:artist:a","contextURI":"spotify:playlist:m","tracks":[{"trackUri":"spotify:track:t","title":"T","artists":["A"],"albumTitle":null,"artworkUrl":null,"durationMs":1000}]}"#
        let reply = try JSONDecoder().decode(RadioReply.self, from: Data(json.utf8))
        let track = Track(uri: SpotifyURI("spotify:track:t")!, title: "T", artists: [ArtistSummary(name: "A")],
                          albumTitle: nil, artwork: nil, durationMs: 1000)
        #expect(reply == .mix(requestID: 7, RadioMix(contextURI: SpotifyURI("spotify:playlist:m")!, tracks: [track])))
        #expect(reply.requestID == 7)
    }

    @Test func decodesFailuresAndFoldsUnknownReasonsIntoUnavailable() throws {
        let known = #"{"type":"radioFailed","requestID":8,"seedURI":"spotify:track:t","reason":"noTopTrack"}"#
        #expect(try JSONDecoder().decode(RadioReply.self, from: Data(known.utf8)) == .failed(requestID: 8, .noTopTrack))
        let unknown = #"{"type":"radioFailed","requestID":9,"seedURI":"spotify:track:t","reason":"somethingNew"}"#
        #expect(try JSONDecoder().decode(RadioReply.self, from: Data(unknown.utf8)) == .failed(requestID: 9, .unavailable))
    }
}
```

- [ ] **Step 2: Run them to verify they fail**

Run: `swift test --package-path Packages/BopifyCore --scratch-path /private/tmp/bopify-library-tabs-tests --filter RadioReply`
Expected: compile error, because `RadioReply` cannot be found in scope.

- [ ] **Step 3: Add the domain types**

In `PlaybackEvent.swift`, change `private static func decodeTrack(from decoder: any Decoder) throws -> Track {` to `static func decodeTrack(from decoder: any Decoder) throws -> Track {`. Leave `decodeRemote` as it is.

Create `Packages/BopifyCore/Sources/BopifyDomain/RadioMix.swift`:

```swift
import Foundation

/// Spotify's radio mix for a seed track or artist.
public struct RadioMix: Hashable, Sendable {
    public let contextURI: SpotifyURI
    public let tracks: [Track]

    public init(contextURI: SpotifyURI, tracks: [Track]) {
        self.contextURI = contextURI
        self.tracks = tracks
    }
}

/// Why a station could not be built; raw values are the Rust wire reasons.
public enum RadioFailure: String, Error, Hashable, Sendable {
    case noTopTrack, noMix, unavailable, network
}

/// The engine's answer to one radio request, matched to its caller by `requestID`.
public enum RadioReply: Hashable, Sendable {
    case mix(requestID: UInt64, RadioMix)
    case failed(requestID: UInt64, RadioFailure)

    /// Event types that carry a reply rather than playback state.
    public static let eventTypes: Set<String> = ["radio", "radioFailed"]

    public var requestID: UInt64 {
        switch self {
        case let .mix(id, _): id
        case let .failed(id, _): id
        }
    }
}

extension RadioReply: Decodable {
    private enum CodingKeys: String, CodingKey { case type, requestID, contextURI, tracks, reason }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let id = try c.decode(UInt64.self, forKey: .requestID)
        switch try c.decode(String.self, forKey: .type) {
        case "radio":
            guard let context = SpotifyURI(try c.decode(String.self, forKey: .contextURI)) else {
                throw DecodingError.dataCorruptedError(forKey: .contextURI, in: c, debugDescription: "malformed Spotify URI")
            }
            var list = try c.nestedUnkeyedContainer(forKey: .tracks)
            var tracks: [Track] = []
            while !list.isAtEnd { tracks.append(try PlaybackEvent.decodeTrack(from: try list.superDecoder())) }
            self = .mix(requestID: id, RadioMix(contextURI: context, tracks: tracks))
        case "radioFailed":
            // A reason added on the Rust side must still fail the request rather than strand it.
            self = .failed(requestID: id, RadioFailure(rawValue: try c.decode(String.self, forKey: .reason)) ?? .unavailable)
        case let other:
            throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "not a radio reply: \(other)")
        }
    }
}
```

In `PlaybackEngine.swift`, add the following as the last requirement of `protocol PlaybackEngine`:

```swift
    /// Spotify's radio for a track or artist seed. Throws `RadioFailure` when Spotify has none.
    func requestRadio(seed: SpotifyURI) async throws -> RadioMix
```

- [ ] **Step 4: Write the failing bridge tests**

Append to `Packages/BopifyCore/Tests/PlaybackTests/EventBridgeTests.swift`:

```swift
/// Pushes payloads in order from one Rust-like background thread.
private func push(_ payloads: [String], into bridge: EventBridge) {
    let encoded = payloads.map { Array($0.utf8) }
    Thread.detachNewThread {
        let ctx = bridge.retainedContext()
        defer { EventBridge.releaseContext(ctx) }
        for json in encoded {
            json.withUnsafeBufferPointer { bopifyEventTrampoline($0.baseAddress!, UInt($0.count), ctx) }
        }
    }
}

private func mixJSON(_ id: UInt64) -> String {
    #"{"type":"radio","requestID":\#(id),"seedURI":"spotify:track:s","contextURI":"spotify:playlist:m","tracks":[{"trackUri":"spotify:track:a","title":"A","artists":["X"],"albumTitle":null,"artworkUrl":null,"durationMs":1000}]}"#
}

@Suite("EventBridge radio")
struct EventBridgeRadioTests {
    @Test func aReplyResumesTheRequestWithItsID() async throws {
        let bridge = EventBridge()
        let mix = try await bridge.radio { id in push([mixJSON(id)], into: bridge) }
        #expect(mix.contextURI.rawValue == "spotify:playlist:m")
        #expect(mix.tracks.map(\.uri.rawValue) == ["spotify:track:a"])
    }

    @Test func aFailedReplyThrowsItsReason() async {
        let bridge = EventBridge()
        await #expect(throws: RadioFailure.noMix) {
            _ = try await bridge.radio { id in
                push([#"{"type":"radioFailed","requestID":\#(id),"seedURI":"spotify:track:s","reason":"noMix"}"#], into: bridge)
            }
        }
    }

    @Test func aRejectedSendThrowsWithoutWaiting() async {
        let bridge = EventBridge()
        await #expect(throws: PlayerError.playbackSessionLost) {
            _ = try await bridge.radio { _ in throw PlayerError.playbackSessionLost }
        }
    }

    @Test func finishFailsRequestsStillWaiting() async {
        let bridge = EventBridge()
        let waiting = Task { try await bridge.radio { _ in } }
        try? await Task.sleep(for: .milliseconds(20))
        bridge.finish()
        await #expect(throws: PlayerError.playbackSessionLost) { _ = try await waiting.value }
    }

    @Test func cancellingTheCallerStopsItsWait() async {
        let bridge = EventBridge()
        let waiting = Task { try await bridge.radio { _ in } }
        try? await Task.sleep(for: .milliseconds(20))
        waiting.cancel()
        await #expect(throws: CancellationError.self) { _ = try await waiting.value }
    }

    @Test func radioRepliesNeverReachThePlaybackStream() async {
        let bridge = EventBridge()
        push([mixJSON(999), #"{"type":"endOfTrack"}"#], into: bridge)
        var iterator = bridge.events.makeAsyncIterator()
        #expect(await iterator.next() == .endOfTrack)
    }
}
```

- [ ] **Step 5: Run them to verify they fail**

Run: `swift test --package-path Packages/BopifyCore --scratch-path /private/tmp/bopify-library-tabs-tests --filter EventBridge`
Expected: compile error. `EventBridge` has no member `radio`, and the conformers lack `requestRadio`.

- [ ] **Step 6: Implement the bridge correlation**

In `EventBridge.swift`, add `import os` below `import BopifyDomain`. Add these stored properties after `private let continuation`:

```swift
    private let radioWaiters = OSAllocatedUnfairLock(initialState: RadioWaiters())

    private struct RadioWaiters: Sendable {
        var lastID: UInt64 = 0
        var waiting: [UInt64: CheckedContinuation<RadioMix, any Error>] = [:]
        var finished = false
    }

    private struct Envelope: Decodable {
        let type: String
        let requestID: UInt64?
    }
```

Add these methods after `retainedContext()`:

```swift
    /// Sends one radio request and waits for the reply that carries its ID.
    ///
    /// The waiter is registered before `send` runs: the reply can arrive on a
    /// Rust thread before `send` has even returned.
    func radio(_ send: (UInt64) throws -> Void) async throws -> RadioMix {
        let id = radioWaiters.withLock { state in
            state.lastID += 1
            return state.lastID
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let registered = radioWaiters.withLock { state in
                    guard !state.finished else { return false }
                    state.waiting[id] = continuation
                    return true
                }
                guard registered else { return continuation.resume(throwing: PlayerError.playbackSessionLost) }
                if Task.isCancelled { return resolveRadio(id, with: .failure(CancellationError())) }
                do { try send(id) } catch { resolveRadio(id, with: .failure(error)) }
            }
        } onCancel: {
            resolveRadio(id, with: .failure(CancellationError()))
        }
    }

    /// Resumes a waiter at most once; a reply for an ID nobody waits on is dropped.
    private func resolveRadio(_ id: UInt64, with result: Result<RadioMix, any Error>) {
        radioWaiters.withLock { $0.waiting.removeValue(forKey: id) }?.resume(with: result)
    }

    private func deliverRadio(_ data: Data, requestID: UInt64?) {
        guard let reply = try? JSONDecoder().decode(RadioReply.self, from: data) else {
            BopifyLog.playback.error("radio reply decode failed")
            if let requestID { resolveRadio(requestID, with: .failure(RadioFailure.unavailable)) }
            return
        }
        switch reply {
        case let .mix(id, mix): resolveRadio(id, with: .success(mix))
        case let .failed(id, reason): resolveRadio(id, with: .failure(reason))
        }
    }
```

In `yield(rawJSON:)`, insert the following right after `let data = Data(bytes: base, count: rawJSON.count)`:

```swift
        // Radio replies answer one caller; the playback stream never sees them.
        if let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
           RadioReply.eventTypes.contains(envelope.type) {
            deliverRadio(data, requestID: envelope.requestID)
            return
        }
```

Replace `public func finish() { continuation.finish() }` with:

```swift
    public func finish() {
        continuation.finish()
        let waiting = radioWaiters.withLock { state in
            state.finished = true
            defer { state.waiting = [:] }
            return Array(state.waiting.values)
        }
        for waiter in waiting { waiter.resume(throwing: PlayerError.playbackSessionLost) }
    }
```

Update the doc comment above `finish()` to read: "Ends the stream for its consumer and fails any radio request still waiting. Idempotent, and independent of the engine: events yielded after it are dropped, not delivered."

- [ ] **Step 7: Implement the engine call and update the test conformers**

In `LibrespotEngine.swift`, add the following after `load(_:)`:

```swift
    @concurrent
    public func requestRadio(seed: SpotifyURI) async throws -> RadioMix {
        let raw = seed.rawValue
        return try await bridge.radio { id in
            try perform("requestRadio") { raw.withCString { bopify_request_radio(handle, $0, id) } }
        }
    }
```

In `StubPlaybackEngine.swift`, add the following after `setRepeat`:

```swift
    public func requestRadio(seed: SpotifyURI) async throws -> RadioMix {
        record("radio:\(seed.rawValue)")
        throw RadioFailure.unavailable
    }
```

In `PlayerModelTests.swift`, add `func requestRadio(seed: SpotifyURI) async throws -> RadioMix { throw RadioFailure.unavailable }` inside `FailingSelectionEngine`. Add the same line inside `ControlledVolumeEngine` in `PlayerVolumeTests.swift`.

- [ ] **Step 8: Run the whole package suite**

Run: `swift test --package-path Packages/BopifyCore --scratch-path /private/tmp/bopify-library-tabs-tests`
Expected: everything passes, including the 2 `RadioReply` and 6 `EventBridge radio` tests.

- [ ] **Step 9: Commit**

```bash
git add Packages/BopifyCore/Sources/BopifyDomain/RadioMix.swift Packages/BopifyCore/Sources/BopifyDomain/PlaybackEvent.swift \
        Packages/BopifyCore/Sources/BopifyDomain/PlaybackEngine.swift Packages/BopifyCore/Sources/BopifyPlayback/EventBridge.swift \
        Packages/BopifyCore/Sources/BopifyPlayback/LibrespotEngine.swift Packages/BopifyCore/Tests/DomainTests/RadioReplyTests.swift \
        Packages/BopifyCore/Tests/PlaybackTests/EventBridgeTests.swift Packages/BopifyCore/Tests/PlaybackTests/StubPlaybackEngine.swift \
        Packages/BopifyCore/Tests/PlaybackTests/PlayerModelTests.swift Packages/BopifyCore/Tests/PlaybackTests/PlayerVolumeTests.swift
git commit -m "Request radio mixes from Swift and match replies by ID" -m "The playback stream has a single consumer, so a station reply cannot ride on it. The bridge takes radio events off the stream and resumes the caller waiting on that request ID, failing every waiter when the engine shuts down."
```

---

### Task 4: Recently played and top items from the Web API

**Files:**
- Create: `Packages/BopifyCore/Sources/BopifyDomain/ListeningHistoryService.swift`
- Modify: `Packages/BopifyCore/Sources/BopifyLibrary/SpotifyLibraryClient.swift`
- Modify: `Packages/BopifyCore/Sources/BopifyAuth/SpotifyAuthService.swift:54`
- Test: `Packages/BopifyCore/Tests/LibraryTests/SpotifyLibraryClientTests.swift`, `Packages/BopifyCore/Tests/AuthTests/SpotifyAuthServiceTests.swift`

**Interfaces:**
- Consumes: `SpotifyLibraryClient`'s private `request(method:path:query:scope:)`, `SavedTrack.domain`.
- Produces:
  - `public struct RecentPlay: Hashable, Sendable { track: Track; contextURI: SpotifyURI? }`.
  - `public struct StationSeed: Hashable, Sendable, Identifiable { uri: SpotifyURI; name: String; isArtist: Bool }`, with `init(uri:name:)`.
  - `public enum TopItemKind: String, Sendable { case tracks, artists }`.
  - `public protocol ListeningHistoryService: Sendable`, with `recentlyPlayed() async throws -> [RecentPlay]` and `topItems(_ kind: TopItemKind) async throws -> [StationSeed]`.
  - `SpotifyLibraryClient` conforms to `ListeningHistoryService`.
  - `authorizeLibraryScopes` accepts `user-read-recently-played` and `user-top-read`.

- [ ] **Step 1: Write the failing client tests**

Append inside `struct SpotifyLibraryClientTests`:

```swift
    private func scopedClient(_ expected: Set<String>) -> SpotifyLibraryClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LibraryProtocol.self]
        return SpotifyLibraryClient(session: URLSession(configuration: configuration)) { required in
            #expect(required == expected)
            return "TEST_TOKEN"
        }
    }
    private func query(_ request: URLRequest?) -> [URLQueryItem]? {
        request?.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems }
    }
    @Test func recentlyPlayedKeepsLoadableContextsAndSkipsBadItems() async throws {
        var album = savedTrack("a")
        album["context"] = ["uri": "spotify:album:alb", "type": "album"]
        var collection = savedTrack("b")
        collection["context"] = ["uri": "spotify:user:someone:collection", "type": "collection"]
        var none = savedTrack("c")
        none["context"] = NSNull()
        let body = try JSONSerialization.data(withJSONObject: ["items": [album, collection, ["track": NSNull()], none]])
        LibraryProtocol.fixture.reset(.init(data: body))
        let plays = try await scopedClient(["user-read-recently-played"]).recentlyPlayed()
        #expect(plays.map(\.track.uri.rawValue) == ["spotify:track:a", "spotify:track:b", "spotify:track:c"])
        #expect(plays.map(\.contextURI?.rawValue) == ["spotify:album:alb", nil, nil])
        let request = LibraryProtocol.fixture.requests.first
        #expect(request?.url?.path == "/v1/me/player/recently-played")
        #expect(query(request) == [URLQueryItem(name: "limit", value: "50")])
    }
    @Test func topItemsAskForFiveMediumTermItemsWithTheTopReadScope() async throws {
        let tracks = try JSONSerialization.data(withJSONObject: ["items": [savedTrack("t")["track"]!, ["uri": 1]]])
        LibraryProtocol.fixture.reset(.init(data: tracks))
        let client = scopedClient(["user-top-read"])
        #expect(try await client.topItems(.tracks) == [StationSeed(uri: SpotifyURI("spotify:track:t")!, name: "Song t")])
        #expect(LibraryProtocol.fixture.requests.first?.url?.path == "/v1/me/top/tracks")
        #expect(query(LibraryProtocol.fixture.requests.first) == [
            URLQueryItem(name: "time_range", value: "medium_term"), URLQueryItem(name: "limit", value: "5")])
        let artists = try JSONSerialization.data(withJSONObject: ["items": [
            ["uri": "spotify:artist:ar", "name": "Artist"], ["uri": "spotify:track:notAnArtist", "name": "X"], ["uri": "spotify:artist:blank", "name": ""]]])
        LibraryProtocol.fixture.reset(.init(data: artists))
        let seeds = try await client.topItems(.artists)
        #expect(seeds == [StationSeed(uri: SpotifyURI("spotify:artist:ar")!, name: "Artist")])
        #expect(seeds.first?.isArtist == true)
        #expect(LibraryProtocol.fixture.requests.first?.url?.path == "/v1/me/top/artists")
    }
    @Test func historyRequestsShareTheLibraryCooldown() async {
        LibraryProtocol.fixture.reset(.init(status: 429, headers: ["Retry-After": "30"]))
        let client = client()
        await #expect(throws: LibraryError.rateLimited(retryAfterSeconds: 30)) { _ = try await client.recentlyPlayed() }
        await #expect(throws: LibraryError.rateLimited(retryAfterSeconds: 30)) { _ = try await client.topItems(.artists) }
        await #expect(throws: LibraryError.rateLimited(retryAfterSeconds: 30)) { _ = try await client.savedTracks(offset: 0, limit: 50) }
        #expect(LibraryProtocol.fixture.requests.count == 1)
    }
    @Test func malformedHistoryResponsesAreInvalid() async {
        LibraryProtocol.fixture.reset(.init(data: Data("{}".utf8)))
        await #expect(throws: LibraryError.invalidResponse) { _ = try await client().recentlyPlayed() }
        await #expect(throws: LibraryError.invalidResponse) { _ = try await client().topItems(.tracks) }
    }
```

Append inside `struct SpotifyAuthServiceTests`:

```swift
    @Test func listeningHistoryConsentWidensTheLibraryGrant() async throws {
        let widened = #"{"access_token":"WIDE","token_type":"Bearer","expires_in":3600,"refresh_token":"RT","scope":"user-library-read user-read-recently-played user-top-read"}"#
        AuthFlowStubProtocol.handler = { _ in (200, Data(widened.utf8)) }
        let store = InMemoryTokenStore()
        try store.save(TokenSet(accessToken: "OLD", refreshToken: "RT", expiresAt: Date().addingTimeInterval(3600), grantedScopes: ["user-library-read"]))
        let service = SpotifyAuthService(clientID: "dashboard", client: makeClient(), store: store, openURL: { url in
            let query = Dictionary(uniqueKeysWithValues: URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value ?? "") })
            #expect(Set(query["scope"]!.split(separator: " ").map(String.init)) == ["user-library-read", "user-read-recently-played", "user-top-read"])
            let callback = URL(string: "\(query["redirect_uri"]!)?code=TESTCODE&state=\(query["state"]!)")!
            Task { _ = try? await URLSession.shared.data(from: callback) }
        })
        let token = try await service.authorizeLibraryScopes(["user-read-recently-played", "user-top-read"])
        #expect(token.grantedScopes == ["user-library-read", "user-read-recently-played", "user-top-read"])
    }
```

- [ ] **Step 2: Run them to verify they fail**

Run: `swift test --package-path Packages/BopifyCore --scratch-path /private/tmp/bopify-library-tabs-tests --filter "SpotifyLibraryClient|SpotifyAuthService"`
Expected: compile errors, because `recentlyPlayed`, `topItems` and `StationSeed` are not defined.

- [ ] **Step 3: Add the domain types**

Create `Packages/BopifyCore/Sources/BopifyDomain/ListeningHistoryService.swift`:

```swift
/// One play from the user's recently played list, newest first.
public struct RecentPlay: Hashable, Sendable {
    public let track: Track
    /// What the track was played from, when Spotify says and the URI is one Bopify can load.
    public let contextURI: SpotifyURI?

    public init(track: Track, contextURI: SpotifyURI?) {
        self.track = track
        self.contextURI = contextURI
    }
}

/// A station seed: a top track, a top artist, or a liked song when Spotify has no top items.
public struct StationSeed: Hashable, Sendable, Identifiable {
    public let uri: SpotifyURI
    public let name: String
    public var id: SpotifyURI { uri }
    public var isArtist: Bool { uri.kind == .artist }

    public init(uri: SpotifyURI, name: String) {
        self.uri = uri
        self.name = name
    }
}

public enum TopItemKind: String, Sendable {
    case tracks, artists
}

public protocol ListeningHistoryService: Sendable {
    func recentlyPlayed() async throws -> [RecentPlay]
    func topItems(_ kind: TopItemKind) async throws -> [StationSeed]
}
```

- [ ] **Step 4: Implement the client calls**

In `SpotifyLibraryClient.swift`, change the declaration to `public struct SpotifyLibraryClient: LibraryService, SavedTracksService, ListeningHistoryService {`. Add these methods after `savedTracks(offset:limit:)`:

```swift
    public func recentlyPlayed() async throws -> [RecentPlay] {
        let data = try await request(method: "GET", path: "/v1/me/player/recently-played",
                                     query: [URLQueryItem(name: "limit", value: "50")], scope: "user-read-recently-played")
        guard let page = try? JSONDecoder().decode(RecentPage.self, from: data) else { throw LibraryError.invalidResponse }
        return page.items.compactMap { item in
            item.track?.domain.map { RecentPlay(track: $0, contextURI: item.loadableContext) }
        }
    }

    public func topItems(_ kind: TopItemKind) async throws -> [StationSeed] {
        let data = try await request(method: "GET", path: "/v1/me/top/\(kind.rawValue)", query: [
            URLQueryItem(name: "time_range", value: "medium_term"), URLQueryItem(name: "limit", value: "5")
        ], scope: "user-top-read")
        switch kind {
        case .tracks:
            guard let page = try? JSONDecoder().decode(TopPage<SavedTrack>.self, from: data) else { throw LibraryError.invalidResponse }
            return page.items.compactMap { $0.value?.domain }.map { StationSeed(uri: $0.uri, name: $0.title) }
        case .artists:
            guard let page = try? JSONDecoder().decode(TopPage<TopArtist>.self, from: data) else { throw LibraryError.invalidResponse }
            return page.items.compactMap { $0.value?.seed }
        }
    }
```

Add these private types at the end of the file:

```swift
private struct RecentPage: Decodable { let items: [RecentItem] }

private struct RecentItem: Decodable {
    struct Context: Decodable { let uri: String }
    let track: SavedTrack?
    let context: Context?
    private enum CodingKeys: String, CodingKey { case track, context }
    init(from decoder: Decoder) throws {
        let container = try? decoder.container(keyedBy: CodingKeys.self)
        track = try? container?.decode(SavedTrack.self, forKey: .track)
        context = try? container?.decode(Context.self, forKey: .context)
    }
    /// Only contexts the engine can load with a start track; a Liked Songs collection URI is not one.
    var loadableContext: SpotifyURI? {
        guard let uri = context.flatMap({ SpotifyURI($0.uri) }) else { return nil }
        switch uri.kind {
        case .album, .playlist, .artist, .show: return uri
        default: return nil
        }
    }
}

private struct TopPage<Item: Decodable>: Decodable { let items: [Lenient<Item>] }

/// One malformed item must not discard the rest of the page.
private struct Lenient<Value: Decodable>: Decodable {
    let value: Value?
    init(from decoder: Decoder) throws { value = try? Value(from: decoder) }
}

private struct TopArtist: Decodable {
    let uri: String
    let name: String
    var seed: StationSeed? {
        guard let uri = SpotifyURI(uri), uri.kind == .artist, !name.isEmpty else { return nil }
        return StationSeed(uri: uri, name: name)
    }
}
```

In `SpotifyAuthService.swift:54`, change the set to:

```swift
        let libraryScopes: Set<String> = ["user-library-read", "user-library-modify", "user-read-recently-played", "user-top-read"]
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `swift test --package-path Packages/BopifyCore --scratch-path /private/tmp/bopify-library-tabs-tests`
Expected: all pass.

- [ ] **Step 6: Commit**

```bash
git add Packages/BopifyCore/Sources/BopifyDomain/ListeningHistoryService.swift Packages/BopifyCore/Sources/BopifyLibrary/SpotifyLibraryClient.swift \
        Packages/BopifyCore/Sources/BopifyAuth/SpotifyAuthService.swift Packages/BopifyCore/Tests/LibraryTests/SpotifyLibraryClientTests.swift \
        Packages/BopifyCore/Tests/AuthTests/SpotifyAuthServiceTests.swift
git commit -m "Fetch recently played and top items for the library tabs" -m "Recents needs the recently played list with the context each track came from, and Explore seeds its stations from the user's top tracks and artists. Both go through the shared library cooldown, and one consent grants both new scopes."
```

---

### Task 5: `CoverFlowSource` and `RecentsModel`

**Files:**
- Create: `Packages/BopifyCore/Sources/BopifyLibrary/CoverFlowSource.swift`
- Create: `Packages/BopifyCore/Sources/BopifyLibrary/RecentsModel.swift`
- Create: `Packages/BopifyCore/Tests/LibraryTests/LibraryFakes.swift`
- Create: `Packages/BopifyCore/Tests/LibraryTests/RecentsModelTests.swift`
- Test: `Packages/BopifyCore/Tests/LibraryTests/LikedSongsModelTests.swift`

**Interfaces:**
- Consumes: `ListeningHistoryService` and `RecentPlay` (Task 4), `PlayRequest`.
- Produces:
  - `@MainActor public protocol CoverFlowSource: AnyObject, Observable`. Its members:
    - Properties: `tracks: [Track]`, `selectedURI: SpotifyURI?`, `isLoading: Bool`, `error: LibraryError?`, `retryAfter: Date?`, `hasMore: Bool`.
    - Methods: `reveal(at: Date) async`, `hide(at: Date)`, `select(_: SpotifyURI)`, `loadMore() async`, `loadMoreIfNeeded(near: SpotifyURI) async`, `retry(at: Date) async`, `playRequest(for: Track) -> PlayRequest`.
  - `LikedSongsModel: CoverFlowSource`.
  - `RecentsModel(service: any ListeningHistoryService)`: `CoverFlowSource`, plus `refresh() async` and `clear()`.
  - The test fakes `TestClock`, `FakeHistory`, `FakeSavedTracks` and `func testTrack(_ id: String) -> Track`.

- [ ] **Step 1: Write the shared fakes**

Create `Packages/BopifyCore/Tests/LibraryTests/LibraryFakes.swift`:

```swift
import Foundation
import BopifyDomain

func testTrack(_ id: String) -> Track {
    Track(uri: SpotifyURI("spotify:track:\(id)")!, title: "Song \(id)", artists: [], albumTitle: nil, artwork: nil, durationMs: 100_000)
}

final class TestClock: @unchecked Sendable {
    var date = Date(timeIntervalSince1970: 1000)
    func advance(_ seconds: TimeInterval) { date.addTimeInterval(seconds) }
}

actor FakeHistory: ListeningHistoryService {
    private var plays: Result<[RecentPlay], LibraryError> = .success([])
    private var top: [TopItemKind: [StationSeed]] = [:]
    private(set) var recentCalls = 0
    private(set) var topCalls = 0

    func setPlays(_ result: Result<[RecentPlay], LibraryError>) { plays = result }
    func setTop(_ kind: TopItemKind, _ seeds: [StationSeed]) { top[kind] = seeds }

    func recentlyPlayed() async throws -> [RecentPlay] {
        recentCalls += 1
        return try plays.get()
    }
    func topItems(_ kind: TopItemKind) async throws -> [StationSeed] {
        topCalls += 1
        return top[kind] ?? []
    }
}

actor FakeSavedTracks: SavedTracksService {
    private let tracks: [Track]
    private(set) var requests: [[Int]] = []
    init(_ tracks: [Track]) { self.tracks = tracks }
    func savedTracks(offset: Int, limit: Int) async throws -> SavedTracksPage {
        requests.append([offset, limit])
        return SavedTracksPage(tracks: Array(tracks.prefix(limit)), nextOffset: nil, total: tracks.count)
    }
}
```

- [ ] **Step 2: Write the failing tests**

Create `Packages/BopifyCore/Tests/LibraryTests/RecentsModelTests.swift`:

```swift
import Foundation
import Testing
import BopifyDomain
@testable import BopifyLibrary

@Suite("RecentsModel") @MainActor
struct RecentsModelTests {
    private let album = SpotifyURI("spotify:album:alb")!
    private let playlist = SpotifyURI("spotify:playlist:pl")!
    private func play(_ id: String, _ context: SpotifyURI? = nil) -> RecentPlay {
        RecentPlay(track: testTrack(id), contextURI: context)
    }

    @Test func collapsesRepeatsToTheNewestPlayAndItsContext() async {
        let history = FakeHistory()
        await history.setPlays(.success([play("a", album), play("b"), play("a", playlist), play("c")]))
        let model = RecentsModel(service: history)
        await model.reveal(at: Date())
        #expect(model.tracks.map(\.uri.rawValue) == ["spotify:track:a", "spotify:track:b", "spotify:track:c"])
        #expect(model.selectedURI == testTrack("a").uri)
        #expect(model.playRequest(for: testTrack("a")) == PlayRequest(contextURI: album, startTrackURI: testTrack("a").uri))
        #expect(model.playRequest(for: testTrack("b")) == PlayRequest(contextURI: testTrack("b").uri))
    }

    @Test func reloadsAtMostOncePerMinuteAndKeepsAPresentSelection() async {
        let history = FakeHistory()
        let clock = TestClock()
        await history.setPlays(.success([play("a"), play("b")]))
        let model = RecentsModel(service: history, now: { clock.date })
        await model.reveal(at: clock.date)
        model.select(testTrack("b").uri)
        model.hide(at: clock.date)
        clock.advance(59)
        await history.setPlays(.success([play("c"), play("b")]))
        await model.reveal(at: clock.date)
        #expect(await history.recentCalls == 1)
        clock.advance(1)
        await model.reveal(at: clock.date)
        #expect(await history.recentCalls == 2)
        #expect(model.selectedURI == testTrack("b").uri)
        clock.advance(60)
        await history.setPlays(.success([play("c")]))
        await model.reveal(at: clock.date)
        #expect(model.selectedURI == testTrack("c").uri)
    }

    @Test func aRateLimitWaitsForItsDeadline() async {
        let history = FakeHistory()
        let clock = TestClock()
        await history.setPlays(.failure(.rateLimited(retryAfterSeconds: 30)))
        let model = RecentsModel(service: history, now: { clock.date })
        await model.reveal(at: clock.date)
        #expect(model.error == .rateLimited(retryAfterSeconds: 30))
        #expect(model.retryAfter == clock.date.addingTimeInterval(30))
        await model.retry(at: clock.date.addingTimeInterval(10))
        #expect(await history.recentCalls == 1)
        await history.setPlays(.success([play("a")]))
        await model.retry(at: clock.date.addingTimeInterval(30))
        #expect(model.error == nil && model.tracks.count == 1)
    }

    @Test func clearForgetsEverything() async {
        let history = FakeHistory()
        await history.setPlays(.success([play("a", album)]))
        let model = RecentsModel(service: history)
        await model.reveal(at: Date())
        model.clear()
        #expect(model.tracks.isEmpty && model.selectedURI == nil)
        #expect(model.playRequest(for: testTrack("a")) == PlayRequest(contextURI: testTrack("a").uri))
    }
}
```

Append inside `struct LikedSongsModelTests`:

```swift
    @Test func playsALikedSongOnItsOwn() {
        let model = LikedSongsModel(service: ConsentSavedTracks())
        #expect(model.playRequest(for: track(1)) == PlayRequest(contextURI: track(1).uri))
    }
```

- [ ] **Step 3: Run them to verify they fail**

Run: `swift test --package-path Packages/BopifyCore --scratch-path /private/tmp/bopify-library-tabs-tests --filter "RecentsModel|LikedSongsModel"`
Expected: compile errors, because `RecentsModel` and `playRequest` are not defined.

- [ ] **Step 4: Add the protocol and the Liked conformance**

Create `Packages/BopifyCore/Sources/BopifyLibrary/CoverFlowSource.swift`:

```swift
import Foundation
import Observation
import BopifyDomain

/// What Cover Flow renders and drives, whichever library tab supplies it.
@MainActor
public protocol CoverFlowSource: AnyObject, Observable {
    var tracks: [Track] { get }
    var selectedURI: SpotifyURI? { get }
    var isLoading: Bool { get }
    var error: LibraryError? { get }
    var retryAfter: Date? { get }
    var hasMore: Bool { get }
    func reveal(at date: Date) async
    func hide(at date: Date)
    func select(_ uri: SpotifyURI)
    func loadMore() async
    func loadMoreIfNeeded(near uri: SpotifyURI) async
    func retry(at date: Date) async
    func playRequest(for track: Track) -> PlayRequest
}

extension LikedSongsModel: CoverFlowSource {
    /// A liked song plays on its own, as Cover Flow always has.
    public func playRequest(for track: Track) -> PlayRequest { PlayRequest(contextURI: track.uri) }
}
```

- [ ] **Step 5: Implement `RecentsModel`**

Create `Packages/BopifyCore/Sources/BopifyLibrary/RecentsModel.swift`:

```swift
import Foundation
import Observation
import os
import BopifyDomain

/// Recently played tracks, newest first with repeats collapsed to their newest play.
@MainActor @Observable
public final class RecentsModel: CoverFlowSource {
    public private(set) var tracks: [Track] = []
    public private(set) var selectedURI: SpotifyURI?
    public private(set) var isLoading = false
    public private(set) var error: LibraryError?
    public private(set) var retryAfter: Date?
    public var hasMore: Bool { false }
    @ObservationIgnored private let service: any ListeningHistoryService
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var contexts: [SpotifyURI: SpotifyURI] = [:]
    @ObservationIgnored private var loadedAt: Date?
    @ObservationIgnored private var visible = false
    @ObservationIgnored private var generation = 0

    public convenience init(service: any ListeningHistoryService) { self.init(service: service, now: Date.init) }
    init(service: any ListeningHistoryService, now: @escaping () -> Date) {
        self.service = service
        self.now = now
    }

    public func reveal(at date: Date) async {
        visible = true
        guard !isLoading, retryAfter.map({ $0 <= date }) ?? true else { return }
        if error == nil, let loadedAt, date.timeIntervalSince(loadedAt) < 60 {
            BopifyLog.library.debug("recents cache hit")
            return
        }
        await load()
    }

    public func hide(at date: Date) { visible = false }

    public func select(_ uri: SpotifyURI) {
        guard tracks.contains(where: { $0.uri == uri }) else { return }
        selectedURI = uri
    }

    public func loadMore() async {}
    public func loadMoreIfNeeded(near uri: SpotifyURI) async {}

    public func retry(at date: Date) async {
        guard visible, !isLoading, error != nil, retryAfter.map({ $0 <= date }) ?? true else { return }
        await load()
    }

    /// After consent: reloads now when shown, otherwise on the next reveal.
    public func refresh() async {
        loadedAt = nil
        guard visible, !isLoading else { return }
        await load()
    }

    public func clear() {
        generation += 1
        tracks = []
        selectedURI = nil
        contexts = [:]
        loadedAt = nil
        isLoading = false
        error = nil
        retryAfter = nil
        visible = false
        BopifyLog.library.debug("recents cleared")
    }

    /// Plays from the context Spotify reported for that play, else the track alone.
    public func playRequest(for track: Track) -> PlayRequest {
        guard let context = contexts[track.uri] else { return PlayRequest(contextURI: track.uri) }
        return PlayRequest(contextURI: context, startTrackURI: track.uri)
    }

    private func load() async {
        generation += 1
        let current = generation
        isLoading = true
        error = nil
        retryAfter = nil
        defer { if generation == current { isLoading = false } }
        BopifyLog.library.debug("recents cache miss, loading")
        do {
            let plays = try await service.recentlyPlayed()
            guard generation == current, !Task.isCancelled else { return }
            var seen = Set<SpotifyURI>()
            let newest = plays.filter { seen.insert($0.track.uri).inserted }
            contexts = Dictionary(uniqueKeysWithValues: newest.compactMap { play in play.contextURI.map { (play.track.uri, $0) } })
            tracks = newest.map(\.track)
            if !tracks.contains(where: { $0.uri == selectedURI }) { selectedURI = tracks.first?.uri }
            loadedAt = now()
            BopifyLog.library.debug("recents ready count=\(self.tracks.count, privacy: .public)")
        } catch {
            guard generation == current, !Task.isCancelled else { return }
            let failure = error as? LibraryError ?? .unavailable
            self.error = failure
            switch failure {
            case let .rateLimited(seconds), let .quotaExceeded(seconds):
                retryAfter = now().addingTimeInterval(TimeInterval(seconds ?? 60))
            default: break
            }
            BopifyLog.library.notice("recents request failed")
        }
    }
}
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `swift test --package-path Packages/BopifyCore --scratch-path /private/tmp/bopify-library-tabs-tests`
Expected: all pass, including 4 `RecentsModel` tests and `playsALikedSongOnItsOwn`.

- [ ] **Step 7: Commit**

```bash
git add Packages/BopifyCore/Sources/BopifyLibrary/CoverFlowSource.swift Packages/BopifyCore/Sources/BopifyLibrary/RecentsModel.swift \
        Packages/BopifyCore/Tests/LibraryTests/LibraryFakes.swift Packages/BopifyCore/Tests/LibraryTests/RecentsModelTests.swift \
        Packages/BopifyCore/Tests/LibraryTests/LikedSongsModelTests.swift
git commit -m "Model Recents as a Cover Flow source" -m "Cover Flow needs one shape for every tab, so a protocol captures what it reads and drives, and Liked Songs adopts it unchanged. Recents collapses repeat plays, replays from the context Spotify reported, and reloads at most once a minute."
```

---

### Task 6: `ExploreModel`

**Files:**
- Create: `Packages/BopifyCore/Sources/BopifyLibrary/ExploreModel.swift`
- Create: `Packages/BopifyCore/Tests/LibraryTests/ExploreModelTests.swift`

**Interfaces:**
- Consumes:
  - `CoverFlowSource`, `FakeHistory`, `FakeSavedTracks`, `TestClock` and `testTrack` (Task 5).
  - `StationSeed`, `ListeningHistoryService` (Task 4).
  - `RadioMix`, `RadioFailure` (Task 3).
- Produces:
  - The initializer `ExploreModel(history: any ListeningHistoryService, savedTracks: any SavedTracksService, radio: @escaping @MainActor (SpotifyURI) async throws -> RadioMix)`.
  - Conformance to `CoverFlowSource`.
  - Properties: `chips: [StationSeed]`, `selectedSeed: SpotifyURI?`, `stationFailures: [SpotifyURI: RadioFailure]`, `stationFailure: RadioFailure?`.
  - Methods: `selectChip(_: SpotifyURI) async`, `retryStation() async`, `refresh() async`, `clear()`.

- [ ] **Step 1: Write the failing tests**

Create `Packages/BopifyCore/Tests/LibraryTests/ExploreModelTests.swift`:

```swift
import Foundation
import Testing
import BopifyDomain
@testable import BopifyLibrary

@MainActor
private final class FakeRadio {
    var results: [SpotifyURI: Result<RadioMix, RadioFailure>] = [:]
    var holding: Set<SpotifyURI> = []
    private(set) var requests: [SpotifyURI] = []
    private var held: [SpotifyURI: CheckedContinuation<Void, Never>] = [:]

    func request(_ seed: SpotifyURI) async throws -> RadioMix {
        requests.append(seed)
        if holding.contains(seed) { await withCheckedContinuation { held[seed] = $0 } }
        return try (results[seed] ?? .failure(.noMix)).get()
    }
    func release(_ seed: SpotifyURI) { held.removeValue(forKey: seed)?.resume() }
    func waitUntilHeld(_ seed: SpotifyURI) async { while held[seed] == nil { await Task.yield() } }
}

@Suite("ExploreModel") @MainActor
struct ExploreModelTests {
    private func seed(_ kind: String, _ id: String) -> StationSeed {
        StationSeed(uri: SpotifyURI("spotify:\(kind):\(id)")!, name: id)
    }
    private func mix(_ id: String, _ tracks: [String]) -> RadioMix {
        RadioMix(contextURI: SpotifyURI("spotify:playlist:\(id)")!, tracks: tracks.map(testTrack))
    }
    private func model(_ history: FakeHistory, _ radio: FakeRadio, liked: [Track] = [], clock: TestClock = TestClock()) -> ExploreModel {
        ExploreModel(history: history, savedTracks: FakeSavedTracks(liked), radio: { try await radio.request($0) }, now: { clock.date })
    }

    @Test func interleavesTopTracksAndArtistsAndCapsAtTen() async {
        let history = FakeHistory()
        await history.setTop(.tracks, (1...6).map { seed("track", "t\($0)") })
        await history.setTop(.artists, (1...6).map { seed("artist", "a\($0)") })
        let explore = model(history, FakeRadio())
        await explore.reveal(at: Date())
        #expect(explore.chips.map(\.name) == ["t1", "a1", "t2", "a2", "t3", "a3", "t4", "a4", "t5", "a5"])
        #expect(explore.selectedSeed == seed("track", "t1").uri)
    }

    @Test func fallsBackToTheFiveNewestLikedSongs() async {
        let liked = (1...8).map { testTrack("l\($0)") }
        let saved = FakeSavedTracks(liked)
        let explore = ExploreModel(history: FakeHistory(), savedTracks: saved, radio: { _ in throw RadioFailure.noMix }, now: Date.init)
        await explore.reveal(at: Date())
        #expect(explore.chips.map(\.uri) == liked.prefix(5).map(\.uri))
        #expect(await saved.requests == [[0, 5]])
    }

    @Test func keepsChipsForSixHours() async {
        let history = FakeHistory()
        let clock = TestClock()
        await history.setTop(.tracks, [seed("track", "t1")])
        let explore = model(history, FakeRadio(), clock: clock)
        await explore.reveal(at: clock.date)
        #expect(await history.topCalls == 2)
        explore.hide(at: clock.date)
        await explore.reveal(at: clock.date.addingTimeInterval(6 * 60 * 60 - 1))
        #expect(await history.topCalls == 2)
        await explore.reveal(at: clock.date.addingTimeInterval(6 * 60 * 60))
        #expect(await history.topCalls == 4)
    }

    @Test func requestsEachStationOnceAndPlaysFromTheMix() async {
        let history = FakeHistory()
        let a = seed("track", "a"), b = seed("artist", "b")
        await history.setTop(.tracks, [a])
        await history.setTop(.artists, [b])
        let radio = FakeRadio()
        radio.results = [a.uri: .success(mix("ma", ["x", "y"])), b.uri: .success(mix("mb", ["z"]))]
        let explore = model(history, radio)
        await explore.reveal(at: Date())
        #expect(explore.tracks.map(\.uri) == [testTrack("x").uri, testTrack("y").uri])
        explore.select(testTrack("y").uri)
        await explore.selectChip(b.uri)
        #expect(explore.tracks.map(\.uri) == [testTrack("z").uri])
        await explore.selectChip(a.uri)
        #expect(explore.selectedURI == testTrack("y").uri)
        #expect(radio.requests == [a.uri, b.uri])
        #expect(explore.playRequest(for: testTrack("y")) ==
                PlayRequest(contextURI: SpotifyURI("spotify:playlist:ma")!, startTrackURI: testTrack("y").uri))
    }

    @Test func dropsAStationThatArrivesAfterAnotherChipWasChosen() async {
        let history = FakeHistory()
        let a = seed("track", "a"), b = seed("track", "b")
        await history.setTop(.tracks, [a, b])
        let radio = FakeRadio()
        radio.results = [a.uri: .success(mix("ma", ["x"])), b.uri: .success(mix("mb", ["z"]))]
        radio.holding = [a.uri]
        let explore = model(history, radio)
        let opening = Task { await explore.reveal(at: Date()) }
        await radio.waitUntilHeld(a.uri)
        await explore.selectChip(b.uri)
        radio.release(a.uri)
        await opening.value
        #expect(explore.selectedSeed == b.uri)
        #expect(explore.tracks.map(\.uri) == [testTrack("z").uri])
        radio.holding = []
        await explore.selectChip(a.uri)
        #expect(radio.requests == [a.uri, b.uri, a.uri])
    }

    @Test func aFailingStationLeavesOtherChipsWorkingUntilRetried() async {
        let history = FakeHistory()
        let a = seed("track", "a"), b = seed("track", "b")
        await history.setTop(.tracks, [a, b])
        let radio = FakeRadio()
        radio.results = [a.uri: .failure(.unavailable), b.uri: .success(mix("mb", ["z"]))]
        let explore = model(history, radio)
        await explore.reveal(at: Date())
        #expect(explore.stationFailure == .unavailable && explore.tracks.isEmpty)
        await explore.selectChip(b.uri)
        #expect(explore.stationFailure == nil && explore.tracks.count == 1)
        await explore.selectChip(a.uri)
        #expect(explore.stationFailure == .unavailable)
        #expect(radio.requests == [a.uri, b.uri])
        radio.results[a.uri] = .success(mix("ma", ["x"]))
        await explore.retryStation()
        #expect(explore.stationFailure == nil && explore.tracks.map(\.uri) == [testTrack("x").uri])
    }
}
```

- [ ] **Step 2: Run them to verify they fail**

Run: `swift test --package-path Packages/BopifyCore --scratch-path /private/tmp/bopify-library-tabs-tests --filter ExploreModel`
Expected: compile error, because `ExploreModel` is not found.

- [ ] **Step 3: Implement `ExploreModel`**

Create `Packages/BopifyCore/Sources/BopifyLibrary/ExploreModel.swift`:

```swift
import Foundation
import Observation
import os
import BopifyDomain

/// Station chips seeded from the user's top tracks and artists; each opens Spotify's radio mix for its seed.
@MainActor @Observable
public final class ExploreModel: CoverFlowSource {
    public private(set) var chips: [StationSeed] = []
    public private(set) var selectedSeed: SpotifyURI?
    public private(set) var stationFailures: [SpotifyURI: RadioFailure] = [:]
    public private(set) var error: LibraryError?
    public private(set) var retryAfter: Date?
    private var isLoadingChips = false
    private var loadingSeed: SpotifyURI?
    private var mixes: [SpotifyURI: RadioMix] = [:]
    private var selections: [SpotifyURI: SpotifyURI] = [:]
    @ObservationIgnored private let history: any ListeningHistoryService
    @ObservationIgnored private let savedTracks: any SavedTracksService
    @ObservationIgnored private let radio: @MainActor (SpotifyURI) async throws -> RadioMix
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var chipsLoadedAt: Date?
    @ObservationIgnored private var visible = false
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var station: Task<Void, Never>?

    public var isLoading: Bool { isLoadingChips || loadingSeed != nil }
    public var hasMore: Bool { false }
    public var tracks: [Track] { selectedSeed.flatMap { mixes[$0]?.tracks } ?? [] }
    public var selectedURI: SpotifyURI? { selectedSeed.flatMap { selections[$0] } }
    public var stationFailure: RadioFailure? { selectedSeed.flatMap { stationFailures[$0] } }

    public convenience init(history: any ListeningHistoryService, savedTracks: any SavedTracksService,
                            radio: @escaping @MainActor (SpotifyURI) async throws -> RadioMix) {
        self.init(history: history, savedTracks: savedTracks, radio: radio, now: Date.init)
    }
    init(history: any ListeningHistoryService, savedTracks: any SavedTracksService,
         radio: @escaping @MainActor (SpotifyURI) async throws -> RadioMix, now: @escaping () -> Date) {
        self.history = history
        self.savedTracks = savedTracks
        self.radio = radio
        self.now = now
    }

    public func reveal(at date: Date) async {
        visible = true
        guard !isLoadingChips, retryAfter.map({ $0 <= date }) ?? true else { return }
        if error == nil, let chipsLoadedAt, date.timeIntervalSince(chipsLoadedAt) < 6 * 60 * 60 {
            BopifyLog.library.debug("explore chips cache hit")
            await openSelectedStation()
            return
        }
        await loadChips()
    }

    public func hide(at date: Date) { visible = false }

    public func select(_ uri: SpotifyURI) {
        guard let seed = selectedSeed, tracks.contains(where: { $0.uri == uri }) else { return }
        selections[seed] = uri
    }

    public func selectChip(_ seed: SpotifyURI) async {
        guard seed != selectedSeed, chips.contains(where: { $0.uri == seed }) else { return }
        selectedSeed = seed
        BopifyLog.library.debug("explore chip selected")
        await openSelectedStation()
    }

    public func retryStation() async {
        guard let seed = selectedSeed, stationFailures[seed] != nil else { return }
        stationFailures[seed] = nil
        await openSelectedStation()
    }

    public func loadMore() async {}
    public func loadMoreIfNeeded(near uri: SpotifyURI) async {}

    public func retry(at date: Date) async {
        guard visible, !isLoadingChips, error != nil, retryAfter.map({ $0 <= date }) ?? true else { return }
        await loadChips()
    }

    /// After consent: reloads now when shown, otherwise on the next reveal.
    public func refresh() async {
        chipsLoadedAt = nil
        guard visible, !isLoadingChips else { return }
        await loadChips()
    }

    public func clear() {
        generation += 1
        station?.cancel()
        station = nil
        chips = []
        selectedSeed = nil
        stationFailures = [:]
        isLoadingChips = false
        loadingSeed = nil
        mixes = [:]
        selections = [:]
        error = nil
        retryAfter = nil
        chipsLoadedAt = nil
        visible = false
        BopifyLog.library.debug("explore cleared")
    }

    public func playRequest(for track: Track) -> PlayRequest {
        guard let seed = selectedSeed, let mix = mixes[seed] else { return PlayRequest(contextURI: track.uri) }
        return PlayRequest(contextURI: mix.contextURI, startTrackURI: track.uri)
    }

    /// Alternates tracks and artists so both kinds lead, without repeats, ten at most.
    static func interleave(_ tracks: [StationSeed], _ artists: [StationSeed]) -> [StationSeed] {
        var seen = Set<SpotifyURI>()
        var result: [StationSeed] = []
        for index in 0..<max(tracks.count, artists.count) {
            for list in [tracks, artists] where index < list.count && seen.insert(list[index].uri).inserted {
                result.append(list[index])
            }
        }
        return Array(result.prefix(10))
    }

    private func loadChips() async {
        generation += 1
        let current = generation
        isLoadingChips = true
        error = nil
        retryAfter = nil
        BopifyLog.library.debug("explore chips cache miss, loading")
        do {
            var seeds = Self.interleave(try await history.topItems(.tracks), try await history.topItems(.artists))
            if seeds.isEmpty {
                // Liked songs are only a fallback; without that consent Explore just has no chips.
                let liked = (try? await savedTracks.savedTracks(offset: 0, limit: 5))?.tracks ?? []
                seeds = liked.map { StationSeed(uri: $0.uri, name: $0.title) }
                BopifyLog.library.debug("explore chips from liked songs count=\(seeds.count, privacy: .public)")
            }
            guard generation == current, !Task.isCancelled else { return }
            chips = seeds
            chipsLoadedAt = now()
            if !seeds.contains(where: { $0.uri == selectedSeed }) { selectedSeed = seeds.first?.uri }
        } catch {
            guard generation == current, !Task.isCancelled else { return }
            isLoadingChips = false
            let failure = error as? LibraryError ?? .unavailable
            self.error = failure
            switch failure {
            case let .rateLimited(seconds), let .quotaExceeded(seconds):
                retryAfter = now().addingTimeInterval(TimeInterval(seconds ?? 60))
            default: break
            }
            BopifyLog.library.notice("explore top items request failed")
            return
        }
        isLoadingChips = false
        await openSelectedStation()
    }

    /// One station request at a time: choosing another chip cancels the one in flight and drops its result.
    private func openSelectedStation() async {
        guard let seed = selectedSeed else { return }
        if mixes[seed] != nil {
            BopifyLog.library.debug("explore station cache hit")
            return
        }
        guard stationFailures[seed] == nil, loadingSeed != seed else { return }
        station?.cancel()
        loadingSeed = seed
        BopifyLog.library.debug("explore station cache miss, requesting")
        let task = Task { [self] in
            do {
                let mix = try await radio(seed)
                guard !Task.isCancelled else { return }
                mixes[seed] = mix
                if selections[seed] == nil { selections[seed] = mix.tracks.first?.uri }
            } catch {
                guard !Task.isCancelled else { return }
                stationFailures[seed] = error as? RadioFailure ?? .unavailable
                BopifyLog.library.notice("explore station request failed")
            }
            if loadingSeed == seed { loadingSeed = nil }
        }
        station = task
        await task.value
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --package-path Packages/BopifyCore --scratch-path /private/tmp/bopify-library-tabs-tests`
Expected: all pass, including 6 `ExploreModel` tests. If `dropsAStationThatArrivesAfterAnotherChipWasChosen` hangs, the cancelled task is not returning. Check that `selectChip` reaches `station?.cancel()`, and do not add a sleep to the test.

- [ ] **Step 5: Commit**

```bash
git add Packages/BopifyCore/Sources/BopifyLibrary/ExploreModel.swift Packages/BopifyCore/Tests/LibraryTests/ExploreModelTests.swift
git commit -m "Model Explore's station chips and radio mixes" -m "Chips alternate the user's top tracks and artists and last six hours, falling back to the newest liked songs. Each chip's mix is fetched once per session with one request in flight, so a quick chip change cancels the stale request instead of letting it overwrite the newer one, and a failing station never blocks the rest."
```

---

### Task 7: Generalize Cover Flow over any source

**Files:**
- Rename: `Bopify/Bopify/Views/LikedSongsCoverFlow.swift` → `Bopify/Bopify/Views/CoverFlowView.swift` (via `git mv`)
- Modify: `Bopify/Bopify/Views/MonolithPlayerView.swift:75-76`
- Modify: `Bopify/Bopify/Localizable.xcstrings`

**Interfaces:**
- Consumes: `CoverFlowSource` (Task 5).
- Produces:
  - `struct CoverFlowCopy`, with `permission`, `enable`, `empty` and `unavailable: LocalizedStringKey`, and the static members `.liked`, `.recents` and `.explore`.
  - `struct CoverFlowView<Source: CoverFlowSource>: View`, with `init(model: Source, copy: CoverFlowCopy, artworkStore: ArtworkStore, onPlay: @escaping (Track) -> Void, onEnable: @escaping @MainActor () async -> Void)`.

- [ ] **Step 1: Rename the file and the type**

```bash
git mv Bopify/Bopify/Views/LikedSongsCoverFlow.swift Bopify/Bopify/Views/CoverFlowView.swift
```

In `CoverFlowView.swift`, replace:

```swift
struct LikedSongsCoverFlow: View {
    let model: LikedSongsModel
    let artworkStore: ArtworkStore
    let onPlay: (Track) -> Void
```

with:

```swift
/// The empty and error copy that differs between library tabs.
struct CoverFlowCopy {
    let permission: LocalizedStringKey
    let enable: LocalizedStringKey
    let empty: LocalizedStringKey
    let unavailable: LocalizedStringKey

    static var liked: Self { .init(permission: "library.permission", enable: "library.enable", empty: "library.empty", unavailable: "library.unavailable") }
    static var recents: Self { .init(permission: "history.permission", enable: "history.enable", empty: "recents.empty", unavailable: "recents.unavailable") }
    static var explore: Self { .init(permission: "history.permission", enable: "history.enable", empty: "explore.empty", unavailable: "explore.unavailable") }
}

struct CoverFlowView<Source: CoverFlowSource>: View {
    let model: Source
    let copy: CoverFlowCopy
    let artworkStore: ArtworkStore
    let onPlay: (Track) -> Void
    let onEnable: @MainActor () async -> Void
```

- [ ] **Step 2: Replace the title row with a status overlay**

Remove the header `HStack` at the top of the `VStack`. The tabs now name the shelf. Replace:

```swift
        VStack(spacing: 3) {
            HStack {
                Text("library.title").font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                if model.isLoading && !model.tracks.isEmpty { ProgressView().controlSize(.mini) }
                if model.error != nil && !model.tracks.isEmpty {
                    TimelineView(.periodic(from: .now, by: 1)) { context in retryButton(at: context.date) }
                }
            }
            if model.tracks.isEmpty {
```

with:

```swift
        VStack(spacing: 3) {
            if model.tracks.isEmpty {
```

Replace:

```swift
                .scaleEffect(min(1, max(0.6, (available.size.height - 46) / 88)))
```

with:

```swift
                .scaleEffect(min(1, max(0.6, (available.size.height - 46) / 88)))
                .overlay(alignment: .topTrailing) { status }
```

Add this property before `emptyState`:

```swift
    /// Loading and retry for a shelf that already shows covers; an empty shelf shows them in `emptyState`.
    private var status: some View {
        HStack(spacing: 4) {
            if model.isLoading { ProgressView().controlSize(.mini) }
            if model.error != nil {
                TimelineView(.periodic(from: .now, by: 1)) { context in retryButton(at: context.date) }
            }
        }
    }
```

- [ ] **Step 3: Use the per-source copy and enable action in `emptyState`**

In `emptyState`, make these replacements:
- `Text("library.permission")` becomes `Text(copy.permission)`.
- `Button("library.enable") { Task { await environment?.enableLikedSongs() } }` becomes `Button(copy.enable) { Task { await onEnable() } }`.
- `Text(model.retryAfter == nil ? "library.unavailable" : "library.rateLimited")` becomes `Text(model.retryAfter == nil ? copy.unavailable : "library.rateLimited")`.
- `Text("library.empty")` becomes `Text(copy.empty)`.

- [ ] **Step 4: Update the call site**

In `MonolithPlayerView.swift`, replace:

```swift
                LikedSongsCoverFlow(model: environment.likedSongs, artworkStore: artworkStore,
                                    onPlay: { player.load(PlayRequest(contextURI: $0.uri)) })
```

with:

```swift
                CoverFlowView(model: environment.likedSongs, copy: .liked, artworkStore: artworkStore,
                              onPlay: { player.load(environment.likedSongs.playRequest(for: $0)) },
                              onEnable: { await environment.enableLikedSongs() })
```

- [ ] **Step 5: Update the string catalog**

In `Bopify/Bopify/Localizable.xcstrings`, delete the whole `"library.title"` entry, which is no longer used. Add these entries in key order, each in the existing shape:

```json
    "explore.empty" : { "localizations" : { "en" : { "stringUnit" : { "state" : "translated", "value" : "Play or like a few songs to get stations." } } } },
    "explore.retryStation" : { "localizations" : { "en" : { "stringUnit" : { "state" : "translated", "value" : "Retry Station" } } } },
    "explore.station %@" : { "localizations" : { "en" : { "stringUnit" : { "state" : "translated", "value" : "%@ station" } } } },
    "explore.stationsUnavailable" : { "localizations" : { "en" : { "stringUnit" : { "state" : "translated", "value" : "Stations unavailable" } } } },
    "explore.unavailable" : { "localizations" : { "en" : { "stringUnit" : { "state" : "translated", "value" : "Stations couldn’t load." } } } },
    "history.enable" : { "localizations" : { "en" : { "stringUnit" : { "state" : "translated", "value" : "Enable Recents and Explore" } } } },
    "history.permission" : { "localizations" : { "en" : { "stringUnit" : { "state" : "translated", "value" : "Bring your recent plays and stations here." } } } },
    "library.tab.explore" : { "localizations" : { "en" : { "stringUnit" : { "state" : "translated", "value" : "Explore" } } } },
    "library.tab.liked" : { "localizations" : { "en" : { "stringUnit" : { "state" : "translated", "value" : "Liked" } } } },
    "library.tab.recents" : { "localizations" : { "en" : { "stringUnit" : { "state" : "translated", "value" : "Recents" } } } },
    "library.tabs" : { "localizations" : { "en" : { "stringUnit" : { "state" : "translated", "value" : "Library" } } } },
    "recents.empty" : { "localizations" : { "en" : { "stringUnit" : { "state" : "translated", "value" : "Songs you play will appear here." } } } },
    "recents.unavailable" : { "localizations" : { "en" : { "stringUnit" : { "state" : "translated", "value" : "Recent plays couldn’t load." } } } },
```

Then validate the JSON: `jaq . Bopify/Bopify/Localizable.xcstrings > /dev/null`. If it isn't installed, use `, jaq`. Expected: no output, exit 0.

- [ ] **Step 6: Build the app**

Run the app build command from Global Constraints.
Expected: `** BUILD SUCCEEDED **` with no errors. `docs/superpowers/verification/MonolithInputRoutingProbe.swift` still names `LikedSongsCoverFlow`. It was already stale and is not part of any target, so leave it.

- [ ] **Step 7: Check that Liked is unchanged**

Ask the user to quit any running Bopify, run the new build, and expand the player. Expected: Liked Songs covers, dragging, the wheel, click-to-play and the empty and Enable states behave as before. The "LIKED SONGS" title no longer appears.

- [ ] **Step 8: Commit**

```bash
git add Bopify/Bopify/Views/CoverFlowView.swift Bopify/Bopify/Views/LikedSongsCoverFlow.swift \
        Bopify/Bopify/Views/MonolithPlayerView.swift Bopify/Bopify/Localizable.xcstrings
git commit -m "Let Cover Flow render any library source" -m "Recents and Explore reuse the Liked Songs Cover Flow, so the view now takes any CoverFlowSource with its own empty-state copy and enable action. The tabs will name the shelf, so the fixed title becomes a status overlay."
```

---

### Task 8: Library shelf with tabs and station chips, wired into the app

**Files:**
- Create: `Bopify/Bopify/Views/LibraryShelf.swift`
- Modify: `Bopify/Bopify/Views/MonolithPlayerView.swift` (the Task 7 call site)
- Modify: `Bopify/Bopify/AppEnvironment.swift`

**Interfaces:**
- Consumes:
  - `CoverFlowView` and `CoverFlowCopy` (Task 7).
  - `RecentsModel` (Task 5) and `ExploreModel` (Task 6).
  - `PlaybackEngine.requestRadio` (Task 3) and `ListeningHistoryService` (Task 4).
- Produces:
  - On `AppEnvironment`: `recents: RecentsModel`, `explore: ExploreModel` and `enableListeningHistory() async`.
  - `LibraryShelf(environment:artworkStore:onPlay:)`.

- [ ] **Step 1: Wire the models into `AppEnvironment`**

In `AppEnvironment.swift`, after `let likedSongs: LikedSongsModel`, add:

```swift
    let recents: RecentsModel
    let explore: ExploreModel
    @ObservationIgnored private let stations: StationRoute
```

Change `@ObservationIgnored private var engine: LibrespotEngine?` to:

```swift
    @ObservationIgnored private var engine: LibrespotEngine? { didSet { stations.engine = engine } }
```

In `init()`, after `likedSongs = LikedSongsModel(service: library)`:

```swift
        let stations = StationRoute()
        self.stations = stations
        recents = RecentsModel(service: library)
        explore = ExploreModel(history: library, savedTracks: library, radio: { try await stations.mix(for: $0) })
```

In the `#if DEBUG` initializer, add the parameter `historyService: (any ListeningHistoryService)? = nil` after `savedTracksService`. Then add the following after its `likedSongs = …` line:

```swift
        let stations = StationRoute()
        self.stations = stations
        recents = RecentsModel(service: historyService ?? UnavailableHistory())
        explore = ExploreModel(history: historyService ?? UnavailableHistory(),
                               savedTracks: savedTracksService ?? UnavailableSavedTracks(),
                               radio: { try await stations.mix(for: $0) })
```

Add the following after `enableLikedSongs()`:

```swift
    func enableListeningHistory() async {
        await enableLibrary(scopes: ["user-read-recently-played", "user-top-read"])
    }
```

In `enableLibrary(scopes:)`, replace:

```swift
            guard generation == libraryGeneration else { return }
            await likedSongs.refresh()
```

with:

```swift
            guard generation == libraryGeneration else { return }
            await likedSongs.refresh()
            guard generation == libraryGeneration else { return }
            await recents.refresh()
            guard generation == libraryGeneration else { return }
            await explore.refresh()
```

In `clearLibrary()`, after `likedSongs.clear()`, add:

```swift
        recents.clear()
        explore.clear()
```

At the end of the file, before the `#if DEBUG` block, add:

```swift
/// Explore's way to the current engine: a token refresh replaces the engine, so the model cannot hold it.
@MainActor
private final class StationRoute {
    var engine: (any PlaybackEngine)?

    func mix(for seed: SpotifyURI) async throws -> RadioMix {
        guard let engine else { throw RadioFailure.unavailable }
        return try await engine.requestRadio(seed: seed)
    }
}
```

Inside the existing `#if DEBUG` block at the end, add:

```swift
private struct UnavailableHistory: ListeningHistoryService {
    func recentlyPlayed() async throws -> [RecentPlay] { throw LibraryError.unavailable }
    func topItems(_ kind: TopItemKind) async throws -> [StationSeed] { throw LibraryError.unavailable }
}
```

- [ ] **Step 2: Create the shelf**

Create `Bopify/Bopify/Views/LibraryShelf.swift`:

```swift
import SwiftUI
import os
import BopifyDomain
import BopifyLibrary

enum LibraryTab: String, CaseIterable, Identifiable {
    case recents, explore, liked
    var id: Self { self }
    var title: LocalizedStringKey {
        switch self {
        case .recents: "library.tab.recents"
        case .explore: "library.tab.explore"
        case .liked: "library.tab.liked"
        }
    }
}

/// Tabs, Explore's station chips and the shared Cover Flow in the sleeve's lower frame.
struct LibraryShelf: View {
    let environment: AppEnvironment
    let artworkStore: ArtworkStore
    let onPlay: (PlayRequest) -> Void
    @AppStorage("library.tab") private var tab: LibraryTab = .liked
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 4) {
            Picker("library.tabs", selection: $tab) {
                ForEach(LibraryTab.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .fixedSize()
            if tab == .explore { StationChips(model: environment.explore) }
            shelf.transition(reduceMotion ? AnyTransition.opacity : AnyTransition.opacity.combined(with: .scale(scale: 0.94)))
        }
        .animation(reduceMotion ? .easeInOut(duration: 0.2) : .snappy, value: tab)
        .onChange(of: tab) { _, tab in
            BopifyLog.library.debug("library tab changed tab=\(tab.rawValue, privacy: .public)")
        }
    }

    /// Each source gets its own identity so Cover Flow's position and fling never carry across tabs or stations.
    @ViewBuilder private var shelf: some View {
        switch tab {
        case .recents:
            CoverFlowView(model: environment.recents, copy: .recents, artworkStore: artworkStore,
                          onPlay: { onPlay(environment.recents.playRequest(for: $0)) },
                          onEnable: { await environment.enableListeningHistory() })
                .id(LibraryTab.recents)
        case .explore:
            if environment.explore.stationFailure != nil {
                VStack(spacing: 8) {
                    Text("explore.stationsUnavailable").font(.caption).foregroundStyle(.secondary)
                    Button("explore.retryStation") { Task { await environment.explore.retryStation() } }.font(.caption)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(PlayerBackgroundDragRegion())
            } else {
                CoverFlowView(model: environment.explore, copy: .explore, artworkStore: artworkStore,
                              onPlay: { onPlay(environment.explore.playRequest(for: $0)) },
                              onEnable: { await environment.enableListeningHistory() })
                    .id(environment.explore.selectedSeed)
            }
        case .liked:
            CoverFlowView(model: environment.likedSongs, copy: .liked, artworkStore: artworkStore,
                          onPlay: { onPlay(environment.likedSongs.playRequest(for: $0)) },
                          onEnable: { await environment.enableLikedSongs() })
                .id(LibraryTab.liked)
        }
    }
}

/// Up to ten station chips: ♪ for a track seed, ● for an artist, a retry arrow for a failed station.
private struct StationChips: View {
    let model: ExploreModel

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    ForEach(model.chips) { seed in chip(seed) }
                }
                .padding(.horizontal, 12)
            }
            .scrollIndicators(.never)
            .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.06),
                                         .init(color: .black, location: 0.94), .init(color: .clear, location: 1)],
                                 startPoint: .leading, endPoint: .trailing))
            .onChange(of: model.selectedSeed) { _, seed in
                // Chips are identified by non-optional URIs, so an optional would never match.
                if let seed { withAnimation(.snappy) { proxy.scrollTo(seed, anchor: .center) } }
            }
        }
        .frame(height: 20)
    }

    private func chip(_ seed: StationSeed) -> some View {
        let selected = seed.uri == model.selectedSeed
        let failed = model.stationFailures[seed.uri] != nil
        return Button {
            Task {
                if selected && failed { await model.retryStation() } else { await model.selectChip(seed.uri) }
            }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: failed ? "arrow.clockwise" : seed.isArtist ? "circle.fill" : "music.note")
                    .font(.system(size: failed ? 8 : 6, weight: .semibold))
                    .opacity(0.7)
                Text(seed.name).lineLimit(1)
            }
            .font(.system(size: 10, weight: .medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .foregroundStyle(selected ? Color.black : Color.primary)
            .background(Capsule().fill(selected ? Color.white.opacity(0.92) : Color.clear))
            .overlay(Capsule().strokeBorder(Color.primary.opacity(selected ? 0 : 0.2)))
        }
        .buttonStyle(.plain)
        .id(seed.uri)
        .accessibilityLabel(Text("explore.station \(seed.name)"))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
```

- [ ] **Step 3: Put the shelf in the lower frame**

In `MonolithPlayerView.swift`, replace the Task 7 call:

```swift
                CoverFlowView(model: environment.likedSongs, copy: .liked, artworkStore: artworkStore,
                              onPlay: { player.load(environment.likedSongs.playRequest(for: $0)) },
                              onEnable: { await environment.enableLikedSongs() })
```

with:

```swift
                LibraryShelf(environment: environment, artworkStore: artworkStore, onPlay: { player.load($0) })
```

Keep the `.frame(width: layout.lowerFrame.width, height: layout.lowerFrame.height)` and `.offset(...)` modifiers below it as they are.

- [ ] **Step 4: Build the app and run the package tests**

Run the app build command, then the Swift package test command, both from Global Constraints.
Expected: `** BUILD SUCCEEDED **`, and every package test passes.

- [ ] **Step 5: Check the tabs by hand**

Ask the user to quit any running Bopify fully, run the new build, expand the player, and check each item:
1. The tabs read "Recents · Explore · Liked", and Liked is selected on first launch.
2. Recents and Explore show "Enable Recents and Explore". One consent fills both tabs.
3. Recents plays a track from its album or playlist, so the queue shows that context. A track first played from Liked Songs plays alone.
4. Explore shows up to ten chips. Choosing chips switches mixes. The selected chip scrolls into view. Playing a cover starts the mix at that track.
5. Each of these scrolls the chip row: a trackpad swipe, and a Logi smoothed wheel.
6. Switching tabs keeps each tab's selection. The tab choice survives a relaunch.
7. With Reduce Motion on, tabs crossfade.

For item 5: if vertical wheel input doesn't scroll the horizontal chip row, record it in the Task 9 report as a follow-up. Don't widen this task. The fix would route `deltaY` to horizontal scrolling in an `NSViewRepresentable`, as `CoverFlowInput` does.

Capture `log stream --predicate 'subsystem == "com.leesiongchan.bopify"' --level debug` while doing this. Confirm three kinds of lines appear:
- `library tab changed`.
- `explore station cache hit` and `explore station cache miss`.
- `radio: resolved seed=track` (or `seed=artist`).

- [ ] **Step 6: Commit**

```bash
git add Bopify/Bopify/Views/LibraryShelf.swift Bopify/Bopify/Views/MonolithPlayerView.swift Bopify/Bopify/AppEnvironment.swift
git commit -m "Add Recents, Explore and Liked tabs above Cover Flow" -m "The lower sleeve only showed liked songs. A segmented control now switches Cover Flow between recent plays, Spotify radio stations seeded from the user's top tracks and artists, and liked songs, with a chip row choosing Explore's station. The tab persists, each tab keeps its selection, and stations reach whichever engine is current."
```

---

### Task 9: Live probe and verification report

**Files:**
- Create: `docs/superpowers/verification/LibraryTabsLiveProbe.swift`
- Create: `docs/superpowers/verification/2026-10-01-library-tabs.md`

**Interfaces:**
- Consumes: `SpotifyLibraryClient.recentlyPlayed()`, `topItems(_:)` and `LibrespotEngine.requestRadio(seed:)`.
- Produces: the pass or blocked categories recorded in the report.

- [ ] **Step 1: Write the probe**

Create `docs/superpowers/verification/LibraryTabsLiveProbe.swift`:

```swift
import Foundation
import BopifyAuth
import BopifyDomain
import BopifyLibrary
import BopifyPlayback

// Matches AppEnvironment's constant: the probe builds outside the app target.
let dashboardLibraryClientID = "25bbd3bacca4412b80f17b892072af71"

/// One real recently-played, top-items and station request. Prints counts and categories only:
/// never tokens, URIs, titles or response bodies. Creates a short-lived "Bopify Probe" Connect device.
@main struct LibraryTabsLiveProbe {
    static func main() async {
        var blocked = false
        let auth = SpotifyAuthService(clientID: dashboardLibraryClientID,
                                      store: KeychainTokenStore(service: "com.leesiongchan.bopify.library"),
                                      callbackPort: 8898, callbackPath: "/callback")
        let library = SpotifyLibraryClient { scopes in try await auth.validAccessToken(requiredScopes: scopes) }
        var seed: SpotifyURI?
        do {
            let plays = try await library.recentlyPlayed()
            seed = plays.first?.track.uri
            print("PASS: recently played count=\(plays.count) withContext=\(plays.filter { $0.contextURI != nil }.count)")
        } catch { blocked = true; print("BLOCKED: recently played \(category(error))") }
        do {
            let tracks = try await library.topItems(.tracks)
            let artists = try await library.topItems(.artists)
            print("PASS: top items tracks=\(tracks.count) artists=\(artists.count)")
            seed = seed ?? tracks.first?.uri ?? artists.first?.uri
        } catch { blocked = true; print("BLOCKED: top items \(category(error))") }
        guard let seed else { print("BLOCKED: no seed available"); exit(77) }
        do {
            let token = try await SpotifyAuthService(clientID: librespotClientID).validAccessToken()
            let engine = try await LibrespotEngine(accessToken: token, deviceName: "Bopify Probe")
            do {
                let mix = try await engine.requestRadio(seed: seed)
                print("PASS: station seedKind=\(seed.kind) contextKind=\(mix.contextURI.kind) tracks=\(mix.tracks.count)")
            } catch { blocked = true; print("BLOCKED: station \(category(error))") }
            await engine.shutdown()
        } catch { blocked = true; print("BLOCKED: playback engine \(category(error))") }
        exit(blocked ? 77 : 0)
    }

    static func category(_ error: any Error) -> String {
        switch error {
        case let failure as RadioFailure: "radio.\(failure.rawValue)"
        case let failure as LibraryError: "library.\(failure)"
        case let failure as PlayerError: "player.\(failure)"
        default: "unexpected"
        }
    }
}
```

- [ ] **Step 2: Run the probe in a throwaway package**

Run this while nothing else is playing on the account, because the probe briefly registers a Connect device.

```bash
root=$(pwd)
rm -rf /private/tmp/bopify-library-tabs-probe
mkdir -p /private/tmp/bopify-library-tabs-probe/Sources/LibraryTabsLiveProbe
cp docs/superpowers/verification/LibraryTabsLiveProbe.swift /private/tmp/bopify-library-tabs-probe/Sources/LibraryTabsLiveProbe/
cat > /private/tmp/bopify-library-tabs-probe/Package.swift <<EOF
// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "LibraryTabsLiveProbe",
    platforms: [.macOS(.v14)],
    dependencies: [.package(path: "$root/Packages/BopifyCore")],
    targets: [.executableTarget(name: "LibraryTabsLiveProbe", dependencies: [
        .product(name: "BopifyAuth", package: "BopifyCore"), .product(name: "BopifyDomain", package: "BopifyCore"),
        .product(name: "BopifyLibrary", package: "BopifyCore"), .product(name: "BopifyPlayback", package: "BopifyCore")])]
)
EOF
swift run -q --package-path /private/tmp/bopify-library-tabs-probe LibraryTabsLiveProbe; echo "exit=$?"
```

Expected: three `PASS:` lines and `exit=0`, with a station `tracks=` count between 1 and 50.

A `BLOCKED: … library.authorizationRequired` line means the Task 8 consent hasn't been granted yet. Grant it in the app and run the probe again.

Any other `BLOCKED` line is a finding. Record it, don't work around it.

- [ ] **Step 3: Write the verification report**

Create `docs/superpowers/verification/2026-10-01-library-tabs.md`. Follow the existing reports' format. Record:
- The commands and outcomes of `cargo test`, the package tests and the app build.
- The probe's exact output lines.
- Each manual check from Task 8, Step 5, with the result the user reported.
- The chip-row wheel finding.
- That the radio fixture was captured on the date of Task 1. This replaces the spec's "2026-09-30 spike" wording.

Each spec failure state is exercised as follows:

| Failure state | Exercised by |
|---|---|
| consent | `RecentsModel`/`ExploreModel` empty state with `authorizationRequired`, manual item 2 |
| rate limit / quota | `aRateLimitWaitsForItsDeadline`, `historyRequestsShareTheLibraryCooldown` |
| station failure | `aFailingStationLeavesOtherChipsWorkingUntilRetried`, `every_failure_names_its_category` |
| internal endpoint breakage | `RadioFailure.unavailable` path in `every_failure_names_its_category` and the bridge's `aFailedReplyThrowsItsReason` |
| no engine | `StationRoute` throws `.unavailable`; `finishFailsRequestsStillWaiting` |

- [ ] **Step 4: Commit**

```bash
git add docs/superpowers/verification/LibraryTabsLiveProbe.swift docs/superpowers/verification/2026-10-01-library-tabs.md
git commit -m "Verify the library tabs against live Spotify" -m "The probe makes one real recently-played, top-items and station request and prints only counts and failure categories, so the report can show the undocumented radio path working end to end without exposing account data."
```
