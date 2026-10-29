//! macOS playout: the system's default output unit (AudioToolbox), fed 48 kHz stereo
//! interleaved float straight from the playout buffer by the unit's own render thread.
//!
//! The default output unit follows the system's default output device by itself and
//! converts the sample rate to whatever that device runs at, so there is no device
//! handling here. Capture (the controlled side) is not implemented on macOS.
//!
//! Raw FFI only — the handful of AudioToolbox calls needed do not justify a crate.

use std::ffi::c_void;
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::ptr;
use std::sync::{Arc, Mutex};

use super::{DeviceSelection, NoticeSink, PlayoutInfo, PlayoutSink};
use crate::jitter::PlayoutBuffer;

type OSStatus = i32;
type AudioUnit = *mut c_void;
type AudioComponent = *mut c_void;

#[repr(C)]
struct AudioComponentDescription {
    component_type: u32,
    component_sub_type: u32,
    component_manufacturer: u32,
    component_flags: u32,
    component_flags_mask: u32,
}

#[repr(C)]
struct AudioStreamBasicDescription {
    sample_rate: f64,
    format_id: u32,
    format_flags: u32,
    bytes_per_packet: u32,
    frames_per_packet: u32,
    bytes_per_frame: u32,
    channels_per_frame: u32,
    bits_per_channel: u32,
    reserved: u32,
}

#[repr(C)]
struct AudioBuffer {
    number_channels: u32,
    data_byte_size: u32,
    data: *mut c_void,
}

#[repr(C)]
struct AudioBufferList {
    number_buffers: u32,
    buffers: [AudioBuffer; 1],
}

type RenderCallback = unsafe extern "C" fn(
    ref_con: *mut c_void,
    action_flags: *mut u32,
    time_stamp: *const c_void,
    bus_number: u32,
    number_frames: u32,
    data: *mut AudioBufferList,
) -> OSStatus;

#[repr(C)]
struct AURenderCallbackStruct {
    input_proc: Option<RenderCallback>,
    input_proc_ref_con: *mut c_void,
}

#[link(name = "AudioToolbox", kind = "framework")]
extern "C" {
    fn AudioComponentFindNext(component: AudioComponent, description: *const AudioComponentDescription) -> AudioComponent;
    fn AudioComponentInstanceNew(component: AudioComponent, instance: *mut AudioUnit) -> OSStatus;
    fn AudioComponentInstanceDispose(instance: AudioUnit) -> OSStatus;
    fn AudioUnitSetProperty(unit: AudioUnit, id: u32, scope: u32, element: u32, data: *const c_void, size: u32) -> OSStatus;
    fn AudioUnitInitialize(unit: AudioUnit) -> OSStatus;
    fn AudioUnitUninitialize(unit: AudioUnit) -> OSStatus;
    fn AudioOutputUnitStart(unit: AudioUnit) -> OSStatus;
    fn AudioOutputUnitStop(unit: AudioUnit) -> OSStatus;
}

const fn four_cc(code: &[u8; 4]) -> u32 {
    ((code[0] as u32) << 24) | ((code[1] as u32) << 16) | ((code[2] as u32) << 8) | code[3] as u32
}

const K_AUDIO_UNIT_TYPE_OUTPUT: u32 = four_cc(b"auou");
const K_AUDIO_UNIT_SUB_TYPE_DEFAULT_OUTPUT: u32 = four_cc(b"def ");
const K_AUDIO_UNIT_MANUFACTURER_APPLE: u32 = four_cc(b"appl");
const K_AUDIO_FORMAT_LINEAR_PCM: u32 = four_cc(b"lpcm");
const K_AUDIO_FORMAT_FLAG_IS_FLOAT: u32 = 1 << 0;
const K_AUDIO_FORMAT_FLAG_IS_PACKED: u32 = 1 << 3;
const K_AUDIO_UNIT_PROPERTY_STREAM_FORMAT: u32 = 8;
const K_AUDIO_UNIT_PROPERTY_SET_RENDER_CALLBACK: u32 = 23;
const K_AUDIO_UNIT_SCOPE_INPUT: u32 = 1;

const SAMPLE_RATE: f64 = 48_000.0;
const CHANNELS: u32 = 2;

/// What the render callback reads from; boxed so its address stays put while the unit runs.
struct RenderContext {
    buffer: Arc<Mutex<PlayoutBuffer>>,
}

unsafe extern "C" fn render(
    ref_con: *mut c_void,
    _action_flags: *mut u32,
    _time_stamp: *const c_void,
    _bus_number: u32,
    number_frames: u32,
    data: *mut AudioBufferList,
) -> OSStatus {
    // A panic must never unwind into CoreAudio's render thread.
    let _ = catch_unwind(AssertUnwindSafe(|| {
        if ref_con.is_null() || data.is_null() {
            return;
        }
        let context = &*(ref_con as *const RenderContext);
        let list = &mut *data;
        let count = list.number_buffers as usize;
        if count == 0 {
            return;
        }
        let buffers = std::slice::from_raw_parts_mut(list.buffers.as_mut_ptr(), count);
        for (index, buffer) in buffers.iter_mut().enumerate() {
            if buffer.data.is_null() {
                continue;
            }
            let samples = buffer.data_byte_size as usize / std::mem::size_of::<f32>();
            let out = std::slice::from_raw_parts_mut(buffer.data as *mut f32, samples);
            if index == 0 {
                // One interleaved stereo buffer, as the stream format asks for.
                let wanted = (number_frames as usize * CHANNELS as usize).min(samples);
                let mut playout = match context.buffer.lock() {
                    Ok(guard) => guard,
                    Err(poisoned) => poisoned.into_inner(),
                };
                playout.read(&mut out[..wanted]);
                drop(playout);
                out[wanted..].fill(0.0);
            } else {
                out.fill(0.0);
            }
        }
    }));
    0
}

pub struct CoreAudioPlayout {
    unit: AudioUnit,
    context: Option<Box<RenderContext>>,
}

// The unit handle is only touched from start/stop, which the engine calls from one thread
// at a time; CoreAudio itself is thread-safe for these calls.
unsafe impl Send for CoreAudioPlayout {}

impl CoreAudioPlayout {
    pub fn new(_device: DeviceSelection) -> Self {
        CoreAudioPlayout { unit: ptr::null_mut(), context: None }
    }

    fn check(status: OSStatus, what: &str) -> Result<(), String> {
        if status == 0 {
            Ok(())
        } else {
            Err(format!("{what} failed (OSStatus {status})"))
        }
    }

    fn open(&mut self, buffer: Arc<Mutex<PlayoutBuffer>>) -> Result<(), String> {
        let description = AudioComponentDescription {
            component_type: K_AUDIO_UNIT_TYPE_OUTPUT,
            component_sub_type: K_AUDIO_UNIT_SUB_TYPE_DEFAULT_OUTPUT,
            component_manufacturer: K_AUDIO_UNIT_MANUFACTURER_APPLE,
            component_flags: 0,
            component_flags_mask: 0,
        };
        unsafe {
            let component = AudioComponentFindNext(ptr::null_mut(), &description);
            if component.is_null() {
                return Err("the default output audio unit is not available".into());
            }
            let mut unit: AudioUnit = ptr::null_mut();
            Self::check(AudioComponentInstanceNew(component, &mut unit), "AudioComponentInstanceNew")?;
            if unit.is_null() {
                return Err("AudioComponentInstanceNew returned no unit".into());
            }
            self.unit = unit;

            let bytes_per_frame = CHANNELS * std::mem::size_of::<f32>() as u32;
            let format = AudioStreamBasicDescription {
                sample_rate: SAMPLE_RATE,
                format_id: K_AUDIO_FORMAT_LINEAR_PCM,
                format_flags: K_AUDIO_FORMAT_FLAG_IS_FLOAT | K_AUDIO_FORMAT_FLAG_IS_PACKED,
                bytes_per_packet: bytes_per_frame,
                frames_per_packet: 1,
                bytes_per_frame,
                channels_per_frame: CHANNELS,
                bits_per_channel: 32,
                reserved: 0,
            };
            Self::check(
                AudioUnitSetProperty(
                    unit,
                    K_AUDIO_UNIT_PROPERTY_STREAM_FORMAT,
                    K_AUDIO_UNIT_SCOPE_INPUT,
                    0,
                    &format as *const _ as *const c_void,
                    std::mem::size_of::<AudioStreamBasicDescription>() as u32,
                ),
                "setting the output stream format",
            )?;

            let context = Box::new(RenderContext { buffer });
            let callback = AURenderCallbackStruct {
                input_proc: Some(render),
                input_proc_ref_con: &*context as *const RenderContext as *mut c_void,
            };
            // Keep the context alive before the unit can call into it.
            self.context = Some(context);
            Self::check(
                AudioUnitSetProperty(
                    unit,
                    K_AUDIO_UNIT_PROPERTY_SET_RENDER_CALLBACK,
                    K_AUDIO_UNIT_SCOPE_INPUT,
                    0,
                    &callback as *const _ as *const c_void,
                    std::mem::size_of::<AURenderCallbackStruct>() as u32,
                ),
                "installing the render callback",
            )?;
            Self::check(AudioUnitInitialize(unit), "AudioUnitInitialize")?;
            Self::check(AudioOutputUnitStart(unit), "AudioOutputUnitStart")?;
        }
        Ok(())
    }

    fn close(&mut self) {
        if !self.unit.is_null() {
            unsafe {
                // Stop is synchronous: no render callback runs once it returns, so the
                // context can be freed afterwards.
                AudioOutputUnitStop(self.unit);
                AudioUnitUninitialize(self.unit);
                AudioComponentInstanceDispose(self.unit);
            }
            self.unit = ptr::null_mut();
        }
        self.context = None;
    }
}

impl PlayoutSink for CoreAudioPlayout {
    fn start(&mut self, buffer: Arc<Mutex<PlayoutBuffer>>, _notices: NoticeSink) -> Result<PlayoutInfo, String> {
        self.close();
        if let Err(error) = self.open(buffer) {
            self.close();
            return Err(error);
        }
        Ok(PlayoutInfo { warning: None, description: "the default output device (CoreAudio)".into() })
    }

    /// The default output unit always follows the system's default device.
    fn set_device(&mut self, _device: DeviceSelection) {}

    fn stop(&mut self) {
        self.close();
    }
}

impl Drop for CoreAudioPlayout {
    fn drop(&mut self) {
        self.close();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn struct_layouts_match_the_c_abi() {
        assert_eq!(std::mem::size_of::<AudioStreamBasicDescription>(), 40);
        assert_eq!(std::mem::size_of::<AudioBuffer>(), 16);
        assert_eq!(std::mem::size_of::<AudioBufferList>(), 24);
        assert_eq!(std::mem::size_of::<AURenderCallbackStruct>(), 16);
        assert_eq!(std::mem::size_of::<AudioComponentDescription>(), 20);
    }

    #[test]
    fn render_fills_from_the_buffer_and_pads_with_silence() {
        let buffer = Arc::new(Mutex::new(PlayoutBuffer::new(48_000, 2, 10)));
        buffer.lock().unwrap().write(&[0.5; 960]); // 10 ms: armed
        let context = RenderContext { buffer: buffer.clone() };
        let mut samples = vec![1.0f32; 1024];
        let mut list = AudioBufferList {
            number_buffers: 1,
            buffers: [AudioBuffer { number_channels: 2, data_byte_size: 1024 * 4, data: samples.as_mut_ptr() as *mut c_void }],
        };
        let status = unsafe { render(&context as *const _ as *mut c_void, ptr::null_mut(), ptr::null(), 0, 512, &mut list) };
        assert_eq!(status, 0);
        assert!(samples[..960].iter().all(|s| *s == 0.5));
        assert!(samples[960..].iter().all(|s| *s == 0.0));
    }
}
