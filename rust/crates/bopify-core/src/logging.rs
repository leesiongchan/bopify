//! Forwards the `log` facade to `os_log`, under the subsystem Swift uses.

use std::ffi::{CStr, CString, c_char, c_void};
use std::sync::{Once, OnceLock};

use log::{Level, LevelFilter, Log, Metadata, Record};

// Matches Swift's BopifyLog so both halves appear in the same log stream.
const SUBSYSTEM: &CStr = c"com.leesiongchan.bopify";

const CATEGORY_PLAYBACK: &CStr = c"playback";

const CATEGORY_LIBRESPOT: &CStr = c"librespot";

// Limit dependency noise; its messages stay private even if this ceiling is raised.
const LIBRESPOT_CEILING: LevelFilter = LevelFilter::Warn;

const OWN_CEILING: LevelFilter = LevelFilter::Debug;

mod sys {
    use std::ffi::{c_char, c_void};

    unsafe extern "C" {
        // The logging runtime owns the returned object for the process lifetime.
        pub fn os_log_create(subsystem: *const c_char, category: *const c_char) -> *mut c_void;

        // Privacy qualifiers must be literals at the shim's C call sites.
        pub fn bopify_os_log_emit_public(log: *mut c_void, r#type: u8, message: *const c_char);
        pub fn bopify_os_log_emit_private(log: *mut c_void, r#type: u8, message: *const c_char);
    }
}

// From `os/log.h:105-109`.
const OS_LOG_TYPE_DEFAULT: u8 = 0x00;
const OS_LOG_TYPE_INFO: u8 = 0x01;
const OS_LOG_TYPE_DEBUG: u8 = 0x02;
const OS_LOG_TYPE_ERROR: u8 = 0x10;

struct Category {
    handle: *mut c_void,
    public: bool,
}

// SAFETY: `os_log_t` is documented as a process-wide object the logging
// runtime owns and hands out per subsystem/category pair; emitting through
// it is thread-safe, and Rust never dereferences the pointer itself.
unsafe impl Send for Category {}
unsafe impl Sync for Category {}

impl Category {
    fn new(category: &CStr, public: bool) -> Self {
        // SAFETY: both C strings remain valid for the call.
        let handle = unsafe { sys::os_log_create(SUBSYSTEM.as_ptr(), category.as_ptr()) };
        Self { handle, public }
    }

    fn emit(&self, kind: u8, message: *const c_char) {
        // SAFETY: `self.handle` came from `os_log_create` and is never freed;
        // `message` is a NUL-terminated string that outlives the call.
        unsafe {
            if self.public {
                sys::bopify_os_log_emit_public(self.handle, kind, message);
            } else {
                sys::bopify_os_log_emit_private(self.handle, kind, message);
            }
        }
    }
}

struct OsLogBackend {
    playback: Category,
    librespot: Category,
}

impl OsLogBackend {
    fn new() -> Self {
        Self {
            // Only this crate's audited messages may be public.
            playback: Category::new(CATEGORY_PLAYBACK, true),
            librespot: Category::new(CATEGORY_LIBRESPOT, false),
        }
    }
}

impl Log for OsLogBackend {
    fn enabled(&self, metadata: &Metadata) -> bool {
        metadata.level() <= ceiling_for(metadata.target())
    }

    fn log(&self, record: &Record) {
        if !self.enabled(record.metadata()) {
            return;
        }
        // Reject interior NULs rather than silently truncating the message.
        let Ok(message) = CString::new(format!("{}", record.args())) else {
            return;
        };
        self.category_for(record.target())
            .emit(os_log_type(record.level()), message.as_ptr());
    }

    fn flush(&self) {}
}

impl OsLogBackend {
    fn category_for(&self, target: &str) -> &Category {
        if is_ours(target) {
            &self.playback
        } else {
            &self.librespot
        }
    }
}

fn is_ours(target: &str) -> bool {
    target == "bopify_core" || target.starts_with("bopify_core::")
}

fn ceiling_for(target: &str) -> LevelFilter {
    if is_ours(target) {
        OWN_CEILING
    } else {
        LIBRESPOT_CEILING
    }
}

/// `os_log` has no warning level; `DEFAULT` is the level above info, which
/// is where a warning belongs.
fn os_log_type(level: Level) -> u8 {
    match level {
        Level::Error => OS_LOG_TYPE_ERROR,
        Level::Warn => OS_LOG_TYPE_DEFAULT,
        Level::Info => OS_LOG_TYPE_INFO,
        Level::Debug | Level::Trace => OS_LOG_TYPE_DEBUG,
    }
}

/// Installs once, preserving any logger and filter already owned by the host.
pub(crate) fn install() {
    static INSTALL: Once = Once::new();
    static BACKEND: OnceLock<OsLogBackend> = OnceLock::new();
    INSTALL.call_once(|| {
        let backend = BACKEND.get_or_init(OsLogBackend::new);
        if log::set_logger(backend).is_ok() {
            // The facade filters before enabled(), so admit either category's ceiling.
            log::set_max_level(OWN_CEILING.max(LIBRESPOT_CEILING));
        } else {
            log::debug!("logging: a backend was already installed, keeping it");
        }
    });
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn our_modules_map_to_the_swift_playback_category() {
        for target in [
            "bopify_core::engine",
            "bopify_core::ffi",
            "bopify_core::event",
        ] {
            assert!(is_ours(target), "{target}");
            assert_eq!(ceiling_for(target), LevelFilter::Debug);
        }
    }

    #[test]
    fn librespot_is_a_separate_category_held_at_warn() {
        for target in [
            "librespot_core::session",
            "librespot_playback::player",
            "tokio::runtime",
        ] {
            assert!(!is_ours(target), "{target}");
            assert_eq!(ceiling_for(target), LevelFilter::Warn);
        }
    }

    #[test]
    fn levels_map_onto_the_documented_os_log_types() {
        assert_eq!(os_log_type(Level::Error), 0x10);
        assert_eq!(os_log_type(Level::Warn), 0x00);
        assert_eq!(os_log_type(Level::Info), 0x01);
        assert_eq!(os_log_type(Level::Debug), 0x02);
        assert_eq!(os_log_type(Level::Trace), 0x02);
    }

    #[test]
    fn only_our_own_lines_are_public() {
        let backend = OsLogBackend::new();
        assert!(!backend.category_for("bopify_core_extra::session").public);
        assert!(backend.category_for("bopify_core").public);
        assert!(backend.category_for("bopify_core::engine").public);
        assert!(backend.category_for("bopify_core::ffi").public);
        assert!(!backend.category_for("librespot_core::session").public);
        assert!(!backend.category_for("librespot_playback::player").public);
    }

    #[test]
    fn existing_logger_keeps_its_filter() {
        const CHILD: &str = "BOPIFY_HOST_LOGGER_TEST";
        if std::env::var_os(CHILD).is_none() {
            let status = std::process::Command::new(std::env::current_exe().unwrap())
                .args([
                    "--exact",
                    "logging::tests::existing_logger_keeps_its_filter",
                ])
                .env(CHILD, "1")
                .status()
                .unwrap();
            assert!(status.success());
            return;
        }

        struct HostLogger;
        impl Log for HostLogger {
            fn enabled(&self, _: &Metadata) -> bool {
                true
            }
            fn log(&self, _: &Record) {}
            fn flush(&self) {}
        }
        log::set_logger(&HostLogger).unwrap();
        log::set_max_level(LevelFilter::Error);
        install();
        assert_eq!(log::max_level(), LevelFilter::Error);
    }
}
