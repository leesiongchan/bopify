//! Owns the librespot session, player and Spirc on a dedicated tokio runtime.

use std::sync::Arc;

use librespot_connect::{
    ConnectConfig, LoadRequest, LoadRequestOptions, PlayingTrack, QueueSelection,
    QueueSelectionError, Spirc,
};
use librespot_core::{Session, SessionConfig, authentication::Credentials};
use librespot_playback::{
    audio_backend,
    config::{AudioFormat, PlayerConfig},
    mixer::{Mixer, MixerConfig, softmixer::SoftMixer},
    player::{Player, PlayerEventChannel},
};
use tokio::runtime::Runtime;

use crate::{error::BopifyError, event::WireEvent};

/// Called on a librespot runtime thread, never on the caller's. The Swift
/// side must be safe to invoke from a non-main thread.
pub type EventSink = Arc<dyn Fn(WireEvent) + Send + Sync>;

/// A live Connect device.
///
/// Dropping an `Engine` drops the runtime, which joins its worker threads
/// before returning; that cancels the Spirc task, which releases the last
/// `Arc<Player>`, whose `Drop` joins the audio thread. So no spawned work,
/// and therefore no [`EventSink`] call, can outlive the drop.
///
/// **Never replace that plain drop with `Runtime::shutdown_timeout` or
/// `Runtime::shutdown_background`.** Only `Runtime::drop` joins every worker
/// thread unconditionally; the other two return while tasks may still be
/// running, which turns "no callback after destroy" into a use-after-free of
/// the Swift context. Neither substitution produces a compiler error or a
/// failing test, so this comment is the only guard. Destroy being slow is a
/// latency complaint, not a bug to fix that way.
pub struct Engine {
    /// Owns every worker, including selection acknowledgements; Drop joins them
    /// before Swift releases the event callback context.
    runtime: Runtime,
    spirc: Spirc,
    sink: EventSink,
    /// For radio lookups. Declared after `runtime`, so the runtime still drops (and joins) first.
    session: Session,
}

impl Engine {
    /// Blocks the calling thread for the whole network login. Callers must
    /// not run this on a UI thread.
    pub fn new(
        access_token: &str,
        device_name: &str,
        sink: EventSink,
    ) -> Result<Self, BopifyError> {
        log::info!("engine: creating device_name={device_name}");

        let runtime = tokio::runtime::Builder::new_multi_thread()
            .worker_threads(2)
            .enable_all()
            .build()
            .map_err(|why| {
                log::error!("engine: runtime build failed kind={:?}", why.kind());
                BopifyError::Unknown
            })?;

        let (spirc, session) = runtime.block_on(async {
            // SessionConfig::default() supplies librespot's own client id.
            // A Spotify Developer Dashboard id is rejected by login5 with a
            // raw HTTP 400, so it must not be overridden here.
            let session = Session::new(SessionConfig::default(), None);
            let credentials = Credentials::with_access_token(access_token);

            // Do NOT call session.connect() here. Spirc::new() connects the
            // session itself (connect/src/spirc.rs:223 at the pinned rev), and
            // Session holds its transport in a OnceLock whose second `set`
            // fails -- so a pre-connect makes Spirc::new die with the
            // misleadingly named SessionError::NotConnected. Connection errors
            // are classified off Spirc::new below instead.

            let mixer: Arc<dyn Mixer> =
                Arc::new(SoftMixer::open(MixerConfig::default()).map_err(|_| {
                    log::error!("engine: mixer open failed");
                    BopifyError::Unknown
                })?);
            let backend = audio_backend::find(None).ok_or_else(|| {
                log::error!("engine: no audio backend available");
                BopifyError::Unknown
            })?;
            let player = Player::new(
                PlayerConfig::default(),
                session.clone(),
                mixer.get_soft_volume(),
                move || backend(None, AudioFormat::default()),
            );

            // Subscribe before connecting so nothing emitted during login is
            // lost: the channel is unbounded and buffers until the forwarder
            // is spawned, which only happens once the engine really exists.
            let events = player.get_player_event_channel();

            let (spirc, task) = Spirc::new(
                ConnectConfig {
                    name: device_name.to_string(),
                    emit_set_queue_events: true,
                    // Decides from the first connect cluster what to load, so the
                    // device is never active without content (see the startup-restore spec).
                    startup_restore: true,
                    ..Default::default()
                },
                session.clone(),
                credentials,
                player,
                mixer,
            )
            .await
            // This is the only place a bad token or a non-Premium account
            // surfaces: librespot reports both through the same failure path,
            // and since Spotify removed `product` from GET /me in February
            // 2026 it is the only Premium signal available. Classifying it
            // here, not mapping it to Unknown, is what keeps PremiumRequired
            // and AuthInvalid reachable in the error taxonomy.
            .map_err(classify_connect_error)?;

            // The returned future is the event loop. Commands issued before
            // it is driven are queued, so spawning it here is correct.
            tokio::spawn(task);
            let radio_session = session.clone();
            supervise_forwarder(events, sink.clone(), session);
            Ok::<_, BopifyError>((spirc, radio_session))
        })?;

        log::info!("engine: session connected, spirc running");
        Ok(Self {
            runtime,
            spirc,
            sink,
            session,
        })
    }

    pub fn play(&self) -> Result<(), BopifyError> {
        self.spirc.play().map_err(command_failed)
    }
    pub fn play_here(&self) -> Result<(), BopifyError> {
        self.spirc.play_here().map_err(command_failed)
    }
    pub fn pause(&self) -> Result<(), BopifyError> {
        self.spirc.pause().map_err(command_failed)
    }
    pub fn next(&self) -> Result<(), BopifyError> {
        self.spirc.next().map_err(command_failed)
    }
    pub fn previous(&self) -> Result<(), BopifyError> {
        self.spirc.prev().map_err(command_failed)
    }
    pub fn seek(&self, position_ms: u32) -> Result<(), BopifyError> {
        self.spirc
            .set_position_ms(position_ms)
            .map_err(command_failed)
    }
    pub fn set_volume(&self, volume: u16) -> Result<(), BopifyError> {
        self.spirc.set_volume(volume).map_err(command_failed)
    }

    pub fn select_queue(&self, generation: u64, raw_next_index: u32) -> Result<(), BopifyError> {
        let reply = self
            .spirc
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
        self.spirc.shuffle(enabled).map_err(command_failed)
    }

    pub fn set_repeat(&self, mode: u8) -> Result<(), BopifyError> {
        if mode > 2 {
            return Err(BopifyError::InvalidArgument);
        }
        self.spirc.repeat(mode == 1).map_err(command_failed)?;
        self.spirc.repeat_track(mode == 2).map_err(command_failed)
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
        self.spirc.load(request).map_err(command_failed)
    }

    /// Queues a station lookup. The answer arrives on the sink as `Radio` or
    /// `RadioFailed` carrying `request_id`, and the work ends with the runtime.
    pub fn request_radio(&self, seed_uri: &str, request_id: u64) -> Result<(), BopifyError> {
        let seed = crate::radio::Seed::parse(seed_uri).ok_or(BopifyError::InvalidArgument)?;
        let source = crate::radio::SessionRadio(self.session.clone());
        let sink = self.sink.clone();
        self.runtime.spawn(async move { sink(crate::radio::resolve(&source, seed, request_id).await) });
        Ok(())
    }
}

/// Spawns the forwarder under a watcher.
///
/// Without the watcher a panic anywhere in translation or serialisation would
/// kill the task, tokio would swallow it, and event delivery would stop for
/// good with no terminal `Failed` -- the UI would sit on stale state forever.
fn supervise_forwarder(events: PlayerEventChannel, sink: EventSink, session: Session) {
    let metadata = crate::queue::start(session.clone(), sink.clone());
    let remote = crate::remote::start(session, sink.clone());
    let forwarder = tokio::spawn(forward_events(events, sink.clone(), metadata, remote));
    tokio::spawn(async move {
        match forwarder.await {
            Ok(()) => {}
            // Cancellation is the normal teardown path -- the runtime is going
            // away and Swift is not listening any more, so stay quiet.
            Err(why) if why.is_cancelled() => {}
            Err(_) => {
                log::error!("engine: event forwarder panicked, reporting SessionLost");
                sink(session_lost_event());
            }
        }
    });
}

/// Drains librespot's player events onto the sink until the player goes away.
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
    // The channel only closes when the player thread is gone, which during a
    // normal teardown never gets here: runtime shutdown drops this task
    // rather than polling it.
    log::error!("engine: player event channel closed, reporting SessionLost");
    sink(session_lost_event());
}

fn session_lost_event() -> WireEvent {
    WireEvent::Failed {
        code: BopifyError::SessionLost.code(),
        message: BopifyError::SessionLost.message().to_string(),
    }
}

/// Every `Spirc` command is an unbounded-channel send, so this only fires
/// once the Spirc event loop has ended.
fn command_failed<E>(_err: E) -> BopifyError {
    log::error!("engine: spirc command rejected, event loop gone");
    BopifyError::SessionLost
}

fn classify_connect_error<E: std::fmt::Debug>(err: E) -> BopifyError {
    // Classification only. This string can carry login5 payload, so it must
    // never be logged or put on the wire -- only the verdict below escapes.
    let text = format!("{err:?}").to_lowercase();
    let error = if text.contains("premium") {
        BopifyError::PremiumRequired
    } else if text.contains("token") || text.contains("credential") || text.contains("unauthor") {
        BopifyError::AuthInvalid
    } else if text.contains("dns") || text.contains("connect") || text.contains("network") {
        BopifyError::NetworkUnavailable
    } else {
        BopifyError::Unknown
    };
    log::error!("engine: spirc connect failed error={error:?}");
    error
}

#[cfg(test)]
mod tests {
    use super::*;
    use librespot_playback::player::{PlayerEvent, RemoteState};
    #[tokio::test]
    async fn transport_drain_publishes_structure_before_metadata_without_waiting() {
        let (tx, rx) = tokio::sync::mpsc::unbounded_channel();
        let (metadata, mut requests) = tokio::sync::watch::channel(None);
        let (remote, _mirror) = tokio::sync::watch::channel(None);
        let (output, mut received) = tokio::sync::mpsc::unbounded_channel();
        let sink: EventSink = Arc::new(move |event| { output.send(event).unwrap(); });
        tx.send(PlayerEvent::SetQueue { generation: 9, context_uri: String::new(), current_track: None, next_tracks: vec![], prev_tracks: vec![] }).unwrap();
        tx.send(PlayerEvent::Paused { play_request_id: 0, track_id: librespot_core::SpotifyUri::from_uri("spotify:track:6rqhFgbbKwnb9MLmUQDhG6").unwrap(), position_ms: 250 }).unwrap();
        drop(tx);
        forward_events(rx, sink, metadata, remote).await;
        assert!(matches!(received.recv().await.unwrap(), WireEvent::QueueChanged { generation: 9, .. }));
        assert!(matches!(received.recv().await.unwrap(), WireEvent::Paused { position_ms: 250 }));
        assert!(requests.borrow_and_update().is_some());
    }

    #[tokio::test]
    async fn the_mirror_waits_for_its_metadata_instead_of_reaching_swift_directly() {
        let (tx, rx) = tokio::sync::mpsc::unbounded_channel();
        let (metadata, _requests) = tokio::sync::watch::channel(None);
        let (remote, mirrored) = tokio::sync::watch::channel(None);
        let (output, mut received) = tokio::sync::mpsc::unbounded_channel();
        let sink: EventSink = Arc::new(move |event| { output.send(event).unwrap(); });
        tx.send(PlayerEvent::RemotePlayback { remote: Some(RemoteState { device_name: "iPhone".into(), track_uri: "spotify:track:abc".into(), is_playing: true, position_ms: 0, duration_ms: 1000 }) }).unwrap();
        drop(tx);
        forward_events(rx, sink, metadata, remote).await;
        let mirrored = mirrored.borrow().clone();
        assert_eq!(mirrored.map(|remote| remote.track_uri), Some("spotify:track:abc".to_string()));
        // Only the drain's closing SessionLost went straight to Swift.
        assert!(matches!(received.recv().await.unwrap(), WireEvent::Failed { .. }));
    }
}
