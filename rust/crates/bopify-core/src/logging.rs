//! Forwards the `log` facade to `os_log`, under the subsystem Swift uses.
//!
//! Hand-rolled rather than taken from a crate: the only `log::Log`
//! implementation on crates.io that is widely used is four years
//! unmaintained and pulls a concurrent hashmap to cache category objects,
//! which the logging runtime already caches itself ("one per
//! subsystem/category pair ... these objects are never deallocated",
//! `os/log.h`). What is left is small enough to own.

use std::ffi::{CString, c_char, c_void};
use std::sync::Once;

use log::{Level, LevelFilter, Log, Metadata, Record};

/// Shared with `BopifyLog.subsystem` on the Swift side, so one
/// `log stream --subsystem my.snsoft.bopify` shows both halves of the app.
const SUBSYSTEM: &str = "my.snsoft.bopify";

/// The engine, the FFI layer and event translation are all one thing to
/// someone reading the log, and Swift already calls that `playback`.
const CATEGORY_PLAYBACK: &str = "playback";

/// librespot gets its own category so it stays filterable, in or out.
const CATEGORY_LIBRESPOT: &str = "librespot";

/// librespot is extremely chatty at debug and trace and would swamp the
/// unified log. There is no runtime switch to raise this -- that would mean
/// a twelfth ABI function -- so to debug a connection problem, change this
/// to `LevelFilter::Debug` and rebuild.
const LIBRESPOT_CEILING: LevelFilter = LevelFilter::Warn;

/// Our own modules log at debug; the FFI entry points depend on it.
const OWN_CEILING: LevelFilter = LevelFilter::Debug;

/// Symbols this crate imports. `lib.rs` keeps the whole module out of the
/// generated header, since none of it is part of the published ABI.
mod sys {
    use std::ffi::{c_char, c_void};

    unsafe extern "C" {
        /// `OS_EXPORT` in `os/log.h`, so it links directly. The returned
        /// object is owned by the logging runtime and never deallocated.
        pub fn os_log_create(subsystem: *const c_char, category: *const c_char) -> *mut c_void;

        /// Ours, from `oslog_shim.c`. `type` is an `os_log_type_t`.
        pub fn bopify_os_log_emit(log: *mut c_void, r#type: u8, message: *const c_char);
    }
}

// From `os/log.h:105-109`.
const OS_LOG_TYPE_DEFAULT: u8 = 0x00;
const OS_LOG_TYPE_INFO: u8 = 0x01;
const OS_LOG_TYPE_DEBUG: u8 = 0x02;
const OS_LOG_TYPE_ERROR: u8 = 0x10;

/// An `os_log_t`, which is an opaque handle Rust only ever passes back.
struct Category(*mut c_void);

// SAFETY: `os_log_t` is documented as a process-wide object the logging
// runtime owns and hands out per subsystem/category pair; emitting through
// it is thread-safe, and Rust never dereferences the pointer itself.
unsafe impl Send for Category {}
unsafe impl Sync for Category {}

impl Category {
    fn new(category: &str) -> Self {
        let subsystem = CString::new(SUBSYSTEM).expect("subsystem has no interior NUL");
        let category = CString::new(category).expect("category has no interior NUL");
        // SAFETY: both pointers are NUL-terminated and live for this call,
        // which is all `os_log_create` requires. It always returns a usable
        // object, never null.
        Self(unsafe { sys::os_log_create(subsystem.as_ptr(), category.as_ptr()) })
    }

    fn emit(&self, kind: u8, message: *const c_char) {
        // SAFETY: `self.0` came from `os_log_create` and is never freed;
        // `message` is a NUL-terminated string that outlives the call.
        unsafe { sys::bopify_os_log_emit(self.0, kind, message) };
    }
}

struct OsLogBackend {
    playback: Category,
    librespot: Category,
}

impl Log for OsLogBackend {
    fn enabled(&self, metadata: &Metadata) -> bool {
        metadata.level() <= ceiling_for(metadata.target())
    }

    fn log(&self, record: &Record) {
        if !self.enabled(record.metadata()) {
            return;
        }
        // An interior NUL can only come from a log message built out of
        // binary data. Dropping the line beats truncating it at the NUL.
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
    target.starts_with("bopify_core")
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

/// Installs the backend once, on the first `bopify_engine_create`.
///
/// It hangs off that entry point rather than one of its own because the C
/// ABI is pinned at eleven functions. Failure is ignored: a host that
/// installed its own `log` backend first keeps it.
pub(crate) fn install() {
    static INSTALL: Once = Once::new();
    INSTALL.call_once(|| {
        let backend = OsLogBackend {
            playback: Category::new(CATEGORY_PLAYBACK),
            librespot: Category::new(CATEGORY_LIBRESPOT),
        };
        // `log`'s macros test the global ceiling before calling `enabled`,
        // so it has to be the most permissive of the per-target ceilings.
        log::set_max_level(OWN_CEILING.max(LIBRESPOT_CEILING));
        // Leaked on purpose, and `set_logger` rather than
        // `set_boxed_logger` so `log`'s `std` feature is not needed: the
        // backend is installed once and the process keeps it, exactly like
        // the `os_log_t` objects it holds.
        if log::set_logger(Box::leak(Box::new(backend))).is_err() {
            log::debug!("logging: a backend was already installed, keeping it");
        }
    });
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn our_modules_map_to_the_swift_playback_category() {
        for target in ["bopify_core::engine", "bopify_core::ffi", "bopify_core::event"] {
            assert!(is_ours(target), "{target}");
            assert_eq!(ceiling_for(target), LevelFilter::Debug);
        }
    }

    #[test]
    fn librespot_is_a_separate_category_held_at_warn() {
        for target in ["librespot_core::session", "librespot_playback::player", "tokio::runtime"] {
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
    fn a_real_category_can_be_created_and_written_to() {
        // Exercises the C shim and the os_log_create declaration: a bad
        // signature or a missing symbol fails to link, and a bad pointer
        // would crash here rather than in the app.
        let category = Category::new("test");
        let message = CString::new("bopify logging self-test").unwrap();
        category.emit(OS_LOG_TYPE_DEBUG, message.as_ptr());
    }
}
