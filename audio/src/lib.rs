//! remremote's audio streaming engine.
//!
//! Streams one computer's system audio to another in the RemSound wire format (Opus frames,
//! AES-256-GCM sealed, over UDP), which is what the remremote NVDA add-on and the native Mac
//! app already speak. The crate is built as a plain C-ABI dynamic library (`ffi`) that the
//! add-on loads straight into NVDA with ctypes, and as a Rust library for the test CLI.
//!
//! Layout:
//! * `packet`   – the 12-byte RemSound header and the Format payload
//! * `crypto`   – PBKDF2 key/fingerprint derivation and the sealed-packet layout
//! * `hello`    – remremote's sealed hello/pong NAT punch packets
//! * `opus`     – thin safe wrappers over libopus
//! * `jitter`   – the receiver's playout buffer
//! * `net`      – UDP helpers and the relay's registration framing
//! * `engine`   – the sender and receiver pipelines
//! * `platform` – system audio capture and playout (WASAPI on Windows; test sources elsewhere)
//! * `ffi`      – the C API

pub mod crypto;
pub mod engine;
pub mod ffi;
pub mod hello;
pub mod jitter;
pub mod net;
pub mod opus;
pub mod packet;
pub mod platform;

/// Version string reported to the add-on; kept in step with the add-on version.
pub const VERSION: &str = env!("CARGO_PKG_VERSION");
