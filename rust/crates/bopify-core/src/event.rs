use librespot_metadata::audio::{AudioItem, UniqueFields};
use librespot_playback::player::PlayerEvent;
use serde::Serialize;

/// The JSON contract between Rust and Swift. Changing a case or a field
/// name here is a breaking change: `BopifyDomain.PlaybackEvent` must
/// change in the same commit.
#[derive(Debug, Clone, Serialize)]
#[serde(tag = "type", rename_all = "camelCase")]
pub enum WireEvent {
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
    Playing { position_ms: u32 },
    #[serde(rename_all = "camelCase")]
    Paused { position_ms: u32 },
    #[serde(rename_all = "camelCase")]
    Seeked { position_ms: u32 },
    #[serde(rename_all = "camelCase")]
    PositionCorrection { position_ms: u32 },
    #[serde(rename_all = "camelCase")]
    VolumeChanged { volume: u16 },
    Loading,
    EndOfTrack,
    #[serde(rename_all = "camelCase")]
    ActiveDeviceChanged { is_active: bool },
    #[serde(rename_all = "camelCase")]
    Failed { code: i32, message: String },
}

/// Maps librespot's player events onto the wire format.
///
/// Every variant is listed by name and nothing is swallowed by a catch-all,
/// so a variant added by a future librespot bump breaks the build instead of
/// disappearing silently, and a deliberate drop stays distinguishable from an
/// oversight.
pub fn translate(event: PlayerEvent) -> Option<WireEvent> {
    match event {
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
        // The only source of "another device took over": spirc emits it from
        // handle_disconnect (connect/src/spirc.rs:1316), reached when a cluster
        // update shows a different active device. `connection_id` and
        // `user_name` are discarded -- `user_name` is the numeric Spotify user
        // id and must not cross the boundary.
        PlayerEvent::SessionDisconnected { .. } => {
            Some(WireEvent::ActiveDeviceChanged { is_active: false })
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
        PlayerEvent::SetQueue { .. } => dropped("SetQueue"),
        PlayerEvent::ShuffleChanged { .. } => dropped("ShuffleChanged"),
        PlayerEvent::RepeatChanged { .. } => dropped("RepeatChanged"),
        PlayerEvent::AutoPlayChanged { .. } => dropped("AutoPlayChanged"),
        PlayerEvent::FilterExplicitContentChanged { .. } => {
            dropped("FilterExplicitContentChanged")
        }
    }
}

fn dropped(kind: &str) -> Option<WireEvent> {
    log::debug!("event: dropping unmodelled player event kind={kind}");
    None
}

fn track_changed(item: AudioItem) -> WireEvent {
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

    WireEvent::TrackChanged {
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
        let json = serde_json::to_string(&WireEvent::ActiveDeviceChanged { is_active: false }).unwrap();
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
        SpotifyUri::Unknown { kind: Cow::Borrowed("track"), id: "5Ohxk2dO5COHF1krpoPigN".into() }
    }

    fn cover(url: &str, size: ImageSize, width: i32) -> CoverImage {
        CoverImage { url: url.into(), size, width, height: width }
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
            vec![cover("https://i.scdn.co/image/large", ImageSize::LARGE, 640)],
            one_track("Harry Styles"),
        );
        let wire = translate(PlayerEvent::TrackChanged { audio_item: Box::new(item) }).unwrap();
        let WireEvent::TrackChanged { track_uri, title, artists, album_title, artwork_url, duration_ms } = wire
        else {
            panic!("expected TrackChanged");
        };
        assert_eq!(track_uri, "spotify:track:5Ohxk2dO5COHF1krpoPigN");
        assert_eq!(title, "Sign of the Times");
        assert_eq!(artists, vec!["Harry Styles".to_string()]);
        assert_eq!(album_title.as_deref(), Some("Harry Styles"));
        assert_eq!(artwork_url.as_deref(), Some("https://i.scdn.co/image/large"));
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
        let wire = translate(PlayerEvent::TrackChanged { audio_item: Box::new(item) }).unwrap();
        let WireEvent::TrackChanged { artwork_url, .. } = wire else { panic!("expected TrackChanged") };
        assert_eq!(artwork_url.as_deref(), Some("https://i.scdn.co/image/large"));
    }

    #[test]
    fn session_disconnected_becomes_an_inactive_device() {
        let wire = translate(PlayerEvent::SessionDisconnected {
            connection_id: "conn".into(),
            user_name: "31abcdef".into(),
        });
        assert_eq!(
            serde_json::to_string(&wire.unwrap()).unwrap(),
            r#"{"type":"activeDeviceChanged","isActive":false}"#
        );
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
            translate(PlayerEvent::Playing { play_request_id: 1, track_id: uri(), position_ms: 42 }),
            Some(WireEvent::Playing { position_ms: 42 })
        ));
        assert!(matches!(
            translate(PlayerEvent::Loading { play_request_id: 1, track_id: uri(), position_ms: 0 }),
            Some(WireEvent::Loading)
        ));
    }
}
