//! UDP plumbing shared by the sender and receiver, plus the remremote relay's registration
//! framing: `b"RRLY" | version(1) | session id(32)`, repeated every two seconds as a keepalive.
//! The relay pairs the two endpoints that register the same session id and forwards their
//! datagrams to each other verbatim, never decrypting anything.

use std::net::{Ipv4Addr, SocketAddr, SocketAddrV4, ToSocketAddrs, UdpSocket};
use std::time::Duration;

pub const RELAY_MAGIC: &[u8; 4] = b"RRLY";
pub const RELAY_VERSION: u8 = 1;
pub const RELAY_REGISTRATION_LEN: usize = 4 + 1 + 32;
pub const RELAY_REGISTER_INTERVAL: Duration = Duration::from_secs(2);
/// How long a blocking receive waits before the loop checks its stop flag.
pub const RECV_TIMEOUT: Duration = Duration::from_millis(250);

/// The audio transport is IPv4-only (RemSound's is, and every relay/host it talks to is v4).
pub fn resolve_ipv4(host: &str, port: u16) -> Result<SocketAddrV4, String> {
    if let Ok(ip) = host.parse::<Ipv4Addr>() {
        return Ok(SocketAddrV4::new(ip, port));
    }
    let addresses = (host, port)
        .to_socket_addrs()
        .map_err(|e| format!("could not resolve \"{host}\": {e}"))?;
    for address in addresses {
        if let SocketAddr::V4(v4) = address {
            return Ok(v4);
        }
    }
    Err(format!("could not resolve \"{host}\" to an IPv4 address"))
}

/// Binds a UDP socket on all IPv4 interfaces (`port` 0 = ephemeral) with a large kernel
/// receive buffer and the receive timeout the loops rely on.
pub fn bind_udp(port: u16) -> Result<UdpSocket, String> {
    let socket = socket2::Socket::new(socket2::Domain::IPV4, socket2::Type::DGRAM, Some(socket2::Protocol::UDP))
        .map_err(|e| format!("socket: {e}"))?;
    let _ = socket.set_recv_buffer_size(1024 * 1024);
    let _ = socket.set_send_buffer_size(256 * 1024);
    let address = SocketAddr::V4(SocketAddrV4::new(Ipv4Addr::UNSPECIFIED, port));
    socket
        .bind(&address.into())
        .map_err(|e| format!("could not bind UDP port {port}: {e}"))?;
    let socket: UdpSocket = socket.into();
    socket
        .set_read_timeout(Some(RECV_TIMEOUT))
        .map_err(|e| format!("set_read_timeout: {e}"))?;
    Ok(socket)
}

pub fn relay_registration(session: &[u8; 32]) -> [u8; RELAY_REGISTRATION_LEN] {
    let mut packet = [0u8; RELAY_REGISTRATION_LEN];
    packet[..4].copy_from_slice(RELAY_MAGIC);
    packet[4] = RELAY_VERSION;
    packet[5..].copy_from_slice(session);
    packet
}

/// The relay answers registrations with the same framing; those are not audio.
pub fn is_relay_packet(packet: &[u8]) -> bool {
    packet.len() == RELAY_REGISTRATION_LEN && &packet[..4] == RELAY_MAGIC
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn relay_registration_framing() {
        let session = [7u8; 32];
        let packet = relay_registration(&session);
        assert_eq!(&packet[..5], b"RRLY\x01");
        assert_eq!(&packet[5..], &session);
        assert!(is_relay_packet(&packet));
        assert!(!is_relay_packet(&packet[..36]));
        assert!(!is_relay_packet(b"RMND"));
    }

    #[test]
    fn resolves_literals_and_binds_ephemeral() {
        assert_eq!(resolve_ipv4("127.0.0.1", 5).unwrap(), SocketAddrV4::new(Ipv4Addr::LOCALHOST, 5));
        assert_eq!(resolve_ipv4("localhost", 6).unwrap().ip(), &Ipv4Addr::LOCALHOST);
        assert!(resolve_ipv4("::1", 7).is_err());
        let socket = bind_udp(0).unwrap();
        assert_ne!(socket.local_addr().unwrap().port(), 0);
    }
}
