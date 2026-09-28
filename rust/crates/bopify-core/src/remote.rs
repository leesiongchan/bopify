//! Track metadata for the mirrored device, latest-wins, off the transport drain.

use crate::{
    engine::EventSink,
    event::{WireEvent, WireRemote, WireTrack},
};
use librespot_core::Session;
use std::{collections::HashMap, future::Future};
use tokio::{sync::watch, task::JoinSet};

pub(crate) fn start(session: Session, sink: EventSink) -> watch::Sender<Option<WireRemote>> {
    let (sender, receiver) = watch::channel(None);
    tokio::spawn(run(receiver, sink, move |raw| crate::queue::lookup(session.clone(), raw)));
    sender
}

async fn run<F, Fut>(mut requests: watch::Receiver<Option<WireRemote>>, sink: EventSink, fetch: F)
where
    F: Fn(String) -> Fut + Send + 'static,
    Fut: Future<Output = Option<WireTrack>> + Send + 'static,
{
    let mut lookup = JoinSet::new();
    let mut cache: HashMap<String, WireTrack> = HashMap::new();
    loop {
        tokio::select! {
            biased;
            changed = requests.changed() => {
                if changed.is_err() { break; }
                // Latest wins: an older lookup, even one already finished, must never land after this one.
                lookup.abort_all();
                while lookup.join_next().await.is_some() {}
                let Some(mut remote) = requests.borrow_and_update().clone() else {
                    sink(WireEvent::RemotePlayback { remote: None });
                    continue;
                };
                if let Some(track) = cache.get(&remote.track_uri) {
                    remote.track = Some(track.clone());
                    sink(WireEvent::RemotePlayback { remote: Some(remote) });
                } else {
                    let pending = fetch(remote.track_uri.clone());
                    lookup.spawn(async move { (remote, pending.await) });
                }
            }
            result = lookup.join_next(), if !lookup.is_empty() => {
                let Some(Ok((mut remote, track))) = result else { continue };
                match &track {
                    Some(track) => {
                        // One track shows at a time, so a small bound that resets is enough.
                        if cache.len() >= 64 { cache.clear(); }
                        cache.insert(remote.track_uri.clone(), track.clone());
                    }
                    None => log::debug!("remote: metadata unavailable"),
                }
                remote.track = track;
                sink(WireEvent::RemotePlayback { remote: Some(remote) });
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::{
        Arc,
        atomic::{AtomicUsize, Ordering},
    };
    use tokio::sync::mpsc;

    fn remote(uri: &str, is_playing: bool) -> WireRemote {
        WireRemote {
            device_name: "iPhone".into(),
            track_uri: uri.into(),
            track: None,
            is_playing,
            position_ms: 0,
            duration_ms: 1000,
        }
    }

    fn track(uri: String) -> WireTrack {
        WireTrack { track_uri: uri, title: "Title".into(), artists: vec![], album_title: None, artwork_url: None, duration_ms: 1000 }
    }

    fn recording_sink() -> (EventSink, mpsc::UnboundedReceiver<WireEvent>) {
        let (events, received) = mpsc::unbounded_channel();
        (Arc::new(move |event| { events.send(event).unwrap(); }), received)
    }

    async fn next(received: &mut mpsc::UnboundedReceiver<WireEvent>) -> Option<WireRemote> {
        let event = tokio::time::timeout(std::time::Duration::from_secs(1), received.recv()).await.unwrap().unwrap();
        match event {
            WireEvent::RemotePlayback { remote } => remote,
            other => panic!("expected remotePlayback, got {other:?}"),
        }
    }

    #[tokio::test]
    async fn a_newer_mirror_wins_over_a_slower_lookup() {
        let (tx, rx) = watch::channel(None);
        let (sink, mut received) = recording_sink();
        let started = Arc::new(tokio::sync::Notify::new());
        let signal = started.clone();
        let task = tokio::spawn(run(rx, sink, move |uri: String| {
            let signal = signal.clone();
            async move {
                if uri == "old" {
                    signal.notify_one();
                    std::future::pending::<()>().await;
                }
                Some(track(uri))
            }
        }));
        tx.send_replace(Some(remote("old", true)));
        started.notified().await;
        tx.send_replace(Some(remote("new", true)));
        let mirrored = next(&mut received).await.unwrap();
        assert_eq!(mirrored.track_uri, "new");
        assert_eq!(mirrored.track.unwrap().track_uri, "new");
        assert!(received.try_recv().is_err());
        task.abort();
    }

    #[tokio::test]
    async fn a_cached_track_serves_a_new_position_without_a_lookup() {
        let (tx, rx) = watch::channel(None);
        let (sink, mut received) = recording_sink();
        let calls = Arc::new(AtomicUsize::new(0));
        let observed = calls.clone();
        let task = tokio::spawn(run(rx, sink, move |uri| {
            observed.fetch_add(1, Ordering::SeqCst);
            async move { Some(track(uri)) }
        }));
        tx.send_replace(Some(remote("a", true)));
        assert!(next(&mut received).await.unwrap().track.is_some());
        tx.send_replace(Some(remote("a", false)));
        let paused = next(&mut received).await.unwrap();
        assert!(!paused.is_playing);
        assert!(paused.track.is_some());
        assert_eq!(calls.load(Ordering::SeqCst), 1);
        task.abort();
    }

    #[tokio::test]
    async fn no_mirror_and_a_failed_lookup_both_reach_swift() {
        let (tx, rx) = watch::channel(None);
        let (sink, mut received) = recording_sink();
        let task = tokio::spawn(run(rx, sink, |_| async { None }));
        tx.send_replace(Some(remote("a", true)));
        let unresolved = next(&mut received).await.unwrap();
        assert_eq!(unresolved.device_name, "iPhone");
        assert!(unresolved.track.is_none());
        tx.send_replace(None);
        assert!(next(&mut received).await.is_none());
        task.abort();
    }
}
