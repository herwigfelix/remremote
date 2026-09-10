//! The C API the NVDA add-on drives with ctypes.
//!
//! ```c
//! const char* remremote_audio_version(void);
//! void* remremote_audio_start(const char* config_json,
//!                             void (*callback)(void* user, const char* event_json),
//!                             void* user);            // NULL on failure, see last_error
//! void  remremote_audio_stop(void* handle);            // joins every thread; no callback after
//! size_t remremote_audio_last_error(char* buf, size_t capacity);
//! ```
//!
//! `config_json`: `{"mode": "send"|"recv", "password": "...", "bindPort": 0, "host": "...",
//! "port": 6837, "excludePid": 0, "maxLatency": 0, "relaySession": "<base64 32 bytes>"}`.
//! Events are the same JSON objects the engine emits, delivered on worker threads.

use std::cell::RefCell;
use std::ffi::{c_char, c_void, CStr, CString};
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::sync::{Arc, OnceLock};

use base64::Engine as _;
use serde::Deserialize;

use crate::engine::{self, EventSink, RecvConfig, Receiver, SendConfig, Sender};
use crate::platform;

pub type EventCallback = Option<unsafe extern "C" fn(*mut c_void, *const c_char)>;

pub enum Engine {
    Send(Sender),
    Recv(Receiver),
}

pub struct Handle {
    engine: Engine,
}

thread_local! {
    static LAST_ERROR: RefCell<String> = const { RefCell::new(String::new()) };
}

fn set_last_error(message: impl Into<String>) {
    LAST_ERROR.with(|slot| *slot.borrow_mut() = message.into());
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Config {
    mode: String,
    #[serde(default)]
    password: String,
    #[serde(default)]
    bind_port: u16,
    #[serde(default)]
    host: Option<String>,
    #[serde(default)]
    port: u16,
    #[serde(default)]
    exclude_pid: u32,
    #[serde(default)]
    max_latency: u32,
    #[serde(default)]
    relay_session: Option<String>,
}

fn parse_session(encoded: Option<String>) -> Result<Option<[u8; 32]>, String> {
    let Some(encoded) = encoded.filter(|s| !s.is_empty()) else { return Ok(None) };
    let bytes = base64::engine::general_purpose::STANDARD
        .decode(encoded.trim())
        .map_err(|e| format!("relaySession is not valid base64: {e}"))?;
    let array: [u8; 32] = bytes.try_into().map_err(|_| "relaySession must be 32 bytes".to_string())?;
    Ok(Some(array))
}

struct CallbackTarget {
    callback: unsafe extern "C" fn(*mut c_void, *const c_char),
    user: *mut c_void,
}

// The add-on promises the callback and user pointer stay valid until stop() returns.
unsafe impl Send for CallbackTarget {}
unsafe impl Sync for CallbackTarget {}

impl CallbackTarget {
    fn call(&self, text: &CString) {
        unsafe { (self.callback)(self.user, text.as_ptr()) }
    }
}

fn make_sink(callback: EventCallback, user: *mut c_void) -> EventSink {
    match callback {
        Some(callback) => {
            let target = CallbackTarget { callback, user };
            Arc::new(move |value: serde_json::Value| {
                if let Ok(text) = CString::new(value.to_string()) {
                    target.call(&text);
                }
            })
        }
        None => Arc::new(|_| {}),
    }
}

/// Starts a pipeline from a JSON config. Shared by the C entry point and the CLI.
pub fn start_from_json(config_json: &str, events: EventSink) -> Result<Engine, String> {
    let config: Config = serde_json::from_str(config_json).map_err(|e| format!("bad config: {e}"))?;
    let relay_session = parse_session(config.relay_session)?;
    match config.mode.as_str() {
        "send" => {
            let capture = platform::system_capture(config.exclude_pid)?;
            let sender = engine::start_sender(
                SendConfig {
                    password: config.password,
                    bind_port: config.bind_port,
                    host: config.host,
                    port: config.port,
                    exclude_pid: config.exclude_pid,
                    relay_session,
                },
                capture,
                events,
            )?;
            Ok(Engine::Send(sender))
        }
        "recv" => {
            let playout = platform::system_playout()?;
            let receiver = engine::start_receiver(
                RecvConfig {
                    password: config.password,
                    bind_port: config.bind_port,
                    host: config.host,
                    port: config.port,
                    max_latency_ms: config.max_latency,
                    relay_session,
                },
                playout,
                events,
            )?;
            Ok(Engine::Recv(receiver))
        }
        other => Err(format!("unknown mode \"{other}\" (expected send or recv)")),
    }
}

impl Engine {
    pub fn stop(&mut self) {
        match self {
            Engine::Send(sender) => sender.stop(),
            Engine::Recv(receiver) => receiver.stop(),
        }
    }
}

#[no_mangle]
pub extern "C" fn remremote_audio_version() -> *const c_char {
    static VERSION: OnceLock<CString> = OnceLock::new();
    VERSION.get_or_init(|| CString::new(crate::VERSION).unwrap()).as_ptr()
}

/// # Safety
/// `config_json` must be a valid NUL-terminated UTF-8 string; `callback`/`user` must stay
/// valid until `remremote_audio_stop` returns.
#[no_mangle]
pub unsafe extern "C" fn remremote_audio_start(config_json: *const c_char, callback: EventCallback, user: *mut c_void) -> *mut Handle {
    let result = catch_unwind(AssertUnwindSafe(|| {
        if config_json.is_null() {
            return Err("config is NULL".to_string());
        }
        let config = CStr::from_ptr(config_json).to_str().map_err(|e| format!("config is not UTF-8: {e}"))?;
        start_from_json(config, make_sink(callback, user))
    }));
    match result {
        Ok(Ok(engine)) => Box::into_raw(Box::new(Handle { engine })),
        Ok(Err(message)) => {
            set_last_error(message);
            std::ptr::null_mut()
        }
        Err(_) => {
            set_last_error("the audio engine panicked while starting");
            std::ptr::null_mut()
        }
    }
}

/// # Safety
/// `handle` must come from `remremote_audio_start` and not be used afterwards.
#[no_mangle]
pub unsafe extern "C" fn remremote_audio_stop(handle: *mut Handle) {
    if handle.is_null() {
        return;
    }
    let mut handle = Box::from_raw(handle);
    let _ = catch_unwind(AssertUnwindSafe(|| handle.engine.stop()));
}

/// Copies the last error of this thread into `buf` (NUL-terminated, truncated to fit) and
/// returns the full message length.
///
/// # Safety
/// `buf` must point to `capacity` writable bytes (or be NULL with capacity 0).
#[no_mangle]
pub unsafe extern "C" fn remremote_audio_last_error(buf: *mut c_char, capacity: usize) -> usize {
    LAST_ERROR.with(|slot| {
        let message = slot.borrow();
        let bytes = message.as_bytes();
        if !buf.is_null() && capacity > 0 {
            let n = bytes.len().min(capacity - 1);
            std::ptr::copy_nonoverlapping(bytes.as_ptr(), buf as *mut u8, n);
            *buf.add(n) = 0;
        }
        bytes.len()
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn version_and_errors_cross_the_boundary() {
        let version = unsafe { CStr::from_ptr(remremote_audio_version()) }.to_str().unwrap();
        assert_eq!(version, crate::VERSION);
        let bad = CString::new(r#"{"mode":"neither"}"#).unwrap();
        let handle = unsafe { remremote_audio_start(bad.as_ptr(), None, std::ptr::null_mut()) };
        assert!(handle.is_null());
        let mut buf = [0 as c_char; 128];
        let len = unsafe { remremote_audio_last_error(buf.as_mut_ptr(), buf.len()) };
        let message = unsafe { CStr::from_ptr(buf.as_ptr()) }.to_str().unwrap();
        assert_eq!(len, message.len());
        assert!(message.contains("unknown mode"), "{message}");
        let short = unsafe { remremote_audio_last_error(std::ptr::null_mut(), 0) };
        assert_eq!(short, len);
        unsafe { remremote_audio_stop(std::ptr::null_mut()) };
        assert!(parse_session(Some("AAAA".into())).is_err());
        assert_eq!(parse_session(Some(String::new())).unwrap(), None);
        let session = base64::engine::general_purpose::STANDARD.encode([9u8; 32]);
        assert_eq!(parse_session(Some(session)).unwrap(), Some([9u8; 32]));
    }
}
