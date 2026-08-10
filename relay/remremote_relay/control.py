"""The TLS control relay — the NVDA Remote / TeleNVDA relay protocol.

Clients connect with TLS, send a ``protocol_version`` then ``join`` a channel (any
string key). Everyone in the same channel is grouped; once a client is authenticated,
every message it sends is forwarded verbatim to the other members of its channel, with
an ``origin`` field added. This mirrors the reference server so stock NVDA Remote clients
interoperate unchanged.
"""

import asyncio
import json
import logging
import random
import ssl
from typing import Dict, Optional, Set

log = logging.getLogger("remremote.control")

#: How often the server pings every authenticated client (seconds), matching the
#: reference relay. Keeps NAT mappings and dead-peer detection alive.
PING_INTERVAL = 300


class Client:
    _next_id = 0

    def __init__(self, relay: "ControlRelay", reader: asyncio.StreamReader, writer: asyncio.StreamWriter):
        Client._next_id += 1
        self.id = Client._next_id
        self.relay = relay
        self.reader = reader
        self.writer = writer
        self.buffer = b""
        self.authenticated = False
        self.channel: Optional[str] = None
        self.connection_type: Optional[str] = None
        self.protocol_version = 1
        peer = writer.get_extra_info("peername")
        self.addr = peer[0] if peer else "?"

    def as_dict(self) -> dict:
        return {"id": self.id, "connection_type": self.connection_type}

    # --- receiving ---

    async def serve(self):
        try:
            while True:
                data = await self.reader.read(16384)
                if not data:
                    break
                self.buffer += data
                if b"\n" not in self.buffer:
                    continue
                while b"\n" in self.buffer:
                    line, _, self.buffer = self.buffer.partition(b"\n")
                    if line:
                        self.parse(line)
        except (ConnectionError, ssl.SSLError, asyncio.IncompleteReadError):
            pass
        except Exception:
            log.exception("client %s read loop failed", self.id)
        finally:
            await self.relay.remove(self)

    def parse(self, line: bytes):
        try:
            message = json.loads(line)
        except ValueError:
            raise ConnectionError("invalid JSON")
        if not isinstance(message, dict) or "type" not in message:
            return
        if self.authenticated:
            # Everything an authenticated client sends is relayed to its channel peers.
            self.relay.send_to_others(self, **message)
            return
        handler = getattr(self, "do_" + str(message["type"]), None)
        if handler is not None:
            handler(message)

    # --- pre-authentication handlers ---

    def do_protocol_version(self, message: dict):
        version = message.get("version")
        if isinstance(version, int):
            self.protocol_version = version

    def do_join(self, message: dict):
        channel = message.get("channel")
        if not isinstance(channel, str) or not channel:
            self.send(type="error", message="invalid_parameters")
            return
        self.channel = channel
        self.connection_type = message.get("connection_type")
        self.authenticated = True
        peers = self.relay.join(self)
        self.send(
            type="channel_joined",
            channel=channel,
            user_ids=[c.id for c in peers],
            clients=[c.as_dict() for c in peers],
        )
        self.relay.send_to_others(self, type="client_joined", user_id=self.id, client=self.as_dict())
        if self.relay.motd:
            self.send(type="motd", motd=self.relay.motd, force_display=self.relay.motd_force_display)
        log.info("client %s (%s) joined a channel (%d in channel)", self.id, self.connection_type, len(peers) + 1)

    def do_generate_key(self, message: dict):
        # Only meaningful before joining a channel.
        if self.authenticated:
            return
        self.send(type="generate_key", key=self.relay.generate_key())

    # --- sending ---

    def send(self, type: str, origin: Optional[int] = None, clients=None, client=None, **kwargs):
        payload = dict(type=type, **kwargs)
        # Fields introduced in protocol 2 must not be sent to protocol 1 clients.
        if self.protocol_version > 1:
            if origin is not None:
                payload["origin"] = origin
            if clients is not None:
                payload["clients"] = clients
            if client is not None:
                payload["client"] = client
        try:
            self.writer.write((json.dumps(payload) + "\n").encode("utf-8"))
        except Exception:
            pass

    async def close(self):
        try:
            self.writer.close()
            await self.writer.wait_closed()
        except Exception:
            pass


class ControlRelay:
    def __init__(self, cert_provider, host: str = "", port: int = 6837,
                 motd: str = "", motd_force_display: bool = False):
        self.cert_provider = cert_provider
        self.host = host
        self.port = port
        self.motd = motd
        self.motd_force_display = motd_force_display
        #: channel key -> set of authenticated clients
        self.channels: Dict[str, Set[Client]] = {}
        self._server: Optional[asyncio.AbstractServer] = None

    # --- membership ---

    def join(self, client: Client) -> Set[Client]:
        """Add a client to its channel; return the peers already present."""
        members = self.channels.setdefault(client.channel, set())
        peers = set(members)
        members.add(client)
        return peers

    async def remove(self, client: Client):
        if client.channel is not None:
            members = self.channels.get(client.channel)
            if members and client in members:
                members.discard(client)
                if client.authenticated:
                    self.send_to_others(client, type="client_left", user_id=client.id, client=client.as_dict())
                if not members:
                    del self.channels[client.channel]
        await client.close()
        if client.authenticated:
            log.info("client %s disconnected", client.id)

    def send_to_others(self, sender: Client, origin: Optional[int] = None, **message):
        if sender.channel is None:
            return
        if origin is None:
            origin = sender.id
        for peer in list(self.channels.get(sender.channel, ())):
            if peer is not sender and peer.authenticated:
                peer.send(origin=origin, **message)

    def generate_key(self) -> str:
        active = set(self.channels.keys())
        while True:
            key = "".join(random.choice("0123456789") for _ in range(7))
            if key not in active:
                return key

    # --- lifecycle ---

    async def start(self):
        context = self.cert_provider.context
        self._server = await asyncio.start_server(
            self._handle_connection, host=self.host or None, port=self.port, ssl=context
        )
        sockets = ", ".join(str(s.getsockname()) for s in self._server.sockets or [])
        log.info("control relay listening on %s (TLS)", sockets)
        asyncio.create_task(self._ping_loop())

    async def _handle_connection(self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter):
        client = Client(self, reader, writer)
        await client.serve()

    async def _ping_loop(self):
        while True:
            await asyncio.sleep(PING_INTERVAL)
            for members in list(self.channels.values()):
                for client in list(members):
                    if client.authenticated:
                        client.send(type="ping")
