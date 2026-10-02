//! Spotify's own radio for a seed track or artist. The only code that calls the
//! internal radio endpoints; the Spotify calls sit behind `RadioSource` so the
//! mapping is testable without a network.

use std::{
    future::Future,
    sync::atomic::{AtomicBool, Ordering},
    time::Duration,
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
        let artist = Artist::get(&self.0, artist).await.map_err(|e| classify_artist_lookup(&e))?;
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
    resolve_within(source, seed, request_id, Duration::from_secs(30)).await
}

async fn resolve_within<S: RadioSource>(source: &S, seed: Seed, request_id: u64, limit: Duration) -> WireEvent {
    let seed_uri = seed.uri();
    let kind = seed.kind();
    // librespot sets no HTTP timeout, so a stalled request would otherwise leave Explore loading forever.
    let outcome = tokio::time::timeout(limit, mix_for(source, seed)).await.unwrap_or(Err(RadioFailure::Network));
    match outcome {
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
        ErrorKind::DeadlineExceeded | ErrorKind::Unavailable | ErrorKind::Aborted | ErrorKind::ResourceExhausted => RadioFailure::Network,
        // librespot maps HTTP 404 here: Spotify has no mix for this seed, not a broken endpoint.
        ErrorKind::NotFound => RadioFailure::NoMix,
        _ => RadioFailure::Unavailable,
    }
}

/// A 404 on the artist lookup means the artist is missing, so there is no top track to seed a mix from.
fn classify_artist_lookup(error: &librespot_core::Error) -> RadioFailure {
    match classify(error) {
        RadioFailure::NoMix => RadioFailure::NoTopTrack,
        other => other,
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
        hang: bool,
        mixed_for: Arc<Mutex<Vec<String>>>,
    }

    impl Fake {
        fn new(context: Vec<String>) -> Self {
            Self { top: None, mix: Ok(MIX.to_vec()), context, missing: vec![], hang: false, mixed_for: Arc::default() }
        }
    }

    impl RadioSource for Fake {
        async fn top_track(&self, _artist: &SpotifyUri) -> Result<Option<SpotifyUri>, RadioFailure> {
            Ok(self.top.map(|uri| SpotifyUri::from_uri(uri).unwrap()))
        }
        async fn mix(&self, track: &SpotifyUri) -> Result<Vec<u8>, RadioFailure> {
            self.mixed_for.lock().unwrap().push(track.to_uri());
            if self.hang {
                std::future::pending::<()>().await;
            }
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

    #[tokio::test]
    async fn a_request_that_never_answers_fails_as_a_network_error() {
        let mut stalled = Fake::new(uris(2));
        stalled.hang = true;
        let reply = resolve_within(&stalled, Seed::parse(SEED_TRACK).unwrap(), 7, Duration::from_millis(5));
        let event = tokio::time::timeout(Duration::from_secs(2), reply).await.expect("resolve never gave up");
        assert!(matches!(event, WireEvent::RadioFailed { request_id: 7, reason: RadioFailure::Network, .. }), "{event:?}");
    }

    #[test]
    fn a_missing_artist_has_no_top_track() {
        use librespot_core::Error;
        assert_eq!(classify_artist_lookup(&Error::not_found("x")), RadioFailure::NoTopTrack);
        assert_eq!(classify_artist_lookup(&Error::unavailable("x")), RadioFailure::Network);
    }

    #[test]
    fn classify_maps_librespot_errors_to_failure_categories() {
        use librespot_core::Error;
        assert_eq!(classify(&Error::not_found("x")), RadioFailure::NoMix);
        assert_eq!(classify(&Error::resource_exhausted("x")), RadioFailure::Network);
        assert_eq!(classify(&Error::unavailable("x")), RadioFailure::Network);
        assert_eq!(classify(&Error::deadline_exceeded("x")), RadioFailure::Network);
        assert_eq!(classify(&Error::permission_denied("x")), RadioFailure::Unavailable);
    }
}
