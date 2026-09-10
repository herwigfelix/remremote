//! The receiver's playout buffer: decoded interleaved float samples queue here and the render
//! thread drains them. Playback arms once a target latency's worth of audio is buffered,
//! outputs silence on underrun and re-arms afterwards, so network hiccups produce silence
//! rather than drift. A hard cap discards the oldest audio when the sender runs ahead (bursts,
//! or slow clock drift over a long session).

use std::collections::VecDeque;

pub struct PlayoutBuffer {
    samples: VecDeque<f32>,
    channels: usize,
    sample_rate: usize,
    target_ms: u32,
    max_ms: u32,
    armed: bool,
    pub underruns: u64,
    pub dropped_samples: u64,
    pub trimmed_samples: u64,
    pub written_samples: u64,
    pub read_samples: u64,
}

impl PlayoutBuffer {
    pub fn new(sample_rate: usize, channels: usize, target_ms: u32) -> Self {
        let mut buffer = PlayoutBuffer {
            samples: VecDeque::new(),
            channels: channels.max(1),
            sample_rate: sample_rate.max(1),
            target_ms: 0,
            max_ms: 0,
            armed: false,
            underruns: 0,
            dropped_samples: 0,
            trimmed_samples: 0,
            written_samples: 0,
            read_samples: 0,
        };
        buffer.set_target(target_ms);
        buffer
    }

    /// Changes the depth of the buffer. The cap stays well above the target so a normal burst
    /// never trips it.
    pub fn set_target(&mut self, target_ms: u32) {
        self.target_ms = target_ms.max(10);
        self.max_ms = self.target_ms * 2 + 120;
    }

    pub fn target_ms(&self) -> u32 {
        self.target_ms
    }

    pub fn max_ms(&self) -> u32 {
        self.max_ms
    }

    fn samples_for_ms(&self, ms: u32) -> usize {
        self.sample_rate * ms as usize / 1000 * self.channels
    }

    pub fn buffered_ms(&self) -> u32 {
        (self.samples.len() / self.channels * 1000 / self.sample_rate) as u32
    }

    pub fn armed(&self) -> bool {
        self.armed
    }

    /// Drops everything buffered (a new stream is starting).
    pub fn clear(&mut self) {
        self.samples.clear();
        self.armed = false;
    }

    /// Appends interleaved samples.
    ///
    /// Depth correction: after a network stall the buffer refills from a late burst and would
    /// otherwise stay that deep for the rest of the session (it drains exactly as fast as it
    /// fills). Excess is trimmed by discarding silent frames while the buffer sits well above
    /// its target, which brings the latency back down without an audible cut.
    pub fn write(&mut self, samples: &[f32]) {
        if self.samples.len() > self.samples_for_ms(self.target_ms + self.target_ms / 2 + 30)
            && samples.iter().all(|s| s.abs() < 1e-3)
        {
            self.trimmed_samples += samples.len() as u64;
            return;
        }
        self.samples.extend(samples.iter().copied());
        self.written_samples += samples.len() as u64;
        let max = self.samples_for_ms(self.max_ms);
        if self.samples.len() > max {
            // Ran ahead: cut back to the target rather than to the cap, so the next few bursts
            // have room again instead of tripping this on every packet.
            let keep = self.samples_for_ms(self.target_ms);
            let drop = self.samples.len() - keep;
            self.samples.drain(..drop);
            self.dropped_samples += drop as u64;
        }
        if !self.armed && self.samples.len() >= self.samples_for_ms(self.target_ms) {
            self.armed = true;
        }
    }

    /// Fills `out` with the next samples, zero-filling whatever is not available. Returns the
    /// number of real samples copied.
    pub fn read(&mut self, out: &mut [f32]) -> usize {
        if !self.armed {
            out.fill(0.0);
            return 0;
        }
        let available = self.samples.len().min(out.len());
        for slot in out.iter_mut().take(available) {
            *slot = self.samples.pop_front().unwrap_or(0.0);
        }
        out[available..].fill(0.0);
        self.read_samples += available as u64;
        if available < out.len() {
            // Underrun: refill to the target before resuming.
            self.armed = false;
            self.underruns += 1;
        }
        available
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn arms_at_target_and_rearms_after_underrun() {
        let mut buffer = PlayoutBuffer::new(48_000, 2, 20); // 20 ms = 1920 samples
        let mut out = [1.0f32; 960];
        // Not armed: silence, nothing consumed.
        buffer.write(&[0.5; 960]);
        assert_eq!(buffer.read(&mut out), 0);
        assert!(out.iter().all(|s| *s == 0.0));
        buffer.write(&[0.5; 960]);
        assert!(buffer.armed());
        assert_eq!(buffer.read(&mut out), 960);
        assert!(out.iter().all(|s| *s == 0.5));
        assert_eq!(buffer.read(&mut out), 960);
        // Empty now: the next read underruns, disarms and zero-fills.
        assert_eq!(buffer.read(&mut out), 0);
        assert_eq!(buffer.underruns, 1);
        assert!(!buffer.armed());
        buffer.write(&[0.25; 960]);
        assert_eq!(buffer.read(&mut out), 0);
    }

    #[test]
    fn trims_silence_when_too_deep_but_never_sound() {
        let mut buffer = PlayoutBuffer::new(48_000, 2, 40); // trims above 90 ms
        for _ in 0..12 {
            buffer.write(&[0.2; 960]); // 120 ms of sound: kept
        }
        assert_eq!(buffer.buffered_ms(), 120);
        buffer.write(&[0.0; 960]); // silent frame while too deep: discarded
        assert_eq!(buffer.buffered_ms(), 120);
        assert_eq!(buffer.trimmed_samples, 960);
        buffer.write(&[0.2; 960]); // sound is always kept
        assert_eq!(buffer.buffered_ms(), 130);
        let mut out = [0.0f32; 960 * 5];
        buffer.read(&mut out); // down to 80 ms: below the trim line
        buffer.write(&[0.0; 960]);
        assert_eq!(buffer.buffered_ms(), 90);
    }

    #[test]
    fn caps_runaway_depth_back_to_target() {
        let mut buffer = PlayoutBuffer::new(48_000, 2, 40);
        assert_eq!(buffer.max_ms(), 200);
        for _ in 0..30 {
            buffer.write(&[0.1; 960]); // 10 ms each: 300 ms in total
        }
        assert!(buffer.buffered_ms() <= 200);
        assert!(buffer.dropped_samples > 0);
        assert!(buffer.buffered_ms() >= 40);
    }
}
