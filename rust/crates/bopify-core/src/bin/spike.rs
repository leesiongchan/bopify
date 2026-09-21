// rust/crates/bopify-core/src/bin/spike.rs
use std::sync::Arc;

use librespot_connect::{ConnectConfig, Spirc};
use librespot_core::{Session, SessionConfig, authentication::Credentials};
use librespot_oauth::OAuthClientBuilder;
use librespot_playback::{
    audio_backend,
    config::{AudioFormat, PlayerConfig},
    mixer::{Mixer, MixerConfig, softmixer::SoftMixer},
    player::Player,
};

/// The Spotify app the user registered. Usable for Web API calls, but NOT
/// for the streaming path -- Spotify does not admit third-party dashboard
/// client ids to the login5/AP endpoint that librespot authenticates against.
const OWN_CLIENT_ID: &str = "25bbd3bacca4412b80f17b892072af71";

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    // Two modes so the client-id question can be settled empirically.
    //
    //   BOPIFY_SPIKE_MODE=own       -- force BOTH the OAuth client id and the
    //                                  session's client id to OWN_CLIENT_ID so
    //                                  the two genuinely match. Expected to
    //                                  fail: Spotify's AP rejects third-party
    //                                  ids regardless of self-consistency.
    //   BOPIFY_SPIKE_MODE=keymaster -- librespot's own configuration, matching
    //                                  examples/play_connect.rs: the session
    //                                  default client id (KEYMASTER on macOS)
    //                                  and the /login redirect path.
    let mode = std::env::var("BOPIFY_SPIKE_MODE").unwrap_or_else(|_| "keymaster".into());

    let mut session_config = SessionConfig::default();
    let redirect_uri = match mode.as_str() {
        "own" => {
            session_config.client_id = OWN_CLIENT_ID.to_string();
            "http://127.0.0.1:8898/callback"
        }
        "keymaster" => "http://127.0.0.1:8898/login",
        other => return Err(format!("unknown BOPIFY_SPIKE_MODE {other:?}").into()),
    };
    println!("[spike] mode={mode} client_id={} redirect={redirect_uri}", session_config.client_id);

    // 1. Token, minted with the SAME client id the session will present to
    //    login5. librespot's own example does exactly this; a mismatch is what
    //    produced FaultyRequest(INVALID_CREDENTIALS) on the first run.
    let oauth = OAuthClientBuilder::new(&session_config.client_id, redirect_uri, vec!["streaming"])
        .open_in_browser()
        .build()?;
    let token = oauth.get_access_token_async().await?;
    println!("[spike] token acquired, scopes: {:?}", token.scopes);

    // 2. Session. Deliberately not connected here: `Spirc::new` calls
    //    `session.connect` itself, and `Session` stores its transport in a
    //    `OnceLock`, so a second connect fails with `SessionError::NotConnected`.
    let session = Session::new(session_config, None);
    let credentials = Credentials::with_access_token(token.access_token.clone());
    println!("[spike] session built, connecting via Spirc");

    // 3. Player with the default rodio sink.
    let mixer: Arc<dyn Mixer> = Arc::new(SoftMixer::open(MixerConfig::default())?);
    let backend = audio_backend::find(None).ok_or("no audio backend")?;
    let player = Player::new(
        PlayerConfig::default(),
        session.clone(),
        mixer.get_soft_volume(),
        move || backend(None, AudioFormat::default()),
    );

    // 4. Log every event. Q1 is answered by reading this output: does the
    //    track-changed event carry title/artist/artwork, or only an id?
    let mut events = player.get_player_event_channel();
    tokio::spawn(async move {
        while let Some(event) = events.recv().await {
            println!("[spike][event] {event:?}");
        }
    });

    // 5. Spirc owns queue and transport.
    let (spirc, task) = Spirc::new(
        ConnectConfig {
            name: "Bopify Spike".to_string(),
            ..Default::default()
        },
        session.clone(),
        credentials,
        player,
        mixer,
    )
    .await?;

    spirc.activate()?;
    println!("[spike] activated. Open Spotify on your phone or the web player");
    println!("[spike] and look for a device named 'Bopify Spike'.");

    // 6. Drive the event loop. Without awaiting this future nothing runs.
    task.await;
    Ok(())
}
