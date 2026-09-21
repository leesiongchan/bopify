//! The C ABI Swift links against.
//!
//! Contract for every entry point below:
//!
//! * `bopify_engine_create` and `bopify_engine_destroy` **block**. Create
//!   performs the whole network login; destroy waits for the runtime's
//!   worker threads and then for librespot's audio thread. Neither may be
//!   called on the main thread.
//! * The event callback runs on a librespot runtime thread, never the
//!   caller's, and may fire before `bopify_engine_create` returns: librespot
//!   emits a volume event while still inside the login. `ctx` must therefore
//!   be fully usable at the moment of the create call, and the handler must
//!   not assume the handle has been stored yet.
//! * `ctx` must stay alive until `bopify_engine_destroy` has returned. Once
//!   it has, no further callback can occur.
//! * `bopify_engine_destroy` must not overlap with any other call on the
//!   same handle. The caller serialises: no command may be in flight when
//!   destroy is entered, and no call may use the handle afterwards. Destroy
//!   frees the box while a concurrent command still holds a borrow of it.
//! * String arguments are borrowed for the duration of the call only; the
//!   engine copies whatever it keeps.

use std::ffi::{CStr, c_char, c_void};
use std::sync::Arc;

use crate::{engine::Engine, error::BopifyError, event::WireEvent};

/// Opaque handle. Swift never looks inside.
pub struct BopifyEngine {
    inner: Engine,
}

/// The Swift-provided context pointer, carried onto the runtime threads.
struct SendCtx(*mut c_void);

impl SendCtx {
    /// Reading through this method rather than the field matters: closure
    /// capture is per-field, so `ctx.0` would capture the bare `*mut c_void`
    /// and lose the `Send`/`Sync` impls below.
    fn as_ptr(&self) -> *mut c_void {
        self.0
    }
}

// SAFETY: the pointer is opaque here -- Rust never dereferences it, it is
// only handed back to the Swift callback. Swift owns the pointee, and the
// contract above requires it to remain valid, and safe to touch from a
// non-main thread, until `bopify_engine_destroy` returns.
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

/// Builds a Connect device and starts pushing events into `callback`, which
/// receives one UTF-8 JSON event per call in a buffer valid only for that
/// call.
///
/// The callback type is written out rather than aliased: cbindgen renders
/// `Option<fn>` as a nullable function pointer only when it can see a literal
/// function pointer, and turns an aliased one into an opaque by-value struct.
///
/// # Safety
/// `access_token` and `device_name` must each be a NUL-terminated UTF-8
/// string that stays valid for the call, `out_err` must be null or a
/// writable `int32_t`, and `ctx` must satisfy the contract at the top of
/// this header. The returned handle is owned by the caller and must be
/// released with `bopify_engine_destroy`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn bopify_engine_create(
    access_token: *const c_char,
    device_name: *const c_char,
    callback: Option<extern "C" fn(json: *const u8, len: usize, ctx: *mut c_void)>,
    ctx: *mut c_void,
    out_err: *mut i32,
) -> *mut BopifyEngine {
    log::info!("ffi: bopify_engine_create");

    // SAFETY: both pointers satisfy `str_from`'s contract per the header, and
    // the borrows are consumed inside this call.
    let (Some(token), Some(name)) =
        (unsafe { str_from(access_token) }, unsafe { str_from(device_name) })
    else {
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

    match Engine::new(token, name, sink) {
        Ok(inner) => {
            // SAFETY: as above.
            unsafe { write_err(out_err, 0) };
            log::info!("ffi: bopify_engine_create succeeded");
            Box::into_raw(Box::new(BopifyEngine { inner }))
        }
        Err(error) => {
            log::error!("ffi: bopify_engine_create failed error={error:?}");
            // SAFETY: as above.
            unsafe { write_err(out_err, error.code()) };
            std::ptr::null_mut()
        }
    }
}

/// Blocks until every runtime thread and librespot's audio thread have
/// stopped, which is what makes a callback after this point impossible.
///
/// # Safety
/// `handle` must be null, or a pointer returned by `bopify_engine_create`
/// and not yet destroyed. No other call on the same handle may be running
/// concurrently, and it must not be used again afterwards.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn bopify_engine_destroy(handle: *mut BopifyEngine) {
    if handle.is_null() {
        return;
    }
    log::info!("ffi: bopify_engine_destroy, shutting down runtime");
    // SAFETY: non-null and, per the contract, an unaliased box from
    // `bopify_engine_create` that has not been freed yet.
    drop(unsafe { Box::from_raw(handle) });
    log::info!("ffi: bopify_engine_destroy complete");
}

/// Borrows the engine behind a handle the caller promises is null or live.
///
/// # Safety
/// `handle` must be null or a live handle from `bopify_engine_create`. The
/// returned lifetime is unbound, so the borrow must not outlive the entry
/// point that took it -- every one below drops it before returning.
unsafe fn engine_for<'a>(handle: *mut BopifyEngine) -> Option<&'a Engine> {
    // SAFETY: per this function's contract the pointer is null or points at a
    // live, unaliased `BopifyEngine`; `as_ref` turns null into None.
    unsafe { handle.as_ref() }.map(|handle| &handle.inner)
}

fn code_of(result: Result<(), BopifyError>) -> i32 {
    match result {
        Ok(()) => 0,
        Err(error) => error.code(),
    }
}

// The five no-argument commands are spelled out rather than generated by a
// macro: cbindgen parses the source without expanding `macro_rules!`, so a
// generated entry point never reaches the header.

/// # Safety
/// `handle` must be null or a live handle from `bopify_engine_create`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn bopify_activate(handle: *mut BopifyEngine) -> i32 {
    log::debug!("ffi: bopify_activate");
    // SAFETY: forwards this function's own contract to `engine_for`.
    let Some(engine) = (unsafe { engine_for(handle) }) else {
        return BopifyError::InvalidArgument.code();
    };
    code_of(engine.activate())
}

/// # Safety
/// `handle` must be null or a live handle from `bopify_engine_create`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn bopify_play(handle: *mut BopifyEngine) -> i32 {
    log::debug!("ffi: bopify_play");
    // SAFETY: forwards this function's own contract to `engine_for`.
    let Some(engine) = (unsafe { engine_for(handle) }) else {
        return BopifyError::InvalidArgument.code();
    };
    code_of(engine.play())
}

/// # Safety
/// `handle` must be null or a live handle from `bopify_engine_create`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn bopify_pause(handle: *mut BopifyEngine) -> i32 {
    log::debug!("ffi: bopify_pause");
    // SAFETY: forwards this function's own contract to `engine_for`.
    let Some(engine) = (unsafe { engine_for(handle) }) else {
        return BopifyError::InvalidArgument.code();
    };
    code_of(engine.pause())
}

/// # Safety
/// `handle` must be null or a live handle from `bopify_engine_create`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn bopify_next(handle: *mut BopifyEngine) -> i32 {
    log::debug!("ffi: bopify_next");
    // SAFETY: forwards this function's own contract to `engine_for`.
    let Some(engine) = (unsafe { engine_for(handle) }) else {
        return BopifyError::InvalidArgument.code();
    };
    code_of(engine.next())
}

/// # Safety
/// `handle` must be null or a live handle from `bopify_engine_create`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn bopify_previous(handle: *mut BopifyEngine) -> i32 {
    log::debug!("ffi: bopify_previous");
    // SAFETY: forwards this function's own contract to `engine_for`.
    let Some(engine) = (unsafe { engine_for(handle) }) else {
        return BopifyError::InvalidArgument.code();
    };
    code_of(engine.previous())
}

/// # Safety
/// `handle` must be null or a live handle from `bopify_engine_create`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn bopify_seek(handle: *mut BopifyEngine, position_ms: u32) -> i32 {
    log::debug!("ffi: bopify_seek position_ms={position_ms}");
    // SAFETY: forwards this function's own contract to `engine_for`.
    let Some(engine) = (unsafe { engine_for(handle) }) else {
        return BopifyError::InvalidArgument.code();
    };
    code_of(engine.seek(position_ms))
}

/// `volume` is on librespot's `u16::MAX` scale.
///
/// # Safety
/// `handle` must be null or a live handle from `bopify_engine_create`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn bopify_set_volume(handle: *mut BopifyEngine, volume: u16) -> i32 {
    log::debug!("ffi: bopify_set_volume volume={volume}");
    // SAFETY: forwards this function's own contract to `engine_for`.
    let Some(engine) = (unsafe { engine_for(handle) }) else {
        return BopifyError::InvalidArgument.code();
    };
    code_of(engine.set_volume(volume))
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
    // SAFETY: forwards this function's own contract to `engine_for`.
    let Some(engine) = (unsafe { engine_for(handle) }) else {
        return BopifyError::InvalidArgument.code();
    };
    // SAFETY: the URI pointers satisfy `str_from`'s contract per the header,
    // and both borrows are consumed before this call returns.
    let Some(context) = (unsafe { str_from(context_uri) }) else {
        return BopifyError::InvalidArgument.code();
    };
    let start = unsafe { str_from(start_track_uri) };
    code_of(engine.load(context, start, start_position_ms))
}

/// Always fails with `SessionLost`: librespot cannot swap credentials in
/// place, so the caller has to destroy the engine and create a new one.
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
    // SAFETY: forwards this function's own contract to `engine_for`.
    let Some(_engine) = (unsafe { engine_for(handle) }) else {
        return BopifyError::InvalidArgument.code();
    };
    // SAFETY: satisfies `str_from`'s contract per the header; the borrow is
    // consumed before returning.
    let Some(_token) = (unsafe { str_from(access_token) }) else {
        return BopifyError::InvalidArgument.code();
    };
    // librespot has no in-place credential swap: `Credentials` is consumed by
    // `Spirc::new`. Returning SessionLost tells Swift to tear down and rebuild
    // the engine, which is the behaviour the facade already implements for a
    // dead session.
    log::info!("ffi: bopify_update_token unsupported, asking Swift to rebuild the engine");
    BopifyError::SessionLost.code()
}

/// Returns a static, never-freed message for an error code. Unknown codes
/// map onto the "unknown error" message.
#[unsafe(no_mangle)]
pub extern "C" fn bopify_error_message(code: i32) -> *const c_char {
    let error = BopifyError::ALL
        .iter()
        .find(|candidate| candidate.code() == code)
        .copied()
        .unwrap_or(BopifyError::Unknown);
    message_cstr(error).as_ptr()
}

/// NUL-terminated mirror of `BopifyError::message`, kept here so the C ABI
/// can hand out a `'static` pointer without allocating or leaking per call.
/// `messages_match_the_rust_side` keeps the two in step.
fn message_cstr(error: BopifyError) -> &'static CStr {
    match error {
        BopifyError::InvalidArgument => c"invalid argument",
        BopifyError::SessionLost => c"playback session lost",
        BopifyError::AuthInvalid => c"access token rejected or expired",
        BopifyError::PremiumRequired => c"Spotify Premium is required",
        BopifyError::NetworkUnavailable => c"network unavailable",
        BopifyError::Unknown => c"unknown error",
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn messages_match_the_rust_side() {
        for error in BopifyError::ALL {
            assert_eq!(message_cstr(error).to_str().unwrap(), error.message());
        }
    }

    #[test]
    fn error_message_resolves_every_code_and_falls_back() {
        for error in BopifyError::ALL {
            let ptr = bopify_error_message(error.code());
            // SAFETY: `bopify_error_message` always returns a static, NUL-
            // terminated string that lives for the whole program.
            let text = unsafe { CStr::from_ptr(ptr) }.to_str().unwrap();
            assert_eq!(text, error.message());
        }
        let ptr = bopify_error_message(12345);
        // SAFETY: as above.
        let text = unsafe { CStr::from_ptr(ptr) }.to_str().unwrap();
        assert_eq!(text, BopifyError::Unknown.message());
    }

    #[test]
    fn a_null_handle_is_an_invalid_argument_not_a_crash() {
        // SAFETY: null is explicitly allowed by every entry point's contract.
        unsafe {
            assert_eq!(bopify_play(std::ptr::null_mut()), BopifyError::InvalidArgument.code());
            assert_eq!(bopify_seek(std::ptr::null_mut(), 0), BopifyError::InvalidArgument.code());
            assert_eq!(
                bopify_set_volume(std::ptr::null_mut(), 0),
                BopifyError::InvalidArgument.code()
            );
            assert_eq!(
                bopify_load(std::ptr::null_mut(), c"spotify:album:x".as_ptr(), std::ptr::null(), 0),
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
