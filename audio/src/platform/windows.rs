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
use windows::core::PCWSTR;
use windows::Win32::Foundation::PROPERTYKEY;
use windows::Win32::Media::Audio::{
    eMultimedia, eRender, ActivateAudioInterfaceAsync, EDataFlow, ERole, IActivateAudioInterfaceAsyncOperation, IMMDevice,
    IMMNotificationClient, IMMNotificationClient_Impl, DEVICE_STATE, DEVICE_STATE_ACTIVE,
    IActivateAudioInterfaceCompletionHandler, IActivateAudioInterfaceCompletionHandler_Impl, IAudioCaptureClient,
    IAudioClient, IAudioRenderClient, IMMDeviceEnumerator, MMDeviceEnumerator, AUDCLNT_BUFFERFLAGS_SILENT,
    AUDCLNT_SHAREMODE_SHARED, AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM, AUDCLNT_STREAMFLAGS_EVENTCALLBACK,
    AUDCLNT_STREAMFLAGS_LOOPBACK, AUDCLNT_STREAMFLAGS_SRC_DEFAULT_QUALITY, VIRTUAL_AUDIO_DEVICE_PROCESS_LOOPBACK,
    WAVEFORMATEX, WAVEFORMATEXTENSIBLE,
};
use windows::Win32::Media::Multimedia::{KSDATAFORMAT_SUBTYPE_IEEE_FLOAT, WAVE_FORMAT_IEEE_FLOAT};
use windows::Win32::System::Com::StructuredStorage::{PropVariantClear, PropVariantToStringAlloc, PROPVARIANT};
use windows::Win32::System::Com::{CoCreateInstance, CoInitializeEx, CoTaskMemFree, CoUninitialize, CLSCTX_ALL, COINIT_MULTITHREADED, STGM_READ};
use windows::Win32::System::Threading::{
    AvRevertMmThreadCharacteristics, AvSetMmThreadCharacteristicsW, CreateEventW, WaitForSingleObject,
};

use super::{CaptureInfo, CaptureSource, DeviceSelection, Notice, NoticeSink, PlayoutInfo, PlayoutSink};
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

// ------------------------------------------------------------ output devices

/// PKEY_Device_FriendlyName: {a45c254e-df1c-4efd-8020-67d146a850e0}, 14.
const PKEY_DEVICE_FRIENDLY_NAME: PROPERTYKEY = PROPERTYKEY {
    fmtid: windows::core::GUID::from_u128(0xa45c254e_df1c_4efd_8020_67d146a850e0),
    pid: 14,
};

fn pwstr_to_string(pwstr: windows::core::PWSTR) -> String {
    if pwstr.is_null() {
        return String::new();
    }
    let text = unsafe { pwstr.to_string() }.unwrap_or_default();
    unsafe { CoTaskMemFree(Some(pwstr.0 as *const c_void)) };
    text
}

fn device_id(device: &IMMDevice) -> String {
    unsafe { device.GetId() }.map(pwstr_to_string).unwrap_or_default()
}

fn device_name(device: &IMMDevice) -> String {
    let Ok(store) = (unsafe { device.OpenPropertyStore(STGM_READ) }) else { return String::new() };
    let Ok(mut value) = (unsafe { store.GetValue(&PKEY_DEVICE_FRIENDLY_NAME) }) else { return String::new() };
    let name = unsafe { PropVariantToStringAlloc(&value) }.map(pwstr_to_string).unwrap_or_default();
    unsafe {
        let _ = PropVariantClear(&mut value);
    }
    name
}

fn enumerator() -> Result<IMMDeviceEnumerator, String> {
    unsafe { CoCreateInstance(&MMDeviceEnumerator, None, CLSCTX_ALL) }.map_err(|e| format!("MMDeviceEnumerator: {e}"))
}

fn default_render_device(enumerator: &IMMDeviceEnumerator) -> Result<IMMDevice, String> {
    unsafe { enumerator.GetDefaultAudioEndpoint(eRender, eMultimedia) }.map_err(|e| format!("no default output device: {e}"))
}

/// Every active render endpoint as (id, friendly name, is default).
pub fn list_render_devices() -> Result<Vec<(String, String, bool)>, String> {
    let _com = ComGuard::new();
    let enumerator = enumerator()?;
    let default_id = default_render_device(&enumerator).map(|d| device_id(&d)).unwrap_or_default();
    let collection = unsafe { enumerator.EnumAudioEndpoints(eRender, DEVICE_STATE_ACTIVE) }.map_err(|e| format!("EnumAudioEndpoints: {e}"))?;
    let count = unsafe { collection.GetCount() }.map_err(|e| format!("GetCount: {e}"))?;
    let mut devices = Vec::new();
    for index in 0..count {
        let Ok(device) = (unsafe { collection.Item(index) }) else { continue };
        let id = device_id(&device);
        let is_default = id == default_id;
        devices.push((id, device_name(&device), is_default));
    }
    Ok(devices)
}

/// The device a selection names, or the default (with a warning) when it cannot be found.
/// Names match case-insensitively, exactly or as a prefix: NVDA versions before 2025.1 store
/// the WinMM name, which is the friendly name cut to 31 characters.
fn resolve_render_device(enumerator: &IMMDeviceEnumerator, selection: &DeviceSelection) -> Result<(IMMDevice, String, Option<(String, String)>), String> {
    let fallback = |reason: String| -> Result<(IMMDevice, String, Option<(String, String)>), String> {
        let device = default_render_device(enumerator)?;
        let name = device_name(&device);
        Ok((
            device,
            format!("{name} (default; {reason})"),
            Some(("device-missing".to_string(), format!("{reason}; using the default output device {name}"))),
        ))
    };
    match selection {
        DeviceSelection::Default => {
            let device = default_render_device(enumerator)?;
            let name = device_name(&device);
            Ok((device, format!("{name} (default)"), None))
        }
        DeviceSelection::Id(id) => {
            let wide: Vec<u16> = id.encode_utf16().chain(std::iter::once(0)).collect();
            match unsafe { enumerator.GetDevice(PCWSTR(wide.as_ptr())) } {
                // GetDevice also returns unplugged and disabled endpoints; only an active one
                // can play.
                Ok(device) if unsafe { device.GetState() }.map_or(false, |state| state == DEVICE_STATE_ACTIVE) => {
                    let name = device_name(&device);
                    Ok((device, name, None))
                }
                Ok(device) => fallback(format!("the configured output device {} is not active", device_name(&device))),
                Err(error) => fallback(format!("the configured output device {id} is unavailable ({error})")),
            }
        }
        DeviceSelection::Name(wanted) => {
            let wanted_lower = wanted.trim().to_lowercase();
            let collection = unsafe { enumerator.EnumAudioEndpoints(eRender, DEVICE_STATE_ACTIVE) }.map_err(|e| format!("EnumAudioEndpoints: {e}"))?;
            let count = unsafe { collection.GetCount() }.map_err(|e| format!("GetCount: {e}"))?;
            let mut prefix_match: Option<(IMMDevice, String)> = None;
            for index in 0..count {
                let Ok(device) = (unsafe { collection.Item(index) }) else { continue };
                let name = device_name(&device);
                let lower = name.to_lowercase();
                if lower == wanted_lower {
                    return Ok((device, name, None));
                }
                if prefix_match.is_none() && !wanted_lower.is_empty() && lower.starts_with(&wanted_lower) {
                    prefix_match = Some((device, name));
                }
            }
            match prefix_match {
                Some((device, name)) => Ok((device, name, None)),
                None => fallback(format!("the configured output device \"{wanted}\" is unavailable")),
            }
        }
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

// ------------------------------------------------------- device change tracking

/// Shared between a capture/playout object, its worker thread and the endpoint watcher:
/// the wanted device, and a flag telling the worker to re-evaluate it (the wanted device
/// changed, or the set of devices / the default device did).
struct DeviceControl {
    selection: Mutex<DeviceSelection>,
    reevaluate: AtomicBool,
}

impl DeviceControl {
    fn new(selection: DeviceSelection) -> Arc<Self> {
        Arc::new(DeviceControl { selection: Mutex::new(selection), reevaluate: AtomicBool::new(false) })
    }

    fn set(&self, selection: DeviceSelection) {
        *self.selection.lock().unwrap() = selection;
        self.reevaluate.store(true, Ordering::Relaxed);
    }

    fn current(&self) -> DeviceSelection {
        self.selection.lock().unwrap().clone()
    }
}

/// Listens for endpoint changes (default device switched, a device plugged or unplugged,
/// enabled or disabled) and asks the worker to re-evaluate its device.
#[implement(IMMNotificationClient)]
struct EndpointWatcher {
    control: Arc<DeviceControl>,
}

impl IMMNotificationClient_Impl for EndpointWatcher_Impl {
    fn OnDeviceStateChanged(&self, _id: &PCWSTR, _state: DEVICE_STATE) -> WinResult<()> {
        self.control.reevaluate.store(true, Ordering::Relaxed);
        Ok(())
    }
    fn OnDeviceAdded(&self, _id: &PCWSTR) -> WinResult<()> {
        self.control.reevaluate.store(true, Ordering::Relaxed);
        Ok(())
    }
    fn OnDeviceRemoved(&self, _id: &PCWSTR) -> WinResult<()> {
        self.control.reevaluate.store(true, Ordering::Relaxed);
        Ok(())
    }
    fn OnDefaultDeviceChanged(&self, flow: EDataFlow, role: ERole, _id: &PCWSTR) -> WinResult<()> {
        if flow == eRender && role == eMultimedia {
            self.control.reevaluate.store(true, Ordering::Relaxed);
        }
        Ok(())
    }
    fn OnPropertyValueChanged(&self, _id: &PCWSTR, _key: &PROPERTYKEY) -> WinResult<()> {
        Ok(())
    }
}

/// Registers the watcher for the lifetime of the guard (the worker thread's).
struct WatcherGuard {
    enumerator: IMMDeviceEnumerator,
    client: IMMNotificationClient,
}

impl WatcherGuard {
    fn new(enumerator: &IMMDeviceEnumerator, control: Arc<DeviceControl>) -> Option<Self> {
        let client: IMMNotificationClient = EndpointWatcher { control }.into();
        unsafe { enumerator.RegisterEndpointNotificationCallback(&client) }.ok()?;
        Some(WatcherGuard { enumerator: enumerator.clone(), client })
    }
}

impl Drop for WatcherGuard {
    fn drop(&mut self) {
        unsafe {
            let _ = self.enumerator.UnregisterEndpointNotificationCallback(&self.client);
        }
    }
}

/// Between reopen attempts after a device vanished; and how long to keep trying before
/// giving up on the pipeline.
const REOPEN_DELAY: Duration = Duration::from_millis(400);
const REOPEN_ATTEMPTS: u32 = 25; // ~10 s

/// Reports a device warning only when it differs from the previous one, so a missing
/// device does not repeat itself every time the worker re-evaluates.
fn report_device_warning(notices: &mut NoticeSink, last: &mut Option<String>, warning: Option<(String, String)>) {
    match warning {
        Some((code, message)) => {
            if last.as_deref() != Some(message.as_str()) {
                notices(Notice::Warning(code, message.clone()));
                *last = Some(message);
            }
        }
        None => *last = None,
    }
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
    /// The endpoint a whole-device capture is on; empty for process loopback.
    device_id: String,
}

impl Drop for CaptureStream {
    fn drop(&mut self) {
        unsafe {
            let _ = self.client.Stop();
        }
    }
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
    Ok(CaptureStream { client, capture, event: Some(event), channels: 2, converter: None, device_id: String::new() })
}

fn open_loopback_on(device: &IMMDevice) -> Result<CaptureStream, String> {
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
    let (client, channels, converter) = match converted {
        Ok(()) => (client, 2, None),
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
            (client_again, channels, Some(Converter::new(channels, rate)))
        }
    };
    let capture: IAudioCaptureClient = unsafe { client.GetService() }.map_err(|e| format!("GetService(capture): {e}"))?;
    unsafe { client.Start() }.map_err(|e| format!("IAudioClient::Start: {e}"))?;
    Ok(CaptureStream { client, capture, event: None, channels, converter, device_id: device_id(device) })
}

/// Opens the capture for `exclude_pid` / `selection`: process loopback when a process is to
/// be excluded and the API is available, otherwise the selected (or default) output device.
fn open_capture(enumerator: &IMMDeviceEnumerator, exclude_pid: u32, selection: &DeviceSelection) -> Result<(CaptureStream, CaptureInfo), String> {
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
    let (device, name, device_warning) = resolve_render_device(enumerator, selection)?;
    let stream = open_loopback_on(&device)?;
    Ok((stream, CaptureInfo { excluding_pid: None, warning: warning.or(device_warning), description: format!("output device {name}") }))
}

/// Why the capture loop returned.
enum LoopExit {
    Stopped,
    /// The selected device changed (or the device set did) and a different device applies now.
    Switch,
    /// The stream broke (device unplugged, disabled, ...); reopen.
    Failed(String),
}

fn run_capture(stream: &mut CaptureStream, stop: &AtomicBool, control: &DeviceControl, enumerator: &IMMDeviceEnumerator, sink: &mut dyn FnMut(&[f32])) -> LoopExit {
    let _boost = MmcssGuard::new();
    let mut scratch: Vec<f32> = Vec::with_capacity(4096);
    let mut converted: Vec<f32> = Vec::with_capacity(4096);
    let silent = AUDCLNT_BUFFERFLAGS_SILENT.0 as u32;
    loop {
        if stop.load(Ordering::Relaxed) {
            return LoopExit::Stopped;
        }
        if control.reevaluate.swap(false, Ordering::Relaxed) && stream.event.is_none() {
            // Whole-device capture: follow the selection if it now resolves elsewhere.
            if let Ok((device, _, _)) = resolve_render_device(enumerator, &control.current()) {
                if device_id(&device) != stream.device_id {
                    return LoopExit::Switch;
                }
            }
        }
        match &stream.event {
            Some(event) => {
                event.wait(200);
            }
            None => thread::sleep(Duration::from_millis(5)),
        }
        if stop.load(Ordering::Relaxed) {
            return LoopExit::Stopped;
        }
        loop {
            let mut data: *mut u8 = null_mut();
            let mut frames = 0u32;
            let mut flags = 0u32;
            if let Err(e) = unsafe { stream.capture.GetBuffer(&mut data, &mut frames, &mut flags, None, None) } {
                return LoopExit::Failed(format!("IAudioCaptureClient::GetBuffer: {e}"));
            }
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
            if let Err(e) = unsafe { stream.capture.ReleaseBuffer(frames) } {
                return LoopExit::Failed(format!("ReleaseBuffer: {e}"));
            }
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
}

pub struct WasapiCapture {
    exclude_pid: u32,
    control: Arc<DeviceControl>,
    stop: Arc<AtomicBool>,
    thread: Option<JoinHandle<()>>,
}

impl WasapiCapture {
    pub fn new(exclude_pid: u32, device: DeviceSelection) -> Self {
        WasapiCapture { exclude_pid, control: DeviceControl::new(device), stop: Arc::new(AtomicBool::new(false)), thread: None }
    }
}

/// The whole life of the capture on one MTA thread: open, run, and on a switch or a broken
/// stream open again (falling back to the default device while the wanted one is away),
/// giving up only after repeated failures.
fn capture_thread(
    exclude_pid: u32,
    control: Arc<DeviceControl>,
    stop: Arc<AtomicBool>,
    ready: mpsc::Sender<Result<CaptureInfo, String>>,
    sink: &mut dyn FnMut(&[f32]),
    notices: &mut NoticeSink,
) {
    let _com = ComGuard::new();
    let enumerator = match enumerator() {
        Ok(e) => e,
        Err(error) => {
            let _ = ready.send(Err(error));
            return;
        }
    };
    let _watcher = WatcherGuard::new(&enumerator, control.clone());
    let mut ready = Some(ready);
    let mut last_warning: Option<String> = None;
    let mut failures = 0u32;
    while !stop.load(Ordering::Relaxed) {
        let (mut stream, info) = match open_capture(&enumerator, exclude_pid, &control.current()) {
            Ok(opened) => opened,
            Err(error) => {
                if let Some(tx) = ready.take() {
                    let _ = tx.send(Err(error));
                    return;
                }
                failures += 1;
                if failures >= REOPEN_ATTEMPTS {
                    notices(Notice::Fatal(format!("capture could not be reopened: {error}")));
                    return;
                }
                thread::sleep(REOPEN_DELAY);
                continue;
            }
        };
        failures = 0;
        match ready.take() {
            Some(tx) => {
                let _ = tx.send(Ok(info));
            }
            None => {
                report_device_warning(notices, &mut last_warning, info.warning.clone());
                notices(Notice::Diag(format!("capture reopened: {}", info.description)));
            }
        }
        match run_capture(&mut stream, &stop, &control, &enumerator, sink) {
            LoopExit::Stopped => return,
            LoopExit::Switch => notices(Notice::Diag("capture device changed; switching".into())),
            LoopExit::Failed(error) => {
                if stop.load(Ordering::Relaxed) {
                    return;
                }
                notices(Notice::Diag(format!("capture stream lost ({error}); reopening")));
                thread::sleep(REOPEN_DELAY);
            }
        }
        drop(stream);
    }
}

impl CaptureSource for WasapiCapture {
    fn start(&mut self, mut sink: Box<dyn FnMut(&[f32]) + Send>, mut notices: NoticeSink) -> Result<CaptureInfo, String> {
        let stop = self.stop.clone();
        let control = self.control.clone();
        let exclude_pid = self.exclude_pid;
        let (ready_tx, ready_rx) = mpsc::channel::<Result<CaptureInfo, String>>();
        let thread = thread::Builder::new()
            .name("remremote-audio-capture".into())
            .spawn(move || {
                let outcome = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                    capture_thread(exclude_pid, control, stop, ready_tx, &mut *sink, &mut notices)
                }));
                if outcome.is_err() {
                    notices(Notice::Fatal("capture thread panicked".to_string()));
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

    fn set_device(&mut self, device: DeviceSelection) {
        self.control.set(device);
    }

    fn stop(&mut self) {
        self.stop.store(true, Ordering::Relaxed);
        if let Some(thread) = self.thread.take() {
            let _ = thread.join();
        }
    }
}

// ------------------------------------------------------------------- playout

struct RenderStream {
    client: IAudioClient,
    render: IAudioRenderClient,
    event: Event,
    buffer_frames: u32,
    device_id: String,
    name: String,
}

impl Drop for RenderStream {
    fn drop(&mut self) {
        unsafe {
            let _ = self.client.Stop();
        }
    }
}

fn open_render(device: &IMMDevice, name: &str) -> Result<RenderStream, String> {
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
        format!("IAudioClient::Initialize (render 48 kHz float stereo on {name}; device mix format: {mix}): {e}")
    })?;
    let buffer_frames = unsafe { client.GetBufferSize() }.map_err(|e| format!("GetBufferSize: {e}"))?;
    let event = Event::new()?;
    unsafe { client.SetEventHandle(event.0) }.map_err(|e| format!("SetEventHandle: {e}"))?;
    let render: IAudioRenderClient = unsafe { client.GetService() }.map_err(|e| format!("GetService(render): {e}"))?;
    // Prime the whole buffer with silence, then let the event drive us.
    unsafe {
        let _ = render.GetBuffer(buffer_frames).map_err(|e| format!("GetBuffer: {e}"))?;
        render.ReleaseBuffer(buffer_frames, AUDCLNT_BUFFERFLAGS_SILENT.0 as u32).map_err(|e| format!("ReleaseBuffer: {e}"))?;
        client.Start().map_err(|e| format!("IAudioClient::Start: {e}"))?;
    }
    Ok(RenderStream { client, render, event, buffer_frames, device_id: device_id(device), name: name.to_string() })
}

fn run_render(stream: &RenderStream, buffer: &Mutex<PlayoutBuffer>, stop: &AtomicBool, control: &DeviceControl, enumerator: &IMMDeviceEnumerator) -> LoopExit {
    let _boost = MmcssGuard::new();
    loop {
        if stop.load(Ordering::Relaxed) {
            return LoopExit::Stopped;
        }
        if control.reevaluate.swap(false, Ordering::Relaxed) {
            if let Ok((device, _, _)) = resolve_render_device(enumerator, &control.current()) {
                if device_id(&device) != stream.device_id {
                    return LoopExit::Switch;
                }
            }
        }
        if !stream.event.wait(200) {
            continue;
        }
        if stop.load(Ordering::Relaxed) {
            return LoopExit::Stopped;
        }
        let padding = match unsafe { stream.client.GetCurrentPadding() } {
            Ok(padding) => padding,
            Err(e) => return LoopExit::Failed(format!("GetCurrentPadding: {e}")),
        };
        let frames = stream.buffer_frames.saturating_sub(padding);
        if frames == 0 {
            continue;
        }
        let data = match unsafe { stream.render.GetBuffer(frames) } {
            Ok(data) => data,
            Err(e) => return LoopExit::Failed(format!("IAudioRenderClient::GetBuffer: {e}")),
        };
        if data.is_null() {
            continue;
        }
        let out = unsafe { slice::from_raw_parts_mut(data as *mut f32, frames as usize * 2) };
        buffer.lock().unwrap().read(out);
        if let Err(e) = unsafe { stream.render.ReleaseBuffer(frames, 0) } {
            return LoopExit::Failed(format!("ReleaseBuffer: {e}"));
        }
    }
}

pub struct WasapiPlayout {
    control: Arc<DeviceControl>,
    stop: Arc<AtomicBool>,
    thread: Option<JoinHandle<()>>,
}

impl WasapiPlayout {
    pub fn new(device: DeviceSelection) -> Self {
        WasapiPlayout { control: DeviceControl::new(device), stop: Arc::new(AtomicBool::new(false)), thread: None }
    }
}

/// The whole life of the playout on one MTA thread; same shape as `capture_thread`.
fn playout_thread(
    buffer: Arc<Mutex<PlayoutBuffer>>,
    control: Arc<DeviceControl>,
    stop: Arc<AtomicBool>,
    ready: mpsc::Sender<Result<PlayoutInfo, String>>,
    notices: &mut NoticeSink,
) {
    let _com = ComGuard::new();
    let enumerator = match enumerator() {
        Ok(e) => e,
        Err(error) => {
            let _ = ready.send(Err(error));
            return;
        }
    };
    let _watcher = WatcherGuard::new(&enumerator, control.clone());
    let mut ready = Some(ready);
    let mut last_warning: Option<String> = None;
    let mut failures = 0u32;
    while !stop.load(Ordering::Relaxed) {
        let opened = resolve_render_device(&enumerator, &control.current()).and_then(|(device, name, warning)| {
            open_render(&device, &name).map(|stream| (stream, warning))
        });
        let (stream, warning) = match opened {
            Ok(opened) => opened,
            Err(error) => {
                if let Some(tx) = ready.take() {
                    let _ = tx.send(Err(error));
                    return;
                }
                failures += 1;
                if failures >= REOPEN_ATTEMPTS {
                    notices(Notice::Fatal(format!("playout could not be reopened: {error}")));
                    return;
                }
                thread::sleep(REOPEN_DELAY);
                continue;
            }
        };
        failures = 0;
        match ready.take() {
            Some(tx) => {
                let _ = tx.send(Ok(PlayoutInfo { warning, description: format!("output device {}", stream.name) }));
            }
            None => {
                report_device_warning(notices, &mut last_warning, warning);
                notices(Notice::Diag(format!("playout now on output device {}", stream.name)));
                // Start afresh on the new device rather than replaying what piled up meanwhile.
                buffer.lock().unwrap().clear();
            }
        }
        match run_render(&stream, &buffer, &stop, &control, &enumerator) {
            LoopExit::Stopped => return,
            LoopExit::Switch => notices(Notice::Diag("output device changed; switching".into())),
            LoopExit::Failed(error) => {
                if stop.load(Ordering::Relaxed) {
                    return;
                }
                notices(Notice::Diag(format!("playout stream lost ({error}); reopening")));
                thread::sleep(REOPEN_DELAY);
            }
        }
        drop(stream);
    }
}

impl PlayoutSink for WasapiPlayout {
    fn start(&mut self, buffer: Arc<Mutex<PlayoutBuffer>>, mut notices: NoticeSink) -> Result<PlayoutInfo, String> {
        let stop = self.stop.clone();
        let control = self.control.clone();
        let (ready_tx, ready_rx) = mpsc::channel::<Result<PlayoutInfo, String>>();
        let thread = thread::Builder::new()
            .name("remremote-audio-playout".into())
            .spawn(move || {
                let outcome = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                    playout_thread(buffer, control, stop, ready_tx, &mut notices)
                }));
                if outcome.is_err() {
                    notices(Notice::Fatal("playout thread panicked".to_string()));
                }
            })
            .map_err(|e| format!("could not start the playout thread: {e}"))?;
        self.thread = Some(thread);
        match ready_rx.recv_timeout(Duration::from_secs(10)) {
            Ok(Ok(info)) => Ok(info),
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

    fn set_device(&mut self, device: DeviceSelection) {
        self.control.set(device);
    }

    fn stop(&mut self) {
        self.stop.store(true, Ordering::Relaxed);
        if let Some(thread) = self.thread.take() {
            let _ = thread.join();
        }
    }
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
