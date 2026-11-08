#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BopifyError {
    InvalidArgument,
    SessionLost,
    AuthInvalid,
    PremiumRequired,
    NetworkUnavailable,
    AccountRestricted,
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
            Self::AccountRestricted => -6,
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
            Self::AccountRestricted => "Spotify will not let this account play here",
            Self::Unknown => "unknown error",
        }
    }
}
