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

const CLIENT_ID: &str = "25bbd3bacca4412b80f17b892072af71";
const REDIRECT_URI: &str = "http://127.0.0.1:8898/callback";

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    // 1. Token. Only `streaming` — the 28-scope bundle in librespot's CLI
    //    mirrors the Spotify desktop app and is not required here.
    let oauth = OAuthClientBuilder::new(CLIENT_ID, REDIRECT_URI, vec!["streaming"])
        .open_in_browser()
        .build()?;
    let token = oauth.get_access_token_async().await?;
    println!("[spike] token acquired, scopes: {:?}", token.scopes);

    // 2. Session. Deliberately not connected here: `Spirc::new` calls
    //    `session.connect` itself, and `Session` stores its transport in a
    //    `OnceLock`, so a second connect fails with `SessionError::NotConnected`.
    let session = Session::new(SessionConfig::default(), None);
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
