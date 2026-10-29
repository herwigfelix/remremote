//! Where the audio comes from and where it goes. The engine only sees these two traits; the
//! Windows implementation (WASAPI) is the one that ships, the tone/null pair exists for tests
//! and the CLI on any platform.

use std::sync::{Arc, Mutex};

use crate::jitter::PlayoutBuffer;

pub mod null;
pub mod tone;
#[cfg(windows)]
pub mod windows;
#[cfg(target_os = "macos")]
pub mod macos;

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

/// What a running capture or playout wants the engine to know after `start` returned.
#[derive(Clone, Debug)]
pub enum Notice {
    /// The pipeline died for good.
    Fatal(String),
    /// (code, message) worth telling the user, e.g. that the chosen device went missing.
    Warning(String, String),
    /// Diagnostic detail for the log.
    Diag(String),
}

pub type NoticeSink = Box<dyn FnMut(Notice) + Send>;

pub struct CaptureInfo {
    /// The process tree actually excluded from the capture, if any.
    pub excluding_pid: Option<u32>,
    /// (code, message) worth telling the user, e.g. that exclusion is unavailable.
    pub warning: Option<(String, String)>,
    pub description: String,
}

/// Delivers 48 kHz stereo interleaved float samples to `sink` from its own thread until
/// stopped; `notices` reports what happens after `start` returned.
pub trait CaptureSource: Send {
    fn start(&mut self, sink: Box<dyn FnMut(&[f32]) + Send>, notices: NoticeSink) -> Result<CaptureInfo, String>;
    /// Switch a whole-device capture to another device while running (no-op otherwise).
    fn set_device(&mut self, device: DeviceSelection);
    fn stop(&mut self);
}

pub struct PlayoutInfo {
    /// (code, message) worth telling the user, e.g. that the chosen device is missing.
    pub warning: Option<(String, String)>,
    pub description: String,
}

/// Drains the playout buffer to the system output from its own thread until stopped.
pub trait PlayoutSink: Send {
    fn start(&mut self, buffer: Arc<Mutex<PlayoutBuffer>>, notices: NoticeSink) -> Result<PlayoutInfo, String>;
    /// Switch to another output device while running.
    fn set_device(&mut self, device: DeviceSelection);
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
    #[cfg(target_os = "macos")]
    {
        Ok(Box::new(macos::CoreAudioPlayout::new(device)))
    }
    #[cfg(not(any(windows, target_os = "macos")))]
    {
        let _ = device;
        Err("system audio playout is only implemented on Windows and macOS".into())
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
