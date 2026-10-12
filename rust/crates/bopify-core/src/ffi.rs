//! C ABI for Swift; the caller contract is defined in `rust/cbindgen.toml`.
//! Destroy retains the handle shell so late calls return SessionLost safely.

use std::ffi::{CStr, c_char, c_void};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, PoisonError, RwLock};

use crate::{engine::Engine, error::BopifyError, event::WireEvent};

/// Opaque handle retained after destroy to keep concurrent and late calls safe.
pub struct BopifyEngine {
    /// Read without the lock so a late command fails fast instead of queueing
    /// behind a write lock that is held across a multi-second runtime drop.
    alive: AtomicBool,
    inner: RwLock<Option<Engine>>,
}

// FFI callers share the engine across threads; enforce that invariant at compile time.
const _: fn() = || {
    fn assert_send_sync<T: Send + Sync>() {}
    assert_send_sync::<Engine>();
};

/// The Swift-provided context pointer, carried onto the runtime threads.
struct SendCtx(*mut c_void);

impl SendCtx {
    // Access through a method so closures capture SendCtx rather than its non-Send field.
    fn as_ptr(&self) -> *mut c_void {
        self.0
    }
}

// SAFETY: Rust only returns this opaque pointer to the callback; the caller
// keeps its pointee valid and thread-safe until destroy returns.
unsafe impl Send for SendCtx {}
unsafe impl Sync for SendCtx {}

/// Borrows a C string for the duration of the current call.
///
/// # Safety
/// `ptr` must be null, or point to a NUL-terminated string that stays valid
/// and unmodified for the whole call. The returned borrow must not outlive
/// that call; its lifetime is unbound and the caller has to pin it.
unsafe fn str_from<'a>(ptr: *const c_char) -> Option<&'a str> {
    if ptr.is_null() {
        return None;
    }
    // SAFETY: guaranteed by this function's own contract, which every entry
    // point below upholds by consuming the borrow before returning.
    unsafe { CStr::from_ptr(ptr) }.to_str().ok()
}

/// Writes an error code into an optional out-parameter.
///
/// # Safety
/// `out_err` must be null or a writable, caller-owned `int32_t`.
unsafe fn write_err(out_err: *mut i32, code: i32) {
    if !out_err.is_null() {
        // SAFETY: non-null and, per the contract, a writable aligned i32 that
        // outlives this call.
        unsafe { *out_err = code };
    }
}

/// Starts a Connect device and delivers UTF-8 JSON buffers valid only during each callback.
// cbindgen needs the literal Option<fn> type to generate a nullable function pointer.
///
/// # Safety
/// `access_token` and `device_name` must each be a NUL-terminated UTF-8
/// string that stays valid for the call, `out_err` must be null or a
/// writable `int32_t`, and `ctx` must satisfy the contract at the top of
/// this header. The returned handle must be shut down with
/// `bopify_engine_destroy`; it stays safe to pass to any entry point after
/// that, so the caller may keep or discard the pointer as it likes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn bopify_engine_create(
    access_token: *const c_char,
    device_name: *const c_char,
    callback: Option<extern "C" fn(json: *const u8, len: usize, ctx: *mut c_void)>,
    ctx: *mut c_void,
    out_err: *mut i32,
) -> *mut BopifyEngine {
    // SAFETY: forwards the legacy creator's borrowed pointer contract.
    unsafe { create_engine(access_token, device_name, None, callback, ctx, out_err) }
}

/// Creates a device with validated JSON startup options. String storage is borrowed only during this call.
/// # Safety
/// Pointers and callback context obey the same contract as `bopify_engine_create`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn bopify_engine_create_with_options(
    access_token: *const c_char,
    device_name: *const c_char,
    options_json: *const c_char,
    callback: Option<extern "C" fn(json: *const u8, len: usize, ctx: *mut c_void)>,
    ctx: *mut c_void,
    out_err: *mut i32,
) -> *mut BopifyEngine {
    // SAFETY: options_json is a borrowed NUL-terminated string for this call.
    let options = unsafe { str_from(options_json) }
        .ok_or(BopifyError::InvalidArgument)
        .and_then(crate::recovery::EngineCreateOptions::parse);
    match options {
        // SAFETY: remaining arguments forward the creator's contract.
        Ok(options) => unsafe {
            create_engine(
                access_token,
                device_name,
                Some(options),
                callback,
                ctx,
                out_err,
            )
        },
        Err(error) => {
            unsafe { write_err(out_err, error.code()) };
            std::ptr::null_mut()
        }
    }
}

unsafe fn create_engine(
    access_token: *const c_char,
    device_name: *const c_char,
    options: Option<crate::recovery::EngineCreateOptions>,
    callback: Option<extern "C" fn(json: *const u8, len: usize, ctx: *mut c_void)>,
    ctx: *mut c_void,
    out_err: *mut i32,
) -> *mut BopifyEngine {
    crate::logging::install();
    log::info!("ffi: bopify_engine_create");

    // SAFETY: both pointers satisfy `str_from`'s contract per the header, and
    // the borrows are consumed inside this call.
    let (Some(token), Some(name)) = (unsafe { str_from(access_token) }, unsafe {
        str_from(device_name)
    }) else {
        log::error!("ffi: bopify_engine_create rejected, missing token or device name");
        // SAFETY: `out_err` satisfies `write_err`'s contract per the header.
        unsafe { write_err(out_err, BopifyError::InvalidArgument.code()) };
        return std::ptr::null_mut();
    };

    // Swift imports a C function pointer as an optional, so null has to be
    // rejected here rather than called.
    let Some(callback) = callback else {
        log::error!("ffi: bopify_engine_create rejected, null callback");
        // SAFETY: as above.
        unsafe { write_err(out_err, BopifyError::InvalidArgument.code()) };
        return std::ptr::null_mut();
    };

    let ctx = SendCtx(ctx);
    let sink: crate::engine::EventSink = Arc::new(move |event: WireEvent| {
        let Ok(json) = serde_json::to_vec(&event) else {
            log::error!("ffi: event serialisation failed, dropping event");
            return;
        };
        callback(json.as_ptr(), json.len(), ctx.as_ptr());
    });

    let result = match options {
        Some(options) => Engine::new_with_options(token, name, options, sink),
        None => Engine::new(token, name, sink),
    };
    match result {
        Ok(inner) => {
            // SAFETY: as above.
            unsafe { write_err(out_err, 0) };
            log::info!("ffi: bopify_engine_create succeeded");
            Box::into_raw(Box::new(BopifyEngine {
                alive: AtomicBool::new(true),
                inner: RwLock::new(Some(inner)),
            }))
        }
        Err(error) => {
            log::error!("ffi: bopify_engine_create failed error={error:?}");
            // SAFETY: as above.
            unsafe { write_err(out_err, error.code()) };
            std::ptr::null_mut()
        }
    }
}

/// Stops the engine and joins its workers before returning, including concurrent destroys.
///
/// # Safety
/// `handle` must be null or a pointer returned by `bopify_engine_create`.
/// It stays valid to pass to any entry point afterwards; later calls simply
/// report `SessionLost`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn bopify_engine_destroy(handle: *mut BopifyEngine) {
    // SAFETY: per the contract the pointer is null or points at a box from
    // `bopify_engine_create`, which is never freed, so this borrow is always
    // valid; `as_ref` turns null into None.
    let Some(handle) = (unsafe { handle.as_ref() }) else {
        return;
    };
    log::info!("ffi: bopify_engine_destroy");
    // Stop new commands from queueing behind the write lock below. This is a
    // hint, not the synchronisation: the lock is.
    handle.alive.store(false, Ordering::Release);

    // Every destroy must wait for teardown before its caller may release ctx.
    let mut guard = handle.inner.write().unwrap_or_else(PoisonError::into_inner);
    let was_live = guard.is_some();
    // Drop under the write lock so concurrent destroys cannot return before workers stop.
    *guard = None;
    drop(guard);

    if was_live {
        log::info!("ffi: bopify_engine_destroy complete, runtime stopped");
    } else {
        log::debug!("ffi: bopify_engine_destroy on an already-destroyed handle");
    }
}

/// Rejects null or destroyed handles and holds the read lock while submitting a command.
///
/// # Safety
/// `handle` must be null or a pointer returned by `bopify_engine_create`.
unsafe fn with_engine<F>(handle: *mut BopifyEngine, command: F) -> i32
where
    F: FnOnce(&Engine) -> Result<(), BopifyError>,
{
    // SAFETY: per this function's contract the pointer is null or points at a
    // box from `bopify_engine_create`, which is never freed; `as_ref` turns
    // null into None.
    let Some(handle) = (unsafe { handle.as_ref() }) else {
        return BopifyError::InvalidArgument.code();
    };
    if !handle.alive.load(Ordering::Relaxed) {
        return BopifyError::SessionLost.code();
    }
    // Commands only enqueue work; recover a poisoned lock so teardown remains possible.
    let guard = handle.inner.read().unwrap_or_else(PoisonError::into_inner);
    match guard.as_ref() {
        Some(engine) => match command(engine) {
            Ok(()) => 0,
            Err(error) => {
                if error == BopifyError::SessionLost {
                    engine.report_command_loss();
                }
                error.code()
            }
        },
        // Lost the race with destroy between the `alive` read and the lock.
        None => BopifyError::SessionLost.code(),
    }
}

// cbindgen does not expand macro_rules!, so ABI entry points must be explicit.

/// # Safety
/// `handle` must be null or a live handle from `bopify_engine_create`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn bopify_play(handle: *mut BopifyEngine) -> i32 {
    log::debug!("ffi: bopify_play");
    // SAFETY: forwards this function's own contract to `with_engine`.
    unsafe { with_engine(handle, Engine::play) }
}

/// # Safety
/// `handle` must be null or a live handle from `bopify_engine_create`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn bopify_play_here(handle: *mut BopifyEngine) -> i32 {
    log::debug!("ffi: bopify_play_here");
    // SAFETY: forwards this function's own contract to `with_engine`.
    unsafe { with_engine(handle, Engine::play_here) }
}

/// # Safety
/// `handle` must be null or a live handle from `bopify_engine_create`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn bopify_pause(handle: *mut BopifyEngine) -> i32 {
    log::debug!("ffi: bopify_pause");
    // SAFETY: forwards this function's own contract to `with_engine`.
    unsafe { with_engine(handle, Engine::pause) }
}

/// # Safety
/// `handle` must be null or a live handle from `bopify_engine_create`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn bopify_next(handle: *mut BopifyEngine) -> i32 {
    log::debug!("ffi: bopify_next");
    // SAFETY: forwards this function's own contract to `with_engine`.
    unsafe { with_engine(handle, Engine::next) }
}

/// # Safety
/// `handle` must be null or a live handle from `bopify_engine_create`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn bopify_previous(handle: *mut BopifyEngine) -> i32 {
    log::debug!("ffi: bopify_previous");
    // SAFETY: forwards this function's own contract to `with_engine`.
    unsafe { with_engine(handle, Engine::previous) }
}

/// # Safety
/// `handle` must be null or a live handle from `bopify_engine_create`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn bopify_seek(handle: *mut BopifyEngine, position_ms: u32) -> i32 {
    log::debug!("ffi: bopify_seek position_ms={position_ms}");
    // SAFETY: forwards this function's own contract to `with_engine`.
    unsafe { with_engine(handle, |engine| engine.seek(position_ms)) }
}

/// `volume` is on librespot's `u16::MAX` scale.
///
/// # Safety
/// `handle` must be null or a live handle from `bopify_engine_create`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn bopify_set_volume(handle: *mut BopifyEngine, volume: u16) -> i32 {
    log::debug!("ffi: bopify_set_volume volume={volume}");
    // SAFETY: forwards this function's own contract to `with_engine`.
    unsafe { with_engine(handle, |engine| engine.set_volume(volume)) }
}

/// Selects one occurrence in the observed queue. Success means enqueued.
/// # Safety
/// `handle` must be null or a live handle from `bopify_engine_create`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn bopify_select_queue(
    handle: *mut BopifyEngine,
    generation: u64,
    raw_next_index: u32,
) -> i32 {
    log::debug!("ffi: bopify_select_queue generation={generation} index={raw_next_index}");
    // SAFETY: forwards this function's own contract to `with_engine`.
    unsafe {
        with_engine(handle, |engine| {
            engine.select_queue(generation, raw_next_index)
        })
    }
}

/// # Safety
/// `handle` must be null or a live handle from `bopify_engine_create`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn bopify_set_shuffle(handle: *mut BopifyEngine, enabled: bool) -> i32 {
    log::debug!("ffi: bopify_set_shuffle enabled={enabled}");
    // SAFETY: forwards this function's own contract to `with_engine`.
    unsafe { with_engine(handle, |engine| engine.set_shuffle(enabled)) }
}

/// `mode`: 0 off, 1 context, 2 track.
/// # Safety
/// `handle` must be null or a live handle from `bopify_engine_create`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn bopify_set_repeat(handle: *mut BopifyEngine, mode: u8) -> i32 {
    log::debug!("ffi: bopify_set_repeat mode={mode}");
    if mode > 2 {
        return BopifyError::InvalidArgument.code();
    }
    // SAFETY: forwards this function's own contract to `with_engine`.
    unsafe { with_engine(handle, |engine| engine.set_repeat(mode)) }
}

/// Starts playback of a context URI, optionally at a given track.
///
/// # Safety
/// `handle` must be null or a live handle from `bopify_engine_create`.
/// `context_uri` must be a NUL-terminated UTF-8 string valid for the call;
/// `start_track_uri` may be null, or the same kind of string.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn bopify_load(
    handle: *mut BopifyEngine,
    context_uri: *const c_char,
    start_track_uri: *const c_char,
    start_position_ms: u32,
) -> i32 {
    log::debug!("ffi: bopify_load start_position_ms={start_position_ms}");
    // SAFETY: the URI pointers satisfy `str_from`'s contract per the header,
    // and both borrows are consumed before this call returns.
    let Some(context) = (unsafe { str_from(context_uri) }) else {
        return BopifyError::InvalidArgument.code();
    };
    let start = unsafe { str_from(start_track_uri) };
    if !start_track_uri.is_null() && start.is_none() {
        return BopifyError::InvalidArgument.code();
    }
    // SAFETY: forwards this function's own contract to `with_engine`.
    unsafe {
        with_engine(handle, |engine| {
            engine.load(context, start, start_position_ms)
        })
    }
}

/// Asks for Spotify's radio mix for a track or artist URI. Returns once the
/// request is queued; the answer is one `radio` or `radioFailed` event with
/// the same `request_id`.
///
/// # Safety
/// `handle` must be null or a live handle from `bopify_engine_create`, and
/// `seed_uri` must satisfy `str_from`'s contract.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn bopify_request_radio(
    handle: *mut BopifyEngine,
    seed_uri: *const c_char,
    request_id: u64,
) -> i32 {
    log::debug!("ffi: bopify_request_radio request_id={request_id}");
    // SAFETY: the seed pointer satisfies `str_from`'s contract per the header,
    // and the borrow is consumed before this call returns.
    let Some(seed) = (unsafe { str_from(seed_uri) }) else {
        return BopifyError::InvalidArgument.code();
    };
    // SAFETY: forwards this function's own contract to `with_engine`.
    unsafe { with_engine(handle, |engine| engine.request_radio(seed, request_id)) }
}

/// Valid calls return `SessionLost`: librespot cannot swap credentials in place.
///
/// # Safety
/// `handle` must be null or a live handle from `bopify_engine_create`, and
/// `access_token` must be a NUL-terminated UTF-8 string valid for the call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn bopify_update_token(
    handle: *mut BopifyEngine,
    access_token: *const c_char,
) -> i32 {
    log::debug!("ffi: bopify_update_token");
    // Reject malformed input before SessionLost can trigger an unnecessary rebuild.
    // SAFETY: satisfies `str_from`'s contract per the header; the borrow is
    // consumed before returning.
    let Some(_token) = (unsafe { str_from(access_token) }) else {
        return BopifyError::InvalidArgument.code();
    };
    // SAFETY: the handle satisfies with_engine's contract.
    let looked_up = unsafe { with_engine(handle, |_| Ok(())) };
    if looked_up != 0 {
        return looked_up;
    }
    // Spirc consumes credentials at creation; SessionLost asks Swift to rebuild.
    log::info!("ffi: bopify_update_token unsupported, asking Swift to rebuild the engine");
    BopifyError::SessionLost.code()
}

#[cfg(test)]
mod tests {
    use super::*;

    // Exercises handle guards without a network login.
    fn handle_without_an_engine(alive: bool) -> *mut BopifyEngine {
        Box::into_raw(Box::new(BopifyEngine {
            alive: AtomicBool::new(alive),
            inner: RwLock::new(None),
        }))
    }

    /// Production never frees the box; tests do, so they do not leak.
    ///
    /// # Safety
    /// `ptr` must come from `handle_without_an_engine` and not be used after.
    unsafe fn release(ptr: *mut BopifyEngine) {
        // SAFETY: guaranteed by this function's contract.
        drop(unsafe { Box::from_raw(ptr) });
    }

    #[test]
    fn every_command_on_a_destroyed_handle_reports_session_lost() {
        let ptr = handle_without_an_engine(false);
        let lost = BopifyError::SessionLost.code();
        // SAFETY: `ptr` is a live handle from `handle_without_an_engine`, and
        // the string pointers are valid literals.
        unsafe {
            assert_eq!(bopify_play(ptr), lost);
            assert_eq!(bopify_play_here(ptr), lost);
            assert_eq!(bopify_pause(ptr), lost);
            assert_eq!(bopify_next(ptr), lost);
            assert_eq!(bopify_select_queue(ptr, 1, 0), lost);
            assert_eq!(
                bopify_request_radio(ptr, c"spotify:track:6rqhFgbbKwnb9MLmUQDhG6".as_ptr(), 1),
                lost
            );
            assert_eq!(
                bopify_request_radio(ptr, std::ptr::null(), 1),
                BopifyError::InvalidArgument.code()
            );
            assert_eq!(bopify_set_shuffle(ptr, true), lost);
            assert_eq!(bopify_set_repeat(ptr, 2), lost);
            assert_eq!(
                bopify_set_repeat(ptr, 3),
                BopifyError::InvalidArgument.code()
            );
            assert_eq!(bopify_previous(ptr), lost);
            assert_eq!(bopify_seek(ptr, 1000), lost);
            assert_eq!(bopify_set_volume(ptr, 32767), lost);
            assert_eq!(
                bopify_load(ptr, c"spotify:album:x".as_ptr(), std::ptr::null(), 0),
                lost
            );
            assert_eq!(bopify_update_token(ptr, c"token".as_ptr()), lost);
            release(ptr);
        }
    }

    #[test]
    fn update_token_validates_its_argument_before_the_handle_state() {
        let ptr = handle_without_an_engine(false);
        // SAFETY: `ptr` is a live handle and a null token is explicitly
        // allowed as an input to be rejected.
        unsafe {
            assert_eq!(
                bopify_update_token(ptr, std::ptr::null()),
                BopifyError::InvalidArgument.code()
            );
            release(ptr);
        }
    }

    #[test]
    fn load_rejects_invalid_utf8_in_an_optional_start_track() {
        let ptr = handle_without_an_engine(false);
        let invalid = c"\xff";
        // SAFETY: the handle and NUL-terminated strings remain valid throughout the call.
        unsafe {
            assert_eq!(
                bopify_load(ptr, c"spotify:album:x".as_ptr(), invalid.as_ptr(), 0),
                BopifyError::InvalidArgument.code()
            );
            release(ptr);
        }
    }

    #[test]
    fn losing_the_race_with_destroy_also_reports_session_lost() {
        // `alive` is still true but the engine is gone: the window between
        // the relaxed `alive` read and taking the read lock.
        let ptr = handle_without_an_engine(true);
        // SAFETY: as above.
        unsafe {
            assert_eq!(bopify_play(ptr), BopifyError::SessionLost.code());
            release(ptr);
        }
    }

    #[test]
    fn a_concurrent_second_destroy_waits_for_the_teardown() {
        use std::sync::mpsc::{self, RecvTimeoutError};
        use std::time::Duration;

        // Stands in for the winner mid-teardown: `alive` already cleared,
        // and the write lock held across what would be `Runtime::drop`.
        let ptr = handle_without_an_engine(false);
        // SAFETY: `ptr` is a live box from `handle_without_an_engine`, and
        // this thread holds the only reference until the join below.
        let guard = unsafe { (*ptr).inner.write().unwrap() };

        // Raw pointers are not Send; the box outlives the thread because the
        // test joins it before releasing.
        let address = ptr as usize;
        let (tx, rx) = mpsc::channel();
        let loser = std::thread::spawn(move || {
            // SAFETY: `address` is that same live box, freed only after join.
            unsafe { bopify_engine_destroy(address as *mut BopifyEngine) };
            let _ = tx.send(());
        });

        // A concurrent destroy must not return while ctx is still in use.
        assert_eq!(
            rx.recv_timeout(Duration::from_millis(200)),
            Err(RecvTimeoutError::Timeout),
            "destroy returned while the teardown it must wait for was still running"
        );

        drop(guard);
        rx.recv_timeout(Duration::from_secs(5))
            .expect("destroy should return once the teardown completes");
        loser.join().unwrap();
        // SAFETY: the thread is joined, so nothing else touches the box.
        unsafe { release(ptr) };
    }

    #[test]
    fn destroy_is_idempotent_and_leaves_the_handle_usable() {
        let ptr = handle_without_an_engine(true);
        // SAFETY: as above. Calling destroy twice, then a command, is exactly
        // the sequence the header promises is safe.
        unsafe {
            bopify_engine_destroy(ptr);
            bopify_engine_destroy(ptr);
            assert_eq!(bopify_play(ptr), BopifyError::SessionLost.code());
            assert!(!(*ptr).alive.load(Ordering::Relaxed));
            release(ptr);
        }
    }

    #[test]
    fn a_null_handle_is_an_invalid_argument_not_a_crash() {
        // SAFETY: null is explicitly allowed by every entry point's contract.
        unsafe {
            assert_eq!(
                bopify_play(std::ptr::null_mut()),
                BopifyError::InvalidArgument.code()
            );
            assert_eq!(
                bopify_select_queue(std::ptr::null_mut(), 1, 0),
                BopifyError::InvalidArgument.code()
            );
            assert_eq!(
                bopify_set_shuffle(std::ptr::null_mut(), true),
                BopifyError::InvalidArgument.code()
            );
            assert_eq!(
                bopify_set_repeat(std::ptr::null_mut(), 0),
                BopifyError::InvalidArgument.code()
            );
            assert_eq!(
                bopify_seek(std::ptr::null_mut(), 0),
                BopifyError::InvalidArgument.code()
            );
            assert_eq!(
                bopify_set_volume(std::ptr::null_mut(), 0),
                BopifyError::InvalidArgument.code()
            );
            assert_eq!(
                bopify_load(
                    std::ptr::null_mut(),
                    c"spotify:album:x".as_ptr(),
                    std::ptr::null(),
                    0
                ),
                BopifyError::InvalidArgument.code()
            );
            bopify_engine_destroy(std::ptr::null_mut());
        }
    }

    #[test]
    fn create_rejects_null_arguments_without_touching_out_err_when_absent() {
        extern "C" fn never_called(_json: *const u8, _len: usize, _ctx: *mut c_void) {
            unreachable!("no events can be emitted before the engine exists");
        }
        let mut code = 0i32;
        // SAFETY: null string pointers are explicitly allowed, `code` is a
        // live writable i32, and the callback pointer is valid.
        let handle = unsafe {
            bopify_engine_create(
                std::ptr::null(),
                c"Bopify".as_ptr(),
                Some(never_called),
                std::ptr::null_mut(),
                &mut code,
            )
        };
        assert!(handle.is_null());
        assert_eq!(code, BopifyError::InvalidArgument.code());

        // SAFETY: as above, with a null out-parameter, which is allowed.
        let handle = unsafe {
            bopify_engine_create(
                c"token".as_ptr(),
                c"Bopify".as_ptr(),
                None,
                std::ptr::null_mut(),
                std::ptr::null_mut(),
            )
        };
        assert!(handle.is_null());
    }
}
