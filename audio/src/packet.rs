//! The RemSound UDP wire format, header version 1.
//!
//! Every datagram starts with a 12-byte little-endian header:
//! `uint32 magic "RMND" | uint8 version = 1 | uint8 type | uint16 streamId | uint32 sequence`.
//! The body length is implied by the datagram. A stream id of 0 is read as 1 on both ends.

pub const HEADER_SIZE: usize = 12;
pub const MAGIC: u32 = 0x444E_4D52; // "RMND" little-endian
pub const VERSION: u8 = 1;
/// Reserved stream id carrying remremote's sealed hello/pong packets (see `hello`).
pub const HELLO_STREAM_ID: u16 = 0xFFFE;

/// Format payload sizes: the 32-byte legacy block, the 36-byte block with the render-lane
/// byte, and the 44-byte block with the 8-byte password fingerprint appended.
pub const FORMAT_PAYLOAD_SIZE: usize = 32;
pub const FORMAT_PAYLOAD_EXTENDED_SIZE: usize = 36;
pub const FORMAT_PAYLOAD_WITH_FINGERPRINT_SIZE: usize = 44;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[repr(u8)]
pub enum PacketType {
    Format = 1,
    Audio = 2,
    KeepAlive = 3,
    Heartbeat = 4,
    Control = 5,
    AddrCheck = 10,
}

impl PacketType {
    pub fn from_u8(value: u8) -> Option<Self> {
        Some(match value {
            1 => PacketType::Format,
            2 => PacketType::Audio,
            3 => PacketType::KeepAlive,
            4 => PacketType::Heartbeat,
            5 => PacketType::Control,
            10 => PacketType::AddrCheck,
            _ => return None,
        })
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Header {
    pub packet_type: PacketType,
    pub stream_id: u16,
    pub sequence: u32,
}

impl Header {
    pub fn new(packet_type: PacketType, stream_id: u16, sequence: u32) -> Self {
        Header { packet_type, stream_id, sequence }
    }

    /// Appends the 12-byte header to `out`.
    pub fn write(&self, out: &mut Vec<u8>) {
        out.extend_from_slice(&MAGIC.to_le_bytes());
        out.push(VERSION);
        out.push(self.packet_type as u8);
        let stream_id = if self.stream_id == 0 { 1 } else { self.stream_id };
        out.extend_from_slice(&stream_id.to_le_bytes());
        out.extend_from_slice(&self.sequence.to_le_bytes());
    }

    /// Parses the header of a datagram; `None` for anything that is not a RemSound v1 packet.
    pub fn parse(packet: &[u8]) -> Option<Header> {
        if packet.len() < HEADER_SIZE {
            return None;
        }
        if u32::from_le_bytes([packet[0], packet[1], packet[2], packet[3]]) != MAGIC {
            return None;
        }
        if packet[4] != VERSION {
            return None;
        }
        let packet_type = PacketType::from_u8(packet[5])?;
        let mut stream_id = u16::from_le_bytes([packet[6], packet[7]]);
        if stream_id == 0 {
            stream_id = 1;
        }
        let sequence = u32::from_le_bytes([packet[8], packet[9], packet[10], packet[11]]);
        Some(Header { packet_type, stream_id, sequence })
    }
}

pub const CODEC_PCM: i32 = 1;
pub const CODEC_OPUS: i32 = 2;

/// The Format packet payload: what the sender's stream looks like, plus (from
/// encryption-capable senders) a fingerprint of the password so a receiver can tell a
/// mismatched password from a broken stream without either side sending the password.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct AudioFormat {
    pub sample_rate: i32,
    pub channels: i32,
    pub bits_per_sample: i32,
    pub encoding: i32,
    pub block_align: i32,
    pub average_bytes_per_second: i32,
    pub codec: i32,
    pub frame_samples_per_channel: i32,
    pub lane: u8,
    pub fingerprint: Option<[u8; 8]>,
}

impl AudioFormat {
    /// The format remremote always streams: 48 kHz stereo IEEE float over Opus.
    pub fn opus_stereo(frame_samples_per_channel: i32, fingerprint: [u8; 8]) -> Self {
        AudioFormat {
            sample_rate: 48_000,
            channels: 2,
            bits_per_sample: 32,
            encoding: 3, // IEEE float
            block_align: 8,
            average_bytes_per_second: 384_000,
            codec: CODEC_OPUS,
            frame_samples_per_channel,
            lane: 0,
            fingerprint: Some(fingerprint),
        }
    }

    /// Appends the payload: 36 bytes, or 44 with the fingerprint.
    pub fn write(&self, out: &mut Vec<u8>) {
        for value in [
            self.sample_rate,
            self.channels,
            self.bits_per_sample,
            self.encoding,
            self.block_align,
            self.average_bytes_per_second,
            self.codec,
            self.frame_samples_per_channel,
        ] {
            out.extend_from_slice(&value.to_le_bytes());
        }
        out.extend_from_slice(&[self.lane, 0, 0, 0]);
        if let Some(fingerprint) = &self.fingerprint {
            out.extend_from_slice(fingerprint);
        }
    }

    /// Parses a 32-, 36- or 44-byte payload (older senders omit the trailing fields).
    pub fn parse(payload: &[u8]) -> Option<Self> {
        if payload.len() < FORMAT_PAYLOAD_SIZE {
            return None;
        }
        let int32 = |offset: usize| {
            i32::from_le_bytes([
                payload[offset],
                payload[offset + 1],
                payload[offset + 2],
                payload[offset + 3],
            ])
        };
        let lane = if payload.len() >= FORMAT_PAYLOAD_EXTENDED_SIZE {
            match payload[32] {
                lane @ 0..=2 => lane,
                _ => 0,
            }
        } else {
            0
        };
        let fingerprint = if payload.len() >= FORMAT_PAYLOAD_WITH_FINGERPRINT_SIZE {
            let mut bytes = [0u8; 8];
            bytes.copy_from_slice(&payload[36..44]);
            Some(bytes)
        } else {
            None
        };
        Some(AudioFormat {
            sample_rate: int32(0),
            channels: int32(4),
            bits_per_sample: int32(8),
            encoding: int32(12),
            block_align: int32(16),
            average_bytes_per_second: int32(20),
            codec: int32(24),
            frame_samples_per_channel: int32(28),
            lane,
            fingerprint,
        })
    }

    /// Whether two announcements describe the same decodable stream.
    pub fn same_stream(&self, other: &AudioFormat) -> bool {
        self.codec == other.codec
            && self.sample_rate == other.sample_rate
            && self.channels == other.channels
            && self.frame_samples_per_channel == other.frame_samples_per_channel
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn header_round_trip() {
        let mut bytes = Vec::new();
        Header::new(PacketType::Heartbeat, 65534, 42).write(&mut bytes);
        assert_eq!(bytes.len(), HEADER_SIZE);
        assert_eq!(&bytes[..4], &[0x52, 0x4D, 0x4E, 0x44]); // "RMND"
        bytes.extend_from_slice(&[1, 2, 3]);
        let header = Header::parse(&bytes).unwrap();
        assert_eq!(header.packet_type, PacketType::Heartbeat);
        assert_eq!(header.stream_id, 65534);
        assert_eq!(header.sequence, 42);
        assert!(Header::parse(&[0, 1, 2]).is_none());
        // Stream id 0 reads as 1, like every other implementation.
        let mut zero = Vec::new();
        Header::new(PacketType::Audio, 0, 1).write(&mut zero);
        assert_eq!(Header::parse(&zero).unwrap().stream_id, 1);
        // A different version or magic is not ours.
        let mut wrong = bytes.clone();
        wrong[4] = 2;
        assert!(Header::parse(&wrong).is_none());
    }

    #[test]
    fn format_round_trip_and_legacy_sizes() {
        let format = AudioFormat::opus_stereo(480, [1, 2, 3, 4, 5, 6, 7, 8]);
        let mut payload = Vec::new();
        format.write(&mut payload);
        assert_eq!(payload.len(), FORMAT_PAYLOAD_WITH_FINGERPRINT_SIZE);
        let parsed = AudioFormat::parse(&payload).unwrap();
        assert_eq!(parsed, format);
        assert_eq!(parsed.codec, CODEC_OPUS);
        // The Mac test vector: 48000 Hz, 2 ch, 16 bit, encoding 1, align 4, 384000 B/s,
        // codec 2, 480 samples, lane 0, fingerprint 1..8.
        let mut vector = Vec::new();
        for value in [48000i32, 2, 16, 1, 4, 384_000, 2, 480] {
            vector.extend_from_slice(&value.to_le_bytes());
        }
        vector.extend_from_slice(&[0, 0, 0, 0, 1, 2, 3, 4, 5, 6, 7, 8]);
        let parsed = AudioFormat::parse(&vector).unwrap();
        assert_eq!(parsed.frame_samples_per_channel, 480);
        assert_eq!(parsed.fingerprint, Some([1, 2, 3, 4, 5, 6, 7, 8]));
        let legacy = AudioFormat::parse(&vector[..32]).unwrap();
        assert_eq!(legacy.fingerprint, None);
        assert_eq!(legacy.lane, 0);
        assert!(AudioFormat::parse(&vector[..31]).is_none());
        assert!(parsed.same_stream(&legacy));
    }
}
