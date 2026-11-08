//! Owns the authenticated metadata session on a synchronously joined Tokio runtime.

use crate::{error::BopifyError, event::WireEvent};
use librespot_core::{Session, SessionConfig, authentication::Credentials};
use std::sync::Arc;
use tokio::runtime::Runtime;

/// Runs on a Rust runtime thread; callback context stays valid until destruction returns.
pub type EventSink = Arc<dyn Fn(WireEvent) + Send + Sync>;

/// Runtime drops first, joining all callbacks before the remaining fields are released.
pub struct Services {
    runtime: Runtime,
    sink: EventSink,
    session: Session,
}

impl Services {
    /// Blocks during login. The caller must run this away from the UI thread.
    pub fn new(
        access_token: &str,
        expected_username: &str,
        sink: EventSink,
    ) -> Result<Self, BopifyError> {
        validate_identity(expected_username)?;
        log::info!("services: creating metadata session");
        let runtime = tokio::runtime::Builder::new_multi_thread()
            .worker_threads(2)
            .enable_all()
            .build()
            .map_err(|why| {
                log::error!("services: runtime build failed kind={:?}", why.kind());
                BopifyError::Unknown
            })?;
        let session = runtime.block_on(async {
            let session = Session::new(SessionConfig::default(), None);
            with_connect_deadline(
                session.connect(Credentials::with_access_token(access_token), false),
            )
            .await?;
            verify_identity(&session, expected_username)?;
            Ok::<_, BopifyError>(session)
        })?;
        log::info!("services: metadata session connected");
        Ok(Self {
            runtime,
            sink,
            session,
        })
    }

    /// Queues a station lookup. The answer arrives on the sink as `Radio` or
    /// `RadioFailed` carrying `request_id`, and the work ends with the runtime.
    pub fn request_radio(&self, seed_uri: &str, request_id: u64) -> Result<(), BopifyError> {
        let seed = crate::radio::Seed::parse(seed_uri).ok_or(BopifyError::InvalidArgument)?;
        let source = crate::radio::SessionRadio(self.session.clone());
        let sink = self.sink.clone();
        self.runtime
            .spawn(async move { sink(crate::radio::resolve(&source, seed, request_id).await) });
        Ok(())
    }

    /// Queues a lyric lookup. The answer arrives on the sink as `Lyrics` or
    /// `LyricsFailed` carrying `request_id`, and the work ends with the runtime.
    pub fn request_lyrics(&self, track_uri: &str, request_id: u64) -> Result<(), BopifyError> {
        let track = crate::lyrics::parse_track(track_uri).ok_or(BopifyError::InvalidArgument)?;
        let source = crate::lyrics::SessionLyrics(self.session.clone());
        let sink = self.sink.clone();
        self.runtime
            .spawn(async move { sink(crate::lyrics::resolve(&source, track, request_id).await) });
        Ok(())
    }

    /// Queues a displayed artist's popular songs. The answer arrives on the sink as
    /// `ArtistTopTracks` or `ArtistTopTracksFailed` carrying `request_id`.
    pub fn request_artist_top_tracks(
        &self,
        track_uri: &str,
        artist_index: u32,
        request_id: u64,
    ) -> Result<(), BopifyError> {
        let track = crate::lyrics::parse_track(track_uri).ok_or(BopifyError::InvalidArgument)?;
        let source = crate::artist::SessionArtist(self.session.clone());
        let sink = self.sink.clone();
        self.runtime.spawn(async move {
            sink(crate::artist::resolve(&source, track, artist_index, request_id).await)
        });
        Ok(())
    }
}

pub(crate) fn validate_identity(username: &str) -> Result<(), BopifyError> {
    if username.trim().is_empty() || username.len() > 256 || username.chars().any(char::is_control)
    {
        return Err(BopifyError::InvalidArgument);
    }
    Ok(())
}

fn verify_identity(session: &Session, expected: &str) -> Result<(), BopifyError> {
    if session.username() != expected {
        session.shutdown();
        log::error!("services: authenticated identity mismatch");
        return Err(BopifyError::AuthInvalid);
    }
    Ok(())
}

fn classify_connect_error(error: librespot_core::Error) -> BopifyError {
    use librespot_core::error::ErrorKind;
    log::error!("services: connect failed kind={:?}", error.kind);
    match error.kind {
        ErrorKind::PermissionDenied | ErrorKind::Unauthenticated => BopifyError::AuthInvalid,
        _ => BopifyError::NetworkUnavailable,
    }
}

const LOGIN_DEADLINE: std::time::Duration = std::time::Duration::from_secs(30);

async fn with_connect_deadline<T>(
    operation: impl std::future::Future<Output = Result<T, librespot_core::Error>>,
) -> Result<T, BopifyError> {
    match tokio::time::timeout(LOGIN_DEADLINE, operation).await {
        Ok(result) => result.map_err(classify_connect_error),
        Err(_) => {
            log::error!("services: login deadline expired");
            Err(BopifyError::NetworkUnavailable)
        }
    }
}

impl Drop for Services {
    fn drop(&mut self) {
        self.session.shutdown();
    }
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;

    // Constructs real runtime/session ownership without a live-account login.
    pub(crate) fn disconnected(sink: EventSink) -> (Services, tokio::runtime::Handle) {
        let runtime = Runtime::new().unwrap();
        let handle = runtime.handle().clone();
        let session = runtime.block_on(async { Session::new(SessionConfig::default(), None) });
        (
            Services {
                runtime,
                sink,
                session,
            },
            handle,
        )
    }

    #[test]
    fn identity_validation_counts_utf8_bytes_without_normalizing() {
        for username in ["listener", " listener ", &"a".repeat(256), &"é".repeat(128)] {
            assert_eq!(validate_identity(username), Ok(()));
        }
        for username in [
            "",
            " ",
            "\u{2003}",
            "line\n",
            "name\u{7f}",
            &"é".repeat(129),
        ] {
            assert_eq!(
                validate_identity(username),
                Err(BopifyError::InvalidArgument)
            );
        }
    }

    #[tokio::test]
    async fn identity_must_match_exactly_and_mismatch_shuts_down_the_session() {
        for actual in ["listener", "Listener", "listener ", "", "another"] {
            let session = Session::new(SessionConfig::default(), None);
            session.set_username(actual);
            let result = verify_identity(&session, "listener");
            if actual == "listener" {
                assert_eq!(result, Ok(()));
                assert!(!session.is_invalid());
            } else {
                assert_eq!(result, Err(BopifyError::AuthInvalid));
                assert!(session.is_invalid());
            }
        }
    }

    #[tokio::test(start_paused = true)]
    async fn login_deadline_expires_without_waiting_forever() {
        let result =
            with_connect_deadline(std::future::pending::<Result<(), librespot_core::Error>>())
                .await;
        assert_eq!(result, Err(BopifyError::NetworkUnavailable));
    }
}
