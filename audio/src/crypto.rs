//! RemSound's audio encryption: AES-256-GCM with a key derived from the shared password by
//! PBKDF2-HMAC-SHA256 over a fixed salt. The iteration count and salts are a cross-
//! implementation contract (Windows RemSound, the Mac app, this crate) and must not change.
//!
//! Sealed payload layout on the wire: `nonce(12) ‖ tag(16) ‖ ciphertext`.

use aes_gcm::aead::{Aead, KeyInit, Payload};
use aes_gcm::{Aes256Gcm, Nonce};

use sha2::Sha256;

pub const KEY_SALT: &[u8] = b"RemSound.v1.audio-key";
pub const FINGERPRINT_SALT: &[u8] = b"RemSound.v1.fingerprint";
pub const PBKDF2_ITERATIONS: u32 = 100_000;
pub const NONCE_BYTES: usize = 12;
pub const TAG_BYTES: usize = 16;
pub const OVERHEAD_BYTES: usize = NONCE_BYTES + TAG_BYTES;

/// The 256-bit AES key for a password. Slow on purpose (100k rounds): derive once per session.
pub fn derive_key(password: &str) -> [u8; 32] {
    let mut key = [0u8; 32];
    pbkdf2::pbkdf2_hmac::<Sha256>(password.as_bytes(), KEY_SALT, PBKDF2_ITERATIONS, &mut key);
    key
}

/// A short, non-reversible id of a password, sent in Format packets so peers can discover a
/// password mismatch without revealing the password.
pub fn fingerprint(password: &str) -> [u8; 8] {
    let mut out = [0u8; 8];
    pbkdf2::pbkdf2_hmac::<Sha256>(password.as_bytes(), FINGERPRINT_SALT, PBKDF2_ITERATIONS, &mut out);
    out
}

/// One session's cipher. Nonces are a random 48-bit prefix plus a 48-bit counter, so they can
/// never repeat within a session and are vanishingly unlikely to collide across sessions on
/// the same key (RemSound's `NonceSequence`).
pub struct Cipher {
    gcm: Aes256Gcm,
    prefix: [u8; 6],
    counter: u64,
}

impl Cipher {
    pub fn new(key: &[u8; 32]) -> Self {
        let mut prefix = [0u8; 6];
        rand::fill(&mut prefix);
        Cipher { gcm: Aes256Gcm::new(key.into()), prefix, counter: 0 }
    }

    fn next_nonce(&mut self) -> [u8; NONCE_BYTES] {
        let mut nonce = [0u8; NONCE_BYTES];
        nonce[..6].copy_from_slice(&self.prefix);
        let counter = self.counter;
        self.counter = self.counter.wrapping_add(1);
        for i in 0..6 {
            nonce[6 + i] = (counter >> (8 * i)) as u8;
        }
        nonce
    }

    /// Appends `nonce ‖ tag ‖ ciphertext` for `plaintext` to `out`.
    pub fn seal(&mut self, plaintext: &[u8], out: &mut Vec<u8>) {
        let nonce = self.next_nonce();
        // aes-gcm yields ciphertext ‖ tag; the wire wants the tag in front of the ciphertext.
        let sealed = self
            .gcm
            .encrypt(&Nonce::from(nonce), Payload { msg: plaintext, aad: &[] })
            .expect("AES-GCM encryption cannot fail for in-memory buffers");
        let split = sealed.len() - TAG_BYTES;
        out.extend_from_slice(&nonce);
        out.extend_from_slice(&sealed[split..]);
        out.extend_from_slice(&sealed[..split]);
    }

    /// Reverses `seal`. `None` when the packet is too short or the tag does not verify (wrong
    /// password, or tampering).
    pub fn open(&self, packet: &[u8]) -> Option<Vec<u8>> {
        if packet.len() < OVERHEAD_BYTES {
            return None;
        }
        let mut nonce = [0u8; NONCE_BYTES];
        nonce.copy_from_slice(&packet[..NONCE_BYTES]);
        let tag = &packet[NONCE_BYTES..OVERHEAD_BYTES];
        let ciphertext = &packet[OVERHEAD_BYTES..];
        let mut combined = Vec::with_capacity(ciphertext.len() + TAG_BYTES);
        combined.extend_from_slice(ciphertext);
        combined.extend_from_slice(tag);
        self.gcm
            .decrypt(&Nonce::from(nonce), Payload { msg: &combined, aad: &[] })
            .ok()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn hex(bytes: &[u8]) -> String {
        bytes.iter().map(|b| format!("{:02x}", b)).collect()
    }

    /// The same vectors the Mac app's interop tests pin (originally checked against RemSound).
    #[test]
    fn key_derivation_vectors() {
        assert_eq!(
            hex(&derive_key("test123")),
            "b419d5d5ab025172af8ea4f8923ef9176bf2c0e720e40873d82aa4350f0e87d3"
        );
        assert_eq!(hex(&fingerprint("test123")), "fb6a9f52926ac190");
        assert_eq!(hex(&fingerprint("")), "7a78e2d810154bf7");
    }

    #[test]
    fn seal_open_round_trip() {
        let key = derive_key("test123");
        let mut cipher = Cipher::new(&key);
        let plaintext = b"TNVH1 payload";
        let mut sealed = Vec::new();
        cipher.seal(plaintext, &mut sealed);
        assert_eq!(sealed.len(), plaintext.len() + OVERHEAD_BYTES);
        assert_eq!(cipher.open(&sealed).as_deref(), Some(&plaintext[..]));
        let other = Cipher::new(&derive_key("other"));
        assert!(other.open(&sealed).is_none());
        let mut tampered = sealed.clone();
        tampered[OVERHEAD_BYTES] ^= 1;
        assert!(cipher.open(&tampered).is_none());
        assert!(cipher.open(&sealed[..10]).is_none());
        // Nonces advance.
        let mut again = Vec::new();
        cipher.seal(plaintext, &mut again);
        assert_ne!(again[..NONCE_BYTES], sealed[..NONCE_BYTES]);
    }
}
