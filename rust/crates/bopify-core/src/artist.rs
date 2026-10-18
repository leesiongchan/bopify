//! The current track's main artist and their country-specific popular songs.

use std::{collections::HashSet, future::Future, time::Duration};

use librespot_core::{Session, SpotifyUri, error::ErrorKind};
use librespot_metadata::{Artist, Metadata, Track};
use serde::Serialize;
use tokio::task::JoinSet;

use crate::event::{WireEvent, WireTrack};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum ArtistTopTracksFailure {
    Unavailable,
    Network,
}

pub(crate) struct ArtistTracks {
    uri: String,
    name: String,
    tracks: Vec<SpotifyUri>,
}

pub(crate) trait ArtistSource: Clone + Send + Sync + 'static {
    fn artist(
        &self,
        track: &SpotifyUri,
    ) -> impl Future<Output = Result<ArtistTracks, ArtistTopTracksFailure>> + Send;
    fn track(&self, uri: String) -> impl Future<Output = Option<WireTrack>> + Send;
}

#[derive(Clone)]
pub(crate) struct SessionArtist(pub Session);

impl ArtistSource for SessionArtist {
    async fn artist(&self, track: &SpotifyUri) -> Result<ArtistTracks, ArtistTopTracksFailure> {
        let track = Track::get(&self.0, track).await.map_err(classify)?;
        let artist = track
            .artists
            .first()
            .ok_or(ArtistTopTracksFailure::Unavailable)?;
        let artist = Artist::get(&self.0, &artist.id).await.map_err(classify)?;
        Ok(ArtistTracks {
            uri: artist.id.to_uri(),
            name: artist.name,
            tracks: crate::radio::pick_top_tracks(&artist.top_tracks, &self.0.country()),
        })
    }

    async fn track(&self, uri: String) -> Option<WireTrack> {
        crate::queue::lookup(self.0.clone(), uri).await
    }
}

fn classify(error: librespot_core::Error) -> ArtistTopTracksFailure {
    match error.kind {
        ErrorKind::Unavailable
        | ErrorKind::DeadlineExceeded
        | ErrorKind::Aborted
        | ErrorKind::ResourceExhausted => ArtistTopTracksFailure::Network,
        _ => ArtistTopTracksFailure::Unavailable,
    }
}

pub(crate) async fn resolve<S: ArtistSource>(
    source: &S,
    track: SpotifyUri,
    request_id: u64,
) -> WireEvent {
    resolve_within(source, track, request_id, Duration::from_secs(30)).await
}

async fn resolve_within<S: ArtistSource>(
    source: &S,
    track: SpotifyUri,
    request_id: u64,
    timeout: Duration,
) -> WireEvent {
    let result = tokio::time::timeout(timeout, songs(source, &track))
        .await
        .unwrap_or(Err(ArtistTopTracksFailure::Network));
    match result {
        Ok((artist, tracks)) => {
            log::info!("artist songs: resolved tracks={}", tracks.len());
            WireEvent::ArtistTopTracks {
                request_id,
                track_uri: track.to_uri(),
                artist_uri: artist.uri,
                artist_name: artist.name,
                tracks,
            }
        }
        Err(reason) => {
            log::debug!("artist songs: lookup failed reason={reason:?}");
            WireEvent::ArtistTopTracksFailed {
                request_id,
                track_uri: track.to_uri(),
                reason,
            }
        }
    }
}

async fn songs<S: ArtistSource>(
    source: &S,
    track: &SpotifyUri,
) -> Result<(ArtistTracks, Vec<WireTrack>), ArtistTopTracksFailure> {
    let mut artist = source.artist(track).await?;
    let has_top_tracks = !artist.tracks.is_empty();
    let mut seen = HashSet::new();
    let mut pending = std::mem::take(&mut artist.tracks)
        .into_iter()
        .filter(|uri| matches!(uri, SpotifyUri::Track { .. }) && seen.insert(uri.to_uri()))
        .take(10)
        .enumerate();
    let mut jobs = JoinSet::new();
    let mut tracks = Vec::new();
    loop {
        while jobs.len() < 4 {
            let Some((index, uri)) = pending.next() else {
                break;
            };
            let source = source.clone();
            jobs.spawn(async move { (index, source.track(uri.to_uri()).await) });
        }
        match jobs.join_next().await {
            Some(Ok((index, Some(track)))) => tracks.push((index, track)),
            Some(_) => (),
            None => break,
        }
    }
    if has_top_tracks && tracks.is_empty() {
        return Err(ArtistTopTracksFailure::Unavailable);
    }
    tracks.sort_unstable_by_key(|(index, _)| *index);
    Ok((artist, tracks.into_iter().map(|(_, track)| track).collect()))
}

#[cfg(test)]
mod tests {
    use super::*;

    const SOURCE: &str = "spotify:track:11dFghVXANMlKmJXsNCbNl";
    const SECOND: &str = "spotify:track:4uLU6hMCjMI75M1A2tKUQC";

    #[derive(Clone)]
    struct Fake {
        tracks: Vec<SpotifyUri>,
        failure: Option<ArtistTopTracksFailure>,
        stall: bool,
        missing_metadata: bool,
    }

    impl ArtistSource for Fake {
        async fn artist(&self, _: &SpotifyUri) -> Result<ArtistTracks, ArtistTopTracksFailure> {
            if self.stall {
                std::future::pending::<()>().await;
            }
            if let Some(failure) = self.failure {
                return Err(failure);
            }
            Ok(ArtistTracks {
                uri: "spotify:artist:6rqhFgbbKwnb9MLmUQDhG6".into(),
                name: "Singer".into(),
                tracks: self.tracks.clone(),
            })
        }
        async fn track(&self, uri: String) -> Option<WireTrack> {
            if self.missing_metadata {
                return None;
            }
            if uri == SOURCE {
                tokio::task::yield_now().await;
            }
            Some(WireTrack {
                track_uri: uri,
                title: "Song".into(),
                artists: vec!["Singer".into()],
                album_title: None,
                artwork_url: None,
                duration_ms: 1000,
            })
        }
    }

    fn fake(uris: &[&str]) -> Fake {
        Fake {
            tracks: uris
                .iter()
                .map(|uri| SpotifyUri::from_uri(uri).unwrap())
                .collect(),
            failure: None,
            stall: false,
            missing_metadata: false,
        }
    }

    #[tokio::test]
    async fn keeps_popularity_order_and_removes_duplicates() {
        let result = resolve(
            &fake(&[SOURCE, SECOND, SOURCE]),
            SpotifyUri::from_uri(SOURCE).unwrap(),
            7,
        )
        .await;
        let WireEvent::ArtistTopTracks {
            request_id,
            track_uri,
            artist_name,
            tracks,
            ..
        } = result
        else {
            panic!("expected songs")
        };
        assert_eq!(request_id, 7);
        assert_eq!(track_uri, SOURCE);
        assert_eq!(artist_name, "Singer");
        assert_eq!(
            tracks
                .iter()
                .map(|track| track.track_uri.as_str())
                .collect::<Vec<_>>(),
            vec![SOURCE, SECOND]
        );
    }

    #[tokio::test]
    async fn artist_without_top_tracks_returns_empty_list() {
        assert!(
            matches!(resolve(&fake(&[]), SpotifyUri::from_uri(SOURCE).unwrap(), 7).await,
            WireEvent::ArtistTopTracks { tracks, .. } if tracks.is_empty())
        );
    }

    #[tokio::test]
    async fn failed_metadata_is_retryable_rather_than_an_empty_artist() {
        let source = Fake {
            missing_metadata: true,
            ..fake(&[SOURCE])
        };
        assert!(matches!(
            resolve(&source, SpotifyUri::from_uri(SOURCE).unwrap(), 7).await,
            WireEvent::ArtistTopTracksFailed {
                reason: ArtistTopTracksFailure::Unavailable,
                ..
            }
        ));
    }

    #[tokio::test]
    async fn failures_keep_request_identity() {
        let source = Fake {
            failure: Some(ArtistTopTracksFailure::Unavailable),
            ..fake(&[])
        };
        assert!(matches!(
            resolve(&source, SpotifyUri::from_uri(SOURCE).unwrap(), 7).await,
            WireEvent::ArtistTopTracksFailed {
                request_id: 7,
                reason: ArtistTopTracksFailure::Unavailable,
                ..
            }
        ));
    }

    #[tokio::test]
    async fn stalled_service_has_a_bounded_deadline() {
        let source = Fake {
            stall: true,
            ..fake(&[])
        };
        assert!(matches!(
            resolve_within(
                &source,
                SpotifyUri::from_uri(SOURCE).unwrap(),
                7,
                Duration::from_millis(1)
            )
            .await,
            WireEvent::ArtistTopTracksFailed {
                reason: ArtistTopTracksFailure::Network,
                ..
            }
        ));
    }
}
