use librespot_metadata::audio::{AudioItem, UniqueFields};
use librespot_playback::player::{PlayerEvent, RemoteState, StartupOutcome};
use serde::Serialize;

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct WireQueueEntry {
    pub id: String,
    pub uri: Option<String>,
    pub raw_next_index: Option<u32>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct WireTrack {
    pub track_uri: String,
    pub title: String,
    pub artists: Vec<String>,
    pub album_title: Option<String>,
    pub artwork_url: Option<String>,
    pub duration_ms: u32,
}

/// Another device's playback, mirrored while Bopify is inactive.
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct WireRemote {
    pub device_name: String,
    pub track_uri: String,
    pub track: Option<WireTrack>,
    pub is_playing: bool,
    pub position_ms: u32,
    pub duration_ms: u32,
}

/// Why a station could not be built. Swift's `RadioFailure` uses these names as raw values.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum RadioFailure {
    NoTopTrack,
    NoMix,
    Unavailable,
    Network,
}

/// The JSON contract between Rust and Swift. Changing a case or a field
/// name here is a breaking change: `BopifyDomain.PlaybackEvent` must
/// change in the same commit.
#[derive(Debug, Clone, Serialize)]
#[serde(tag = "type", rename_all = "camelCase")]
pub enum WireEvent {
    RecoveryIdentity {
        identity: crate::recovery::RecoveryIdentity,
    },
    ConnectionReady {
        outcome: &'static str,
        #[serde(skip_serializing_if = "Option::is_none")]
        identity: Option<crate::recovery::RecoveryIdentity>,
    },
    SessionLost {
        reason: crate::terminal::SessionLossReason,
    },
    QueueChanged {
        generation: u64,
        previous: Vec<WireQueueEntry>,
        current: Option<WireQueueEntry>,
        next: Vec<WireQueueEntry>,
    },
    QueueMetadata {
        generation: u64,
        #[serde(rename = "entryID")]
        entry_id: String,
        track: Option<WireTrack>,
    },
    ShuffleChanged {
        enabled: bool,
    },
    RepeatChanged {
        mode: &'static str,
    },
    CommandRejected {
        reason: &'static str,
    },
    #[serde(rename_all = "camelCase")]
    TrackChanged {
        track_uri: String,
        title: String,
        artists: Vec<String>,
        album_title: Option<String>,
        artwork_url: Option<String>,
        duration_ms: u32,
    },
    #[serde(rename_all = "camelCase")]
    Playing {
        position_ms: u32,
    },
    #[serde(rename_all = "camelCase")]
    Paused {
        position_ms: u32,
    },
    #[serde(rename_all = "camelCase")]
    Seeked {
        position_ms: u32,
    },
    #[serde(rename_all = "camelCase")]
    PositionCorrection {
        position_ms: u32,
    },
    #[serde(rename_all = "camelCase")]
    VolumeChanged {
        volume: u16,
    },
    Loading,
    EndOfTrack,
    #[serde(rename_all = "camelCase")]
    ActiveDeviceChanged {
        is_active: bool,
    },
    #[serde(rename_all = "camelCase")]
    Failed {
        code: i32,
        message: String,
    },
    #[serde(rename_all = "camelCase")]
    StartupResolved {
        outcome: &'static str,
        #[serde(skip_serializing_if = "Option::is_none")]
        device_name: Option<String>,
    },
    RemotePlayback {
        remote: Option<WireRemote>,
    },
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
}

/// Maps librespot's player events onto the wire format.
///
/// Every variant is listed by name and nothing is swallowed by a catch-all,
/// so a variant added by a future librespot bump breaks the build instead of
/// disappearing silently, and a deliberate drop stays distinguishable from an
/// oversight.
pub fn translate(event: PlayerEvent) -> Option<WireEvent> {
    match event {
        PlayerEvent::RecoveryIdentity { identity } => Some(WireEvent::RecoveryIdentity {
            identity: identity.into(),
        }),
        PlayerEvent::ConnectionReady { outcome } => {
            use librespot_playback::player::ConnectionOutcome;
            let (outcome, identity) = match outcome {
                ConnectionOutcome::Local(identity) => ("local", Some(identity.into())),
                ConnectionOutcome::Remote => ("remote", None),
                ConnectionOutcome::Unavailable => ("unavailable", None),
            };
            log::info!("event: connection ready outcome={outcome}");
            Some(WireEvent::ConnectionReady { outcome, identity })
        }
        PlayerEvent::TrackChanged { audio_item } => Some(track_changed(*audio_item)),
        PlayerEvent::Playing { position_ms, .. } => Some(WireEvent::Playing { position_ms }),
        PlayerEvent::Paused { position_ms, .. } => Some(WireEvent::Paused { position_ms }),
        PlayerEvent::Seeked { position_ms, .. } => Some(WireEvent::Seeked { position_ms }),
        PlayerEvent::PositionCorrection { position_ms, .. } => {
            Some(WireEvent::PositionCorrection { position_ms })
        }
        PlayerEvent::Loading { .. } => Some(WireEvent::Loading),
        PlayerEvent::EndOfTrack { .. } => Some(WireEvent::EndOfTrack),
        PlayerEvent::VolumeChanged { volume } => Some(WireEvent::VolumeChanged { volume }),
        // Connection cleanup must not erase resume intent as if a foreign device took over.
        // Connection and user identifiers stay inside the native boundary.
        PlayerEvent::SessionDisconnected {
            connection_lost, ..
        } => {
            log::info!("event: session disconnected connection_lost={connection_lost}");
            if connection_lost {
                Some(WireEvent::SessionLost {
                    reason: crate::terminal::SessionLossReason::Legacy,
                })
            } else {
                Some(WireEvent::ActiveDeviceChanged { is_active: false })
            }
        }

        // Deliberately dropped, by name. Each of these is either internal to
        // librespot, out of scope for this slice, or already covered by an
        // event we do forward.
        //
        // `SessionConnected` also carries `user_name`; its "we are active now"
        // signal is redundant because Playing and Paused already imply it.
        PlayerEvent::SessionConnected { .. } => dropped("SessionConnected"),
        PlayerEvent::SessionClientChanged { .. } => dropped("SessionClientChanged"),
        PlayerEvent::PlayRequestIdChanged { .. } => dropped("PlayRequestIdChanged"),
        PlayerEvent::Stopped { .. } => dropped("Stopped"),
        PlayerEvent::Preloading { .. } => dropped("Preloading"),
        PlayerEvent::TimeToPreloadNextTrack { .. } => dropped("TimeToPreloadNextTrack"),
        PlayerEvent::Unavailable { .. } => dropped("Unavailable"),
        PlayerEvent::PositionChanged { .. } => dropped("PositionChanged"),
        PlayerEvent::SetQueue {
            generation,
            current_track,
            next_tracks,
            prev_tracks,
            ..
        } => Some(WireEvent::QueueChanged {
            generation,
            previous: prev_tracks.into_iter().filter_map(queue_entry).collect(),
            current: current_track.and_then(queue_entry),
            next: next_tracks.into_iter().filter_map(queue_entry).collect(),
        }),
        PlayerEvent::StartupResolved { outcome } => Some(startup_resolved(outcome)),
        PlayerEvent::RemotePlayback { remote } => Some(remote_playback(remote)),
        PlayerEvent::ShuffleChanged { shuffle } => {
            Some(WireEvent::ShuffleChanged { enabled: shuffle })
        }
        PlayerEvent::RepeatChanged { context, track } => Some(WireEvent::RepeatChanged {
            mode: if track {
                "track"
            } else if context {
                "context"
            } else {
                "off"
            },
        }),
        PlayerEvent::AutoPlayChanged { .. } => dropped("AutoPlayChanged"),
        PlayerEvent::FilterExplicitContentChanged { .. } => dropped("FilterExplicitContentChanged"),
    }
}

fn dropped(kind: &str) -> Option<WireEvent> {
    log::debug!("event: dropping unmodelled player event kind={kind}");
    None
}

fn startup_resolved(outcome: StartupOutcome) -> WireEvent {
    let (outcome, device_name) = match outcome {
        StartupOutcome::Restored => ("restored", None),
        StartupOutcome::LikedSongs => ("likedSongs", None),
        StartupOutcome::Remote { device_name } => ("remote", Some(device_name)),
        StartupOutcome::Nothing => ("nothing", None),
    };
    // The outcome only: a device name is whatever the user called their phone.
    log::info!("event: startup resolved outcome={outcome}");
    WireEvent::StartupResolved {
        outcome,
        device_name,
    }
}

fn remote_playback(remote: Option<RemoteState>) -> WireEvent {
    // Presence only: a device name is whatever the user called their phone.
    log::debug!("event: remote playback present={}", remote.is_some());
    WireEvent::RemotePlayback {
        remote: remote.map(|remote| WireRemote {
            device_name: remote.device_name,
            track_uri: remote.track_uri,
            track: None,
            is_playing: remote.is_playing,
            position_ms: remote.position_ms,
            duration_ms: remote.duration_ms,
        }),
    }
}

fn queue_entry(track: librespot_playback::player::QueueTrack) -> Option<WireQueueEntry> {
    use librespot_core::SpotifyUri;
    if track.uid.starts_with("delimiter") {
        return None;
    }
    let playable = track.provider != "unavailable"
        && matches!(
            SpotifyUri::from_uri(&track.uri),
            Ok(SpotifyUri::Track { .. } | SpotifyUri::Episode { .. })
        );
    Some(WireQueueEntry {
        id: track.id.to_string(),
        uri: playable.then_some(track.uri),
        raw_next_index: if playable { track.raw_next_index } else { None },
    })
}

fn track_changed(item: AudioItem) -> WireEvent {
    let WireTrack {
        track_uri,
        title,
        artists,
        album_title,
        artwork_url,
        duration_ms,
    } = track_metadata(item);
    WireEvent::TrackChanged {
        track_uri,
        title,
        artists,
        album_title,
        artwork_url,
        duration_ms,
    }
}

pub(crate) fn track_metadata(item: AudioItem) -> WireTrack {
    let (artists, album_title) = match item.unique_fields {
        UniqueFields::Track { artists, album, .. } => {
            (artists.0.into_iter().map(|a| a.name).collect(), Some(album))
        }
        UniqueFields::Episode { show_name, .. } => (vec![show_name], None),
        UniqueFields::Local { artists, album, .. } => (artists.into_iter().collect(), album),
    };
    // The spike saw `covers` sorted widest-first, but that is one observation
    // and not a documented guarantee, so pick by width rather than by index.
    let artwork_url = item
        .covers
        .iter()
        .max_by_key(|cover| cover.width)
        .map(|cover| cover.url.clone());

    WireTrack {
        track_uri: item.uri,
        title: item.name,
        artists,
        album_title,
        artwork_url,
        duration_ms: item.duration_ms,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn playing_serialises_with_a_type_tag() {
        let json = serde_json::to_string(&WireEvent::Playing { position_ms: 1000 }).unwrap();
        assert_eq!(json, r#"{"type":"playing","positionMs":1000}"#);
    }

    #[test]
    fn track_changed_carries_metadata() {
        let json = serde_json::to_string(&WireEvent::TrackChanged {
            track_uri: "spotify:track:abc".into(),
            title: "Title".into(),
            artists: vec!["Artist".into()],
            album_title: Some("Album".into()),
            artwork_url: None,
            duration_ms: 240_000,
        })
        .unwrap();
        assert!(json.contains(r#""type":"trackChanged""#));
        assert!(json.contains(r#""durationMs":240000"#));
        assert!(json.contains(r#""artworkUrl":null"#));
    }

    #[test]
    fn active_device_changed_round_trips() {
        let json =
            serde_json::to_string(&WireEvent::ActiveDeviceChanged { is_active: false }).unwrap();
        assert_eq!(json, r#"{"type":"activeDeviceChanged","isActive":false}"#);
    }

    use std::borrow::Cow;

    use librespot_core::SpotifyUri;
    use librespot_metadata::{
        artist::{ArtistRole, ArtistWithRole, ArtistsWithRole},
        audio::{AudioFiles, item::CoverImage},
        image::ImageSize,
    };

    fn uri() -> SpotifyUri {
        SpotifyUri::Unknown {
            kind: Cow::Borrowed("track"),
            id: "5Ohxk2dO5COHF1krpoPigN".into(),
        }
    }

    fn cover(url: &str, size: ImageSize, width: i32) -> CoverImage {
        CoverImage {
            url: url.into(),
            size,
            width,
            height: width,
        }
    }

    fn audio_item(covers: Vec<CoverImage>, unique_fields: UniqueFields) -> AudioItem {
        AudioItem {
            track_id: uri(),
            uri: "spotify:track:5Ohxk2dO5COHF1krpoPigN".into(),
            files: AudioFiles::default(),
            name: "Sign of the Times".into(),
            covers,
            language: vec![],
            duration_ms: 340_706,
            is_explicit: false,
            availability: Ok(()),
            alternatives: None,
            unique_fields,
        }
    }

    fn one_track(name: &str) -> UniqueFields {
        UniqueFields::Track {
            artists: ArtistsWithRole(vec![ArtistWithRole {
                id: uri(),
                name: name.into(),
                role: ArtistRole::ARTIST_ROLE_MAIN_ARTIST,
            }]),
            album: "Harry Styles".into(),
            album_artists: vec![],
            popularity: 94,
            number: 2,
            disc_number: 1,
        }
    }

    #[test]
    fn track_changed_carries_the_spike_metadata() {
        let item = audio_item(
            vec![cover(
                "https://i.scdn.co/image/large",
                ImageSize::LARGE,
                640,
            )],
            one_track("Harry Styles"),
        );
        let wire = translate(PlayerEvent::TrackChanged {
            audio_item: Box::new(item),
        })
        .unwrap();
        let WireEvent::TrackChanged {
            track_uri,
            title,
            artists,
            album_title,
            artwork_url,
            duration_ms,
        } = wire
        else {
            panic!("expected TrackChanged");
        };
        assert_eq!(track_uri, "spotify:track:5Ohxk2dO5COHF1krpoPigN");
        assert_eq!(title, "Sign of the Times");
        assert_eq!(artists, vec!["Harry Styles".to_string()]);
        assert_eq!(album_title.as_deref(), Some("Harry Styles"));
        assert_eq!(
            artwork_url.as_deref(),
            Some("https://i.scdn.co/image/large")
        );
        assert_eq!(duration_ms, 340_706);
    }

    #[test]
    fn artwork_picks_the_widest_cover_regardless_of_order() {
        let item = audio_item(
            vec![
                cover("https://i.scdn.co/image/small", ImageSize::SMALL, 64),
                cover("https://i.scdn.co/image/large", ImageSize::LARGE, 640),
                cover("https://i.scdn.co/image/default", ImageSize::DEFAULT, 300),
            ],
            one_track("Harry Styles"),
        );
        let wire = translate(PlayerEvent::TrackChanged {
            audio_item: Box::new(item),
        })
        .unwrap();
        let WireEvent::TrackChanged { artwork_url, .. } = wire else {
            panic!("expected TrackChanged")
        };
        assert_eq!(
            artwork_url.as_deref(),
            Some("https://i.scdn.co/image/large")
        );
    }

    #[test]
    fn session_disconnected_becomes_an_inactive_device() {
        let wire = translate(PlayerEvent::SessionDisconnected {
            connection_id: "conn".into(),
            user_name: "31abcdef".into(),
            connection_lost: false,
        });
        assert_eq!(
            serde_json::to_string(&wire.unwrap()).unwrap(),
            r#"{"type":"activeDeviceChanged","isActive":false}"#
        );
    }

    #[test]
    fn lost_connection_is_terminal_before_late_cleanup_events() {
        use crate::terminal::{EngineReporter, SessionLossReason};
        use std::sync::{Arc, Mutex};

        let events = Arc::new(Mutex::new(Vec::new()));
        let output = events.clone();
        let reporter =
            EngineReporter::new(Arc::new(move |event| output.lock().unwrap().push(event)));
        reporter.event(
            translate(PlayerEvent::SessionDisconnected {
                connection_id: "conn".into(),
                user_name: "31abcdef".into(),
                connection_lost: true,
            })
            .unwrap(),
        );
        reporter.event(WireEvent::ActiveDeviceChanged { is_active: false });
        reporter.event(WireEvent::Paused { position_ms: 250 });
        reporter.session_lost(SessionLossReason::PlayerChannelClosed);
        let events = events.lock().unwrap();
        assert_eq!(events.len(), 1);
        assert!(matches!(
            events[0],
            WireEvent::SessionLost {
                reason: SessionLossReason::Legacy
            }
        ));
    }

    #[test]
    fn session_connected_is_dropped_so_the_user_id_never_crosses() {
        let wire = translate(PlayerEvent::SessionConnected {
            connection_id: "conn".into(),
            user_name: "31abcdef".into(),
        });
        assert!(wire.is_none());
    }

    #[test]
    fn volume_and_transport_events_map_across() {
        assert!(matches!(
            translate(PlayerEvent::VolumeChanged { volume: 32767 }),
            Some(WireEvent::VolumeChanged { volume: 32767 })
        ));
        assert!(matches!(
            translate(PlayerEvent::Playing {
                play_request_id: 1,
                track_id: uri(),
                position_ms: 42
            }),
            Some(WireEvent::Playing { position_ms: 42 })
        ));
        assert!(matches!(
            translate(PlayerEvent::Loading {
                play_request_id: 1,
                track_id: uri(),
                position_ms: 0
            }),
            Some(WireEvent::Loading)
        ));
    }
    #[test]
    fn queue_snapshot_keeps_occurrences_and_raw_indices_on_the_wire() {
        let event = WireEvent::QueueChanged {
            generation: 12,
            previous: vec![],
            current: None,
            next: vec![
                WireQueueEntry {
                    id: "a".into(),
                    uri: Some("spotify:track:same".into()),
                    raw_next_index: Some(0),
                },
                WireQueueEntry {
                    id: "b".into(),
                    uri: Some("spotify:track:same".into()),
                    raw_next_index: Some(1),
                },
            ],
        };
        assert_eq!(
            serde_json::to_string(&event).unwrap(),
            r#"{"type":"queueChanged","generation":12,"previous":[],"current":null,"next":[{"id":"a","uri":"spotify:track:same","rawNextIndex":0},{"id":"b","uri":"spotify:track:same","rawNextIndex":1}]}"#
        );
    }
    #[test]
    fn repeat_track_takes_priority_over_repeat_context() {
        let json = serde_json::to_value(
            translate(PlayerEvent::RepeatChanged {
                context: true,
                track: true,
            })
            .unwrap(),
        )
        .unwrap();
        assert_eq!(
            json,
            serde_json::json!({"type":"repeatChanged", "mode":"track"})
        );
    }

    #[test]
    fn startup_outcomes_carry_a_device_name_only_when_remote() {
        let remote = translate(PlayerEvent::StartupResolved {
            outcome: StartupOutcome::Remote {
                device_name: "iPhone".into(),
            },
        });
        assert_eq!(
            serde_json::to_string(&remote.unwrap()).unwrap(),
            r#"{"type":"startupResolved","outcome":"remote","deviceName":"iPhone"}"#
        );
        for (outcome, wire) in [
            (StartupOutcome::Restored, "restored"),
            (StartupOutcome::LikedSongs, "likedSongs"),
            (StartupOutcome::Nothing, "nothing"),
        ] {
            let event = translate(PlayerEvent::StartupResolved { outcome }).unwrap();
            assert_eq!(
                serde_json::to_string(&event).unwrap(),
                format!(r#"{{"type":"startupResolved","outcome":"{wire}"}}"#)
            );
        }
    }

    #[test]
    fn remote_playback_serialises_the_mirror_or_null() {
        let none = translate(PlayerEvent::RemotePlayback { remote: None }).unwrap();
        assert_eq!(
            serde_json::to_string(&none).unwrap(),
            r#"{"type":"remotePlayback","remote":null}"#
        );
        let some = translate(PlayerEvent::RemotePlayback {
            remote: Some(RemoteState {
                device_name: "iPhone".into(),
                track_uri: "spotify:track:abc".into(),
                is_playing: true,
                position_ms: 7_500,
                duration_ms: 200_000,
            }),
        })
        .unwrap();
        assert_eq!(
            serde_json::to_string(&some).unwrap(),
            r#"{"type":"remotePlayback","remote":{"deviceName":"iPhone","trackUri":"spotify:track:abc","track":null,"isPlaying":true,"positionMs":7500,"durationMs":200000}}"#
        );
    }

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
}
