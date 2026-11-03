#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BopifyError {
    InvalidArgument,
    SessionLost,
    AuthInvalid,
    PremiumRequired,
    NetworkUnavailable,
    Unknown,
}

impl std::fmt::Display for BopifyError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str(self.message())
    }
}

impl std::error::Error for BopifyError {}

impl BopifyError {
    pub fn code(&self) -> i32 {
        match self {
            Self::InvalidArgument => -1,
            Self::SessionLost => -2,
            Self::AuthInvalid => -3,
            Self::PremiumRequired => -4,
            Self::NetworkUnavailable => -5,
            Self::Unknown => -99,
        }
    }

    pub fn message(&self) -> &'static str {
        match self {
            Self::InvalidArgument => "invalid argument",
            Self::SessionLost => "playback session lost",
            Self::AuthInvalid => "access token rejected or expired",
            Self::PremiumRequired => "Spotify Premium is required",
            Self::NetworkUnavailable => "network unavailable",
            Self::Unknown => "unknown error",
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Swift's `LibrespotEngineTests` read the same fixture, so a code changes on both sides or neither.
    #[test]
    fn codes_match_the_shared_wire_contract() {
        use BopifyError::*;
        fn name(error: BopifyError) -> &'static str {
            // A new variant stops this compiling until it is named, and so listed in the fixture.
            match error {
                InvalidArgument => "invalidArgument",
                SessionLost => "sessionLost",
                AuthInvalid => "authInvalid",
                PremiumRequired => "premiumRequired",
                NetworkUnavailable => "networkUnavailable",
                Unknown => "unknown",
            }
        }
        let all = [
            InvalidArgument,
            SessionLost,
            AuthInvalid,
            PremiumRequired,
            NetworkUnavailable,
            Unknown,
        ];
        let actual: std::collections::BTreeMap<String, i32> = all
            .iter()
            .map(|error| (name(*error).to_owned(), error.code()))
            .collect();
        let contract: std::collections::BTreeMap<String, i32> =
            serde_json::from_str(include_str!(concat!(
                env!("CARGO_MANIFEST_DIR"),
                "/../../../contracts/ffi-error-codes.json"
            )))
            .unwrap();
        assert_eq!(actual, contract);
    }
}
