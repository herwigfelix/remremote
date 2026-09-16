//! A playout sink with no sound card: drains the buffer at the real-time rate and can dump
//! what it played as raw 48 kHz stereo float32 for offline checks.

use std::fs::File;
use std::io::{BufWriter, Write};
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};

use super::{DeviceSelection, Notice, NoticeSink, PlayoutInfo, PlayoutSink};
use crate::jitter::PlayoutBuffer;

pub struct NullPlayout {
    dump: Option<PathBuf>,
    stop: Arc<AtomicBool>,
    thread: Option<JoinHandle<()>>,
}

impl NullPlayout {
    pub fn new(dump: Option<PathBuf>) -> Self {
        NullPlayout { dump, stop: Arc::new(AtomicBool::new(false)), thread: None }
    }
}

impl PlayoutSink for NullPlayout {
    fn set_device(&mut self, _device: DeviceSelection) {}

    fn start(&mut self, buffer: Arc<Mutex<PlayoutBuffer>>, mut notices: NoticeSink) -> Result<PlayoutInfo, String> {
        let stop = self.stop.clone();
        let description = match &self.dump {
            Some(path) => format!("raw dump to {}", path.display()),
            None => "discarded (no sound card)".to_string(),
        };
        let mut writer = match &self.dump {
            Some(path) => Some(BufWriter::new(File::create(path).map_err(|e| format!("{}: {e}", path.display()))?)),
            None => None,
        };
        self.thread = Some(
            thread::Builder::new()
                .name("remremote-audio-null-playout".into())
                .spawn(move || {
                    let chunk = Duration::from_millis(10);
                    let mut next = Instant::now();
                    let mut frame = vec![0.0f32; 960];
                    while !stop.load(Ordering::Relaxed) {
                        buffer.lock().unwrap().read(&mut frame);
                        if let Some(writer) = writer.as_mut() {
                            let bytes: Vec<u8> = frame.iter().flat_map(|s| s.to_le_bytes()).collect();
                            if let Err(e) = writer.write_all(&bytes) {
                                notices(Notice::Fatal(format!("dump failed: {e}")));
                                return;
                            }
                        }
                        next += chunk;
                        let now = Instant::now();
                        if next > now {
                            thread::sleep(next - now);
                        } else {
                            next = now;
                        }
                    }
                    if let Some(mut writer) = writer.take() {
                        let _ = writer.flush();
                    }
                })
                .map_err(|e| e.to_string())?,
        );
        Ok(PlayoutInfo { warning: None, description })
    }

    fn stop(&mut self) {
        self.stop.store(true, Ordering::Relaxed);
        if let Some(thread) = self.thread.take() {
            let _ = thread.join();
        }
    }
}
