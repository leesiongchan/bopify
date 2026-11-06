//! Owns the librespot session, player and Spirc on a dedicated tokio runtime.

use std::sync::{
    Arc,
    atomic::{AtomicBool, Ordering},
};

use librespot_connect::{
    ConnectConfig, LoadRequest, LoadRequestOptions, PlayingTrack, QueueSelection,
    QueueSelectionError, Spirc,
};
use librespot_core::{Session, SessionConfig, authentication::Credentials};
use librespot_playback::{
    audio_backend,
    config::{AudioFormat, Bitrate, PlayerConfig},
    mixer::{Mixer, MixerConfig, softmixer::SoftMixer},
    player::{Player, PlayerEventChannel},
};
use tokio::runtime::Runtime;

use crate::{
    error::BopifyError,
    event::WireEvent,
    terminal::{EngineReporter, SessionLossReason},
};

/// Called on a librespot runtime thread, never on the caller's. The Swift
/// side must be safe to invoke from a non-main thread.
pub type EventSink = Arc<dyn Fn(WireEvent) + Send + Sync>;

/// Parsed once at the FFI boundary, so the engine never sees an out-of-range mode.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RepeatMode {
    Off,
    Context,
    Track,
}

impl TryFrom<u8> for RepeatMode {
    type Error = BopifyError;

    fn try_from(mode: u8) -> Result<Self, Self::Error> {
        match mode {
            0 => Ok(Self::Off),
            1 => Ok(Self::Context),
            2 => Ok(Self::Track),
            _ => Err(BopifyError::InvalidArgument),
        }
    }
}

/// A live Connect device whose runtime joins workers before its other fields drop.
/// Never use timeout or background shutdown: callbacks must finish before Swift releases ctx.
pub struct Engine {
    runtime: Runtime,
    reporter: EngineReporter,
    spirc: Option<Spirc>,
    sink: EventSink,
    session: Session,
}

impl Engine {
    /// Blocks the calling thread for the whole network login. Callers must
    /// not run this on a UI thread.
    pub fn new(
        access_token: &str,
        device_name: &str,
        options: crate::recovery::EngineCreateOptions,
        sink: EventSink,
    ) -> Result<Self, BopifyError> {
        log::info!("engine: creating Connect device requested_bitrate_kbps=320");

        let reporter = EngineReporter::new(sink);
        let event_reporter = reporter.clone();
        let sink: EventSink = Arc::new(move |event| event_reporter.event(event));
        let runtime = tokio::runtime::Builder::new_multi_thread()
            .worker_threads(2)
            .enable_all()
            .build()
            .map_err(|why| {
                log::error!("engine: runtime build failed kind={:?}", why.kind());
                BopifyError::Unknown
            })?;

        if options.services_only {
            let session = runtime.block_on(async {
                let session = Session::new(SessionConfig::default(), None);
                with_connect_deadline(
                    session.connect(Credentials::with_access_token(access_token), false),
                )
                .await?;
                Ok::<_, BopifyError>(session)
            })?;
            log::info!("engine: data services connected without audio or Connect registration");
            return Ok(Self {
                runtime,
                reporter,
                spirc: None,
                sink,
                session,
            });
        }

        let (spirc, session) = runtime.block_on(async {
            // SessionConfig::default() supplies librespot's own client id.
            // A Spotify Developer Dashboard id is rejected by login5 with a
            // raw HTTP 400, so it must not be overridden here.
            let session_config = SessionConfig {
                device_id: options.device_id.clone(),
                ..SessionConfig::default()
            };
            let session = Session::new(session_config, None);
            let credentials = Credentials::with_access_token(access_token);

            // Spirc connects the session; pre-connecting would initialise its transport twice.

            let mixer: Arc<dyn Mixer> =
                Arc::new(SoftMixer::open(MixerConfig::default()).map_err(|_| {
                    log::error!("engine: mixer open failed");
                    BopifyError::Unknown
                })?);
            let output_failed = reporter.output_error_signal();
            let player = Player::new(
                PlayerConfig {
                    bitrate: Bitrate::Bitrate320,
                    ..PlayerConfig::default()
                },
                session.clone(),
                mixer.get_soft_volume(),
                move || {
                    audio_backend::mk_rodio_with_error_signal(
                        None,
                        AudioFormat::default(),
                        output_failed.clone(),
                    )
                },
            );

            // Subscribe before login so startup events are buffered for the forwarder.
            let events = player.get_player_event_channel();

            let (spirc, task) = with_connect_deadline(Spirc::new(
                ConnectConfig {
                    name: device_name.to_string(),
                    emit_set_queue_events: true,
                    initial_volume: options.initial_volume(),
                    // Decides from the first connect cluster what to load, so the
                    // device is never active without content.
                    startup_restore: true,
                    startup_mode: options.native_startup(),
                    ..Default::default()
                },
                session.clone(),
                credentials,
                player,
                mixer,
            ))
            .await?;

            supervise_audio_output(reporter.output_error_signal(), reporter.clone());
            // The returned future is the event loop. Commands issued before
            // it is driven are queued, so spawning it here is correct.
            supervise_spirc(task, session.clone(), reporter.clone());
            let radio_session = session.clone();
            supervise_forwarder(events, sink.clone(), session, reporter.clone());
            Ok::<_, BopifyError>((spirc, radio_session))
        })?;

        log::info!("engine: session connected, spirc running");
        Ok(Self {
            runtime,
            reporter,
            spirc: Some(spirc),
            sink,
            session,
        })
    }

    pub fn report_command_loss(&self) {
        let reporter = self.reporter.clone();
        self.runtime.spawn(async move {
            reporter.session_lost(SessionLossReason::CommandFailed);
        });
    }

    fn controller(&self) -> Result<&Spirc, BopifyError> {
        self.spirc.as_ref().ok_or(BopifyError::InvalidArgument)
    }

    pub fn play(&self) -> Result<(), BopifyError> {
        self.controller()?.play().map_err(command_failed)
    }
    pub fn play_here(&self) -> Result<(), BopifyError> {
        self.controller()?.play_here().map_err(command_failed)
    }
    pub fn pause(&self) -> Result<(), BopifyError> {
        self.controller()?.pause().map_err(command_failed)
    }
    pub fn next(&self) -> Result<(), BopifyError> {
        self.controller()?.next().map_err(command_failed)
    }
    pub fn previous(&self) -> Result<(), BopifyError> {
        self.controller()?.prev().map_err(command_failed)
    }
    pub fn seek(&self, position_ms: u32) -> Result<(), BopifyError> {
        self.controller()?
            .set_position_ms(position_ms)
            .map_err(command_failed)
    }
    pub fn set_volume(&self, volume: u16) -> Result<(), BopifyError> {
        self.controller()?
            .set_volume(volume)
            .map_err(command_failed)
    }

    pub fn select_queue(&self, generation: u64, raw_next_index: u32) -> Result<(), BopifyError> {
        let reply = self
            .controller()?
            .select_queue_entry(QueueSelection {
                generation,
                raw_next_index,
            })
            .map_err(command_failed)?;
        let sink = self.sink.clone();
        self.runtime.spawn(async move {
            match reply.await {
                Ok(Ok(())) => {}
                Ok(Err(reason)) => {
                    let reason = match reason {
                        QueueSelectionError::Stale => "staleQueue",
                        QueueSelectionError::Unavailable => "unavailable",
                        QueueSelectionError::OutOfRange => "rejected",
                    };
                    log::debug!("engine: queue selection rejected reason={reason}");
                    sink(WireEvent::CommandRejected { reason });
                }
                Err(_) => sink(session_lost_event()),
            }
        });
        Ok(())
    }

    pub fn set_shuffle(&self, enabled: bool) -> Result<(), BopifyError> {
        self.controller()?.shuffle(enabled).map_err(command_failed)
    }

    pub fn set_repeat(&self, mode: RepeatMode) -> Result<(), BopifyError> {
        self.controller()?
            .repeat(mode == RepeatMode::Context)
            .map_err(command_failed)?;
        self.controller()?
            .repeat_track(mode == RepeatMode::Track)
            .map_err(command_failed)
    }

    pub fn load(
        &self,
        context_uri: &str,
        start_track_uri: Option<&str>,
        position_ms: u32,
    ) -> Result<(), BopifyError> {
        let request = LoadRequest::from_context_uri(
            context_uri.to_string(),
            LoadRequestOptions {
                start_playing: true,
                seek_to: position_ms,
                playing_track: start_track_uri.map(|u| PlayingTrack::Uri(u.to_string())),
                ..Default::default()
            },
        );
        self.controller()?.load(request).map_err(command_failed)
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

// Report forwarder panics so the UI cannot remain on stale playback state.
fn supervise_forwarder(
    events: PlayerEventChannel,
    sink: EventSink,
    session: Session,
    reporter: EngineReporter,
) {
    let metadata = crate::queue::start(session.clone(), sink.clone());
    let remote = crate::remote::start(session, sink.clone());
    let forwarder = tokio::spawn(forward_events(events, sink.clone(), metadata, remote));
    tokio::spawn(async move {
        match forwarder.await {
            Ok(()) => reporter.session_lost(SessionLossReason::PlayerChannelClosed),
            // Cancellation is the normal teardown path -- the runtime is going
            // away and Swift is not listening any more, so stay quiet.
            Err(why) if why.is_cancelled() => {}
            Err(_) => {
                log::error!("engine: event forwarder panicked, reporting SessionLost");
                reporter.session_lost(SessionLossReason::ForwarderPanicked);
            }
        }
    });
}

async fn forward_events(
    mut events: PlayerEventChannel,
    sink: EventSink,
    metadata: tokio::sync::watch::Sender<Option<crate::queue::MetadataRequest>>,
    remote: tokio::sync::watch::Sender<Option<crate::event::WireRemote>>,
) {
    while let Some(event) = events.recv().await {
        if let Some(wire) = crate::event::translate(event) {
            // The mirror waits for its track metadata, so the remote worker publishes it.
            if let WireEvent::RemotePlayback { remote: mirrored } = wire {
                remote.send_replace(mirrored);
                continue;
            }
            let request = crate::queue::MetadataRequest::from_event(&wire);
            sink(wire);
            if let Some(request) = request {
                metadata.send_replace(Some(request));
            }
        }
    }
    log::error!("engine: player event channel closed");
}

fn session_lost_event() -> WireEvent {
    WireEvent::SessionLost {
        reason: SessionLossReason::CommandFailed,
    }
}

/// Every `Spirc` command is an unbounded-channel send, so this only fires
/// once the Spirc event loop has ended.
fn command_failed<E>(_err: E) -> BopifyError {
    log::error!("engine: spirc command rejected, event loop gone");
    BopifyError::SessionLost
}

/// Only account problems are terminal: DNS, routes, Spotify outages and malformed
/// answers can all clear on their own, so recovery keeps retrying them.
fn classify_connect_error(err: librespot_core::Error) -> BopifyError {
    let io_kind = err
        .error
        .downcast_ref::<std::io::Error>()
        .map(std::io::Error::kind);
    let error = connect_error_class(err.authentication_failure(), err.kind);
    log::error!(
        "engine: spirc connect failed kind={:?} io_kind={io_kind:?} error={error:?}",
        err.kind
    );
    error
}

/// The decision itself, apart from librespot's error type: its login-failure variants
/// are crate-private, so tests cannot build an error that carries one.
fn connect_error_class(
    failure: Option<librespot_core::error::AuthenticationFailure>,
    kind: librespot_core::error::ErrorKind,
) -> BopifyError {
    use librespot_core::error::{AuthenticationFailure, ErrorKind};
    match failure {
        Some(AuthenticationFailure::PremiumRequired) => BopifyError::PremiumRequired,
        Some(AuthenticationFailure::InvalidCredentials) => BopifyError::AuthInvalid,
        Some(AuthenticationFailure::AccountRestricted) => BopifyError::AccountRestricted,
        None if kind == ErrorKind::Unauthenticated => BopifyError::AuthInvalid,
        None => BopifyError::NetworkUnavailable,
    }
}

/// librespot's login has no timeout of its own; past this the attempt counts as a network failure.
const LOGIN_DEADLINE: std::time::Duration = std::time::Duration::from_secs(30);

async fn with_connect_deadline<T>(
    operation: impl std::future::Future<Output = Result<T, librespot_core::Error>>,
) -> Result<T, BopifyError> {
    match tokio::time::timeout(LOGIN_DEADLINE, operation).await {
        Ok(result) => result.map_err(classify_connect_error),
        Err(_) => {
            log::error!("engine: login deadline expired");
            Err(BopifyError::NetworkUnavailable)
        }
    }
}

fn supervise_spirc(
    task: impl std::future::Future<Output = ()> + Send + 'static,
    session: Session,
    reporter: EngineReporter,
) {
    let task = tokio::spawn(task);
    tokio::spawn(async move {
        tokio::select! {
            _ = session.invalidated() => {
                log::info!("engine: session invalidated, reporting loss before Connect cleanup");
                reporter.session_lost(SessionLossReason::SessionInvalidated);
            },
            result = task => match result {
                Ok(()) => reporter.session_lost(SessionLossReason::SpircEnded),
                Err(why) if why.is_cancelled() => {},
                Err(_) => reporter.session_lost(SessionLossReason::SpircPanicked),
            },
        }
    });
}

fn supervise_audio_output(failed: Arc<AtomicBool>, reporter: EngineReporter) {
    // The callback only latches a flag; the joined runtime owns all reporting.
    tokio::spawn(async move {
        loop {
            if failed.load(Ordering::Acquire) {
                reporter.session_lost(SessionLossReason::AudioOutputFailed);
                return;
            }
            tokio::time::sleep(std::time::Duration::from_millis(50)).await;
        }
    });
}

impl Drop for Engine {
    fn drop(&mut self) {
        self.reporter.begin_teardown();
        self.session.shutdown();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn services_without_a_controller_reject_every_audio_command() {
        let runtime = tokio::runtime::Runtime::new().unwrap();
        let session = runtime.block_on(async { Session::new(SessionConfig::default(), None) });
        let sink: EventSink = Arc::new(|_| panic!("a service-only audio command emitted an event"));
        let engine = Engine {
            runtime,
            reporter: EngineReporter::new(sink.clone()),
            spirc: None,
            sink,
            session,
        };
        for result in [
            engine.play(),
            engine.play_here(),
            engine.pause(),
            engine.next(),
            engine.previous(),
            engine.seek(0),
            engine.set_volume(0),
            engine.set_shuffle(true),
            engine.set_repeat(RepeatMode::Track),
            engine.select_queue(1, 0),
            engine.load("spotify:track:6rqhFgbbKwnb9MLmUQDhG6", None, 0),
        ] {
            assert_eq!(result, Err(BopifyError::InvalidArgument));
        }
    }
    #[tokio::test(start_paused = true)]
    async fn login_deadline_expires_without_waiting_forever() {
        let result =
            with_connect_deadline(std::future::pending::<Result<(), librespot_core::Error>>())
                .await;
        assert_eq!(result, Err(BopifyError::NetworkUnavailable));
    }

    /// DNS, routes, Spotify outages and malformed answers can all clear on their own,
    /// so only account problems may stop recovery.
    #[test]
    fn only_account_problems_stop_recovery() {
        use librespot_core::Error as Lib;
        use std::io::{Error as Io, ErrorKind as IoKind};
        let retryable = [
            Lib::from(Io::from(IoKind::HostUnreachable)),
            Lib::from(Io::from(IoKind::NetworkUnreachable)),
            Lib::from(Io::from(IoKind::NetworkDown)),
            Lib::from(Io::other("failed to lookup address information")),
            Lib::from(Io::from(IoKind::UnexpectedEof)),
            Lib::from(Io::from(IoKind::InvalidData)),
            Lib::failed_precondition("TRY_AGAIN_LATER"),
            Lib::permission_denied("HTTP 403"),
            Lib::not_found("HTTP 404"),
            Lib::invalid_argument("HTTP 400"),
            Lib::unknown("HTTP 502"),
            Lib::internal("channel closed"),
        ];
        for error in retryable {
            let kind = error.kind;
            assert_eq!(
                classify_connect_error(error),
                BopifyError::NetworkUnavailable,
                "{kind:?}"
            );
        }
        assert_eq!(
            classify_connect_error(Lib::unauthenticated("HTTP 401")),
            BopifyError::AuthInvalid
        );
    }

    #[test]
    fn account_problems_map_to_their_terminal_errors() {
        use librespot_core::error::{AuthenticationFailure as Failure, ErrorKind};
        for (failure, expected, code) in [
            (Failure::PremiumRequired, BopifyError::PremiumRequired, -4),
            (Failure::InvalidCredentials, BopifyError::AuthInvalid, -3),
            (
                Failure::AccountRestricted,
                BopifyError::AccountRestricted,
                -6,
            ),
        ] {
            // The kind must not matter once librespot has named the failure.
            for kind in [ErrorKind::PermissionDenied, ErrorKind::Unavailable] {
                assert_eq!(
                    connect_error_class(Some(failure), kind),
                    expected,
                    "{failure:?}"
                );
            }
            assert_eq!(expected.code(), code, "{expected:?}");
        }
    }

    #[tokio::test(start_paused = true)]
    async fn invalid_session_reports_loss_while_spirc_is_stalled() {
        for already_invalid in [false, true] {
            let session = Session::new(SessionConfig::default(), None);
            let (output, mut received) = tokio::sync::mpsc::unbounded_channel();
            let reporter = EngineReporter::new(Arc::new(move |event| {
                output.send(event).unwrap();
            }));
            if already_invalid {
                session.shutdown();
            }
            supervise_spirc(std::future::pending(), session.clone(), reporter);
            tokio::task::yield_now().await;
            if !already_invalid {
                session.shutdown();
            }
            let event = tokio::time::timeout(std::time::Duration::from_secs(1), received.recv())
                .await
                .expect("session invalidation must report without waiting for Spirc HTTP cleanup")
                .unwrap();
            assert_eq!(
                serde_json::to_value(&event).unwrap(),
                serde_json::json!({"type": "sessionLost", "reason": "sessionInvalidated"})
            );
            assert!(received.recv().await.is_none());
        }
    }

    #[tokio::test]
    async fn spirc_completion_and_panic_report_even_with_the_player_alive() {
        for panics in [false, true] {
            let (output, mut received) = tokio::sync::mpsc::unbounded_channel();
            let reporter = crate::terminal::EngineReporter::new(Arc::new(move |event| {
                output.send(event).unwrap();
            }));
            supervise_spirc(
                async move {
                    if panics {
                        panic!("test spirc");
                    }
                },
                Session::new(SessionConfig::default(), None),
                reporter,
            );
            let event = received.recv().await.unwrap();
            assert!(
                matches!(event, WireEvent::SessionLost { reason } if reason == if panics { crate::terminal::SessionLossReason::SpircPanicked } else { crate::terminal::SessionLossReason::SpircEnded })
            );
        }
    }
    use librespot_playback::player::{PlayerEvent, RemoteState};
    #[tokio::test]
    async fn transport_drain_publishes_structure_before_metadata_without_waiting() {
        let (tx, rx) = tokio::sync::mpsc::unbounded_channel();
        let (metadata, mut requests) = tokio::sync::watch::channel(None);
        let (remote, _mirror) = tokio::sync::watch::channel(None);
        let (output, mut received) = tokio::sync::mpsc::unbounded_channel();
        let sink: EventSink = Arc::new(move |event| {
            output.send(event).unwrap();
        });
        tx.send(PlayerEvent::SetQueue {
            generation: 9,
            context_uri: String::new(),
            current_track: None,
            next_tracks: vec![],
            prev_tracks: vec![],
        })
        .unwrap();
        tx.send(PlayerEvent::Paused {
            play_request_id: 0,
            track_id: librespot_core::SpotifyUri::from_uri("spotify:track:6rqhFgbbKwnb9MLmUQDhG6")
                .unwrap(),
            position_ms: 250,
        })
        .unwrap();
        drop(tx);
        forward_events(rx, sink, metadata, remote).await;
        assert!(matches!(
            received.recv().await.unwrap(),
            WireEvent::QueueChanged { generation: 9, .. }
        ));
        assert!(matches!(
            received.recv().await.unwrap(),
            WireEvent::Paused { position_ms: 250 }
        ));
        assert!(requests.borrow_and_update().is_some());
    }

    #[tokio::test]
    async fn the_mirror_waits_for_its_metadata_instead_of_reaching_swift_directly() {
        let (tx, rx) = tokio::sync::mpsc::unbounded_channel();
        let (metadata, _requests) = tokio::sync::watch::channel(None);
        let (remote, mirrored) = tokio::sync::watch::channel(None);
        let (output, mut received) = tokio::sync::mpsc::unbounded_channel();
        let sink: EventSink = Arc::new(move |event| {
            output.send(event).unwrap();
        });
        tx.send(PlayerEvent::RemotePlayback {
            remote: Some(RemoteState {
                device_name: "iPhone".into(),
                track_uri: "spotify:track:abc".into(),
                is_playing: true,
                position_ms: 0,
                duration_ms: 1000,
            }),
        })
        .unwrap();
        drop(tx);
        forward_events(rx, sink, metadata, remote).await;
        let mirrored = mirrored.borrow().clone();
        assert_eq!(
            mirrored.map(|remote| remote.track_uri),
            Some("spotify:track:abc".to_string())
        );
        assert!(received.try_recv().is_err());
    }

    #[tokio::test(start_paused = true)]
    async fn output_fault_is_reported_without_player_events() {
        let (output, mut received) = tokio::sync::mpsc::unbounded_channel();
        let reporter = EngineReporter::new(Arc::new(move |event| {
            output.send(event).unwrap();
        }));
        let failed = reporter.output_error_signal();
        supervise_audio_output(failed.clone(), reporter);
        tokio::task::yield_now().await;
        failed.store(true, Ordering::Release);
        let event = tokio::time::timeout(std::time::Duration::from_secs(1), received.recv())
            .await
            .unwrap()
            .unwrap();
        assert_eq!(
            serde_json::to_value(event).unwrap(),
            serde_json::json!({"type": "sessionLost", "reason": "audioOutputFailed"})
        );
        failed.store(true, std::sync::atomic::Ordering::Release);
        tokio::time::advance(std::time::Duration::from_secs(1)).await;
        assert!(received.try_recv().is_err());
    }
}
