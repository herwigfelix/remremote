//! WASAPI system-audio capture and playout.
//!
//! Capture prefers the process-loopback API (Windows 10 2004+): `ActivateAudioInterfaceAsync`
//! on the virtual device `VAD\Process_Loopback` with EXCLUDE_TARGET_PROCESS_TREE, which yields
//! everything the machine plays except one process tree (NVDA's, so its speech is not heard
//! twice). When that is unavailable, or no process is excluded, the whole default output
//! device is captured with an ordinary loopback stream. Playout renders to the default output
//! device in shared mode. Both run on their own MTA thread that owns every COM object.

use std::ffi::c_void;
use std::mem::size_of;
use std::ptr::null_mut;
use std::slice;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{mpsc, Arc, Mutex};
use std::thread::{self, JoinHandle};
use std::time::Duration;

use windows::core::{implement, w, Interface, Ref, Result as WinResult, HRESULT};
use windows::Win32::Foundation::{CloseHandle, E_FAIL, HANDLE, WAIT_OBJECT_0};
use windows::Win32::Media::Audio::{
    eMultimedia, eRender, ActivateAudioInterfaceAsync, IActivateAudioInterfaceAsyncOperation,
    IActivateAudioInterfaceCompletionHandler, IActivateAudioInterfaceCompletionHandler_Impl, IAudioCaptureClient,
    IAudioClient, IAudioRenderClient, IMMDeviceEnumerator, MMDeviceEnumerator, AUDCLNT_BUFFERFLAGS_SILENT,
    AUDCLNT_SHAREMODE_SHARED, AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM, AUDCLNT_STREAMFLAGS_EVENTCALLBACK,
    AUDCLNT_STREAMFLAGS_LOOPBACK, AUDCLNT_STREAMFLAGS_SRC_DEFAULT_QUALITY, VIRTUAL_AUDIO_DEVICE_PROCESS_LOOPBACK,
    WAVEFORMATEX, WAVEFORMATEXTENSIBLE,
};
use windows::Win32::Media::Multimedia::{KSDATAFORMAT_SUBTYPE_IEEE_FLOAT, WAVE_FORMAT_IEEE_FLOAT};
use windows::Win32::System::Com::StructuredStorage::PROPVARIANT;
use windows::Win32::System::Com::{CoCreateInstance, CoInitializeEx, CoTaskMemFree, CoUninitialize, CLSCTX_ALL, COINIT_MULTITHREADED};
use windows::Win32::System::Threading::{
    AvRevertMmThreadCharacteristics, AvSetMmThreadCharacteristicsW, CreateEventW, WaitForSingleObject,
};

use super::{CaptureInfo, CaptureSource, PlayoutSink};
use crate::jitter::PlayoutBuffer;

const WAVE_FORMAT_EXTENSIBLE: u16 = 0xFFFE;
const HNS_PER_MS: i64 = 10_000;
const CAPTURE_BUFFER_MS: i64 = 20;
const RENDER_BUFFER_MS: i64 = 30;

// ------------------------------------------------------------------ small guards

/// COM for the current thread, released on drop when this guard initialised it.
struct ComGuard {
    initialised: bool,
}

impl ComGuard {
    fn new() -> Self {
        let hr = unsafe { CoInitializeEx(None, COINIT_MULTITHREADED) };
        ComGuard { initialised: hr.is_ok() }
    }
}

impl Drop for ComGuard {
    fn drop(&mut self) {
        if self.initialised {
            unsafe { CoUninitialize() }
        }
    }
}

struct Event(HANDLE);

impl Event {
    fn new() -> Result<Self, String> {
        let handle = unsafe { CreateEventW(None, false, false, None) }.map_err(|e| format!("CreateEvent: {e}"))?;
        Ok(Event(handle))
    }

    /// True when signalled, false on timeout.
    fn wait(&self, ms: u32) -> bool {
        unsafe { WaitForSingleObject(self.0, ms) == WAIT_OBJECT_0 }
    }
}

impl Drop for Event {
    fn drop(&mut self) {
        unsafe {
            let _ = CloseHandle(self.0);
        }
    }
}

/// Registers the thread with MMCSS ("Pro Audio") so the scheduler treats it like a real-time
/// audio thread; best effort.
struct MmcssGuard(Option<HANDLE>);

impl MmcssGuard {
    fn new() -> Self {
        let mut index = 0u32;
        MmcssGuard(unsafe { AvSetMmThreadCharacteristicsW(w!("Pro Audio"), &mut index) }.ok())
    }
}

impl Drop for MmcssGuard {
    fn drop(&mut self) {
        if let Some(handle) = self.0.take() {
            unsafe {
                let _ = AvRevertMmThreadCharacteristics(handle);
            }
        }
    }
}

fn stereo_float_48k() -> WAVEFORMATEX {
    WAVEFORMATEX {
        wFormatTag: WAVE_FORMAT_IEEE_FLOAT as u16,
        nChannels: 2,
        nSamplesPerSec: 48_000,
        nAvgBytesPerSec: 384_000,
        nBlockAlign: 8,
        wBitsPerSample: 32,
        cbSize: 0,
    }
}

/// The device's shared-mode mix format, if it is IEEE float (as it is on practically every
/// Windows 10/11 machine): (channels, sample rate).
fn float_mix_format(client: &IAudioClient) -> Result<(usize, u32), String> {
    let format = unsafe { client.GetMixFormat() }.map_err(|e| format!("GetMixFormat: {e}"))?;
    if format.is_null() {
        return Err("GetMixFormat returned nothing".into());
    }
    // WAVEFORMATEX is packed: copy every field out before using it.
    let result = unsafe {
        let base = std::ptr::read_unaligned(format);
        let tag = base.wFormatTag;
        let bits = base.wBitsPerSample;
        let channels = base.nChannels;
        let rate = base.nSamplesPerSec;
        let is_float = if tag == WAVE_FORMAT_EXTENSIBLE {
            let extensible = std::ptr::read_unaligned(format as *const WAVEFORMATEXTENSIBLE);
            let sub_format = extensible.SubFormat;
            sub_format == KSDATAFORMAT_SUBTYPE_IEEE_FLOAT
        } else {
            tag == WAVE_FORMAT_IEEE_FLOAT as u16
        };
        if is_float && bits == 32 {
            Ok((channels as usize, rate))
        } else {
            Err(format!("the device mix format is not 32-bit float (tag {tag}, {bits} bit, {channels} ch, {rate} Hz)"))
        }
    };
    unsafe { CoTaskMemFree(Some(format as *const c_void)) };
    result
}

// ------------------------------------------------------------ sample conversion

/// Turns captured float frames of any channel count / rate into 48 kHz stereo (first two
/// channels, linear resampling). Only used when the device refuses to convert for us.
struct Converter {
    channels: usize,
    rate: u32,
    position: f64,
    prev: [f32; 2],
}

impl Converter {
    fn new(channels: usize, rate: u32) -> Self {
        Converter { channels: channels.max(1), rate: rate.max(1), position: 0.0, prev: [0.0; 2] }
    }

    fn convert(&mut self, input: &[f32], out: &mut Vec<f32>) {
        out.clear();
        let frames = input.len() / self.channels;
        if frames == 0 {
            return;
        }
        let stereo = |frame: usize| -> [f32; 2] {
            let base = frame * self.channels;
            if self.channels == 1 {
                [input[base], input[base]]
            } else {
                [input[base], input[base + 1]]
            }
        };
        if self.rate == 48_000 {
            for frame in 0..frames {
                out.extend_from_slice(&stereo(frame));
            }
            return;
        }
        // Virtual index -1 is the last frame of the previous chunk.
        let step = self.rate as f64 / 48_000.0;
        let mut position = self.position;
        while position < (frames as f64) - 1.0 {
            let index = position.floor();
            let t = (position - index) as f32;
            let a = if index < 0.0 { self.prev } else { stereo(index as usize) };
            let b = stereo((index + 1.0) as usize);
            out.push(a[0] + (b[0] - a[0]) * t);
            out.push(a[1] + (b[1] - a[1]) * t);
            position += step;
        }
        self.position = position - frames as f64;
        self.prev = stereo(frames - 1);
    }
}

// ------------------------------------------------------ process-loopback activation

#[repr(C)]
struct ProcessLoopbackParams {
    target_process_id: u32,
    process_loopback_mode: i32, // 0 = include tree, 1 = exclude tree
}

#[repr(C)]
struct ActivationParams {
    activation_type: i32, // 1 = process loopback
    process_loopback_params: ProcessLoopbackParams,
}

/// A PROPVARIANT holding a VT_BLOB, laid out by hand so no binding detail can shift it:
/// vt(2) + 3 reserved words, then BLOB { size, pointer }.
#[repr(C)]
struct BlobPropVariant {
    vt: u16,
    reserved: [u16; 3],
    blob_size: u32,
    blob_data: *mut c_void,
}

#[implement(IActivateAudioInterfaceCompletionHandler)]
struct ActivationHandler {
    done: Mutex<Option<mpsc::Sender<WinResult<IAudioClient>>>>,
}

impl IActivateAudioInterfaceCompletionHandler_Impl for ActivationHandler_Impl {
    fn ActivateCompleted(&self, operation: Ref<IActivateAudioInterfaceAsyncOperation>) -> WinResult<()> {
        let result = (|| {
            let operation = operation.ok()?;
            let mut hr = HRESULT(0);
            let mut activated: Option<windows::core::IUnknown> = None;
            unsafe { operation.GetActivateResult(&mut hr, &mut activated)? };
            hr.ok()?;
            let unknown = activated.ok_or_else(|| windows::core::Error::from(E_FAIL))?;
            unknown.cast::<IAudioClient>()
        })();
        if let Some(sender) = self.done.lock().unwrap().take() {
            let _ = sender.send(result);
        }
        Ok(())
    }
}

fn activate_process_loopback(exclude_pid: u32) -> Result<IAudioClient, String> {
    let params = ActivationParams {
        activation_type: 1,
        process_loopback_params: ProcessLoopbackParams { target_process_id: exclude_pid, process_loopback_mode: 1 },
    };
    let prop = BlobPropVariant {
        vt: 65, // VT_BLOB
        reserved: [0; 3],
        blob_size: size_of::<ActivationParams>() as u32,
        blob_data: &params as *const ActivationParams as *mut c_void,
    };
    let (sender, receiver) = mpsc::channel();
    let handler: IActivateAudioInterfaceCompletionHandler = ActivationHandler { done: Mutex::new(Some(sender)) }.into();
    let _operation = unsafe {
        ActivateAudioInterfaceAsync(
            VIRTUAL_AUDIO_DEVICE_PROCESS_LOOPBACK,
            &IAudioClient::IID,
            Some(&prop as *const BlobPropVariant as *const PROPVARIANT),
            &handler,
        )
    }
    .map_err(|e| format!("ActivateAudioInterfaceAsync: {e}"))?;
    receiver
        .recv_timeout(Duration::from_secs(3))
        .map_err(|_| "process-loopback activation timed out".to_string())?
        .map_err(|e| format!("process-loopback activation failed: {e}"))
}

// ------------------------------------------------------------------- capture

struct CaptureStream {
    client: IAudioClient,
    capture: IAudioCaptureClient,
    /// Event-driven (process loopback) or polled (device loopback, whose events are unreliable
    /// while nothing renders).
    event: Option<Event>,
    channels: usize,
    converter: Option<Converter>,
}

fn open_process_loopback(exclude_pid: u32) -> Result<CaptureStream, String> {
    let client = activate_process_loopback(exclude_pid)?;
    let format = stereo_float_48k();
    unsafe {
        client.Initialize(
            AUDCLNT_SHAREMODE_SHARED,
            AUDCLNT_STREAMFLAGS_LOOPBACK | AUDCLNT_STREAMFLAGS_EVENTCALLBACK | AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM,
            CAPTURE_BUFFER_MS * HNS_PER_MS,
            0,
            &format,
            None,
        )
    }
    .map_err(|e| format!("IAudioClient::Initialize (process loopback): {e}"))?;
    let event = Event::new()?;
    unsafe { client.SetEventHandle(event.0) }.map_err(|e| format!("SetEventHandle: {e}"))?;
    let capture: IAudioCaptureClient = unsafe { client.GetService() }.map_err(|e| format!("GetService(capture): {e}"))?;
    unsafe { client.Start() }.map_err(|e| format!("IAudioClient::Start: {e}"))?;
    Ok(CaptureStream { client, capture, event: Some(event), channels: 2, converter: None })
}

fn open_device_loopback() -> Result<CaptureStream, String> {
    let enumerator: IMMDeviceEnumerator =
        unsafe { CoCreateInstance(&MMDeviceEnumerator, None, CLSCTX_ALL) }.map_err(|e| format!("MMDeviceEnumerator: {e}"))?;
    let device = unsafe { enumerator.GetDefaultAudioEndpoint(eRender, eMultimedia) }
        .map_err(|e| format!("no default output device: {e}"))?;
    let client: IAudioClient = unsafe { device.Activate(CLSCTX_ALL, None) }.map_err(|e| format!("IMMDevice::Activate: {e}"))?;
    let wanted = stereo_float_48k();
    let converted = unsafe {
        client.Initialize(
            AUDCLNT_SHAREMODE_SHARED,
            AUDCLNT_STREAMFLAGS_LOOPBACK | AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM | AUDCLNT_STREAMFLAGS_SRC_DEFAULT_QUALITY,
            CAPTURE_BUFFER_MS * HNS_PER_MS,
            0,
            &wanted,
            None,
        )
    };
    let (channels, converter) = match converted {
        Ok(()) => (2, None),
        Err(_) => {
            // The device will not convert: capture its own float mix format and convert here.
            let client_again: IAudioClient =
                unsafe { device.Activate(CLSCTX_ALL, None) }.map_err(|e| format!("IMMDevice::Activate: {e}"))?;
            let (channels, rate) = float_mix_format(&client_again)?;
            let format = unsafe { client_again.GetMixFormat() }.map_err(|e| format!("GetMixFormat: {e}"))?;
            let init = unsafe {
                client_again.Initialize(AUDCLNT_SHAREMODE_SHARED, AUDCLNT_STREAMFLAGS_LOOPBACK, CAPTURE_BUFFER_MS * HNS_PER_MS, 0, format, None)
            };
            unsafe { CoTaskMemFree(Some(format as *const c_void)) };
            init.map_err(|e| format!("IAudioClient::Initialize (loopback): {e}"))?;
            return finish_device_loopback(client_again, channels, Some(Converter::new(channels, rate)));
        }
    };
    finish_device_loopback(client, channels, converter)
}

fn finish_device_loopback(client: IAudioClient, channels: usize, converter: Option<Converter>) -> Result<CaptureStream, String> {
    let capture: IAudioCaptureClient = unsafe { client.GetService() }.map_err(|e| format!("GetService(capture): {e}"))?;
    unsafe { client.Start() }.map_err(|e| format!("IAudioClient::Start: {e}"))?;
    Ok(CaptureStream { client, capture, event: None, channels, converter })
}

fn open_capture(exclude_pid: u32) -> Result<(CaptureStream, CaptureInfo), String> {
    let mut warning = None;
    if exclude_pid > 0 {
        match open_process_loopback(exclude_pid) {
            Ok(stream) => {
                return Ok((
                    stream,
                    CaptureInfo {
                        excluding_pid: Some(exclude_pid),
                        warning: None,
                        description: format!("system audio except process tree {exclude_pid}"),
                    },
                ))
            }
            Err(error) => {
                warning = Some((
                    "exclude-unsupported".to_string(),
                    format!("process exclusion is unavailable ({error}); capturing the whole default output device"),
                ));
            }
        }
    }
    let stream = open_device_loopback()?;
    Ok((stream, CaptureInfo { excluding_pid: None, warning, description: "default output device".to_string() }))
}

fn run_capture(stream: &mut CaptureStream, stop: &AtomicBool, sink: &mut dyn FnMut(&[f32])) -> Result<(), String> {
    let _boost = MmcssGuard::new();
    let mut scratch: Vec<f32> = Vec::with_capacity(4096);
    let mut converted: Vec<f32> = Vec::with_capacity(4096);
    let silent = AUDCLNT_BUFFERFLAGS_SILENT.0 as u32;
    while !stop.load(Ordering::Relaxed) {
        match &stream.event {
            Some(event) => {
                event.wait(200);
            }
            None => thread::sleep(Duration::from_millis(5)),
        }
        if stop.load(Ordering::Relaxed) {
            break;
        }
        loop {
            let mut data: *mut u8 = null_mut();
            let mut frames = 0u32;
            let mut flags = 0u32;
            unsafe { stream.capture.GetBuffer(&mut data, &mut frames, &mut flags, None, None) }
                .map_err(|e| format!("IAudioCaptureClient::GetBuffer: {e}"))?;
            if frames == 0 {
                break;
            }
            let count = frames as usize * stream.channels;
            scratch.clear();
            if flags & silent != 0 || data.is_null() {
                scratch.resize(count, 0.0);
            } else {
                scratch.extend_from_slice(unsafe { slice::from_raw_parts(data as *const f32, count) });
            }
            unsafe { stream.capture.ReleaseBuffer(frames) }.map_err(|e| format!("ReleaseBuffer: {e}"))?;
            match stream.converter.as_mut() {
                Some(converter) => {
                    converter.convert(&scratch, &mut converted);
                    if !converted.is_empty() {
                        sink(&converted);
                    }
                }
                None => sink(&scratch),
            }
        }
    }
    Ok(())
}

pub struct WasapiCapture {
    exclude_pid: u32,
    stop: Arc<AtomicBool>,
    thread: Option<JoinHandle<()>>,
}

impl WasapiCapture {
    pub fn new(exclude_pid: u32) -> Self {
        WasapiCapture { exclude_pid, stop: Arc::new(AtomicBool::new(false)), thread: None }
    }
}

impl CaptureSource for WasapiCapture {
    fn start(&mut self, mut sink: Box<dyn FnMut(&[f32]) + Send>, mut on_fatal: Box<dyn FnMut(String) + Send>) -> Result<CaptureInfo, String> {
        let stop = self.stop.clone();
        let exclude_pid = self.exclude_pid;
        let (ready_tx, ready_rx) = mpsc::channel::<Result<CaptureInfo, String>>();
        let thread = thread::Builder::new()
            .name("remremote-audio-capture".into())
            .spawn(move || {
                let _com = ComGuard::new();
                let (mut stream, info) = match open_capture(exclude_pid) {
                    Ok(opened) => opened,
                    Err(error) => {
                        let _ = ready_tx.send(Err(error));
                        return;
                    }
                };
                let _ = ready_tx.send(Ok(info));
                let outcome = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| run_capture(&mut stream, &stop, &mut *sink)));
                unsafe {
                    let _ = stream.client.Stop();
                }
                match outcome {
                    Ok(Ok(())) => {}
                    Ok(Err(error)) => {
                        if !stop.load(Ordering::Relaxed) {
                            on_fatal(format!("capture stopped: {error}"));
                        }
                    }
                    Err(_) => on_fatal("capture thread panicked".to_string()),
                }
            })
            .map_err(|e| format!("could not start the capture thread: {e}"))?;
        self.thread = Some(thread);
        match ready_rx.recv_timeout(Duration::from_secs(10)) {
            Ok(Ok(info)) => Ok(info),
            Ok(Err(error)) => {
                self.stop();
                Err(error)
            }
            Err(_) => {
                self.stop();
                Err("the capture thread did not report back".into())
            }
        }
    }

    fn stop(&mut self) {
        self.stop.store(true, Ordering::Relaxed);
        if let Some(thread) = self.thread.take() {
            let _ = thread.join();
        }
    }
}

// ------------------------------------------------------------------- playout

pub struct WasapiPlayout {
    stop: Arc<AtomicBool>,
    thread: Option<JoinHandle<()>>,
}

impl WasapiPlayout {
    pub fn new() -> Self {
        WasapiPlayout { stop: Arc::new(AtomicBool::new(false)), thread: None }
    }
}

impl Default for WasapiPlayout {
    fn default() -> Self {
        Self::new()
    }
}

impl PlayoutSink for WasapiPlayout {
    fn start(&mut self, buffer: Arc<Mutex<PlayoutBuffer>>, mut on_fatal: Box<dyn FnMut(String) + Send>) -> Result<(), String> {
        let stop = self.stop.clone();
        let (ready_tx, ready_rx) = mpsc::channel::<Result<(), String>>();
        let thread = thread::Builder::new()
            .name("remremote-audio-playout".into())
            .spawn(move || {
                let _com = ComGuard::new();
                // Report success once the device has opened; errors before the first callback
                // reach start(), later ones on_fatal.
                let ready = Mutex::new(Some(ready_tx));
                let outcome = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                    run_playout_reporting(&buffer, &stop, &ready)
                }));
                match outcome {
                    Ok(Ok(())) => {}
                    Ok(Err(error)) => {
                        if let Some(tx) = ready.lock().unwrap().take() {
                            let _ = tx.send(Err(error));
                        } else if !stop.load(Ordering::Relaxed) {
                            on_fatal(format!("playout stopped: {error}"));
                        }
                    }
                    Err(_) => {
                        if let Some(tx) = ready.lock().unwrap().take() {
                            let _ = tx.send(Err("playout thread panicked".into()));
                        } else {
                            on_fatal("playout thread panicked".to_string());
                        }
                    }
                }
            })
            .map_err(|e| format!("could not start the playout thread: {e}"))?;
        self.thread = Some(thread);
        match ready_rx.recv_timeout(Duration::from_secs(10)) {
            Ok(Ok(())) => Ok(()),
            Ok(Err(error)) => {
                self.stop();
                Err(error)
            }
            Err(_) => {
                self.stop();
                Err("the playout thread did not report back".into())
            }
        }
    }

    fn stop(&mut self) {
        self.stop.store(true, Ordering::Relaxed);
        if let Some(thread) = self.thread.take() {
            let _ = thread.join();
        }
    }
}

/// `run_playout` split so the "device opened" signal fires right after Start().
fn run_playout_reporting(
    buffer: &Mutex<PlayoutBuffer>,
    stop: &AtomicBool,
    ready: &Mutex<Option<mpsc::Sender<Result<(), String>>>>,
) -> Result<(), String> {
    let enumerator: IMMDeviceEnumerator =
        unsafe { CoCreateInstance(&MMDeviceEnumerator, None, CLSCTX_ALL) }.map_err(|e| format!("MMDeviceEnumerator: {e}"))?;
    let device = unsafe { enumerator.GetDefaultAudioEndpoint(eRender, eMultimedia) }
        .map_err(|e| format!("no default output device: {e}"))?;
    let client: IAudioClient = unsafe { device.Activate(CLSCTX_ALL, None) }.map_err(|e| format!("IMMDevice::Activate: {e}"))?;
    let format = stereo_float_48k();
    unsafe {
        client.Initialize(
            AUDCLNT_SHAREMODE_SHARED,
            AUDCLNT_STREAMFLAGS_EVENTCALLBACK | AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM | AUDCLNT_STREAMFLAGS_SRC_DEFAULT_QUALITY,
            RENDER_BUFFER_MS * HNS_PER_MS,
            0,
            &format,
            None,
        )
    }
    .map_err(|e| {
        let mix = float_mix_format(&client).map(|(c, r)| format!("{c} ch {r} Hz")).unwrap_or_else(|m| m);
        format!("IAudioClient::Initialize (render 48 kHz float stereo; device mix format: {mix}): {e}")
    })?;
    let buffer_frames = unsafe { client.GetBufferSize() }.map_err(|e| format!("GetBufferSize: {e}"))?;
    let event = Event::new()?;
    unsafe { client.SetEventHandle(event.0) }.map_err(|e| format!("SetEventHandle: {e}"))?;
    let render: IAudioRenderClient = unsafe { client.GetService() }.map_err(|e| format!("GetService(render): {e}"))?;
    unsafe {
        let _ = render.GetBuffer(buffer_frames).map_err(|e| format!("GetBuffer: {e}"))?;
        render.ReleaseBuffer(buffer_frames, AUDCLNT_BUFFERFLAGS_SILENT.0 as u32).map_err(|e| format!("ReleaseBuffer: {e}"))?;
        client.Start().map_err(|e| format!("IAudioClient::Start: {e}"))?;
    }
    if let Some(tx) = ready.lock().unwrap().take() {
        let _ = tx.send(Ok(()));
    }
    let _boost = MmcssGuard::new();
    while !stop.load(Ordering::Relaxed) {
        if !event.wait(200) {
            continue;
        }
        if stop.load(Ordering::Relaxed) {
            break;
        }
        let padding = unsafe { client.GetCurrentPadding() }.map_err(|e| format!("GetCurrentPadding: {e}"))?;
        let frames = buffer_frames.saturating_sub(padding);
        if frames == 0 {
            continue;
        }
        let data = unsafe { render.GetBuffer(frames) }.map_err(|e| format!("IAudioRenderClient::GetBuffer: {e}"))?;
        if data.is_null() {
            continue;
        }
        let out = unsafe { slice::from_raw_parts_mut(data as *mut f32, frames as usize * 2) };
        buffer.lock().unwrap().read(out);
        unsafe { render.ReleaseBuffer(frames, 0) }.map_err(|e| format!("ReleaseBuffer: {e}"))?;
    }
    unsafe {
        let _ = client.Stop();
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn propvariant_blob_layout_matches_the_abi() {
        // vt + 3 reserved words = 8 bytes, then BLOB { u32 size, pointer }.
        assert_eq!(size_of::<BlobPropVariant>(), if size_of::<usize>() == 8 { 24 } else { 16 });
        assert_eq!(size_of::<ActivationParams>(), 12);
    }

    #[test]
    fn converter_downmixes_and_resamples() {
        let mut converter = Converter::new(1, 48_000);
        let mut out = Vec::new();
        converter.convert(&[0.5, -0.5], &mut out);
        assert_eq!(out, vec![0.5, 0.5, -0.5, -0.5]);
        let mut converter = Converter::new(2, 96_000);
        let input: Vec<f32> = (0..200).flat_map(|i| [i as f32, -(i as f32)]).collect();
        converter.convert(&input, &mut out);
        assert!((out.len() as i64 - 200).abs() <= 4, "{}", out.len());
        assert_eq!(out[0], 0.0);
        assert!((out[2] - 2.0).abs() < 1e-3);
    }
}
