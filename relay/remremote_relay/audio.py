"""The UDP audio relay — a dumb, encryption-preserving packet reflector.

The relay must not be able to listen in on the audio: it never holds the session
password, never decrypts, never parses RemSound packets. All it does is pair two
endpoints that announce the same opaque 32-byte session id and forward their datagrams to
each other verbatim.

Registration packet (sent by each peer, repeated ~every 2 s as a keepalive)::

    b"RRLY" | version(1) | session_id(32)      # 37 bytes

Anything else arriving from a registered endpoint is forwarded unchanged to the other
endpoint(s) sharing its session id. RemSound's own packets begin with ``RMND`` and so
never collide with the registration magic. Endpoints idle past ``SESSION_TIMEOUT`` are
forgotten, which also frees a session for re-pairing after a restart.
"""

import asyncio
import logging
import time
from typing import Dict, Optional, Set, Tuple

log = logging.getLogger("remremote.audio")

MAGIC = b"RRLY"
VERSION = 1
REGISTRATION_SIZE = 4 + 1 + 32
SESSION_TIMEOUT = 30.0
CLEANUP_INTERVAL = 10.0

Endpoint = Tuple[str, int]


class AudioRelay(asyncio.DatagramProtocol):
    def __init__(self):
        self.transport: Optional[asyncio.DatagramTransport] = None
        #: endpoint -> session id
        self.endpoint_session: Dict[Endpoint, bytes] = {}
        #: session id -> set of endpoints
        self.session_endpoints: Dict[bytes, Set[Endpoint]] = {}
        #: endpoint -> last-seen monotonic time
        self.last_seen: Dict[Endpoint, float] = {}
        self._packets_forwarded = 0

    def connection_made(self, transport):
        self.transport = transport
        sockname = transport.get_extra_info("sockname")
        log.info("audio relay listening on %s (UDP)", sockname)
        asyncio.create_task(self._cleanup_loop())

    def datagram_received(self, data: bytes, addr: Endpoint):
        if len(data) == REGISTRATION_SIZE and data[:4] == MAGIC and data[4] == VERSION:
            self._register(data[5:37], addr)
            return
        # Forward verbatim to the paired endpoint(s).
        session = self.endpoint_session.get(addr)
        if session is None:
            return  # unknown / unregistered source — ignore
        self.last_seen[addr] = time.monotonic()
        for peer in self.session_endpoints.get(session, ()):  # type: ignore[union-attr]
            if peer != addr and self.transport is not None:
                self.transport.sendto(data, peer)
                self._packets_forwarded += 1

    def _register(self, session: bytes, addr: Endpoint):
        now = time.monotonic()
        previous = self.endpoint_session.get(addr)
        if previous is not None and previous != session:
            # This endpoint re-registered under a different session; drop the old link.
            self._forget(addr)
        self.endpoint_session[addr] = session
        self.session_endpoints.setdefault(session, set()).add(addr)
        self.last_seen[addr] = now
        # Acknowledge so the peer knows the relay is alive (and to keep symmetry for RTT).
        if self.transport is not None:
            self.transport.sendto(MAGIC + bytes([VERSION]) + session, addr)
        peers = self.session_endpoints.get(session, set())
        if previous is None:
            log.info("audio endpoint %s registered (%d in session)", addr, len(peers))

    def _forget(self, addr: Endpoint):
        session = self.endpoint_session.pop(addr, None)
        self.last_seen.pop(addr, None)
        if session is not None:
            endpoints = self.session_endpoints.get(session)
            if endpoints:
                endpoints.discard(addr)
                if not endpoints:
                    del self.session_endpoints[session]

    async def _cleanup_loop(self):
        while True:
            await asyncio.sleep(CLEANUP_INTERVAL)
            now = time.monotonic()
            stale = [addr for addr, seen in self.last_seen.items() if now - seen > SESSION_TIMEOUT]
            for addr in stale:
                self._forget(addr)
            if stale:
                log.debug("audio relay pruned %d idle endpoint(s)", len(stale))


async def start_audio_relay(host: str, port: int) -> asyncio.DatagramTransport:
    loop = asyncio.get_running_loop()
    transport, _ = await loop.create_datagram_endpoint(
        AudioRelay, local_addr=(host or "0.0.0.0", port)
    )
    return transport
