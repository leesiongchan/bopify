#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BopifyError {
    InvalidArgument,
    SessionLost,
    AuthInvalid,
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
            Self::NetworkUnavailable => -5,
            Self::Unknown => -99,
        }
    }

    pub fn message(&self) -> &'static str {
        match self {
            Self::InvalidArgument => "invalid argument",
            Self::SessionLost => "metadata session lost",
            Self::AuthInvalid => "access token rejected or expired",
            Self::NetworkUnavailable => "network unavailable",
            Self::Unknown => "unknown error",
        }
    }
}
