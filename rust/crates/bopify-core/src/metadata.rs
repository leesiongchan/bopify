//! Shared metadata lookup used by radio and artist requests.
use crate::event::{WireTrack, track_metadata};
use librespot_core::{Session, SpotifyUri};
use librespot_metadata::audio::AudioItem;

pub(crate) const CONCURRENT_LOOKUPS: usize = 4;

pub(crate) async fn lookup(session: Session, raw: String) -> Option<WireTrack> {
    let uri = SpotifyUri::from_uri(&raw).ok()?;
    if !matches!(uri, SpotifyUri::Track { .. } | SpotifyUri::Episode { .. }) || uri.to_uri() != raw
    {
        return None;
    }
    AudioItem::get_file(&session, uri)
        .await
        .ok()
        .map(track_metadata)
}
