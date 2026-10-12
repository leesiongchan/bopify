//! Bounded queue metadata work, separate from the transport event drain.
use crate::{
    engine::EventSink,
    event::{WireEvent, WireTrack, track_metadata},
};
use librespot_core::{Session, SpotifyUri};
use librespot_metadata::audio::AudioItem;
use std::{
    collections::{HashMap, VecDeque},
    future::Future,
};
use tokio::{sync::watch, task::JoinSet};

#[derive(Clone)]
pub(crate) struct MetadataRequest {
    generation: u64,
    entries: Vec<(String, String)>,
}

impl MetadataRequest {
    pub fn from_event(event: &WireEvent) -> Option<Self> {
        let WireEvent::QueueChanged {
            generation,
            previous,
            current,
            next,
        } = event
        else {
            return None;
        };
        let entries = current
            .iter()
            .chain(previous.last())
            .chain(next.iter())
            .chain(previous.iter().rev().skip(1))
            .filter_map(|entry| {
                entry
                    .uri
                    .as_ref()
                    .map(|uri| (entry.id.clone(), uri.clone()))
            })
            .collect();
        Some(Self {
            generation: *generation,
            entries,
        })
    }
}

/// Looks a track or episode up for display; `None` when it cannot be resolved.
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

pub(crate) fn start(session: Session, sink: EventSink) -> watch::Sender<Option<MetadataRequest>> {
    let (sender, receiver) = watch::channel(None);
    tokio::spawn(run(receiver, sink, move |raw| lookup(session.clone(), raw)));
    sender
}

pub(crate) async fn with_metadata_deadline(
    lookup: impl Future<Output = Option<WireTrack>>,
) -> Option<WireTrack> {
    match tokio::time::timeout(std::time::Duration::from_secs(30), lookup).await {
        Ok(track) => track,
        Err(_) => {
            log::debug!("metadata: lookup deadline expired");
            None
        }
    }
}

async fn run<F, Fut>(
    mut requests: watch::Receiver<Option<MetadataRequest>>,
    sink: EventSink,
    fetch: F,
) where
    F: Fn(String) -> Fut + Send + 'static,
    Fut: Future<Output = Option<WireTrack>> + Send + 'static,
{
    let mut jobs = JoinSet::new();
    let mut in_flight = HashMap::new();
    let mut pending: VecDeque<(String, String)> = VecDeque::new();
    let mut cache: HashMap<String, WireTrack> = HashMap::new();
    let mut recent: VecDeque<String> = VecDeque::new();
    let mut generation = 0;
    loop {
        while jobs.len() < 4 {
            let Some((entry_id, uri)) = pending.pop_front() else {
                break;
            };
            if let Some(track) = cache.get(&uri) {
                sink(WireEvent::QueueMetadata {
                    generation,
                    entry_id,
                    track: Some(track.clone()),
                });
                recent.retain(|key| key != &uri);
                recent.push_back(uri);
            } else {
                let lookup = fetch(uri.clone());
                let task = jobs.spawn(with_metadata_deadline(lookup));
                in_flight.insert(task.id(), (entry_id, uri));
            }
        }
        tokio::select! {
            biased;
            changed = requests.changed() => {
                if changed.is_err() { break; }
                jobs.shutdown().await;
                in_flight.clear();
                if let Some(request) = requests.borrow_and_update().clone() {
                    generation = request.generation;
                    pending = request.entries.into();
                }
            }
            result = jobs.join_next_with_id(), if !jobs.is_empty() => {
                if let Some(result) = result {
                    let (id, track) = match result {
                        Ok(result) => result,
                        Err(error) => {
                            log::error!("queue: metadata lookup task failed");
                            (error.id(), None)
                        }
                    };
                    let Some((entry_id, uri)) = in_flight.remove(&id) else { continue };
                    if let Some(track) = &track {
                        cache.insert(uri.clone(), track.clone());
                        recent.retain(|key| key != &uri);
                        recent.push_back(uri);
                        while recent.len() > 128 {
                            if let Some(old) = recent.pop_front() { cache.remove(&old); }
                        }
                    } else {
                        log::debug!("queue: metadata unavailable");
                    }
                    sink(WireEvent::QueueMetadata { generation, entry_id, track });
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::{
        Arc, Mutex,
        atomic::{AtomicUsize, Ordering},
    };

    fn request(generation: u64, uri: &str) -> MetadataRequest {
        MetadataRequest {
            generation,
            entries: vec![("entry".into(), uri.into())],
        }
    }

    #[tokio::test(start_paused = true)]
    async fn stalled_lookups_report_failure_and_release_capacity() {
        let (tx, rx) = watch::channel(None);
        let (events, mut received) = tokio::sync::mpsc::unbounded_channel();
        let calls = Arc::new(AtomicUsize::new(0));
        let observed = calls.clone();
        let task = tokio::spawn(run(
            rx,
            Arc::new(move |event| {
                events.send(event).unwrap();
            }),
            move |_| {
                observed.fetch_add(1, Ordering::SeqCst);
                std::future::pending::<Option<WireTrack>>()
            },
        ));
        tx.send(Some(MetadataRequest {
            generation: 3,
            entries: (0..5).map(|i| (i.to_string(), i.to_string())).collect(),
        }))
        .unwrap();
        let event = tokio::time::timeout(std::time::Duration::from_secs(31), received.recv())
            .await
            .expect("stalled metadata must produce a row failure")
            .unwrap();
        assert!(matches!(
            event,
            WireEvent::QueueMetadata {
                generation: 3,
                track: None,
                ..
            }
        ));
        assert_eq!(calls.load(Ordering::SeqCst), 5);
        task.abort();
    }

    #[tokio::test]
    async fn a_panicking_lookup_reports_the_row_failure() {
        let (tx, rx) = watch::channel(None);
        let (events, mut received) = tokio::sync::mpsc::unbounded_channel();
        let task = tokio::spawn(run(
            rx,
            Arc::new(move |event| {
                events.send(event).unwrap();
            }),
            |_| async { panic!("metadata lookup failed") },
        ));
        tx.send(Some(request(7, "panicked"))).unwrap();
        let event = tokio::time::timeout(std::time::Duration::from_secs(1), received.recv())
            .await
            .expect("lookup panic must not leave the row loading")
            .unwrap();
        assert!(
            matches!(event, WireEvent::QueueMetadata { generation: 7, entry_id, track: None } if entry_id == "entry")
        );
        task.abort();
    }
    #[tokio::test]
    async fn replacement_cancels_old_metadata_and_reports_row_failure() {
        let (tx, rx) = watch::channel(None);
        let events = Arc::new(Mutex::new(Vec::new()));
        let output = events.clone();
        let sink: EventSink = Arc::new(move |event| output.lock().unwrap().push(event));
        let started = Arc::new(tokio::sync::Notify::new());
        let signal = started.clone();
        let task = tokio::spawn(run(rx, sink, move |uri| {
            let signal = signal.clone();
            async move {
                if uri == "old" {
                    signal.notify_one();
                    std::future::pending::<()>().await;
                }
                None
            }
        }));
        tx.send(Some(request(1, "old"))).unwrap();
        started.notified().await;
        tx.send(Some(request(2, "new"))).unwrap();
        tokio::time::timeout(std::time::Duration::from_secs(1), async {
            loop {
                if !events.lock().unwrap().is_empty() {
                    break;
                }
                tokio::task::yield_now().await;
            }
        })
        .await
        .unwrap();
        let events = events.lock().unwrap();
        assert_eq!(events.len(), 1);
        assert!(matches!(
            &events[0],
            WireEvent::QueueMetadata {
                generation: 2,
                track: None,
                ..
            }
        ));
        task.abort();
    }
    #[tokio::test]
    async fn limits_concurrent_metadata_requests_to_four() {
        let (tx, rx) = watch::channel(None);
        let count = Arc::new(AtomicUsize::new(0));
        let started = count.clone();
        let task = tokio::spawn(run(rx, Arc::new(|_| {}), move |_| {
            let started = started.clone();
            async move {
                started.fetch_add(1, Ordering::SeqCst);
                std::future::pending().await
            }
        }));
        tx.send(Some(MetadataRequest {
            generation: 1,
            entries: (0..80).map(|i| (i.to_string(), i.to_string())).collect(),
        }))
        .unwrap();
        tokio::time::timeout(std::time::Duration::from_secs(1), async {
            while count.load(Ordering::SeqCst) < 4 {
                tokio::task::yield_now().await;
            }
        })
        .await
        .unwrap();
        for _ in 0..10 {
            tokio::task::yield_now().await;
        }
        assert_eq!(count.load(Ordering::SeqCst), 4);
        task.abort();
    }
    #[tokio::test]
    async fn metadata_cache_reuses_recent_tracks_and_evicts_beyond_128() {
        let (tx, rx) = watch::channel(None);
        let (events, mut received) = tokio::sync::mpsc::unbounded_channel();
        let calls = Arc::new(AtomicUsize::new(0));
        let observed = calls.clone();
        let task = tokio::spawn(run(
            rx,
            Arc::new(move |event| {
                events.send(event).unwrap();
            }),
            move |uri| {
                observed.fetch_add(1, Ordering::SeqCst);
                async move {
                    Some(WireTrack {
                        track_uri: uri,
                        title: "Title".into(),
                        artists: vec![],
                        album_title: None,
                        artwork_url: None,
                        duration_ms: 1000,
                    })
                }
            },
        ));
        for version in 1..=129 {
            tx.send(Some(request(version, &version.to_string())))
                .unwrap();
            tokio::time::timeout(std::time::Duration::from_secs(1), received.recv())
                .await
                .unwrap()
                .unwrap();
        }
        tx.send(Some(request(130, "129"))).unwrap();
        received.recv().await.unwrap();
        assert_eq!(calls.load(Ordering::SeqCst), 129);
        tx.send(Some(request(131, "1"))).unwrap();
        received.recv().await.unwrap();
        assert_eq!(calls.load(Ordering::SeqCst), 130);
        task.abort();
    }
}
