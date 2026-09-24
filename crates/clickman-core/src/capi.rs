//! The extern-C boundary — glue only, no logic. Mirrors include/clickman.h, the
//! single source of truth every platform binding links against. Every entry
//! point is panic-proof: a panic or error is caught, recorded in the
//! thread-local last error and reported as a sentinel — a panic must never
//! unwind across FFI.

#![allow(non_camel_case_types)]

use std::cell::RefCell;
use std::ffi::{CStr, CString, c_char};
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::time::Duration;

use serde_json::Value;
use time::OffsetDateTime;

use crate::{Client, Config};

/// An open queue. Opaque to C; freed by `clickman_close`.
pub struct clickman_client(Client);

/// An owned byte buffer. `{NULL, 0}` holds nothing; any other buffer must be
/// released exactly once with `clickman_buf_free`.
#[repr(C)]
pub struct clickman_buf {
    pub ptr: *mut u8,
    pub len: usize,
}

impl clickman_buf {
    const EMPTY: Self = Self {
        ptr: std::ptr::null_mut(),
        len: 0,
    };

    fn from_vec(bytes: Vec<u8>) -> Self {
        let mut boxed = bytes.into_boxed_slice();
        let buf = Self {
            ptr: boxed.as_mut_ptr(),
            len: boxed.len(),
        };
        std::mem::forget(boxed);
        buf
    }
}

/// A batch to send: its id for `clickman_complete_batch`, the number of events
/// and the gzipped JSON body.
#[repr(C)]
pub struct clickman_batch {
    pub id: u64,
    pub events: u32,
    pub body: clickman_buf,
}

thread_local! {
    static LAST_ERROR: RefCell<CString> = RefCell::new(CString::default());
}

fn set_error(message: &str) {
    let message = CString::new(message.replace('\0', " ")).unwrap_or_default();
    LAST_ERROR.with(|last| *last.borrow_mut() = message);
}

fn guard<T>(fallback: T, name: &str, work: impl FnOnce() -> Result<T, String>) -> T {
    set_error("");
    match catch_unwind(AssertUnwindSafe(work)) {
        Ok(Ok(value)) => value,
        Ok(Err(message)) => {
            set_error(&message);
            fallback
        }
        Err(_) => {
            set_error(&format!("panic in {name}"));
            fallback
        }
    }
}

/// # Safety
/// `pointer` is NULL or a NUL-terminated string valid for the call.
unsafe fn text<'a>(pointer: *const c_char, name: &str) -> Result<&'a str, String> {
    if pointer.is_null() {
        return Err(format!("{name} is NULL"));
    }
    unsafe { CStr::from_ptr(pointer) }
        .to_str()
        .map_err(|_| format!("{name} is not UTF-8"))
}

/// # Safety
/// `pointer` is NULL or a client from `clickman_open` not yet closed.
unsafe fn client<'a>(pointer: *const clickman_client) -> Result<&'a Client, String> {
    unsafe { pointer.as_ref() }
        .map(|client| &client.0)
        .ok_or_else(|| "the client is NULL".to_owned())
}

fn time(milliseconds: i64) -> Result<OffsetDateTime, String> {
    OffsetDateTime::from_unix_timestamp_nanos(i128::from(milliseconds) * 1_000_000)
        .map_err(|_| format!("{milliseconds} ms is out of range"))
}

/// The library and protocol version, e.g. "clickman-core 0.1.0 (protocol v1)".
/// Static; never freed.
#[unsafe(no_mangle)]
pub extern "C" fn clickman_version() -> *const c_char {
    concat!(
        "clickman-core ",
        env!("CARGO_PKG_VERSION"),
        " (protocol v1)\0"
    )
    .as_ptr()
    .cast()
}

/// The last error on the calling thread, "" when the last call succeeded.
/// Valid until the next ClickMan call on this thread; never freed.
#[unsafe(no_mangle)]
pub extern "C" fn clickman_last_error() -> *const c_char {
    LAST_ERROR.with(|last| last.borrow().as_ptr())
}

/// Opens or creates the queue at `path`. `config_json` may be NULL for the
/// defaults. Returns NULL on failure (see `clickman_last_error`).
///
/// # Safety
/// `path` and `config_json` are NULL or NUL-terminated strings.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn clickman_open(
    path: *const c_char,
    config_json: *const c_char,
) -> *mut clickman_client {
    guard(std::ptr::null_mut(), "clickman_open", || {
        let path = unsafe { text(path, "path") }?;
        let config = if config_json.is_null() {
            Config::default()
        } else {
            Config::from_json(unsafe { text(config_json, "config") }?)
                .map_err(|error| error.to_string())?
        };
        let client = Client::open(path, config).map_err(|error| error.to_string())?;
        Ok(Box::into_raw(Box::new(clickman_client(client))))
    })
}

/// Closes a queue. NULL is ignored.
///
/// # Safety
/// `client` is NULL or a client from `clickman_open`, closed at most once.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn clickman_close(client: *mut clickman_client) {
    if !client.is_null() {
        drop(unsafe { Box::from_raw(client) });
    }
}

/// Sets the actor of events tracked from now on. Returns 0, or -1.
///
/// # Safety
/// `client` is from `clickman_open`; `external_id` is a NUL-terminated string.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn clickman_identify(
    client: *const clickman_client,
    external_id: *const c_char,
) -> i32 {
    guard(-1, "clickman_identify", || {
        let client = unsafe { self::client(client) }?;
        let external_id = unsafe { text(external_id, "external_id") }?;
        client
            .identify(external_id)
            .map_err(|error| error.to_string())?;
        Ok(0)
    })
}

/// Makes later events anonymous (`*`) and forgets the traits. Returns 0, or -1.
///
/// # Safety
/// `client` is from `clickman_open`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn clickman_reset(client: *const clickman_client) -> i32 {
    guard(-1, "clickman_reset", || {
        let client = unsafe { self::client(client) }?;
        client.reset().map_err(|error| error.to_string())?;
        Ok(0)
    })
}

/// Sets the context JSON object stamped on events tracked from now on.
/// Returns 0, or -1.
///
/// # Safety
/// `client` is from `clickman_open`; `context_json` is a NUL-terminated string.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn clickman_set_context(
    client: *const clickman_client,
    context_json: *const c_char,
) -> i32 {
    guard(-1, "clickman_set_context", || {
        let client = unsafe { self::client(client) }?;
        let context: Value = serde_json::from_str(unsafe { text(context_json, "context")? })
            .map_err(|error| format!("the context is not JSON: {error}"))?;
        client
            .set_context(context)
            .map_err(|error| error.to_string())?;
        Ok(0)
    })
}

/// Merges a JSON object into the traits sent as `context.traits` with events
/// tracked from now on; a null value removes a trait. Returns 0, or -1.
///
/// # Safety
/// `client` is from `clickman_open`; `traits_json` is a NUL-terminated string.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn clickman_set_traits(
    client: *const clickman_client,
    traits_json: *const c_char,
) -> i32 {
    guard(-1, "clickman_set_traits", || {
        let client = unsafe { self::client(client) }?;
        let traits: Value = serde_json::from_str(unsafe { text(traits_json, "traits")? })
            .map_err(|error| format!("the traits are not JSON: {error}"))?;
        client
            .set_traits(traits)
            .map_err(|error| error.to_string())?;
        Ok(0)
    })
}

/// Records a launch of the app: `app_installed` on the first launch,
/// `app_updated` on the first launch of a new version or build, then
/// `app_opened`. Returns 0, or -1.
///
/// # Safety
/// `client` is from `clickman_open`; `version` and `build` are NUL-terminated
/// strings.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn clickman_app_launched(
    client: *const clickman_client,
    version: *const c_char,
    build: *const c_char,
    now_ms: i64,
) -> i32 {
    guard(-1, "clickman_app_launched", || {
        let client = unsafe { self::client(client) }?;
        let version = unsafe { text(version, "version") }?;
        let build = unsafe { text(build, "build") }?;
        client
            .app_launched(version, build, time(now_ms)?)
            .map_err(|error| error.to_string())?;
        Ok(0)
    })
}

/// Queues an event. `properties_json` may be NULL; `timestamp_ms` is the event
/// time in Unix milliseconds, or 0 for now. Returns 0, or -1.
///
/// # Safety
/// `client` is from `clickman_open`; `event` is a NUL-terminated string and
/// `properties_json` NULL or one.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn clickman_track(
    client: *const clickman_client,
    event: *const c_char,
    properties_json: *const c_char,
    timestamp_ms: i64,
) -> i32 {
    guard(-1, "clickman_track", || {
        let client = unsafe { self::client(client) }?;
        let event = unsafe { text(event, "event") }?;
        let properties = if properties_json.is_null() {
            None
        } else {
            Some(
                serde_json::from_str::<Value>(unsafe { text(properties_json, "properties")? })
                    .map_err(|error| format!("the properties are not JSON: {error}"))?,
            )
        };
        let timestamp = if timestamp_ms == 0 {
            None
        } else {
            Some(time(timestamp_ms)?)
        };

        client
            .track(event, properties, timestamp, OffsetDateTime::now_utc())
            .map_err(|error| error.to_string())?;
        Ok(0)
    })
}

/// Hands out the next batch when one is due: returns 1 and fills `out`, whose
/// body the caller frees with `clickman_buf_free`; 0 when nothing is due; -1
/// on error. `force` sends whatever is waiting (the app is leaving the
/// foreground, the network came back).
///
/// # Safety
/// `client` is from `clickman_open`; `out` points to writable memory.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn clickman_take_batch(
    client: *const clickman_client,
    now_ms: i64,
    force: bool,
    out: *mut clickman_batch,
) -> i32 {
    guard(-1, "clickman_take_batch", || {
        let client = unsafe { self::client(client) }?;
        let out = unsafe { out.as_mut() }.ok_or("out is NULL")?;
        *out = clickman_batch {
            id: 0,
            events: 0,
            body: clickman_buf::EMPTY,
        };

        match client
            .take_batch(time(now_ms)?, force)
            .map_err(|error| error.to_string())?
        {
            None => Ok(0),
            Some(batch) => {
                *out = clickman_batch {
                    id: batch.id,
                    events: u32::try_from(batch.events).unwrap_or(u32::MAX),
                    body: clickman_buf::from_vec(batch.body),
                };
                Ok(1)
            }
        }
    })
}

/// Records how sending a batch ended: `http_status` is the response status, or
/// 0 when none came back; `retry_after_ms` is the Retry-After delay, or a
/// negative number when there was none. Returns 0, or -1.
///
/// # Safety
/// `client` is from `clickman_open`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn clickman_complete_batch(
    client: *const clickman_client,
    batch_id: u64,
    http_status: i32,
    retry_after_ms: i64,
    now_ms: i64,
) -> i32 {
    guard(-1, "clickman_complete_batch", || {
        let client = unsafe { self::client(client) }?;
        let status = u16::try_from(http_status)
            .map_err(|_| format!("{http_status} is not an HTTP status"))?;
        let retry_after = u64::try_from(retry_after_ms)
            .ok()
            .map(Duration::from_millis);

        client
            .complete(batch_id, status, retry_after, time(now_ms)?)
            .map_err(|error| error.to_string())?;
        Ok(0)
    })
}

/// Events on the device, in flight or waiting; -1 on error.
///
/// # Safety
/// `client` is from `clickman_open`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn clickman_pending(client: *const clickman_client) -> i64 {
    guard(-1, "clickman_pending", || {
        let client = unsafe { self::client(client) }?;
        let pending = client.pending().map_err(|error| error.to_string())?;
        Ok(i64::try_from(pending).unwrap_or(i64::MAX))
    })
}

/// Releases a buffer handed out by ClickMan. `{NULL, 0}` is ignored.
///
/// # Safety
/// `buf` came from ClickMan and is released at most once.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn clickman_buf_free(buf: clickman_buf) {
    if !buf.ptr.is_null() {
        drop(unsafe { Box::from_raw(std::ptr::slice_from_raw_parts_mut(buf.ptr, buf.len)) });
    }
}
