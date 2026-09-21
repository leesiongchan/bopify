#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BopifyError {
    InvalidArgument,
    SessionLost,
    AuthInvalid,
    PremiumRequired,
    NetworkUnavailable,
    Unknown,
}

impl BopifyError {
    /// Every variant, for tests that need to iterate the taxonomy.
    ///
    /// Hand-maintained, and deliberately so: adding a variant already breaks
    /// the build twice, at `code()` and at `message()`, which are exhaustive
    /// matches in this file. This third list is the one the compiler will not
    /// catch. Forgetting it does not break the wire contract -- it only makes
    /// `every_code_has_a_message`, currently its sole consumer, silently skip
    /// the new variant.
    pub const ALL: [BopifyError; 6] = [
        Self::InvalidArgument,
        Self::SessionLost,
        Self::AuthInvalid,
        Self::PremiumRequired,
        Self::NetworkUnavailable,
        Self::Unknown,
    ];

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

    #[test]
    fn codes_are_stable() {
        assert_eq!(BopifyError::InvalidArgument.code(), -1);
        assert_eq!(BopifyError::SessionLost.code(), -2);
        assert_eq!(BopifyError::AuthInvalid.code(), -3);
        assert_eq!(BopifyError::PremiumRequired.code(), -4);
        assert_eq!(BopifyError::NetworkUnavailable.code(), -5);
        assert_eq!(BopifyError::Unknown.code(), -99);
    }

    #[test]
    fn every_code_has_a_message() {
        for e in BopifyError::ALL {
            assert!(!e.message().is_empty());
        }
    }
}
