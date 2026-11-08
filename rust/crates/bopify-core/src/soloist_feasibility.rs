use super::event::{RadioFailure, WireEvent};
use librespot_core::{Session, SessionConfig, authentication::Credentials};
use serde::{Deserialize, Serialize};
use std::{
    fs::OpenOptions,
    io::{Read, Write},
    os::unix::fs::OpenOptionsExt,
    time::{Duration, Instant},
};

#[derive(Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
enum ProbeFailure {
    MissingInput,
    InputTooLarge,
    InvalidInput,
    InvalidTrack,
    MissingToken,
    LoginFailed,
    LoginTimeout,
    RuntimeFailed,
    ReportFailed,
}

// Never derive Debug: assertion or error formatting must not reveal credentials.
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct ProbeInput {
    access_token: String,
    track_uri: String,
}

fn read_probe_input(reader: impl Read) -> Result<ProbeInput, ProbeFailure> {
    let mut bytes = Vec::new();
    reader
        .take(16_385)
        .read_to_end(&mut bytes)
        .map_err(|_| ProbeFailure::InvalidInput)?;
    if bytes.is_empty() {
        return Err(ProbeFailure::MissingInput);
    }
    if bytes.len() > 16_384 {
        return Err(ProbeFailure::InputTooLarge);
    }
    let input: ProbeInput =
        serde_json::from_slice(&bytes).map_err(|_| ProbeFailure::InvalidInput)?;
    if input.access_token.trim().is_empty() {
        return Err(ProbeFailure::MissingToken);
    }
    crate::lyrics::parse_track(&input.track_uri).ok_or(ProbeFailure::InvalidTrack)?;
    Ok(input)
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
enum ServiceOutcome {
    Available,
    Absent,
    Network,
    Unavailable,
}

#[derive(Serialize)]
struct ServiceObservation {
    outcome: ServiceOutcome,
    count: usize,
}

impl ServiceObservation {
    fn available(count: usize) -> Self {
        Self {
            outcome: if count > 0 {
                ServiceOutcome::Available
            } else {
                ServiceOutcome::Absent
            },
            count,
        }
    }
    fn unavailable() -> Self {
        Self {
            outcome: ServiceOutcome::Unavailable,
            count: 0,
        }
    }
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct CompanionReport {
    schema_version: u8,
    lyrics: ServiceObservation,
    radio: ServiceObservation,
    artist: ServiceObservation,
    elapsed_ms: u64,
    failure: Option<ProbeFailure>,
}

impl CompanionReport {
    fn from_events(
        lyrics: &WireEvent,
        radio: &WireEvent,
        artist: &WireEvent,
        elapsed_ms: u64,
    ) -> Self {
        let lyrics = match lyrics {
            WireEvent::Lyrics { lyrics, .. } => ServiceObservation::available(lyrics.lines.len()),
            WireEvent::LyricsFailed { reason, .. } => ServiceObservation {
                count: 0,
                outcome: match reason {
                    crate::lyrics::LyricFailure::NoLyrics => ServiceOutcome::Absent,
                    crate::lyrics::LyricFailure::Network => ServiceOutcome::Network,
                    crate::lyrics::LyricFailure::Unavailable => ServiceOutcome::Unavailable,
                },
            },
            _ => ServiceObservation::unavailable(),
        };
        let radio = match radio {
            WireEvent::Radio { tracks, .. } => ServiceObservation::available(tracks.len()),
            WireEvent::RadioFailed { reason, .. } => ServiceObservation {
                count: 0,
                outcome: match reason {
                    RadioFailure::NoMix | RadioFailure::NoTopTrack => ServiceOutcome::Absent,
                    RadioFailure::Network => ServiceOutcome::Network,
                    RadioFailure::Unavailable => ServiceOutcome::Unavailable,
                },
            },
            _ => ServiceObservation::unavailable(),
        };
        let artist = match artist {
            WireEvent::ArtistTopTracks { tracks, .. } => {
                ServiceObservation::available(tracks.len())
            }
            WireEvent::ArtistTopTracksFailed { reason, .. } => ServiceObservation {
                count: 0,
                outcome: match reason {
                    crate::artist::ArtistTopTracksFailure::Network => ServiceOutcome::Network,
                    crate::artist::ArtistTopTracksFailure::Unavailable => {
                        ServiceOutcome::Unavailable
                    }
                },
            },
            _ => ServiceObservation::unavailable(),
        };
        Self {
            schema_version: 1,
            lyrics,
            radio,
            artist,
            elapsed_ms,
            failure: None,
        }
    }

    fn failed(failure: ProbeFailure) -> Self {
        Self {
            schema_version: 1,
            lyrics: ServiceObservation::unavailable(),
            radio: ServiceObservation::unavailable(),
            artist: ServiceObservation::unavailable(),
            elapsed_ms: 0,
            failure: Some(failure),
        }
    }

    fn all_available(&self) -> bool {
        self.failure.is_none()
            && [&self.lyrics, &self.radio, &self.artist]
                .iter()
                .all(|service| {
                    matches!(service.outcome, ServiceOutcome::Available) && service.count > 0
                })
    }
}

async fn probe_services(input: ProbeInput) -> Result<CompanionReport, ProbeFailure> {
    let track = crate::lyrics::parse_track(&input.track_uri).ok_or(ProbeFailure::InvalidTrack)?;
    let seed = crate::radio::Seed::parse(&input.track_uri).ok_or(ProbeFailure::InvalidTrack)?;
    let session = Session::new(SessionConfig::default(), None);
    let started = Instant::now();
    let login = tokio::time::timeout(
        Duration::from_secs(30),
        session.connect(Credentials::with_access_token(&input.access_token), false),
    )
    .await;
    match login {
        Ok(Ok(())) => {}
        failed => {
            session.shutdown();
            return Err(if failed.is_err() {
                ProbeFailure::LoginTimeout
            } else {
                ProbeFailure::LoginFailed
            });
        }
    }
    let lyric_source = crate::lyrics::SessionLyrics(session.clone());
    let radio_source = crate::radio::SessionRadio(session.clone());
    let artist_source = crate::artist::SessionArtist(session.clone());
    let (lyrics, radio, artist) = tokio::join!(
        crate::lyrics::resolve(&lyric_source, track.clone(), 1),
        crate::radio::resolve(&radio_source, seed, 2),
        crate::artist::resolve(&artist_source, track, 0, 3),
    );
    session.shutdown();
    Ok(CompanionReport::from_events(
        &lyrics,
        &radio,
        &artist,
        u64::try_from(started.elapsed().as_millis()).unwrap_or(u64::MAX),
    ))
}

#[test]
#[ignore = "requires the explicit Soloist feasibility runner and fresh interactive credentials"]
fn live_data_session() -> Result<(), ProbeFailure> {
    let input = read_probe_input(std::io::stdin().lock())?;
    let output =
        std::env::var_os("BOPIFY_SOLOIST_PROBE_RESULT_PATH").ok_or(ProbeFailure::ReportFailed)?;
    let mut file = OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(output)
        .map_err(|_| ProbeFailure::ReportFailed)?;
    let runtime = tokio::runtime::Builder::new_multi_thread()
        .worker_threads(2)
        .enable_all()
        .build()
        .map_err(|_| ProbeFailure::RuntimeFailed)?;
    // No global logger: dependency diagnostics may contain identifiers or response data.
    let report = runtime
        .block_on(probe_services(input))
        .unwrap_or_else(CompanionReport::failed);
    drop(runtime);
    let bytes = serde_json::to_vec(&report).map_err(|_| ProbeFailure::ReportFailed)?;
    file.write_all(&bytes)
        .map_err(|_| ProbeFailure::ReportFailed)?;
    Ok(())
}

#[test]
fn rejects_missing_or_oversized_probe_input() {
    assert!(matches!(
        read_probe_input(&b""[..]),
        Err(ProbeFailure::MissingInput)
    ));
    assert!(matches!(
        read_probe_input(&vec![b'x'; 16_385][..]),
        Err(ProbeFailure::InputTooLarge)
    ));
}

#[test]
fn rejects_non_track_uri() {
    let input =
        br#"{"access_token":"sentinel-token","track_uri":"spotify:artist:1111111111111111111111"}"#;
    assert!(matches!(
        read_probe_input(&input[..]),
        Err(ProbeFailure::InvalidTrack)
    ));
}

#[test]
fn rejects_missing_token_without_logging_the_payload() {
    let input = br#"{"access_token":"","track_uri":"spotify:track:1111111111111111111111"}"#;
    assert!(matches!(
        read_probe_input(&input[..]),
        Err(ProbeFailure::MissingToken)
    ));
}

#[test]
fn accepts_valid_private_payload() {
    let input =
        br#"{"access_token":"sentinel-token","track_uri":"spotify:track:1111111111111111111111"}"#;
    let parsed = read_probe_input(&input[..]).unwrap();
    assert_eq!(parsed.track_uri, "spotify:track:1111111111111111111111");
}

#[test]
fn absent_services_are_not_reported_as_successful() {
    let report = CompanionReport::from_events(
        &WireEvent::LyricsFailed {
            request_id: 1,
            track_uri: "sentinel-track".into(),
            reason: crate::lyrics::LyricFailure::NoLyrics,
        },
        &WireEvent::RadioFailed {
            request_id: 2,
            seed_uri: "sentinel-seed".into(),
            reason: RadioFailure::NoMix,
        },
        &WireEvent::ArtistTopTracksFailed {
            request_id: 3,
            track_uri: "sentinel-track".into(),
            reason: crate::artist::ArtistTopTracksFailure::Unavailable,
        },
        100,
    );
    assert!(!report.all_available());
    let text = serde_json::to_string(&report).unwrap();
    for forbidden in ["sentinel", "access_token", "track_uri", "lyrics_text"] {
        assert!(!text.contains(forbidden));
    }
}
