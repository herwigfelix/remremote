//! remremote's sealed hello/pong packets, used to punch NATs and to teach the connection host
//! where its peer is. Not part of stock RemSound: a Heartbeat-typed packet on the reserved
//! stream id 0xFFFE whose payload is AES-256-GCM sealed with the session key and holds an
//! ASCII tag ("TNVH1" hello / "TNVP1" pong) plus an int64 little-endian Unix-millisecond
//! timestamp, accepted when within two minutes of the receiver's clock. Only someone who knows
//! the password can produce one, so a forged hello can never redirect the stream. Plain
//! RemSound builds drop it as a malformed heartbeat.

use std::time::{SystemTime, UNIX_EPOCH};

use crate::crypto::Cipher;
use crate::packet::{Header, PacketType, HELLO_STREAM_ID};

pub const HELLO_TAG: &[u8; 5] = b"TNVH1";
pub const PONG_TAG: &[u8; 5] = b"TNVP1";
pub const PLAINTEXT_BYTES: usize = 5 + 8;
pub const FRESHNESS_MS: i64 = 120_000;

pub fn now_unix_ms() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

/// Builds a complete datagram (header + sealed payload) carrying `tag`.
pub fn build(cipher: &mut Cipher, tag: &[u8; 5], sequence: u32) -> Vec<u8> {
    let mut plaintext = [0u8; PLAINTEXT_BYTES];
    plaintext[..5].copy_from_slice(tag);
    plaintext[5..].copy_from_slice(&now_unix_ms().to_le_bytes());
    let mut packet = Vec::with_capacity(12 + PLAINTEXT_BYTES + 28);
    Header::new(PacketType::Heartbeat, HELLO_STREAM_ID, sequence).write(&mut packet);
    cipher.seal(&plaintext, &mut packet);
    packet
}

/// True when `payload` (the datagram after its header) is a fresh, authentic packet with
/// `tag`. Anything else - wrong type or stream id, failed GCM tag, stale timestamp - is false.
pub fn matches(cipher: &Cipher, header: &Header, payload: &[u8], tag: &[u8; 5]) -> bool {
    if header.packet_type != PacketType::Heartbeat || header.stream_id != HELLO_STREAM_ID {
        return false;
    }
    let Some(plaintext) = cipher.open(payload) else { return false };
    if plaintext.len() < PLAINTEXT_BYTES || &plaintext[..5] != tag {
        return false;
    }
    let mut stamp = [0u8; 8];
    stamp.copy_from_slice(&plaintext[5..13]);
    let age = now_unix_ms() - i64::from_le_bytes(stamp);
    age.abs() <= FRESHNESS_MS
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::crypto::derive_key;
    use crate::packet::HEADER_SIZE;

    #[test]
    fn hello_and_pong_are_recognised_only_with_the_right_key_and_tag() {
        let key = derive_key("pw");
        let mut cipher = Cipher::new(&key);
        let packet = build(&mut cipher, HELLO_TAG, 7);
        let header = Header::parse(&packet).unwrap();
        assert_eq!(header.stream_id, HELLO_STREAM_ID);
        assert_eq!(header.sequence, 7);
        let payload = &packet[HEADER_SIZE..];
        assert!(matches(&cipher, &header, payload, HELLO_TAG));
        assert!(!matches(&cipher, &header, payload, PONG_TAG));
        let wrong = Cipher::new(&derive_key("other"));
        assert!(!matches(&wrong, &header, payload, HELLO_TAG));
        let mut audio_header = header;
        audio_header.packet_type = PacketType::Audio;
        assert!(!matches(&cipher, &audio_header, payload, HELLO_TAG));
    }

    #[test]
    fn stale_timestamps_are_rejected() {
        let key = derive_key("pw");
        let mut cipher = Cipher::new(&key);
        let mut plaintext = [0u8; PLAINTEXT_BYTES];
        plaintext[..5].copy_from_slice(HELLO_TAG);
        plaintext[5..].copy_from_slice(&(now_unix_ms() - FRESHNESS_MS - 5_000).to_le_bytes());
        let mut sealed = Vec::new();
        cipher.seal(&plaintext, &mut sealed);
        let header = Header::new(PacketType::Heartbeat, HELLO_STREAM_ID, 1);
        assert!(!matches(&cipher, &header, &sealed, HELLO_TAG));
    }
}
