# remremote relay

A relay server for remremote / NVDA Remote / TeleNVDA. It does two things in one process:

* **Control relay (TCP + TLS, port 6837).** Wire-compatible with the NVDA Remote relay
  protocol — multi-channel, `protocol_version`/`join`/`generate_key`, `channel_joined`,
  `client_joined`/`client_left`, `motd`, `ping`, and the protocol-2 `origin`/`clients`/
  `client` fields gated so protocol-1 (stock NVDA Remote) clients still work.

* **Audio relay (UDP, port 6837).** A deliberately dumb packet reflector so peers that
  can't connect directly still get remremote's audio stream. It never holds the session
  password, never decrypts, never parses RemSound packets — it only pairs two endpoints
  that register the same opaque 32-byte session id and forwards their datagrams verbatim.
  End-to-end encryption (AES-256-GCM) is preserved; the relay is blind to the audio.

Pure Python standard library — no third-party dependencies.

## Run

```
REMREMOTE_TLS_CERT=/path/fullchain.pem \
REMREMOTE_TLS_KEY=/path/privkey.pem \
REMREMOTE_PORT=6837 \
python3 -m remremote_relay
```

### Environment

| Variable | Default | Meaning |
|---|---|---|
| `REMREMOTE_TLS_CERT` | — (required) | Certificate / fullchain PEM |
| `REMREMOTE_TLS_KEY` | — | Private key PEM (omit if combined into the cert) |
| `REMREMOTE_PORT` | `6837` | TCP control port and UDP audio port |
| `REMREMOTE_UDP_PORT` | = `REMREMOTE_PORT` | Override the UDP audio port |
| `REMREMOTE_BIND` | all interfaces | Bind address |
| `REMREMOTE_MOTD` | none | Message of the day shown on join |
| `REMREMOTE_MOTD_FORCE` | `0` | `1` = force display every time |
| `REMREMOTE_LOG_LEVEL` | `INFO` | Log level |

## Docker

`docker compose up -d --build` — see `deploy/README.md` for the full deployment
(DNS, Let's Encrypt via the Apache webroot, retiring the old server).

## How the audio relay pairs peers

The two peers learn the relay's address from their control connection (they are both
connected to it) and a shared random `audio_session` id that the controlling side sends
over the encrypted control channel in `audio_start`. Each peer sends a registration
datagram (`RRLY` + version + the 32-byte session id) to the relay's UDP port, repeated as
a keepalive. The relay pairs the two endpoints that share a session id and forwards
everything else between them untouched. Because the id is opaque and the payload stays
encrypted, the relay cannot correlate a session to a channel or hear its audio.
