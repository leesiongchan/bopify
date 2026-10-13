use crate::{engine::EventSink, event::WireEvent};
use serde::Serialize;
use std::sync::{
    Arc, Mutex, PoisonError,
    atomic::{AtomicBool, Ordering},
};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum SessionLossReason {
    SpircEnded,
    SpircPanicked,
    PlayerChannelClosed,
    AudioOutputFailed,
    ForwarderPanicked,
    CommandFailed,
    Legacy,
}

#[derive(Clone)]
pub struct EngineReporter {
    sink: EventSink,
    live: Arc<Mutex<bool>>,
    output_failed: Arc<AtomicBool>,
}

impl EngineReporter {
    pub fn new(sink: EventSink) -> Self {
        Self {
            sink,
            live: Arc::new(Mutex::new(true)),
            output_failed: Arc::new(AtomicBool::new(false)),
        }
    }

    pub fn output_error_signal(&self) -> Arc<AtomicBool> {
        self.output_failed.clone()
    }

    pub fn event(&self, event: WireEvent) {
        if let WireEvent::SessionLost { reason } = event {
            return self.session_lost(reason);
        }
        if matches!(event, WireEvent::Failed { code: -2, .. }) {
            return self.session_lost(SessionLossReason::Legacy);
        }
        let mut live = self.live.lock().unwrap_or_else(PoisonError::into_inner);
        if *live {
            // Fault-generated pause/end events must not erase the recovery checkpoint.
            if self.output_failed.load(Ordering::Acquire) {
                self.emit_loss(&mut live, SessionLossReason::AudioOutputFailed);
            } else {
                (self.sink)(event);
            }
        }
    }

    pub fn session_lost(&self, reason: SessionLossReason) {
        let mut live = self.live.lock().unwrap_or_else(PoisonError::into_inner);
        self.emit_loss(&mut live, reason);
    }

    fn emit_loss(&self, live: &mut bool, reason: SessionLossReason) {
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

    #[test]
    fn output_fault_reports_once_before_a_pause_can_erase_the_checkpoint() {
        let events = Arc::new(Mutex::new(Vec::new()));
        let output = events.clone();
        let reporter =
            EngineReporter::new(Arc::new(move |event| output.lock().unwrap().push(event)));
        reporter.event(WireEvent::Playing { position_ms: 3200 });
        reporter
            .output_error_signal()
            .store(true, std::sync::atomic::Ordering::Release);
        reporter.event(WireEvent::Paused { position_ms: 0 });
        reporter.event(WireEvent::Playing { position_ms: 0 });
        reporter.session_lost(SessionLossReason::PlayerChannelClosed);
        let events = events.lock().unwrap();
        assert_eq!(events.len(), 2);
        assert!(matches!(
            events[0],
            WireEvent::Playing { position_ms: 3200 }
        ));
        assert_eq!(
            serde_json::to_value(&events[1]).unwrap(),
            serde_json::json!({
                "type": "sessionLost", "reason": "audioOutputFailed"
            })
        );
    }

    #[test]
    fn output_fault_after_teardown_cannot_call_the_sink() {
        let events = Arc::new(Mutex::new(Vec::new()));
        let output = events.clone();
        let reporter =
            EngineReporter::new(Arc::new(move |event| output.lock().unwrap().push(event)));
        reporter.begin_teardown();
        reporter
            .output_error_signal()
            .store(true, std::sync::atomic::Ordering::Release);
        reporter.event(WireEvent::Paused { position_ms: 0 });
        reporter.session_lost(SessionLossReason::PlayerChannelClosed);
        assert!(events.lock().unwrap().is_empty());
    }
}
