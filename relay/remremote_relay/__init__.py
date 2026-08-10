"""remremote relay server.

A single-process asyncio relay that is wire-compatible with NVDA Remote / TeleNVDA over
its TLS control channel, and additionally relays the remremote audio stream over UDP so
that peers which cannot reach each other directly (no port forwarding) still get audio.

Two independent listeners share the process:

* :func:`ControlRelay` — TLS + newline-delimited JSON, multi-channel, faithful to the
  NVDA Remote relay protocol (protocol_version, join, generate_key, channel_joined,
  client_joined/left, motd, ping, and origin/clients/client fields gated on
  protocol_version > 1). Stock NVDA Remote clients work unchanged.

* :func:`AudioRelay` — a deliberately dumb UDP packet reflector. It never decrypts or
  parses RemSound audio; it only pairs two endpoints that register the same opaque
  session id and forwards their datagrams verbatim, preserving end-to-end encryption.
"""

__version__ = "1.0.0"
