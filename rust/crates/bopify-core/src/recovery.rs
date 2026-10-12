use crate::error::BopifyError;
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct EngineCreateOptions {
    pub device_id: String,
    pub startup: StartupMode,
    pub snapshot: Option<RecoveryCheckpoint>,
}

#[derive(Debug, Clone, Copy, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum StartupMode {
    ColdLaunch,
    Recovery,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct RecoveryCheckpoint {
    pub was_active: bool,
    pub should_resume: bool,
    pub identity: Option<RecoveryIdentity>,
    pub position_ms: i64,
    pub volume: f64,
    pub shuffle_enabled: bool,
    pub repeat_mode: String,
}

#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct RecoveryIdentity {
    pub track_uri: String,
    pub track_uid: Option<String>,
    pub context_uri: Option<String>,
}

impl EngineCreateOptions {
    pub fn parse(json: &str) -> Result<Self, BopifyError> {
        let options: Self = serde_json::from_str(json).map_err(|_| BopifyError::InvalidArgument)?;
        options.validate()?;
        Ok(options)
    }
    pub fn validate(&self) -> Result<(), BopifyError> {
        if self.device_id.trim().is_empty()
            || self.device_id.len() > 256
            || self.device_id.contains('\0')
        {
            return Err(BopifyError::InvalidArgument);
        }
        if matches!(self.startup, StartupMode::ColdLaunch) && self.snapshot.is_some() {
            return Err(BopifyError::InvalidArgument);
        }
        if let Some(s) = &self.snapshot {
            if s.position_ms < 0
                || !s.volume.is_finite()
                || !(0.0..=1.0).contains(&s.volume)
                || !["off", "context", "track"].contains(&s.repeat_mode.as_str())
                || (s.should_resume && (!s.was_active || s.identity.is_none()))
            {
                return Err(BopifyError::InvalidArgument);
            }
            if let Some(identity) = &s.identity {
                if !matches!(
                    librespot_core::SpotifyUri::from_uri(&identity.track_uri),
                    Ok(uri @ (librespot_core::SpotifyUri::Track { .. }
                        | librespot_core::SpotifyUri::Episode { .. })) if uri.to_uri() == identity.track_uri
                ) {
                    return Err(BopifyError::InvalidArgument);
                }
            }
        }
        Ok(())
    }
    pub fn native_startup(&self) -> librespot_connect::StartupMode {
        match self.startup {
            StartupMode::ColdLaunch => librespot_connect::StartupMode::ColdLaunch,
            StartupMode::Recovery => {
                librespot_connect::StartupMode::Recovery(self.snapshot.as_ref().map(|s| {
                    librespot_connect::RecoveryCheckpoint {
                        was_active: s.was_active,
                        should_resume: s.should_resume,
                        identity: s.identity.clone().map(Into::into),
                        position_ms: s.position_ms,
                        volume: s.volume,
                        shuffle_enabled: s.shuffle_enabled,
                        repeat_mode: s.repeat_mode.clone(),
                    }
                }))
            }
        }
    }
}

impl From<librespot_playback::player::RecoveryIdentity> for RecoveryIdentity {
    fn from(i: librespot_playback::player::RecoveryIdentity) -> Self {
        Self {
            track_uri: i.track_uri,
            track_uid: i.track_uid,
            context_uri: i.context_uri,
        }
    }
}
impl From<RecoveryIdentity> for librespot_connect::RecoveryIdentity {
    fn from(i: RecoveryIdentity) -> Self {
        Self {
            track_uri: i.track_uri,
            track_uid: i.track_uid,
            context_uri: i.context_uri,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn recovery_options_validate_before_network_work() {
        for json in [
            r#"{"deviceId":"","startup":"recovery"}"#,
            r#"{"deviceId":"own","startup":"wrong"}"#,
            r#"{"deviceId":"own","startup":"recovery","snapshot":{"wasActive":true,"shouldResume":true,"identity":null,"positionMs":0,"volume":0,"shuffleEnabled":false,"repeatMode":"off"}}"#,
            r#"{"deviceId":"own","startup":"recovery","snapshot":{"wasActive":false,"shouldResume":false,"identity":null,"positionMs":-1,"volume":0,"shuffleEnabled":false,"repeatMode":"off"}}"#,
        ] {
            assert!(EngineCreateOptions::parse(json).is_err());
        }
        assert!(EngineCreateOptions::parse(r#"{"deviceId":"own","startup":"recovery","snapshot":{"wasActive":true,"shouldResume":false,"identity":null,"positionMs":0,"volume":0,"shuffleEnabled":false,"repeatMode":"off"}}"#).is_ok());
    }

    #[test]
    fn recovery_rejects_noncanonical_track_identities() {
        for uri in [
            "spotify:track:6rqhFgbbKwnb9MLmUQDhG6:extra",
            "spotify:user:alice:track:6rqhFgbbKwnb9MLmUQDhG6",
        ] {
            let json = serde_json::json!({
                "deviceId": "own", "startup": "recovery",
                "snapshot": {
                    "wasActive": true, "shouldResume": true,
                    "identity": { "trackUri": uri }, "positionMs": 0,
                    "volume": 0.5, "shuffleEnabled": false, "repeatMode": "off"
                }
            });
            assert!(
                EngineCreateOptions::parse(&json.to_string()).is_err(),
                "{uri}"
            );
        }
    }
}
