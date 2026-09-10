//! Where the audio comes from and where it goes. The engine only sees these two traits; the
//! Windows implementation (WASAPI) is the one that ships, the tone/null pair exists for tests
//! and the CLI on any platform.

use std::sync::{Arc, Mutex};

use crate::jitter::PlayoutBuffer;

pub mod null;
pub mod tone;
#[cfg(windows)]
pub mod windows;

pub struct CaptureInfo {
    /// The process tree actually excluded from the capture, if any.
    pub excluding_pid: Option<u32>,
    /// (code, message) worth telling the user, e.g. that exclusion is unavailable.
    pub warning: Option<(String, String)>,
    pub description: String,
}

/// Delivers 48 kHz stereo interleaved float samples to `sink` from its own thread until
/// stopped; `on_fatal` reports a capture that died after `start` returned.
pub trait CaptureSource: Send {
    fn start(
        &mut self,
        sink: Box<dyn FnMut(&[f32]) + Send>,
        on_fatal: Box<dyn FnMut(String) + Send>,
    ) -> Result<CaptureInfo, String>;
    fn stop(&mut self);
}

/// Drains the playout buffer to the system output from its own thread until stopped.
pub trait PlayoutSink: Send {
    fn start(
        &mut self,
        buffer: Arc<Mutex<PlayoutBuffer>>,
        on_fatal: Box<dyn FnMut(String) + Send>,
    ) -> Result<(), String>;
    fn stop(&mut self);
}

/// This machine's system audio, minus `exclude_pid`'s process tree when > 0.
pub fn system_capture(exclude_pid: u32) -> Result<Box<dyn CaptureSource>, String> {
    #[cfg(windows)]
    {
        Ok(Box::new(windows::WasapiCapture::new(exclude_pid)))
    }
    #[cfg(not(windows))]
    {
        let _ = exclude_pid;
        Err("system audio capture is only implemented on Windows".into())
    }
}

/// This machine's default output device.
pub fn system_playout() -> Result<Box<dyn PlayoutSink>, String> {
    #[cfg(windows)]
    {
        Ok(Box::new(windows::WasapiPlayout::new()))
    }
    #[cfg(not(windows))]
    {
        Err("system audio playout is only implemented on Windows".into())
    }
}
