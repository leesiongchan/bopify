use librespot_metadata::audio::{AudioItem, UniqueFields};
use serde::Serialize;
use std::time::Duration;

/// Request deadlines stay shorter than the Swift reply watchdog.
pub(crate) const REPLY_DEADLINE: Duration = Duration::from_secs(30);

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

/// Why a station could not be built. Swift's `RadioFailure` uses these names as raw values.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum RadioFailure {
    NoTopTrack,
    NoMix,
    Unavailable,
    Network,
}

/// Metadata reply JSON consumed by the Swift event bridge.
#[derive(Debug, Clone, Serialize)]
#[serde(tag = "type", rename_all = "camelCase")]
pub enum WireEvent {
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
    Lyrics {
        #[serde(rename = "requestID")]
        request_id: u64,
        #[serde(flatten)]
        lyrics: crate::lyrics::WireLyrics,
    },
    LyricsFailed {
        #[serde(rename = "requestID")]
        request_id: u64,
        #[serde(rename = "trackURI")]
        track_uri: String,
        reason: crate::lyrics::LyricFailure,
    },
    ArtistTopTracks {
        #[serde(rename = "requestID")]
        request_id: u64,
        #[serde(rename = "trackURI")]
        track_uri: String,
        tracks: Vec<WireTrack>,
    },
    ArtistTopTracksFailed {
        #[serde(rename = "requestID")]
        request_id: u64,
        #[serde(rename = "trackURI")]
        track_uri: String,
        reason: crate::artist::ArtistTopTracksFailure,
    },
}

pub(crate) fn track_metadata(item: AudioItem) -> WireTrack {
    let (artists, album_title) = match item.unique_fields {
        UniqueFields::Track { artists, album, .. } => {
            (artists.0.into_iter().map(|a| a.name).collect(), Some(album))
        }
        UniqueFields::Episode { show_name, .. } => (vec![show_name], None),
        UniqueFields::Local { artists, album, .. } => (artists.into_iter().collect(), album),
    };
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
    fn track_metadata_preserves_the_wire_shape() {
        let item = audio_item(
            vec![cover(
                "https://i.scdn.co/image/large",
                ImageSize::LARGE,
                640,
            )],
            one_track("Harry Styles"),
        );
        let wire = track_metadata(item);
        assert_eq!(
            serde_json::to_value(wire).unwrap(),
            serde_json::json!({
                "trackUri": "spotify:track:5Ohxk2dO5COHF1krpoPigN",
                "title": "Sign of the Times", "artists": ["Harry Styles"],
                "albumTitle": "Harry Styles", "artworkUrl": "https://i.scdn.co/image/large",
                "durationMs": 340706
            })
        );
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
        let wire = track_metadata(item);
        let artwork_url = wire.artwork_url;
        assert_eq!(
            artwork_url.as_deref(),
            Some("https://i.scdn.co/image/large")
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
