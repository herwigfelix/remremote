#!/usr/bin/env python3
"""A minimal remremote control-channel peer for driving audio tests without a second NVDA.

Speaks just enough of the NVDA Remote / TeleNVDA protocol: TLS, newline-delimited JSON,
protocol_version, join, the TeleNVDA encryption layer (AES-GCM, 16-byte nonce, key =
SHA-256 of the encryption key), and remremote's audio handshake.

  master: joins as the controlling side, tells the peer we are Windows, then asks for its
          audio (audio_start) and prints the reply. Pair it with
          `remremote-audio-cli recv` pointed at the peer (mode "host") or the relay
          (mode "relay", same --audio-session).
  slave:  joins as the controlled side and answers audio_start with audio_started
          {mode: "relay"}; pair it with `remremote-audio-cli send` registered at the
          relay with the audio_session it prints.

Every message seen is printed as a JSON line. Needs the `cryptography` package.
"""

import argparse
import base64
import hashlib
import json
import os
import socket
import ssl
import sys
import threading
import time

from cryptography.hazmat.primitives.ciphers.aead import AESGCM

EXCLUDED_FROM_ENCRYPTION = {
    "join", "protocol_version", "encrypted", "channel_joined", "motd", "nvda_not_connected",
    "client_left", "ping", "error", "client_joined", "generate_key",
}


class Peer:
    def __init__(self, host, port, channel, encryption_key, connection_type):
        self.address = (host, port)
        self.channel = channel
        self.key = hashlib.sha256(encryption_key.encode()).digest() if encryption_key else None
        self.connection_type = connection_type
        self.sock = None
        self.lock = threading.Lock()
        self.events = []
        self.condition = threading.Condition()

    def connect(self):
        raw = socket.create_connection(self.address, timeout=10)
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE
        self.sock = ctx.wrap_socket(raw, server_hostname=self.address[0])
        self.sock.settimeout(None)
        threading.Thread(target=self._reader, daemon=True).start()
        self.send("protocol_version", version=2)
        self.send("join", channel=self.channel, connection_type=self.connection_type)

    def send(self, type, **fields):
        obj = dict(fields, type=type)
        if self.key is not None and type not in EXCLUDED_FROM_ENCRYPTION:
            nonce = os.urandom(16)
            sealed = AESGCM(self.key).encrypt(nonce, json.dumps(obj).encode(), None)
            obj = {
                "type": "encrypted",
                "nonce": base64.b64encode(nonce).decode(),
                "data": base64.b64encode(sealed[:-16]).decode(),
                "tag": base64.b64encode(sealed[-16:]).decode(),
            }
        with self.lock:
            self.sock.sendall(json.dumps(obj).encode() + b"\n")
        print(json.dumps({"sent": type, **fields}), flush=True)

    def _reader(self):
        buf = b""
        while True:
            try:
                chunk = self.sock.recv(65536)
            except OSError:
                chunk = b""
            if not chunk:
                self._push({"type": "_closed"})
                return
            buf += chunk
            while b"\n" in buf:
                line, buf = buf.split(b"\n", 1)
                if line.strip():
                    self._handle(line)

    def _handle(self, line):
        try:
            obj = json.loads(line)
        except ValueError:
            return
        if obj.get("type") == "encrypted" and self.key is not None:
            try:
                nonce = base64.b64decode(obj["nonce"])
                data = base64.b64decode(obj["data"]) + base64.b64decode(obj["tag"])
                obj = json.loads(AESGCM(self.key).decrypt(nonce, data, None))
            except Exception as error:  # noqa: BLE001
                obj = {"type": "_undecryptable", "error": str(error)}
        self._push(obj)

    def _push(self, obj):
        if obj.get("type") == "ping":
            return
        print(json.dumps(obj)[:400], flush=True)
        with self.condition:
            self.events.append(obj)
            self.condition.notify_all()

    def wait_for(self, type, timeout):
        deadline = time.time() + timeout
        with self.condition:
            while True:
                for event in self.events:
                    if event.get("type") == type:
                        return event
                remaining = deadline - time.time()
                if remaining <= 0:
                    return None
                self.condition.wait(remaining)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("role", choices=["master", "slave"])
    parser.add_argument("--host", required=True)
    parser.add_argument("--port", type=int, default=6837)
    parser.add_argument("--channel", required=True, help="the channel / connection key")
    parser.add_argument("--encryption-key", default="", help="TeleNVDA encryption key (optional)")
    parser.add_argument("--audio-session", help="master: base64 32-byte relay session id to offer")
    parser.add_argument("--master-hosting", action="store_true", help="master: claim to host the connection on --hosting-port")
    parser.add_argument("--hosting-port", type=int, default=0)
    parser.add_argument("--remote-tts", action="store_true", help="master: ask for the slave's own synthesizer in the stream")
    parser.add_argument("--seconds", type=int, default=30, help="how long to keep the session up")
    parser.add_argument("--keys", default="", help="master: comma-separated vk codes to press once audio runs (e.g. 0x2D+0x54 for NVDA+T)")
    args = parser.parse_args()

    peer = Peer(args.host, args.port, args.channel, args.encryption_key, args.role)
    peer.connect()
    if peer.wait_for("channel_joined", 15) is None:
        print("no channel_joined", file=sys.stderr)
        sys.exit(2)
    peer.send("remremote_os", os="windows")

    if args.role == "master":
        if not [e for e in peer.events if e.get("type") == "channel_joined" and e.get("clients")]:
            print("waiting for the controlled computer to join ...", flush=True)
            if peer.wait_for("client_joined", 60) is None:
                print("no client_joined", file=sys.stderr)
                sys.exit(2)
        peer.send("remremote_os", os="windows")
        peer.send("remote_tts", state=args.remote_tts)
        request = {"master_hosting": args.master_hosting, "port": args.hosting_port or None, "remote_tts": args.remote_tts}
        if args.audio_session:
            request["audio_session"] = args.audio_session
        peer.send("audio_start", **request)
        reply = peer.wait_for("audio_started", 15) or peer.wait_for("audio_error", 1)
        if reply is None:
            print("no audio_started / audio_error", file=sys.stderr)
            sys.exit(2)
        for combo in [c for c in args.keys.split(",") if c]:
            time.sleep(2)
            keys = [int(k, 0) for k in combo.split("+")]
            # Insert and the navigation cluster must be sent as extended keys or NVDA sees numpad keys.
            extended = {0x2D, 0x2E, 0x24, 0x23, 0x21, 0x22, 0x25, 0x26, 0x27, 0x28}
            for vk in keys:
                peer.send("key", vk_code=vk, extended=vk in extended, pressed=True, scan_code=0)
            for vk in reversed(keys):
                peer.send("key", vk_code=vk, extended=vk in extended, pressed=False, scan_code=0)
        time.sleep(args.seconds)
        peer.send("audio_stop")
        time.sleep(1)
    else:
        session = args.audio_session
        deadline = time.time() + args.seconds
        # The controlling computer only asks for audio on a gesture there or when we offer
        # ours; offer it, which makes it run the normal audio_start handshake.
        time.sleep(2)
        peer.send("audio_offer")
        while time.time() < deadline:
            event = peer.wait_for("audio_start", deadline - time.time())
            if event is None:
                break
            peer.events.remove(event)
            session = event.get("audio_session") or session
            print(json.dumps({"relay_session": session}), flush=True)
            peer.send("audio_started", mode="relay", port=args.port, remote_tts=bool(event.get("remote_tts")))
            stop = peer.wait_for("audio_stop", deadline - time.time())
            if stop is not None:
                peer.events.remove(stop)


if __name__ == "__main__":
    main()
