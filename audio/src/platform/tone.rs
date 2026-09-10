//! A test signal: a steady sine tone delivered at the real-time rate, in 10 ms chunks.

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};

use super::{CaptureInfo, CaptureSource};

pub struct ToneSource {
    frequency: f32,
    stop: Arc<AtomicBool>,
    thread: Option<JoinHandle<()>>,
}

impl ToneSource {
    pub fn new(frequency: f32) -> Self {
        ToneSource { frequency, stop: Arc::new(AtomicBool::new(false)), thread: None }
    }
}

impl CaptureSource for ToneSource {
    fn start(&mut self, mut sink: Box<dyn FnMut(&[f32]) + Send>, _on_fatal: Box<dyn FnMut(String) + Send>) -> Result<CaptureInfo, String> {
        let stop = self.stop.clone();
        let frequency = self.frequency;
        self.thread = Some(
            thread::Builder::new()
                .name("remremote-audio-tone".into())
                .spawn(move || {
                    let chunk = Duration::from_millis(10);
                    let mut next = Instant::now();
                    let mut phase = 0.0f32;
                    let mut frame = vec![0.0f32; 960];
                    while !stop.load(Ordering::Relaxed) {
                        for i in 0..480 {
                            let sample = (phase * std::f32::consts::TAU).sin() * 0.3;
                            phase = (phase + frequency / 48_000.0).fract();
                            frame[i * 2] = sample;
                            frame[i * 2 + 1] = sample;
                        }
                        sink(&frame);
                        next += chunk;
                        let now = Instant::now();
                        if next > now {
                            thread::sleep(next - now);
                        } else {
                            next = now;
                        }
                    }
                })
                .map_err(|e| e.to_string())?,
        );
        Ok(CaptureInfo { excluding_pid: None, warning: None, description: format!("{frequency} Hz test tone") })
    }

    fn stop(&mut self) {
        self.stop.store(true, Ordering::Relaxed);
        if let Some(thread) = self.thread.take() {
            let _ = thread.join();
        }
    }
}
