use crate::{engine::EventSink, event::WireEvent};
use serde::Serialize;
use std::sync::{Arc, Mutex, PoisonError};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum SessionLossReason {
    SpircEnded,
    SpircPanicked,
    PlayerChannelClosed,
    ForwarderPanicked,
    CommandFailed,
    Legacy,
}

#[derive(Clone)]
pub struct EngineReporter {
    sink: EventSink,
    live: Arc<Mutex<bool>>,
}

impl EngineReporter {
    pub fn new(sink: EventSink) -> Self {
        Self {
            sink,
            live: Arc::new(Mutex::new(true)),
        }
    }

    pub fn event(&self, event: WireEvent) {
        if let WireEvent::SessionLost { reason } = event {
            return self.session_lost(reason);
        }
        if matches!(event, WireEvent::Failed { code: -2, .. }) {
            return self.session_lost(SessionLossReason::Legacy);
        }
        let live = self.live.lock().unwrap_or_else(PoisonError::into_inner);
        if *live {
            (self.sink)(event);
        }
    }

    pub fn session_lost(&self, reason: SessionLossReason) {
        let mut live = self.live.lock().unwrap_or_else(PoisonError::into_inner);
        if !*live {
            return;
        }
        *live = false;
        log::error!("engine: terminal session loss reason={reason:?}");
        (self.sink)(WireEvent::SessionLost { reason });
    }

    pub fn begin_teardown(&self) {
        *self.live.lock().unwrap_or_else(PoisonError::into_inner) = false;
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::{Arc, Mutex};

    #[test]
    fn terminal_reports_once_and_suppresses_late_events() {
        let events = Arc::new(Mutex::new(Vec::new()));
        let output = events.clone();
        let reporter =
            EngineReporter::new(Arc::new(move |event| output.lock().unwrap().push(event)));
        std::thread::scope(|scope| {
            for _ in 0..20 {
                let reporter = reporter.clone();
                scope.spawn(move || {
                    reporter.event(WireEvent::Loading);
                    reporter.session_lost(SessionLossReason::SpircEnded);
                    reporter.event(WireEvent::Playing { position_ms: 10 });
                });
            }
        });
        let events = events.lock().unwrap();
        assert_eq!(
            events
                .iter()
                .filter(|e| matches!(e, WireEvent::SessionLost { .. }))
                .count(),
            1
        );
        assert!(matches!(events.last(), Some(WireEvent::SessionLost { .. })));
    }

    #[test]
    fn intentional_teardown_does_not_report_loss() {
        let events = Arc::new(Mutex::new(Vec::new()));
        let output = events.clone();
        let reporter =
            EngineReporter::new(Arc::new(move |event| output.lock().unwrap().push(event)));
        reporter.begin_teardown();
        reporter.session_lost(SessionLossReason::PlayerChannelClosed);
        reporter.event(WireEvent::Loading);
        assert!(events.lock().unwrap().is_empty());
    }
}
