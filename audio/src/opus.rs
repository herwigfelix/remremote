//! Thin safe wrappers over libopus (statically linked through `audiopus_sys`), configured the
//! way RemSound configures it: 48 kHz stereo, RESTRICTED_LOWDELAY, complexity 10, VBR, inband
//! FEC with a 10 % expected loss, so a receiver can rebuild a single lost packet from the next.

use std::os::raw::c_int;

use audiopus_sys as ffi;

pub const SAMPLE_RATE: i32 = 48_000;
pub const CHANNELS: i32 = 2;
/// 10 ms at 48 kHz: the frame size remremote streams.
pub const FRAME_SAMPLES: i32 = 480;
pub const BITRATE: i32 = 192_000;
const MAX_PACKET_BYTES: usize = 4000;

pub struct Encoder {
    ptr: *mut ffi::OpusEncoder,
    frame_samples: i32,
}

// libopus state is only ever touched from the thread that owns the wrapper.
unsafe impl Send for Encoder {}

impl Encoder {
    pub fn new(frame_samples: i32, bitrate: i32) -> Result<Self, String> {
        let frame_samples = frame_samples.clamp(120, 2880);
        let mut error: c_int = 0;
        let ptr = unsafe {
            ffi::opus_encoder_create(SAMPLE_RATE, CHANNELS, ffi::OPUS_APPLICATION_RESTRICTED_LOWDELAY, &mut error)
        };
        if ptr.is_null() || error != ffi::OPUS_OK {
            return Err(format!("opus_encoder_create failed ({error})"));
        }
        let encoder = Encoder { ptr, frame_samples };
        unsafe {
            ffi::opus_encoder_ctl(ptr, ffi::OPUS_SET_BITRATE_REQUEST, bitrate as c_int);
            ffi::opus_encoder_ctl(ptr, ffi::OPUS_SET_COMPLEXITY_REQUEST, 10 as c_int);
            ffi::opus_encoder_ctl(ptr, ffi::OPUS_SET_VBR_REQUEST, 1 as c_int);
            ffi::opus_encoder_ctl(ptr, ffi::OPUS_SET_INBAND_FEC_REQUEST, 1 as c_int);
            ffi::opus_encoder_ctl(ptr, ffi::OPUS_SET_PACKET_LOSS_PERC_REQUEST, 10 as c_int);
        }
        Ok(encoder)
    }

    pub fn frame_samples(&self) -> i32 {
        self.frame_samples
    }

    /// Encodes exactly one frame of interleaved stereo float samples, appending the packet
    /// to `out`. Returns the packet length.
    pub fn encode(&mut self, pcm: &[f32], out: &mut Vec<u8>) -> Result<usize, String> {
        let expected = (self.frame_samples * CHANNELS) as usize;
        if pcm.len() != expected {
            return Err(format!("expected {expected} samples, got {}", pcm.len()));
        }
        let start = out.len();
        out.resize(start + MAX_PACKET_BYTES, 0);
        let written = unsafe {
            ffi::opus_encode_float(
                self.ptr,
                pcm.as_ptr(),
                self.frame_samples,
                out[start..].as_mut_ptr(),
                MAX_PACKET_BYTES as i32,
            )
        };
        if written <= 0 {
            out.truncate(start);
            return Err(format!("opus_encode_float failed ({written})"));
        }
        out.truncate(start + written as usize);
        Ok(written as usize)
    }
}

impl Drop for Encoder {
    fn drop(&mut self) {
        unsafe { ffi::opus_encoder_destroy(self.ptr) }
    }
}

pub struct Decoder {
    ptr: *mut ffi::OpusDecoder,
    channels: i32,
}

unsafe impl Send for Decoder {}

impl Decoder {
    pub fn new(sample_rate: i32, channels: i32) -> Result<Self, String> {
        let mut error: c_int = 0;
        let ptr = unsafe { ffi::opus_decoder_create(sample_rate, channels, &mut error) };
        if ptr.is_null() || error != ffi::OPUS_OK {
            return Err(format!("opus_decoder_create failed ({error})"));
        }
        Ok(Decoder { ptr, channels })
    }

    /// Decodes one packet (or, with `fec`, the redundant copy of the PREVIOUS frame it
    /// carries) into `out` as interleaved floats. Returns samples per channel decoded.
    pub fn decode(&mut self, packet: &[u8], frame_samples: i32, fec: bool, out: &mut Vec<f32>) -> Result<usize, String> {
        let frame_samples = frame_samples.max(120);
        out.clear();
        out.resize((frame_samples * self.channels) as usize, 0.0);
        let decoded = unsafe {
            ffi::opus_decode_float(
                self.ptr,
                packet.as_ptr(),
                packet.len() as i32,
                out.as_mut_ptr(),
                frame_samples,
                if fec { 1 } else { 0 },
            )
        };
        if decoded <= 0 {
            out.clear();
            return Err(format!("opus_decode_float failed ({decoded})"));
        }
        out.truncate((decoded * self.channels) as usize);
        Ok(decoded as usize)
    }
}

impl Drop for Decoder {
    fn drop(&mut self) {
        unsafe { ffi::opus_decoder_destroy(self.ptr) }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn encode_decode_round_trip_keeps_the_signal() {
        let mut encoder = Encoder::new(FRAME_SAMPLES, BITRATE).unwrap();
        let mut decoder = Decoder::new(SAMPLE_RATE, CHANNELS).unwrap();
        let mut packet = Vec::new();
        let mut pcm = Vec::new();
        let mut phase = 0.0f32;
        let mut energy_in = 0.0f32;
        let mut energy_out = 0.0f32;
        for _ in 0..20 {
            let mut frame = Vec::with_capacity((FRAME_SAMPLES * CHANNELS) as usize);
            for _ in 0..FRAME_SAMPLES {
                let s = (phase * std::f32::consts::TAU).sin() * 0.5;
                phase = (phase + 440.0 / 48_000.0).fract();
                frame.push(s);
                frame.push(s);
            }
            packet.clear();
            let len = encoder.encode(&frame, &mut packet).unwrap();
            assert!(len > 0 && len < 1000);
            let decoded = decoder.decode(&packet, FRAME_SAMPLES, false, &mut pcm).unwrap();
            assert_eq!(decoded, FRAME_SAMPLES as usize);
            energy_in += frame.iter().map(|s| s * s).sum::<f32>();
            energy_out += pcm.iter().map(|s| s * s).sum::<f32>();
        }
        // After the codec's warm-up the decoded energy is in the same ballpark.
        assert!(energy_out > energy_in * 0.5, "in {energy_in} out {energy_out}");
        // FEC decode of a packet yields a frame too (the previous frame's low-bitrate copy).
        let decoded = decoder.decode(&packet, FRAME_SAMPLES, true, &mut pcm).unwrap();
        assert_eq!(decoded, FRAME_SAMPLES as usize);
        assert!(encoder.encode(&[0.0; 10], &mut packet).is_err());
    }
}
