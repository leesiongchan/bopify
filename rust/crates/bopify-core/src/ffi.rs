//! C ABI for Swift; the caller contract is defined in `rust/cbindgen.toml`.

use std::ffi::{CStr, c_char, c_void};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, PoisonError, RwLock};

use crate::{error::BopifyError, event::WireEvent, services::Services};

/// Opaque handle retained after destroy to keep concurrent and late calls safe.
pub struct BopifyServices {
    /// Read without the lock so a late command fails fast instead of queueing
    /// behind a write lock that is held across a multi-second runtime drop.
    alive: AtomicBool,
    inner: RwLock<Option<Services>>,
}

// FFI callers share the services across threads; enforce that invariant at compile time.
const _: fn() = || {
    fn assert_send_sync<T: Send + Sync>() {}
    assert_send_sync::<Services>();
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

/// # Safety
/// `out_err` must be null or a writable, caller-owned `int32_t`.
unsafe fn write_err(out_err: *mut i32, code: i32) {
    if !out_err.is_null() {
        // SAFETY: non-null and, per the contract, a writable aligned i32 that
        // outlives this call.
        unsafe { *out_err = code };
    }
}

/// Starts metadata services and delivers UTF-8 JSON valid only during each callback.
// cbindgen needs the literal Option<fn> type to generate a nullable callback.
///
/// # Safety
/// String arguments must be null or NUL-terminated UTF-8 valid for the call.
/// `out_err` must be null or writable and `ctx` must satisfy the header contract.
/// A successful handle must be shut down with `bopify_services_destroy`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn bopify_services_create(
    access_token: *const c_char,
    expected_username: *const c_char,
    callback: Option<extern "C" fn(json: *const u8, len: usize, ctx: *mut c_void)>,
    ctx: *mut c_void,
    out_err: *mut i32,
) -> *mut BopifyServices {
    crate::logging::install();
    log::info!("ffi: bopify_services_create");
    // SAFETY: the pointers satisfy this function's caller contract.
    let (Some(token), Some(username), Some(callback)) = (
        unsafe { str_from(access_token) },
        unsafe { str_from(expected_username) },
        callback,
    ) else {
        // SAFETY: out_err satisfies the caller contract.
        unsafe { write_err(out_err, BopifyError::InvalidArgument.code()) };
        return std::ptr::null_mut();
    };
    if token.trim().is_empty() || crate::services::validate_identity(username).is_err() {
        log::error!("ffi: services creation rejected invalid arguments");
        // SAFETY: as above.
        unsafe { write_err(out_err, BopifyError::InvalidArgument.code()) };
        return std::ptr::null_mut();
    }
    let ctx = SendCtx(ctx);
    let sink: crate::services::EventSink = Arc::new(move |event: WireEvent| {
        let Ok(json) = serde_json::to_vec(&event) else {
            log::error!("ffi: event serialisation failed, dropping event");
            return;
        };
        callback(json.as_ptr(), json.len(), ctx.as_ptr());
    });
    match Services::new(token, username, sink) {
        Ok(inner) => {
            // SAFETY: as above.
            unsafe { write_err(out_err, 0) };
            log::info!("ffi: bopify_services_create succeeded");
            Box::into_raw(Box::new(BopifyServices {
                alive: AtomicBool::new(true),
                inner: RwLock::new(Some(inner)),
            }))
        }
        Err(error) => {
            log::error!("ffi: bopify_services_create failed error={error:?}");
            // SAFETY: as above.
            unsafe { write_err(out_err, error.code()) };
            std::ptr::null_mut()
        }
    }
}

/// Stops the services and joins its workers before returning, including concurrent destroys.
///
/// # Safety
/// `handle` must be null or a pointer returned by `bopify_services_create`.
/// It stays valid to pass to any entry point afterwards; later calls simply
/// report `SessionLost`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn bopify_services_destroy(handle: *mut BopifyServices) {
    // SAFETY: per the contract the pointer is null or points at a box from
    // `bopify_services_create`, which is never freed, so this borrow is always
    // valid; `as_ref` turns null into None.
    let Some(handle) = (unsafe { handle.as_ref() }) else {
        return;
    };
    log::info!("ffi: bopify_services_destroy");
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
        log::info!("ffi: bopify_services_destroy complete, runtime stopped");
    } else {
        log::debug!("ffi: bopify_services_destroy on an already-destroyed handle");
    }
}

/// Rejects null or destroyed handles and holds the read lock while submitting a command.
///
/// # Safety
/// `handle` must be null or a pointer returned by `bopify_services_create`.
unsafe fn with_services<F>(handle: *mut BopifyServices, command: F) -> i32
where
    F: FnOnce(&Services) -> Result<(), BopifyError>,
{
    // SAFETY: per this function's contract the pointer is null or points at a
    // box from `bopify_services_create`, which is never freed; `as_ref` turns
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
        Some(services) => command(services).map_or_else(|error| error.code(), |()| 0),
        // Lost the race with destroy between the `alive` read and the lock.
        None => BopifyError::SessionLost.code(),
    }
}

/// Asks for Spotify's radio mix for a track or artist URI. Returns once the
/// request is queued; the answer is one `radio` or `radioFailed` event with
/// the same `request_id`.
///
/// # Safety
/// `handle` must be null or a live handle from `bopify_services_create`, and
/// `seed_uri` must satisfy `str_from`'s contract.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn bopify_request_radio(
    handle: *mut BopifyServices,
    seed_uri: *const c_char,
    request_id: u64,
) -> i32 {
    log::debug!("ffi: bopify_request_radio request_id={request_id}");
    // SAFETY: the seed pointer satisfies `str_from`'s contract per the header,
    // and the borrow is consumed before this call returns.
    let Some(seed) = (unsafe { str_from(seed_uri) }) else {
        return BopifyError::InvalidArgument.code();
    };
    // SAFETY: forwards this function's own contract to `with_services`.
    unsafe { with_services(handle, |services| services.request_radio(seed, request_id)) }
}

/// Queues a lyric lookup for a canonical track URI. The callback carries
/// `lyrics` or `lyricsFailed` with the same `request_id`.
///
/// # Safety
/// `handle` must be null or a live handle from `bopify_services_create`, and
/// `track_uri` must satisfy `str_from`'s contract.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn bopify_request_lyrics(
    handle: *mut BopifyServices,
    track_uri: *const c_char,
    request_id: u64,
) -> i32 {
    log::debug!("ffi: bopify_request_lyrics request_id={request_id}");
    // SAFETY: the URI pointer satisfies the caller contract and is borrowed only during this call.
    let Some(track) = (unsafe { str_from(track_uri) }) else {
        return BopifyError::InvalidArgument.code();
    };
    // SAFETY: forwards this function's own handle contract to `with_services`.
    unsafe {
        with_services(handle, |services| {
            services.request_lyrics(track, request_id)
        })
    }
}

/// Queues a displayed artist's popular songs for a canonical track URI. The callback
/// carries `artistTopTracks` or `artistTopTracksFailed` with the same `request_id`.
///
/// # Safety
/// `handle` must be null or live, and `track_uri` must satisfy `str_from`'s contract.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn bopify_request_artist_top_tracks(
    handle: *mut BopifyServices,
    track_uri: *const c_char,
    artist_index: u32,
    request_id: u64,
) -> i32 {
    log::debug!(
        "ffi: bopify_request_artist_top_tracks artist_index={artist_index} request_id={request_id}"
    );
    // SAFETY: the URI is borrowed only for this call, under the caller's contract.
    let Some(track) = (unsafe { str_from(track_uri) }) else {
        return BopifyError::InvalidArgument.code();
    };
    // SAFETY: forwards this function's own handle contract.
    unsafe {
        with_services(handle, |services| {
            services.request_artist_top_tracks(track, artist_index, request_id)
        })
    }
}

#[cfg(test)]
mod services_boundary_tests {
    use super::*;
    use std::ffi::CString;

    extern "C" fn never_called(_json: *const u8, _len: usize, _ctx: *mut c_void) {
        panic!("invalid creation must not invoke a callback");
    }

    #[test]
    fn services_creation_rejects_invalid_tokens_and_missing_callback_before_login() {
        for token in [
            std::ptr::null(),
            c"".as_ptr(),
            c" ".as_ptr(),
            c"\xff".as_ptr(),
        ] {
            let mut code = 0;
            // SAFETY: nonnull pointers are NUL-terminated strings valid for the call.
            let handle = unsafe {
                bopify_services_create(
                    token,
                    c"listener".as_ptr(),
                    Some(never_called),
                    std::ptr::null_mut(),
                    &mut code,
                )
            };
            assert!(handle.is_null());
            assert_eq!(code, -1);
        }
        // SAFETY: null callback and out_err are accepted and checked by the boundary.
        let handle = unsafe {
            bopify_services_create(
                c"token".as_ptr(),
                c"listener".as_ptr(),
                None,
                std::ptr::null_mut(),
                std::ptr::null_mut(),
            )
        };
        assert!(handle.is_null());
    }

    #[test]
    fn services_creation_rejects_invalid_identity_before_login() {
        let invalid_utf8 = c"\xff";
        let values = [
            None,
            Some(CString::new("").unwrap()),
            Some(CString::new(" \t").unwrap()),
            Some(CString::new("listener\n").unwrap()),
            Some(CString::new("a".repeat(257)).unwrap()),
            Some(CString::new("é".repeat(129)).unwrap()),
        ];
        for username in values
            .iter()
            .map(|v| v.as_deref())
            .chain([Some(invalid_utf8)])
        {
            let mut code = 0;
            // SAFETY: pointers remain valid during the call; null identity is supported.
            let handle = unsafe {
                bopify_services_create(
                    c"token".as_ptr(),
                    username.map_or(std::ptr::null(), CStr::as_ptr),
                    Some(never_called),
                    std::ptr::null_mut(),
                    &mut code,
                )
            };
            assert!(handle.is_null());
            assert_eq!(code, -1);
        }
    }
}

#[cfg(test)]
mod lifecycle_tests {
    use super::*;
    use std::sync::mpsc::{self, RecvTimeoutError};
    use std::time::Duration;

    fn empty_handle(alive: bool) -> *mut BopifyServices {
        Box::into_raw(Box::new(BopifyServices {
            alive: AtomicBool::new(alive),
            inner: RwLock::new(None),
        }))
    }

    // Tests reclaim tombstones only after every participating thread joins.
    unsafe fn release(handle: *mut BopifyServices) {
        // SAFETY: the caller owns the box and guarantees no outstanding access.
        drop(unsafe { Box::from_raw(handle) });
    }

    #[test]
    fn metadata_requests_guard_null_destroyed_and_lost_race_handles() {
        for alive in [false, true] {
            let ptr = empty_handle(alive);
            // SAFETY: the test owns ptr and all strings stay valid during the calls.
            unsafe {
                assert_eq!(
                    bopify_request_radio(ptr, c"spotify:track:6rqhFgbbKwnb9MLmUQDhG6".as_ptr(), 1),
                    -2
                );
                assert_eq!(
                    bopify_request_lyrics(ptr, c"spotify:track:6rqhFgbbKwnb9MLmUQDhG6".as_ptr(), 1),
                    -2
                );
                assert_eq!(
                    bopify_request_artist_top_tracks(
                        ptr,
                        c"spotify:track:6rqhFgbbKwnb9MLmUQDhG6".as_ptr(),
                        0,
                        1
                    ),
                    -2
                );
                assert_eq!(bopify_request_radio(ptr, std::ptr::null(), 1), -1);
                assert_eq!(bopify_request_lyrics(ptr, c"\xff".as_ptr(), 1), -1);
                assert_eq!(
                    bopify_request_artist_top_tracks(ptr, c"\xff".as_ptr(), 0, 1),
                    -1
                );
                bopify_services_destroy(ptr);
                bopify_services_destroy(ptr);
                assert!(!(*ptr).alive.load(Ordering::Relaxed));
                release(ptr);
            }
        }
        // SAFETY: null handles and pointers are supported by the contract.
        unsafe {
            assert_eq!(
                bopify_request_radio(
                    std::ptr::null_mut(),
                    c"spotify:track:6rqhFgbbKwnb9MLmUQDhG6".as_ptr(),
                    1
                ),
                -1
            );
            assert_eq!(
                bopify_request_lyrics(
                    std::ptr::null_mut(),
                    c"spotify:track:6rqhFgbbKwnb9MLmUQDhG6".as_ptr(),
                    1
                ),
                -1
            );
            assert_eq!(
                bopify_request_artist_top_tracks(
                    std::ptr::null_mut(),
                    c"spotify:track:6rqhFgbbKwnb9MLmUQDhG6".as_ptr(),
                    0,
                    1
                ),
                -1
            );
            bopify_services_destroy(std::ptr::null_mut());
        }
    }

    #[test]
    fn concurrent_destroys_join_callbacks_and_cancel_pending_work_before_returning() {
        use std::sync::{Mutex, atomic::AtomicUsize};
        struct Dropped(mpsc::Sender<()>);
        impl Drop for Dropped {
            fn drop(&mut self) {
                let _ = self.0.send(());
            }
        }

        let (entered_tx, entered_rx) = mpsc::channel();
        let (release_tx, release_rx) = mpsc::channel();
        let release_rx = Mutex::new(release_rx);
        let callbacks = Arc::new(AtomicUsize::new(0));
        let recorded = callbacks.clone();
        let sink: crate::services::EventSink = Arc::new(move |_| {
            recorded.fetch_add(1, Ordering::SeqCst);
            entered_tx.send(()).unwrap();
            release_rx.lock().unwrap().recv().unwrap();
        });
        let (services, runtime) = crate::services::tests::disconnected(sink.clone());
        let (pending_tx, pending_rx) = mpsc::channel();
        let (dropped_tx, dropped_rx) = mpsc::channel();
        let dropped = Dropped(dropped_tx);
        let delayed_sink = sink.clone();
        runtime.spawn(async move {
            let _dropped = dropped;
            pending_tx.send(()).unwrap();
            std::future::pending::<()>().await;
            delayed_sink(WireEvent::RadioFailed {
                request_id: 2,
                seed_uri: String::new(),
                reason: crate::event::RadioFailure::Network,
            });
        });
        pending_rx.recv_timeout(Duration::from_secs(5)).unwrap();
        runtime.spawn(async move {
            sink(WireEvent::RadioFailed {
                request_id: 1,
                seed_uri: String::new(),
                reason: crate::event::RadioFailure::Network,
            });
        });
        entered_rx.recv_timeout(Duration::from_secs(5)).unwrap();
        let ptr = Box::into_raw(Box::new(BopifyServices {
            alive: AtomicBool::new(true),
            inner: RwLock::new(Some(services)),
        }));
        let address = ptr as usize;
        let (finished_tx, finished_rx) = mpsc::channel();
        let mut destroys = Vec::new();
        for _ in 0..2 {
            let finished_tx = finished_tx.clone();
            destroys.push(std::thread::spawn(move || {
                // SAFETY: the handle outlives all joined threads.
                unsafe { bopify_services_destroy(address as *mut BopifyServices) };
                finished_tx.send(()).unwrap();
            }));
        }
        assert_eq!(
            finished_rx.recv_timeout(Duration::from_millis(200)),
            Err(RecvTimeoutError::Timeout)
        );
        // SAFETY: a destroyed handle remains usable while runtime teardown holds its write lock.
        unsafe {
            assert_eq!(
                bopify_request_lyrics(ptr, c"spotify:track:6rqhFgbbKwnb9MLmUQDhG6".as_ptr(), 1),
                -2
            );
        }
        release_tx.send(()).unwrap();
        for _ in 0..2 {
            finished_rx.recv_timeout(Duration::from_secs(5)).unwrap();
        }
        for thread in destroys {
            thread.join().unwrap();
        }
        dropped_rx
            .try_recv()
            .expect("pending work must be dropped before destroy returns");
        assert_eq!(callbacks.load(Ordering::SeqCst), 1);
        // SAFETY: both destroys are joined, and runtime work can no longer access the box.
        unsafe { release(ptr) };
    }
}
