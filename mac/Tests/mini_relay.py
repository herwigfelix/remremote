#!/usr/bin/env python3
"""A minimal NVDA-Remote-compatible relay for the live integration test.

Speaks just enough of the protocol for LiveRelayTests: TLS with the add-on's
self-signed server.pem, newline-delimited JSON, join/channel_joined/client_joined/
client_left, and forwarding of everything else to the other members of the channel.

Usage: mini_relay.py <port> <path-to-server.pem>
"""

import json
import selectors
import socket
import ssl
import sys


def main():
    port = int(sys.argv[1])
    pem = sys.argv[2]

    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(pem)

    listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    listener.bind(("127.0.0.1", port))
    listener.listen(5)

    selector = selectors.DefaultSelector()
    selector.register(listener, selectors.EVENT_READ)

    clients = {}  # sock -> {"id": int, "channel": str|None, "type": str|None, "buf": bytes}
    next_id = [1]

    def send(sock, obj):
        try:
            sock.sendall(json.dumps(obj).encode() + b"\n")
        except OSError:
            pass

    def peers(sock):
        channel = clients[sock]["channel"]
        return [s for s, c in clients.items() if s is not sock and c["channel"] == channel and channel]

    def drop(sock):
        info = clients.pop(sock, None)
        selector.unregister(sock)
        try:
            sock.close()
        except OSError:
            pass
        if info and info["channel"]:
            for peer in [s for s, c in clients.items() if c["channel"] == info["channel"]]:
                send(peer, {"type": "client_left", "client": info["id"]})

    def handle(sock, line):
        try:
            msg = json.loads(line)
        except ValueError:
            return
        kind = msg.get("type")
        if kind == "protocol_version":
            return
        if kind == "join":
            clients[sock]["channel"] = msg.get("channel")
            clients[sock]["type"] = msg.get("connection_type")
            others = peers(sock)
            send(sock, {
                "type": "channel_joined",
                "channel": msg.get("channel"),
                "origin": clients[sock]["id"],
                "clients": [{"id": clients[s]["id"], "connection_type": clients[s]["type"]} for s in others],
            })
            for peer in others:
                send(peer, {"type": "client_joined", "client": {
                    "id": clients[sock]["id"], "connection_type": clients[sock]["type"]}})
            return
        msg["origin"] = clients[sock]["id"]
        for peer in peers(sock):
            send(peer, msg)

    print("ready", flush=True)
    while True:
        for key, _ in selector.select(timeout=1):
            if key.fileobj is listener:
                raw, _ = listener.accept()
                try:
                    tls = context.wrap_socket(raw, server_side=True)
                except (ssl.SSLError, OSError):
                    continue
                tls.setblocking(False)
                clients[tls] = {"id": next_id[0], "channel": None, "type": None, "buf": b""}
                next_id[0] += 1
                selector.register(tls, selectors.EVENT_READ)
                continue
            sock = key.fileobj
            try:
                data = sock.recv(16384)
            except (ssl.SSLWantReadError, ssl.SSLWantWriteError):
                continue
            except OSError:
                drop(sock)
                continue
            if not data:
                drop(sock)
                continue
            clients[sock]["buf"] += data
            while b"\n" in clients[sock]["buf"]:
                line, _, rest = clients[sock]["buf"].partition(b"\n")
                clients[sock]["buf"] = rest
                handle(sock, line)


if __name__ == "__main__":
    main()
