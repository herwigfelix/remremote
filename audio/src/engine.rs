//! The two pipelines. One `Sender` or `Receiver` = one direction of one audio session.
//!
//! Sender: system audio (48 kHz stereo float) -> 10 ms Opus frames -> AES-256-GCM sealed ->
//! UDP, plus a Format announcement every 250 ms. In host mode (`bind_port` > 0) it binds the
//! well-known port and waits for the receiver's sealed hello to learn where to stream; in
//! connector mode it streams straight at `host:port`. Either way it answers hellos with pongs.
//!
//! Receiver: UDP -> open -> Opus decode (with single-packet FEC recovery) -> playout buffer ->
//! system output. In host mode it just listens; in connector mode it sends sealed hellos at
//! `host:port` every two seconds so the sender's replies traverse the receiver's NAT.
//!
//! When `relay_session` is set, both sides are connectors pointed at the relay and register
//! that session id with it every two seconds; the relay forwards everything else verbatim.
//!
//! Events are JSON objects (`{"event": "started", ...}`) delivered on worker threads.

use std::net::{SocketAddr, SocketAddrV4, UdpSocket};
use std::sync::atomic::{AtomicBool, AtomicU32, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};

use serde_json::{json, Value};

use crate::crypto::{self, Cipher};
use crate::hello;
use crate::jitter::PlayoutBuffer;
use crate::net;
use crate::opus;
use crate::packet::{AudioFormat, Header, PacketType, CODEC_OPUS, HEADER_SIZE, HELLO_STREAM_ID};
use crate::platform::{CaptureSource, PlayoutSink};

pub type EventSink = Arc<dyn Fn(Value) + Send + Sync>;

pub const STATUS_INTERVAL: Duration = Duration::from_secs(2);
pub const HELLO_INTERVAL: Duration = Duration::from_secs(2);
pub const FORMAT_INTERVAL: Duration = Duration::from_millis(250);
/// Jitter-buffer depth for direct connections. Relayed sessions pass a deeper one (their
/// packets arrive in periodic bursts).
pub const DEFAULT_TARGET_LATENCY_MS: u32 = 40;
const TICK: Duration = Duration::from_millis(25);

#[derive(Clone, Debug, Default)]
pub struct SendConfig {
    pub password: String,
    /// > 0: host mode, bind this port and wait for the receiver's hello.
    pub bind_port: u16,
    /// Connector mode: stream at this host (a peer, or the relay).
    pub host: Option<String>,
    pub port: u16,
    /// Capture everything except this process tree (0 = whole default output device).
    pub exclude_pid: u32,
    pub relay_session: Option<[u8; 32]>,
}

#[derive(Clone, Debug, Default)]
pub struct RecvConfig {
    pub password: String,
    pub bind_port: u16,
    pub host: Option<String>,
    pub port: u16,
    /// Jitter-buffer depth in ms; 0 = `DEFAULT_TARGET_LATENCY_MS`.
    pub max_latency_ms: u32,
    pub relay_session: Option<[u8; 32]>,
}

fn emit(events: &EventSink, value: Value) {
    events(value);
}

fn random_stream_id() -> u16 {
    loop {
        let id: u16 = rand::random();
        if id != 0 && id != HELLO_STREAM_ID && id != u16::MAX {
            return id;
        }
    }
}

fn recv_packet(socket: &UdpSocket, buf: &mut [u8]) -> Option<(usize, SocketAddrV4)> {
    match socket.recv_from(buf) {
        Ok((n, SocketAddr::V4(from))) => Some((n, from)),
        _ => None,
    }
}

// ===================================================================== sender

struct SendShared {
    socket: UdpSocket,
    /// Where audio, format and pongs go: fixed in connector mode, learned from the first
    /// authentic hello in host mode (and re-learned if the peer's address changes).
    target: Mutex<Option<SocketAddrV4>>,
    hello_cipher: Mutex<Cipher>,
    hello_sequence: AtomicU32,
    peer_confirmed: AtomicBool,
    packets_sent: AtomicU64,
    bytes_sent: AtomicU64,
    capture_error: Mutex<Option<String>>,
    relay: Option<(SocketAddrV4, [u8; 32])>,
    stop: AtomicBool,
    events: EventSink,
}

impl SendShared {
    fn send(&self, packet: &[u8]) {
        let target = *self.target.lock().unwrap();
        if let Some(target) = target {
            if self.socket.send_to(packet, target).is_ok() {
                self.packets_sent.fetch_add(1, Ordering::Relaxed);
                self.bytes_sent.fetch_add(packet.len() as u64, Ordering::Relaxed);
            }
        }
    }
}

pub struct Sender {
    shared: Arc<SendShared>,
    threads: Vec<JoinHandle<()>>,
    capture: Option<Box<dyn CaptureSource>>,
}

pub fn start_sender(config: SendConfig, mut capture: Box<dyn CaptureSource>, events: EventSink) -> Result<Sender, String> {
    if config.password.is_empty() {
        return Err("a non-empty password is required (encryption is mandatory)".into());
    }
    let host_mode = config.bind_port > 0;
    if !host_mode && config.host.is_none() {
        return Err("need either bindPort (host mode) or host/port (connector mode)".into());
    }
    let key = crypto::derive_key(&config.password);
    let fingerprint = crypto::fingerprint(&config.password);
    let socket = net::bind_udp(if host_mode { config.bind_port } else { 0 })?;
    let target = match &config.host {
        Some(host) => Some(net::resolve_ipv4(host, config.port)?),
        None => None,
    };
    let relay = match (config.relay_session, target) {
        (Some(session), Some(target)) => Some((target, session)),
        (Some(_), None) => return Err("a relay session needs the relay's host/port".into()),
        _ => None,
    };
    let shared = Arc::new(SendShared {
        socket,
        target: Mutex::new(target),
        hello_cipher: Mutex::new(Cipher::new(&key)),
        hello_sequence: AtomicU32::new(0),
        peer_confirmed: AtomicBool::new(false),
        packets_sent: AtomicU64::new(0),
        bytes_sent: AtomicU64::new(0),
        capture_error: Mutex::new(None),
        relay,
        stop: AtomicBool::new(false),
        events: events.clone(),
    });

    // The capture sink: runs on the capture thread, owns the codec and the audio cipher.
    let stream_id = random_stream_id();
    let mut encoder = opus::Encoder::new(opus::FRAME_SAMPLES, opus::BITRATE)?;
    let frame_len = (opus::FRAME_SAMPLES * opus::CHANNELS) as usize;
    let mut audio_cipher = Cipher::new(&key);
    let mut accumulator: Vec<f32> = Vec::with_capacity(frame_len * 4);
    let mut audio_sequence: u32 = 0;
    let mut opus_packet = Vec::with_capacity(1500);
    let mut datagram = Vec::with_capacity(1500);
    let for_sink = shared.clone();
    let sink: Box<dyn FnMut(&[f32]) + Send> = Box::new(move |samples: &[f32]| {
        accumulator.extend_from_slice(samples);
        let mut offset = 0;
        while accumulator.len() - offset >= frame_len {
            let frame = &accumulator[offset..offset + frame_len];
            offset += frame_len;
            if for_sink.target.lock().unwrap().is_none() {
                continue; // host mode, nobody has said hello yet
            }
            opus_packet.clear();
            if encoder.encode(frame, &mut opus_packet).is_err() {
                continue;
            }
            // Audio packets carry a contiguous sequence: the receiver reads any gap as loss.
            audio_sequence = audio_sequence.wrapping_add(1);
            datagram.clear();
            Header::new(PacketType::Audio, stream_id, audio_sequence).write(&mut datagram);
            audio_cipher.seal(&opus_packet, &mut datagram);
            for_sink.send(&datagram);
        }
        accumulator.drain(..offset);
    });
    let for_fatal = shared.clone();
    let on_fatal: Box<dyn FnMut(String) + Send> = Box::new(move |message: String| {
        *for_fatal.capture_error.lock().unwrap() = Some(message.clone());
        emit(&for_fatal.events, json!({"event": "error", "message": message, "fatal": true}));
    });
    let info = capture.start(sink, on_fatal)?;

    // Inbound: the receiver's hellos (learn/confirm the return path, answer with a pong).
    let net_shared = shared.clone();
    let net_thread = thread::Builder::new()
        .name("remremote-audio-send-net".into())
        .spawn(move || {
            let mut buf = [0u8; 2048];
            while !net_shared.stop.load(Ordering::Relaxed) {
                let Some((n, from)) = recv_packet(&net_shared.socket, &mut buf) else { continue };
                let packet = &buf[..n];
                if net_shared.relay.is_some() && net::is_relay_packet(packet) {
                    continue;
                }
                let Some(header) = Header::parse(packet) else { continue };
                let mut cipher = net_shared.hello_cipher.lock().unwrap();
                if !hello::matches(&cipher, &header, &packet[HEADER_SIZE..], hello::HELLO_TAG) {
                    continue;
                }
                {
                    let mut target = net_shared.target.lock().unwrap();
                    if *target != Some(from) {
                        *target = Some(from);
                        emit(&net_shared.events, json!({"event": "peer", "endpoint": from.to_string()}));
                    }
                }
                let sequence = net_shared.hello_sequence.fetch_add(1, Ordering::Relaxed) + 1;
                let pong = hello::build(&mut cipher, hello::PONG_TAG, sequence);
                let _ = net_shared.socket.send_to(&pong, from);
                net_shared.peer_confirmed.store(true, Ordering::Relaxed);
            }
        })
        .map_err(|e| format!("could not start the network thread: {e}"))?;

    // Timers: format announcements, relay keepalive, status.
    let timer_shared = shared.clone();
    let format = AudioFormat::opus_stereo(opus::FRAME_SAMPLES, fingerprint);
    let timer_thread = thread::Builder::new()
        .name("remremote-audio-send-timer".into())
        .spawn(move || {
            let start = Instant::now();
            let mut last_format: Option<Instant> = None;
            let mut last_register: Option<Instant> = None;
            let mut last_status = Instant::now();
            let mut format_sequence: u32 = 0;
            let mut packet = Vec::with_capacity(64);
            while !timer_shared.stop.load(Ordering::Relaxed) {
                let now = Instant::now();
                if let Some((relay, session)) = &timer_shared.relay {
                    if last_register.map_or(true, |t| now - t >= net::RELAY_REGISTER_INTERVAL) {
                        let _ = timer_shared.socket.send_to(&net::relay_registration(session), relay);
                        last_register = Some(now);
                    }
                }
                if last_format.map_or(true, |t| now - t >= FORMAT_INTERVAL) {
                    if timer_shared.target.lock().unwrap().is_some() {
                        format_sequence = format_sequence.wrapping_add(1);
                        packet.clear();
                        Header::new(PacketType::Format, stream_id, format_sequence).write(&mut packet);
                        format.write(&mut packet);
                        timer_shared.send(&packet);
                    }
                    last_format = Some(now);
                }
                if now - last_status >= STATUS_INTERVAL {
                    last_status = now;
                    let target = timer_shared.target.lock().unwrap().map(|t| t.to_string());
                    emit(
                        &timer_shared.events,
                        json!({
                            "event": "status",
                            "mode": "send",
                            "running": timer_shared.capture_error.lock().unwrap().is_none(),
                            "uptimeMs": start.elapsed().as_millis() as u64,
                            "packetsSent": timer_shared.packets_sent.load(Ordering::Relaxed),
                            "bytesSent": timer_shared.bytes_sent.load(Ordering::Relaxed),
                            "peer": target,
                            "peerConfirmed": timer_shared.peer_confirmed.load(Ordering::Relaxed),
                            "captureError": *timer_shared.capture_error.lock().unwrap(),
                        }),
                    );
                }
                thread::sleep(TICK);
            }
        })
        .map_err(|e| format!("could not start the timer thread: {e}"))?;

    if let Some((code, message)) = &info.warning {
        emit(&events, json!({"event": "warning", "code": code, "message": message}));
    }
    emit(
        &events,
        json!({
            "event": "started",
            "mode": "send",
            "bound": if host_mode { Some(config.bind_port) } else { None },
            "target": target.map(|t| t.to_string()),
            "excludingPid": info.excluding_pid,
            "capture": info.description,
            "streamId": stream_id,
        }),
    );
    Ok(Sender { shared, threads: vec![net_thread, timer_thread], capture: Some(capture) })
}

impl Sender {
    /// Stops capture and every thread. No event is delivered after this returns.
    pub fn stop(&mut self) {
        self.shared.stop.store(true, Ordering::Relaxed);
        if let Some(mut capture) = self.capture.take() {
            capture.stop();
        }
        for thread in self.threads.drain(..) {
            let _ = thread.join();
        }
    }
}

impl Drop for Sender {
    fn drop(&mut self) {
        self.stop();
    }
}

// =================================================================== receiver

struct RecvShared {
    socket: UdpSocket,
    target: Option<SocketAddrV4>,
    relay: Option<(SocketAddrV4, [u8; 32])>,
    buffer: Arc<Mutex<PlayoutBuffer>>,
    peer_confirmed: AtomicBool,
    packets_received: AtomicU64,
    bytes_received: AtomicU64,
    audio_packets: AtomicU64,
    last_audio: Mutex<Option<Instant>>,
    fec_recoveries: AtomicU64,
    unrecovered_gaps: AtomicU64,
    rejected_packets: AtomicU64,
    playout_error: Mutex<Option<String>>,
    stop: AtomicBool,
    events: EventSink,
}

pub struct Receiver {
    shared: Arc<RecvShared>,
    threads: Vec<JoinHandle<()>>,
    playout: Option<Box<dyn PlayoutSink>>,
}

/// One sender's stream: keyed by (endpoint, stream id), replaced when either changes.
struct Session {
    endpoint: SocketAddrV4,
    stream_id: u16,
    format: AudioFormat,
    /// Decoded at 48 kHz stereo whatever the announced format: libopus resamples and
    /// up/down-mixes any packet to the decoder's configuration.
    decoder: opus::Decoder,
    frame_samples_48k: i32,
    expected_next: Option<u32>,
}

pub fn start_receiver(config: RecvConfig, mut playout: Box<dyn PlayoutSink>, events: EventSink) -> Result<Receiver, String> {
    if config.password.is_empty() {
        return Err("a non-empty password is required (encryption is mandatory)".into());
    }
    let host_mode = config.bind_port > 0;
    if !host_mode && config.host.is_none() {
        return Err("need either bindPort (host mode) or host/port (connector mode)".into());
    }
    let key = crypto::derive_key(&config.password);
    let our_fingerprint = crypto::fingerprint(&config.password);
    let socket = net::bind_udp(if host_mode { config.bind_port } else { 0 })?;
    let target = match &config.host {
        Some(host) => Some(net::resolve_ipv4(host, config.port)?),
        None => None,
    };
    let relay = match (config.relay_session, target) {
        (Some(session), Some(target)) => Some((target, session)),
        (Some(_), None) => return Err("a relay session needs the relay's host/port".into()),
        _ => None,
    };
    let target_ms = if config.max_latency_ms > 0 { config.max_latency_ms } else { DEFAULT_TARGET_LATENCY_MS };
    let buffer = Arc::new(Mutex::new(PlayoutBuffer::new(
        opus::SAMPLE_RATE as usize,
        opus::CHANNELS as usize,
        target_ms,
    )));
    let shared = Arc::new(RecvShared {
        socket,
        target,
        relay,
        buffer: buffer.clone(),
        peer_confirmed: AtomicBool::new(false),
        packets_received: AtomicU64::new(0),
        bytes_received: AtomicU64::new(0),
        audio_packets: AtomicU64::new(0),
        last_audio: Mutex::new(None),
        fec_recoveries: AtomicU64::new(0),
        unrecovered_gaps: AtomicU64::new(0),
        rejected_packets: AtomicU64::new(0),
        playout_error: Mutex::new(None),
        stop: AtomicBool::new(false),
        events: events.clone(),
    });

    let for_fatal = shared.clone();
    let on_fatal: Box<dyn FnMut(String) + Send> = Box::new(move |message: String| {
        *for_fatal.playout_error.lock().unwrap() = Some(message.clone());
        emit(&for_fatal.events, json!({"event": "error", "message": message, "fatal": true}));
    });
    playout.start(buffer, on_fatal)?;

    // Inbound: pongs confirm the path; Format opens a stream; Audio is decoded into the buffer.
    let net_shared = shared.clone();
    let net_thread = thread::Builder::new()
        .name("remremote-audio-recv-net".into())
        .spawn(move || {
            let cipher = Cipher::new(&key);
            let mut session: Option<Session> = None;
            let mut reported_mismatch = false;
            let mut reported_codec = false;
            let mut pcm: Vec<f32> = Vec::with_capacity(4096);
            let mut buf = [0u8; 2048];
            while !net_shared.stop.load(Ordering::Relaxed) {
                let Some((n, from)) = recv_packet(&net_shared.socket, &mut buf) else { continue };
                let packet = &buf[..n];
                if net_shared.relay.is_some() && net::is_relay_packet(packet) {
                    continue;
                }
                net_shared.packets_received.fetch_add(1, Ordering::Relaxed);
                net_shared.bytes_received.fetch_add(n as u64, Ordering::Relaxed);
                let Some(header) = Header::parse(packet) else {
                    net_shared.rejected_packets.fetch_add(1, Ordering::Relaxed);
                    continue;
                };
                let payload = &packet[HEADER_SIZE..];
                match header.packet_type {
                    PacketType::Heartbeat if header.stream_id == HELLO_STREAM_ID => {
                        if hello::matches(&cipher, &header, payload, hello::PONG_TAG)
                            && !net_shared.peer_confirmed.swap(true, Ordering::Relaxed)
                        {
                            emit(&net_shared.events, json!({"event": "peer", "endpoint": from.to_string()}));
                        }
                    }
                    PacketType::Format => {
                        let Some(incoming) = AudioFormat::parse(payload) else { continue };
                        if let Some(fingerprint) = incoming.fingerprint {
                            if fingerprint != our_fingerprint {
                                if !reported_mismatch {
                                    reported_mismatch = true;
                                    emit(
                                        &net_shared.events,
                                        json!({
                                            "event": "error",
                                            "code": "password-mismatch",
                                            "message": "the sender's audio password differs from ours",
                                        }),
                                    );
                                }
                                continue;
                            }
                        }
                        if let Some(current) = &session {
                            if current.endpoint == from
                                && current.stream_id == header.stream_id
                                && current.format.same_stream(&incoming)
                            {
                                continue;
                            }
                        }
                        if incoming.codec != CODEC_OPUS {
                            if !reported_codec {
                                reported_codec = true;
                                emit(
                                    &net_shared.events,
                                    json!({
                                        "event": "warning",
                                        "code": "codec-unsupported",
                                        "message": format!("only Opus streams are supported (codec {})", incoming.codec),
                                    }),
                                );
                            }
                            session = None;
                            continue;
                        }
                        let Ok(decoder) = opus::Decoder::new(opus::SAMPLE_RATE, opus::CHANNELS) else { continue };
                        let rate = incoming.sample_rate.max(1) as i64;
                        let frame_samples_48k =
                            ((incoming.frame_samples_per_channel as i64 * opus::SAMPLE_RATE as i64) / rate).clamp(120, 5760) as i32;
                        net_shared.buffer.lock().unwrap().clear();
                        emit(
                            &net_shared.events,
                            json!({
                                "event": "diag",
                                "message": format!(
                                    "stream opened from {from}: id {} {} Hz {} ch {} samples/frame",
                                    header.stream_id, incoming.sample_rate, incoming.channels, incoming.frame_samples_per_channel
                                ),
                            }),
                        );
                        session = Some(Session {
                            endpoint: from,
                            stream_id: header.stream_id,
                            format: incoming,
                            decoder,
                            frame_samples_48k,
                            expected_next: None,
                        });
                    }
                    PacketType::Audio => {
                        let Some(current) = session.as_mut() else { continue };
                        if current.endpoint != from || current.stream_id != header.stream_id {
                            continue;
                        }
                        let Some(plain) = cipher.open(payload) else {
                            net_shared.rejected_packets.fetch_add(1, Ordering::Relaxed);
                            continue;
                        };
                        // A single missing packet is rebuilt from the FEC copy the next one
                        // carries; wider gaps are left as silence (uint wrap-around intended).
                        let mut recover = false;
                        if let Some(expected) = current.expected_next {
                            let gap = header.sequence.wrapping_sub(expected);
                            if gap == 1 {
                                recover = true;
                            } else if gap > 1 && gap < 1_000_000 {
                                net_shared.unrecovered_gaps.fetch_add(1, Ordering::Relaxed);
                            }
                        }
                        if recover && current.decoder.decode(&plain, current.frame_samples_48k, true, &mut pcm).is_ok() {
                            net_shared.buffer.lock().unwrap().write(&pcm);
                            net_shared.fec_recoveries.fetch_add(1, Ordering::Relaxed);
                        }
                        if current.decoder.decode(&plain, current.frame_samples_48k, false, &mut pcm).is_ok() {
                            net_shared.buffer.lock().unwrap().write(&pcm);
                            net_shared.audio_packets.fetch_add(1, Ordering::Relaxed);
                            *net_shared.last_audio.lock().unwrap() = Some(Instant::now());
                        } else {
                            net_shared.rejected_packets.fetch_add(1, Ordering::Relaxed);
                        }
                        current.expected_next = Some(header.sequence.wrapping_add(1));
                    }
                    _ => {}
                }
            }
        })
        .map_err(|e| format!("could not start the network thread: {e}"))?;

    // Timers: hellos (connector mode), relay keepalive, status.
    let timer_shared = shared.clone();
    let hello_key = key;
    let timer_thread = thread::Builder::new()
        .name("remremote-audio-recv-timer".into())
        .spawn(move || {
            let mut hello_cipher = Cipher::new(&hello_key);
            let start = Instant::now();
            let mut hello_sequence: u32 = 0;
            let mut last_hello: Option<Instant> = None;
            let mut last_register: Option<Instant> = None;
            let mut last_status = Instant::now();
            while !timer_shared.stop.load(Ordering::Relaxed) {
                let now = Instant::now();
                // Register before the hello so the relay can pair us and forward it onward.
                if let Some((relay, session)) = &timer_shared.relay {
                    if last_register.map_or(true, |t| now - t >= net::RELAY_REGISTER_INTERVAL) {
                        let _ = timer_shared.socket.send_to(&net::relay_registration(session), relay);
                        last_register = Some(now);
                    }
                }
                if let Some(target) = timer_shared.target {
                    if last_hello.map_or(true, |t| now - t >= HELLO_INTERVAL) {
                        hello_sequence = hello_sequence.wrapping_add(1);
                        let packet = hello::build(&mut hello_cipher, hello::HELLO_TAG, hello_sequence);
                        let _ = timer_shared.socket.send_to(&packet, target);
                        last_hello = Some(now);
                    }
                }
                if now - last_status >= STATUS_INTERVAL {
                    last_status = now;
                    let flowing = timer_shared
                        .last_audio
                        .lock()
                        .unwrap()
                        .map_or(false, |t| now - t <= Duration::from_secs(3));
                    let (buffered, target_ms, max_ms, underruns, dropped, trimmed) = {
                        let buffer = timer_shared.buffer.lock().unwrap();
                        (buffer.buffered_ms(), buffer.target_ms(), buffer.max_ms(), buffer.underruns, buffer.dropped_samples, buffer.trimmed_samples)
                    };
                    emit(
                        &timer_shared.events,
                        json!({
                            "event": "status",
                            "mode": "recv",
                            "uptimeMs": start.elapsed().as_millis() as u64,
                            "packetsReceived": timer_shared.packets_received.load(Ordering::Relaxed),
                            "bytesReceived": timer_shared.bytes_received.load(Ordering::Relaxed),
                            "audioPackets": timer_shared.audio_packets.load(Ordering::Relaxed),
                            "audioFlowing": flowing,
                            "bufferMs": buffered,
                            "targetMs": target_ms,
                            "maxMs": max_ms,
                            "underruns": underruns,
                            "droppedSamples": dropped,
                            "trimmedSamples": trimmed,
                            "fecRecoveries": timer_shared.fec_recoveries.load(Ordering::Relaxed),
                            "unrecoveredGaps": timer_shared.unrecovered_gaps.load(Ordering::Relaxed),
                            "rejectedPackets": timer_shared.rejected_packets.load(Ordering::Relaxed),
                            "peerConfirmed": timer_shared.peer_confirmed.load(Ordering::Relaxed),
                            "playoutError": *timer_shared.playout_error.lock().unwrap(),
                        }),
                    );
                }
                thread::sleep(TICK);
            }
        })
        .map_err(|e| format!("could not start the timer thread: {e}"))?;

    emit(
        &events,
        json!({
            "event": "started",
            "mode": "recv",
            "bound": if host_mode { Some(config.bind_port) } else { None },
            "target": target.map(|t| t.to_string()),
            "targetMs": target_ms,
        }),
    );
    Ok(Receiver { shared, threads: vec![net_thread, timer_thread], playout: Some(playout) })
}

impl Receiver {
    /// Stops playout and every thread. No event is delivered after this returns.
    pub fn stop(&mut self) {
        self.shared.stop.store(true, Ordering::Relaxed);
        for thread in self.threads.drain(..) {
            let _ = thread.join();
        }
        if let Some(mut playout) = self.playout.take() {
            playout.stop();
        }
    }
}

impl Drop for Receiver {
    fn drop(&mut self) {
        self.stop();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::platform::null::NullPlayout;
    use crate::platform::tone::ToneSource;
    use std::sync::mpsc;

    fn collector() -> (EventSink, mpsc::Receiver<Value>) {
        let (tx, rx) = mpsc::channel();
        let tx = Mutex::new(tx);
        (Arc::new(move |value| { let _ = tx.lock().unwrap().send(value); }), rx)
    }

    fn wait_for(rx: &mpsc::Receiver<Value>, predicate: impl Fn(&Value) -> bool, timeout: Duration) -> Option<Value> {
        let deadline = Instant::now() + timeout;
        while Instant::now() < deadline {
            match rx.recv_timeout(Duration::from_millis(100)) {
                Ok(value) => {
                    if predicate(&value) {
                        return Some(value);
                    }
                }
                Err(mpsc::RecvTimeoutError::Timeout) => {}
                Err(_) => break,
            }
        }
        None
    }

    /// Host-mode sender (as the controlled computer does when it hosts the connection) and a
    /// connector-mode receiver punching it with hellos: audio must flow end to end.
    #[test]
    fn sender_hosts_receiver_connects() {
        let port = net::bind_udp(0).unwrap().local_addr().unwrap().port();
        let (send_events, send_rx) = collector();
        let (recv_events, recv_rx) = collector();
        let mut sender = start_sender(
            SendConfig { password: "pw".into(), bind_port: port, ..Default::default() },
            Box::new(ToneSource::new(440.0)),
            send_events,
        )
        .unwrap();
        let mut receiver = start_receiver(
            RecvConfig { password: "pw".into(), host: Some("127.0.0.1".into()), port, max_latency_ms: 20, ..Default::default() },
            Box::new(NullPlayout::new(None)),
            recv_events,
        )
        .unwrap();
        assert!(wait_for(&send_rx, |v| v["event"] == "peer", Duration::from_secs(5)).is_some());
        assert!(wait_for(&recv_rx, |v| v["event"] == "peer", Duration::from_secs(5)).is_some());
        let status = wait_for(
            &recv_rx,
            |v| v["event"] == "status" && v["audioFlowing"] == true && v["audioPackets"].as_u64().unwrap_or(0) > 50,
            Duration::from_secs(8),
        )
        .expect("audio should flow");
        assert_eq!(status["rejectedPackets"], 0);
        sender.stop();
        receiver.stop();
    }

    /// Receiver hosts (the controlling computer's control-server port), sender connects: no
    /// hellos involved, the stream just arrives.
    #[test]
    fn receiver_hosts_sender_connects_and_wrong_password_is_rejected() {
        let port = net::bind_udp(0).unwrap().local_addr().unwrap().port();
        let (recv_events, recv_rx) = collector();
        let mut receiver = start_receiver(
            RecvConfig { password: "right".into(), bind_port: port, ..Default::default() },
            Box::new(NullPlayout::new(None)),
            recv_events,
        )
        .unwrap();
        let (bad_events, _bad_rx) = collector();
        let mut bad = start_sender(
            SendConfig { password: "wrong".into(), host: Some("127.0.0.1".into()), port, ..Default::default() },
            Box::new(ToneSource::new(440.0)),
            bad_events,
        )
        .unwrap();
        assert!(wait_for(&recv_rx, |v| v["event"] == "error" && v["code"] == "password-mismatch", Duration::from_secs(5)).is_some());
        bad.stop();
        let (send_events, _send_rx) = collector();
        let mut sender = start_sender(
            SendConfig { password: "right".into(), host: Some("127.0.0.1".into()), port, ..Default::default() },
            Box::new(ToneSource::new(440.0)),
            send_events,
        )
        .unwrap();
        assert!(wait_for(&recv_rx, |v| v["event"] == "status" && v["audioFlowing"] == true, Duration::from_secs(8)).is_some());
        sender.stop();
        receiver.stop();
    }

    #[test]
    fn rejects_bad_configs() {
        let (events, _rx) = collector();
        assert!(start_sender(SendConfig::default(), Box::new(ToneSource::new(1.0)), events.clone()).is_err());
        assert!(start_sender(SendConfig { password: "x".into(), ..Default::default() }, Box::new(ToneSource::new(1.0)), events.clone()).is_err());
        assert!(start_receiver(RecvConfig { password: "x".into(), relay_session: Some([0; 32]), ..Default::default() }, Box::new(NullPlayout::new(None)), events).is_err());
    }
}
