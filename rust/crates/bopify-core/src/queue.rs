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
    let mut pending: VecDeque<(Vec<String>, String)> = VecDeque::new();
    let mut cache: HashMap<String, WireTrack> = HashMap::new();
    let mut recent: VecDeque<String> = VecDeque::new();
    let mut generation = 0;
    loop {
        while jobs.len() < 4 {
            let Some((entry_ids, uri)) = pending.pop_front() else {
                break;
            };
            if let Some(track) = cache.get(&uri) {
                for entry_id in entry_ids {
                    sink(WireEvent::QueueMetadata {
                        generation,
                        entry_id,
                        track: Some(track.clone()),
                    });
                }
                recent.retain(|key| key != &uri);
                recent.push_back(uri);
            } else {
                let lookup = fetch(uri.clone());
                let task = jobs.spawn(with_metadata_deadline(lookup));
                in_flight.insert(task.id(), (entry_ids, uri));
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
                    pending.clear();
                    let mut positions = HashMap::new();
                    for (entry_id, uri) in request.entries {
                        // One attempt per URI in this generation; each occurrence still gets a row event.
                        let position = *positions.entry(uri.clone()).or_insert_with(|| {
                            pending.push_back((Vec::new(), uri));
                            pending.len() - 1
                        });
                        pending[position].0.push(entry_id);
                    }
                    log::debug!("queue: metadata generation={generation} unique_uris={}", pending.len());
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
                    let Some((entry_ids, uri)) = in_flight.remove(&id) else { continue };
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
                    for entry_id in entry_ids {
                        sink(WireEvent::QueueMetadata { generation, entry_id, track: track.clone() });
                    }
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
    async fn duplicate_rows_share_one_result_and_failed_uris_retry_next_generation() {
        for outcome in ["success", "failure", "timeout", "panic"] {
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
                        match outcome {
                            "success" => Some(WireTrack {
                                track_uri: uri,
                                title: "Title".into(),
                                artists: vec![],
                                album_title: None,
                                artwork_url: None,
                                duration_ms: 1000,
                            }),
                            "timeout" => std::future::pending().await,
                            "panic" => panic!("metadata lookup failed"),
                            _ => None,
                        }
                    }
                },
            ));
            for generation in 1..=2 {
                tx.send(Some(MetadataRequest {
                    generation,
                    entries: (0..8).map(|i| (i.to_string(), "same".into())).collect(),
                }))
                .unwrap();
                let mut ids = Vec::new();
                for _ in 0..8 {
                    let deadline = if outcome == "timeout" { 31 } else { 1 };
                    let event = tokio::time::timeout(
                        std::time::Duration::from_secs(deadline),
                        received.recv(),
                    )
                    .await
                    .unwrap()
                    .unwrap();
                    let WireEvent::QueueMetadata {
                        generation: actual,
                        entry_id,
                        track,
                    } = event
                    else {
                        panic!("expected queue metadata");
                    };
                    assert_eq!(actual, generation);
                    assert_eq!(
                        track.as_ref().map(|value| value.track_uri.as_str()),
                        (outcome == "success").then_some("same")
                    );
                    ids.push(entry_id);
                }
                ids.sort();
                assert_eq!(ids, (0..8).map(|i| i.to_string()).collect::<Vec<_>>());
                assert_eq!(
                    calls.load(Ordering::SeqCst),
                    if outcome == "success" {
                        1
                    } else {
                        generation as usize
                    },
                    "{outcome}"
                );
                assert!(received.try_recv().is_err());
            }
            task.abort();
            let _ = task.await;
        }
    }

    #[tokio::test]
    async fn duplicates_leave_capacity_for_other_uris_in_first_occurrence_order() {
        let (tx, rx) = watch::channel(None);
        let (started, mut received) = tokio::sync::mpsc::unbounded_channel();
        let task = tokio::spawn(run(rx, Arc::new(|_| {}), move |uri| {
            started.send(uri).unwrap();
            std::future::pending::<Option<WireTrack>>()
        }));
        tx.send(Some(MetadataRequest {
            generation: 1,
            entries: [
                ("a", "same"),
                ("b", "same"),
                ("c", "one"),
                ("d", "same"),
                ("e", "two"),
                ("f", "three"),
                ("g", "four"),
            ]
            .into_iter()
            .map(|(id, uri)| (id.into(), uri.into()))
            .collect(),
        }))
        .unwrap();
        let mut uris = Vec::new();
        for _ in 0..4 {
            uris.push(
                tokio::time::timeout(std::time::Duration::from_secs(1), received.recv())
                    .await
                    .unwrap()
                    .unwrap(),
            );
        }
        assert_eq!(uris, ["same", "one", "two", "three"]);
        assert!(received.try_recv().is_err());
        task.abort();
        let _ = task.await;
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
    async fn replacement_cancels_old_metadata_and_reports_row_failure() {
        let (tx, rx) = watch::channel(None);
        let events = Arc::new(Mutex::new(Vec::new()));
        let output = events.clone();
        let sink: EventSink = Arc::new(move |event| output.lock().unwrap().push(event));
        let started = Arc::new(tokio::sync::Notify::new());
        let signal = started.clone();
        let calls = Arc::new(AtomicUsize::new(0));
        let observed = calls.clone();
        let task = tokio::spawn(run(rx, sink, move |_| {
            let signal = signal.clone();
            let attempt = observed.fetch_add(1, Ordering::SeqCst);
            async move {
                if attempt == 0 {
                    signal.notify_one();
                    std::future::pending::<()>().await;
                }
                None
            }
        }));
        tx.send(Some(MetadataRequest {
            generation: 1,
            entries: vec![
                ("old-a".into(), "same".into()),
                ("old-b".into(), "same".into()),
            ],
        }))
        .unwrap();
        started.notified().await;
        tx.send(Some(MetadataRequest {
            generation: 2,
            entries: vec![
                ("new-a".into(), "same".into()),
                ("new-b".into(), "same".into()),
            ],
        }))
        .unwrap();
        tokio::time::timeout(std::time::Duration::from_secs(1), async {
            loop {
                if events.lock().unwrap().len() == 2 {
                    break;
                }
                tokio::task::yield_now().await;
            }
        })
        .await
        .unwrap();
        let events = events.lock().unwrap();
        assert_eq!(events.len(), 2);
        assert_eq!(calls.load(Ordering::SeqCst), 2);
        assert!(events.iter().all(|event| matches!(
            event,
            WireEvent::QueueMetadata {
                generation: 2,
                track: None,
                ..
            }
        )));
        task.abort();
    }

    #[tokio::test]
    async fn closing_requests_cancels_the_shared_lookup_without_row_events() {
        struct OnDrop(tokio::sync::mpsc::UnboundedSender<()>);
        impl Drop for OnDrop {
            fn drop(&mut self) {
                let _ = self.0.send(());
            }
        }
        let (tx, rx) = watch::channel(None);
        let (started, mut starts) = tokio::sync::mpsc::unbounded_channel();
        let (dropped, mut drops) = tokio::sync::mpsc::unbounded_channel();
        let (events, mut received) = tokio::sync::mpsc::unbounded_channel();
        let task = tokio::spawn(run(
            rx,
            Arc::new(move |event| {
                events.send(event).unwrap();
            }),
            move |_| {
                started.send(()).unwrap();
                let guard = OnDrop(dropped.clone());
                async move {
                    let _guard = guard;
                    std::future::pending::<Option<WireTrack>>().await
                }
            },
        ));
        tx.send(Some(MetadataRequest {
            generation: 1,
            entries: vec![("a".into(), "same".into()), ("b".into(), "same".into())],
        }))
        .unwrap();
        tokio::time::timeout(std::time::Duration::from_secs(1), starts.recv())
            .await
            .unwrap()
            .unwrap();
        drop(tx);
        tokio::time::timeout(std::time::Duration::from_secs(1), task)
            .await
            .unwrap()
            .unwrap();
        tokio::time::timeout(std::time::Duration::from_secs(1), drops.recv())
            .await
            .unwrap()
            .unwrap();
        assert!(starts.try_recv().is_err());
        assert!(received.recv().await.is_none());
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
