//! Where the audio comes from and where it goes. The engine only sees these two traits; the
//! Windows implementation (WASAPI) is the one that ships, the tone/null pair exists for tests
//! and the CLI on any platform.

use std::sync::{Arc, Mutex};

use crate::jitter::PlayoutBuffer;

pub mod null;
pub mod tone;
#[cfg(windows)]
pub mod windows;

/// Which output device to play on (and, for a whole-device loopback capture, to capture):
/// the system default, or the device NVDA is configured to use — by endpoint id (NVDA 2025.1+)
/// or by the WinMM-style friendly name older NVDA versions store.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub enum DeviceSelection {
    #[default]
    Default,
    Id(String),
    Name(String),
}

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

pub struct PlayoutInfo {
    /// (code, message) worth telling the user, e.g. that the chosen device is missing.
    pub warning: Option<(String, String)>,
    pub description: String,
}

/// Drains the playout buffer to the system output from its own thread until stopped.
pub trait PlayoutSink: Send {
    fn start(
        &mut self,
        buffer: Arc<Mutex<PlayoutBuffer>>,
        on_fatal: Box<dyn FnMut(String) + Send>,
    ) -> Result<PlayoutInfo, String>;
    fn stop(&mut self);
}

/// This machine's system audio, minus `exclude_pid`'s process tree when > 0. `device` only
/// matters for a whole-device capture (no exclusion, or exclusion unavailable).
pub fn system_capture(exclude_pid: u32, device: DeviceSelection) -> Result<Box<dyn CaptureSource>, String> {
    #[cfg(windows)]
    {
        Ok(Box::new(windows::WasapiCapture::new(exclude_pid, device)))
    }
    #[cfg(not(windows))]
    {
        let _ = (exclude_pid, device);
        Err("system audio capture is only implemented on Windows".into())
    }
}

/// This machine's output device.
pub fn system_playout(device: DeviceSelection) -> Result<Box<dyn PlayoutSink>, String> {
    #[cfg(windows)]
    {
        Ok(Box::new(windows::WasapiPlayout::new(device)))
    }
    #[cfg(not(windows))]
    {
        let _ = device;
        Err("system audio playout is only implemented on Windows".into())
    }
}

/// The active output devices: (endpoint id, friendly name, is the default).
pub fn list_output_devices() -> Result<Vec<(String, String, bool)>, String> {
    #[cfg(windows)]
    {
        windows::list_render_devices()
    }
    #[cfg(not(windows))]
    {
        Err("device enumeration is only implemented on Windows".into())
    }
}
