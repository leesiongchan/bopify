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
}
