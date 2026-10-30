//! Retrieves and bounds lyric data using the engine-owned Spotify session.

use std::{future::Future, time::Duration};

use librespot_core::{Session, SpotifyId, SpotifyUri, error::ErrorKind};
use librespot_metadata::{Lyrics, lyrics::SyncType};
use serde::Serialize;

use crate::event::WireEvent;

const MAX_LINES: usize = 2_000;
const MAX_TEXT_BYTES: usize = 262_144;

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct WireLyrics {
    #[serde(rename = "trackURI")]
    pub track_uri: String,
    pub synchronization: LyricSynchronization,
    pub lines: Vec<WireLyricLine>,
    pub provider: String,
    pub provider_display_name: String,
    pub is_right_to_left: bool,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct WireLyricLine {
    pub text: String,
    pub start_time_ms: Option<i64>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum LyricSynchronization {
    LineSynced,
    Unsynced,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum LyricFailure {
    NoLyrics,
    Network,
    Unavailable,
}

pub(crate) fn parse_track(raw: &str) -> Option<SpotifyUri> {
    let uri = SpotifyUri::from_uri(raw).ok()?;
    (uri.to_uri() == raw && matches!(uri, SpotifyUri::Track { .. })).then_some(uri)
}

fn normalize(track_uri: String, lyrics: Lyrics) -> Result<WireLyrics, LyricFailure> {
    let lyrics = lyrics.lyrics;
    if lyrics.lines.len() > MAX_LINES {
        return Err(LyricFailure::Unavailable);
    }
    let synchronization = match lyrics.sync_type {
        SyncType::LineSynced => LyricSynchronization::LineSynced,
        SyncType::Unsynced => LyricSynchronization::Unsynced,
    };
    let mut text_bytes = 0;
    let mut has_text = false;
    let mut lines = Vec::with_capacity(lyrics.lines.len());
    for line in lyrics.lines {
        // The previous total is bounded, so this subtraction cannot underflow.
        if line.words.len() > MAX_TEXT_BYTES - text_bytes {
            return Err(LyricFailure::Unavailable);
        }
        text_bytes += line.words.len();
        has_text |= !line.words.trim().is_empty();
        let start_time_ms = match synchronization {
            LyricSynchronization::LineSynced => Some(
                line.start_time_ms
                    .parse::<i64>()
                    .ok()
                    .filter(|start| *start >= 0)
                    .ok_or(LyricFailure::Unavailable)?,
            ),
            LyricSynchronization::Unsynced => None,
        };
        lines.push(WireLyricLine {
            text: line.words,
            start_time_ms,
        });
    }
    if !has_text {
        return Err(LyricFailure::NoLyrics);
    }
    Ok(WireLyrics {
        track_uri,
        synchronization,
        lines,
        provider: lyrics.provider,
        provider_display_name: lyrics.provider_display_name,
        is_right_to_left: lyrics.is_rtl_language,
    })
}

pub(crate) trait LyricSource: Clone + Send + Sync + 'static {
    fn lyrics(&self, id: &SpotifyId) -> impl Future<Output = Result<Lyrics, LyricFailure>> + Send;
}

#[derive(Clone)]
pub(crate) struct SessionLyrics(pub Session);

impl LyricSource for SessionLyrics {
    async fn lyrics(&self, id: &SpotifyId) -> Result<Lyrics, LyricFailure> {
        Lyrics::get(&self.0, id)
            .await
            .map_err(|error| classify(&error))
    }
}

pub(crate) async fn resolve<S: LyricSource>(
    source: &S,
    track: SpotifyUri,
    request_id: u64,
) -> WireEvent {
    resolve_within(source, track, request_id, crate::event::REPLY_DEADLINE).await
}

async fn resolve_within<S: LyricSource>(
    source: &S,
    track: SpotifyUri,
    request_id: u64,
    limit: Duration,
) -> WireEvent {
    let track_uri = track.to_uri();
    let outcome = tokio::time::timeout(limit, async {
        let SpotifyUri::Track { id } = track else {
            return Err(LyricFailure::Unavailable);
        };
        normalize(track_uri.clone(), source.lyrics(&id).await?)
    })
    .await
    .unwrap_or(Err(LyricFailure::Network));
    match outcome {
        Ok(lyrics) => {
            log::info!(
                "lyrics: resolved request_id={request_id} lines={}",
                lyrics.lines.len()
            );
            WireEvent::Lyrics { request_id, lyrics }
        }
        Err(reason) => {
            log::info!("lyrics: failed request_id={request_id} reason={reason:?}");
            WireEvent::LyricsFailed {
                request_id,
                track_uri,
                reason,
            }
        }
    }
}

fn classify(error: &librespot_core::Error) -> LyricFailure {
    match error.kind {
        ErrorKind::NotFound => LyricFailure::NoLyrics,
        ErrorKind::DeadlineExceeded
        | ErrorKind::Unavailable
        | ErrorKind::Aborted
        | ErrorKind::ResourceExhausted => LyricFailure::Network,
        _ => LyricFailure::Unavailable,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use librespot_metadata::lyrics::{Colors, Line, LyricsInner, SyncType};
    use serde_json::json;
    use std::sync::{Arc, Mutex};

    const TRACK: &str = "spotify:track:11dFghVXANMlKmJXsNCbNl";

    fn fixture(lines: &[(&str, &str)], sync_type: SyncType) -> librespot_metadata::Lyrics {
        librespot_metadata::Lyrics {
            colors: Colors {
                background: 0,
                highlight_text: 0,
                text: 0,
            },
            has_vocal_removal: false,
            lyrics: LyricsInner {
                is_dense_typeface: false,
                is_rtl_language: true,
                language: "ar".into(),
                lines: lines
                    .iter()
                    .map(|(start, words)| Line {
                        start_time_ms: (*start).into(),
                        end_time_ms: "0".into(),
                        words: (*words).into(),
                    })
                    .collect(),
                provider: "fixture".into(),
                provider_display_name: "Fixture provider".into(),
                provider_lyrics_id: "fixture-id".into(),
                sync_lyrics_uri: String::new(),
                sync_type,
            },
        }
    }

    #[test]
    fn timed_lines_preserve_order_repeats_gaps_and_attribution() {
        let result = normalize(
            TRACK.into(),
            fixture(
                &[
                    ("1000", "A quiet street"),
                    ("1000", ""),
                    ("2000", "The lamps return"),
                ],
                SyncType::LineSynced,
            ),
        )
        .unwrap();
        assert_eq!(
            result
                .lines
                .iter()
                .map(|l| l.start_time_ms)
                .collect::<Vec<_>>(),
            [Some(1000), Some(1000), Some(2000)]
        );
        assert_eq!(
            result
                .lines
                .iter()
                .map(|l| l.text.as_str())
                .collect::<Vec<_>>(),
            ["A quiet street", "", "The lamps return"]
        );
        assert_eq!(result.track_uri, TRACK);
        assert_eq!(result.synchronization, LyricSynchronization::LineSynced);
        assert_eq!(result.provider, "fixture");
        assert_eq!(result.provider_display_name, "Fixture provider");
        assert!(result.is_right_to_left);
    }

    #[test]
    fn unsynced_lines_ignore_upstream_starts_and_serialize_null() {
        let result = normalize(
            TRACK.into(),
            fixture(
                &[("0", "A quiet street"), ("nonsense", "The lamps return")],
                SyncType::Unsynced,
            ),
        )
        .unwrap();
        assert_eq!(
            result
                .lines
                .iter()
                .map(|l| l.start_time_ms)
                .collect::<Vec<_>>(),
            [None, None]
        );
        assert_eq!(result.synchronization, LyricSynchronization::Unsynced);
        assert_eq!(
            serde_json::to_value(WireEvent::Lyrics {
                request_id: 42,
                lyrics: result
            })
            .unwrap(),
            json!({
                "type": "lyrics", "requestID": 42, "trackURI": TRACK, "synchronization": "unsynced",
                "lines": [{"text":"A quiet street", "startTimeMs":null}, {"text":"The lamps return", "startTimeMs":null}],
                "provider":"fixture", "providerDisplayName":"Fixture provider", "isRightToLeft":true
            })
        );
    }

    #[test]
    fn invalid_timed_starts_reject_the_whole_response() {
        for start in ["-1", "9223372036854775808", "1000ms", ""] {
            assert_eq!(
                normalize(
                    TRACK.into(),
                    fixture(&[(start, "A quiet street")], SyncType::LineSynced)
                )
                .unwrap_err(),
                LyricFailure::Unavailable
            );
        }
    }

    #[test]
    fn line_count_is_bounded_without_truncation() {
        for (count, accepted) in [(2000, true), (2001, false)] {
            let result = normalize(
                TRACK.into(),
                fixture(&vec![("0", "A"); count], SyncType::LineSynced),
            );
            assert_eq!(result.is_ok(), accepted);
            if let Ok(value) = result {
                assert_eq!(value.lines.len(), 2000);
            } else {
                assert_eq!(result.unwrap_err(), LyricFailure::Unavailable);
            }
        }
    }

    #[test]
    fn text_limit_counts_utf8_bytes_across_lines() {
        let multibyte = "é".repeat(131071);
        for (tail, accepted) in [("ab", true), ("abc", false)] {
            let result = normalize(
                TRACK.into(),
                fixture(&[("0", &multibyte), ("1", tail)], SyncType::LineSynced),
            );
            assert_eq!(result.is_ok(), accepted);
            if !accepted {
                assert_eq!(result.unwrap_err(), LyricFailure::Unavailable);
            }
        }
    }

    #[test]
    fn empty_or_whitespace_content_means_no_lyrics() {
        for lines in [vec![], vec![("0", ""), ("0", " \t\n\u{2003}")]] {
            assert_eq!(
                normalize(TRACK.into(), fixture(&lines, SyncType::LineSynced)).unwrap_err(),
                LyricFailure::NoLyrics
            );
        }
    }

    #[test]
    fn only_canonical_tracks_are_accepted() {
        assert_eq!(parse_track(TRACK).unwrap().to_uri(), TRACK);
        for invalid in [
            "spotify:album:11dFghVXANMlKmJXsNCbNl",
            "spotify:artist:11dFghVXANMlKmJXsNCbNl",
            "spotify:episode:11dFghVXANMlKmJXsNCbNl",
            "spotify:local:artist:album:title:123",
            "garbage",
            "spotify:track:11dFghVXANMlKmJXsNCbNl:extra",
            "spotify:user:alice:track:11dFghVXANMlKmJXsNCbNl",
            "spotify:track:!",
        ] {
            assert!(parse_track(invalid).is_none(), "{invalid}");
        }
    }

    #[derive(Clone)]
    struct Fake {
        result: Result<librespot_metadata::Lyrics, LyricFailure>,
        requested: Arc<Mutex<Vec<String>>>,
        hang: bool,
    }

    impl LyricSource for Fake {
        async fn lyrics(&self, id: &SpotifyId) -> Result<librespot_metadata::Lyrics, LyricFailure> {
            self.requested.lock().unwrap().push(id.to_base62());
            if self.hang {
                std::future::pending::<()>().await;
            }
            self.result.clone()
        }
    }

    fn source(result: Result<librespot_metadata::Lyrics, LyricFailure>) -> Fake {
        Fake {
            result,
            requested: Arc::default(),
            hang: false,
        }
    }

    #[tokio::test]
    async fn resolver_uses_the_requested_track_and_flat_wire_shape() {
        let fake = source(Ok(fixture(
            &[("1000", "A quiet street")],
            SyncType::LineSynced,
        )));
        let event = resolve(&fake, parse_track(TRACK).unwrap(), 42).await;
        assert_eq!(*fake.requested.lock().unwrap(), ["11dFghVXANMlKmJXsNCbNl"]);
        assert_eq!(
            serde_json::to_value(event).unwrap(),
            json!({
                "type":"lyrics", "requestID":42, "trackURI":TRACK, "synchronization":"lineSynced",
                "lines":[{"text":"A quiet street","startTimeMs":1000}],
                "provider":"fixture", "providerDisplayName":"Fixture provider", "isRightToLeft":true
            })
        );
    }

    #[tokio::test]
    async fn failures_keep_request_identity_and_reason() {
        for (reason, wire) in [
            (LyricFailure::NoLyrics, "noLyrics"),
            (LyricFailure::Network, "network"),
            (LyricFailure::Unavailable, "unavailable"),
        ] {
            let event = resolve(&source(Err(reason)), parse_track(TRACK).unwrap(), 17).await;
            assert_eq!(
                serde_json::to_value(event).unwrap(),
                json!({"type":"lyricsFailed", "requestID":17, "trackURI":TRACK, "reason":wire})
            );
        }
        let malformed = source(Ok(fixture(
            &[("bad", "A quiet street")],
            SyncType::LineSynced,
        )));
        assert!(matches!(
            resolve(&malformed, parse_track(TRACK).unwrap(), 18).await,
            WireEvent::LyricsFailed {
                reason: LyricFailure::Unavailable,
                request_id: 18,
                ..
            }
        ));
    }

    #[tokio::test(start_paused = true)]
    async fn stalled_request_reaches_its_deadline() {
        let mut fake = source(Err(LyricFailure::Unavailable));
        fake.hang = true;
        let request = tokio::spawn(async move {
            resolve_within(
                &fake,
                parse_track(TRACK).unwrap(),
                9,
                Duration::from_secs(30),
            )
            .await
        });
        tokio::task::yield_now().await;
        tokio::time::advance(Duration::from_secs(29)).await;
        assert!(!request.is_finished());
        tokio::time::advance(Duration::from_secs(1)).await;
        assert!(matches!(
            request.await.unwrap(),
            WireEvent::LyricsFailed {
                request_id: 9,
                reason: LyricFailure::Network,
                ..
            }
        ));
    }

    #[test]
    fn sdk_errors_map_to_stable_failure_categories() {
        use librespot_core::Error;
        for (error, reason) in [
            (Error::not_found("fixture"), LyricFailure::NoLyrics),
            (Error::deadline_exceeded("fixture"), LyricFailure::Network),
            (Error::unavailable("fixture"), LyricFailure::Network),
            (Error::aborted("fixture"), LyricFailure::Network),
            (Error::resource_exhausted("fixture"), LyricFailure::Network),
            (
                Error::permission_denied("fixture"),
                LyricFailure::Unavailable,
            ),
            (
                Error::failed_precondition("fixture"),
                LyricFailure::Unavailable,
            ),
        ] {
            assert_eq!(classify(&error), reason);
        }
    }
}
