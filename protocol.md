# NVDA Remote Protocol Documentation

## Overview

The NVDA Remote protocol facilitates communication between two NVDA instances, enabling remote assistance and collaboration. It uses a client-server model where either client can act as the controlling (master) or controlled (slave) machine.

## Connection Establishment

1. Clients connect to a relay server using a TCP connection over SSL/TLS.
2. Clients authenticate by joining a shared channel.
3. The relay server facilitates message passing between connected clients.

## Message Format

Messages are serialized as JSON objects with a 'type' field indicating the message type. Each message is terminated with a newline character ('\n').

## Protocol Version Negotiation

1. Upon connection, the client sends a `protocol_version` message.
2. If versions are incompatible, an error is sent and the connection is closed.

## Message Types

Below is a detailed specification of each message type using JSONSchema:

### Connection Setup

```json
{
  "$schema": "http://json-schema.org/draft-07/schema#",
  "definitions": {
    "protocol_version": {
      "type": "object",
      "properties": {
        "type": { "const": "protocol_version" },
        "version": { "type": "integer" }
      },
      "required": ["type", "version"]
    },
    "join": {
      "type": "object",
      "properties": {
        "type": { "const": "join" },
        "channel": { "type": "string" },
        "connection_type": { "enum": ["master", "slave"] }
      },
      "required": ["type", "channel", "connection_type"]
    },
    "channel_joined": {
      "type": "object",
      "properties": {
        "type": { "const": "channel_joined" },
        "channel": { "type": "string" },
        "clients": {
          "type": "array",
          "items": {
            "type": "object",
            "properties": {
              "id": { "type": "integer" },
              "connection_type": { "enum": ["master", "slave"] }
            },
            "required": ["id", "connection_type"]
          }
        }
      },
      "required": ["type", "channel", "clients"]
    },
    "client_joined": {
      "type": "object",
      "properties": {
        "type": { "const": "client_joined" },
        "client": {
          "type": "object",
          "properties": {
            "id": { "type": "integer" },
            "connection_type": { "enum": ["master", "slave"] }
          },
          "required": ["id", "connection_type"]
        }
      },
      "required": ["type", "client"]
    },
    "client_left": {
      "type": "object",
      "properties": {
        "type": { "const": "client_left" },
        "client": { "type": "integer" }
      },
      "required": ["type", "client"]
    }
  }
}
```

### Control Messages

```json
{
  "$schema": "http://json-schema.org/draft-07/schema#",
  "definitions": {
    "key": {
      "type": "object",
      "properties": {
        "type": { "const": "key" },
        "vk_code": { "type": "integer" },
        "scan_code": { "type": "integer" },
        "extended": { "type": "boolean" },
        "pressed": { "type": "boolean" }
      },
      "required": ["type", "vk_code", "scan_code", "extended", "pressed"]
    },
    "speak": {
      "type": "object",
      "properties": {
        "type": { "const": "speak" },
        "sequence": {
          "type": "array",
          "items": {
            "oneOf": [
              { "type": "string" },
              {
                "type": "array",
                "items": [
                  { "type": "string" },
                  { "type": "object" }
                ],
                "minItems": 2,
                "maxItems": 2
              }
            ]
          }
        },
        "priority": { "type": "string" }
      },
      "required": ["type", "sequence", "priority"]
    },
    "cancel": {
      "type": "object",
      "properties": {
        "type": { "const": "cancel" }
      },
      "required": ["type"]
    },
    "pause_speech": {
      "type": "object",
      "properties": {
        "type": { "const": "pause_speech" },
        "switch": { "type": "boolean" }
      },
      "required": ["type", "switch"]
    },
    "tone": {
      "type": "object",
      "properties": {
        "type": { "const": "tone" },
        "hz": { "type": "number" },
        "length": { "type": "number" },
        "left": { "type": "number" },
        "right": { "type": "number" }
      },
      "required": ["type", "hz", "length", "left", "right"]
    },
    "wave": {
      "type": "object",
      "properties": {
        "type": { "const": "wave" },
        "fileName": { "type": "string" },
        "asynchronous": { "type": "boolean" }
      },
      "required": ["type", "fileName"]
    },
    "display": {
      "type": "object",
      "properties": {
        "type": { "const": "display" },
        "cells": { "type": "array", "items": { "type": "integer" } }
      },
      "required": ["type", "cells"]
    },
    "braille_input": {
      "type": "object",
      "properties": {
        "type": { "const": "braille_input" },
        "dots": { "type": "integer" },
        "space": { "type": "boolean" },
        "routingIndex": { "type": "integer" }
      },
      "required": ["type"]
    },
    "set_clipboard_text": {
      "type": "object",
      "properties": {
        "type": { "const": "set_clipboard_text" },
        "text": { "type": "string" }
      },
      "required": ["type", "text"]
    },
    "send_SAS": {
      "type": "object",
      "properties": {
        "type": { "const": "send_SAS" }
      },
      "required": ["type"]
    }
  }
}
```

### Braille Support

```json
{
  "$schema": "http://json-schema.org/draft-07/schema#",
  "definitions": {
    "set_braille_info": {
      "type": "object",
      "properties": {
        "type": { "const": "set_braille_info" },
        "name": { "type": "string" },
        "numCells": { "type": "integer" }
      },
      "required": ["type", "name", "numCells"]
    },
    "set_display_size": {
      "type": "object",
      "properties": {
        "type": { "const": "set_display_size" },
        "sizes": { "type": "array", "items": { "type": "integer" } }
      },
      "required": ["type", "sizes"]
    }
  }
}
```

### Miscellaneous

```json
{
  "$schema": "http://json-schema.org/draft-07/schema#",
  "definitions": {
    "ping": {
      "type": "object",
      "properties": {
        "type": { "const": "ping" }
      },
      "required": ["type"]
    },
    "error": {
      "type": "object",
      "properties": {
        "type": { "const": "error" },
        "message": { "type": "string" }
      },
      "required": ["type", "message"]
    }
  }
}
```

### Audio streaming (remremote extension)

These messages negotiate streaming the slave's system audio to the master. The audio
itself never travels over this channel: it flows over a separate UDP stream in the
RemSound wire format (Opus frames, AES-256-GCM sealed with a key derived from the
connection's encryption key, or the channel key when no encryption key is set), handled
by remremote's audio engine (the Rust library in [remremote-audio](https://github.com/herwigfelix/remremote-audio), loaded into NVDA; the Mac app
has its own implementation). The side that runs the control server binds
the UDP audio port using the same port number as the TCP control server, so only one
port ever needs forwarding. Peers that do not implement this extension simply ignore
`audio_start` and `audio_offer`; the asking side reports a timeout.

When neither peer hosts the control server (a relayed session), the audio travels through
the relay too. The relay runs a deliberately dumb UDP reflector on the same port as its
TCP control port: each side registers an opaque 32-byte session id (`audio_session`,
generated by the master and carried in `audio_start`) and the relay forwards the two
registered endpoints' datagrams to each other verbatim. It never holds the password,
never decrypts, and never parses RemSound packets, so the audio stays end-to-end
encrypted. Both the Windows engine and the macOS app register natively. Registration
packets are `b"RRLY" | version(1) | session_id(32)`, repeated ~every 2 s as a keepalive.

The switch belongs to the slave — it is that machine's own audio being shared — and both
users may operate it. The master's toggle is a request (`audio_start` / `audio_stop`).
The slave's own toggle sends `audio_offer`, which makes the master run the same
`audio_start` handshake it would have run had its own user asked, or `audio_stopped` when
the slave takes its audio back. Everything therefore goes through one negotiation path:
only the master knows whether it hosts the connection, and that is what decides which
side binds the UDP port.

```json
{
  "$schema": "http://json-schema.org/draft-07/schema#",
  "definitions": {
    "audio_start": {
      "description": "Master asks the slave to start streaming its audio (minus the NVDA process tree, unless remote_tts is true).",
      "type": "object",
      "properties": {
        "type": { "const": "audio_start" },
        "master_hosting": { "type": "boolean" },
        "port": { "type": ["integer", "null"], "description": "The master's control-server port when master_hosting is true." },
        "remote_tts": { "type": "boolean", "description": "Keep NVDA IN the captured audio and stop forwarding speech as text, so the master hears the slave's own synthesizer. Absent from older masters; treat as false." },
        "audio_session": { "type": "string", "description": "Base64 of a random 32-byte id used to pair the two ends at the relay when neither hosts (a relayed session). Absent from older masters, which cannot relay audio." }
      },
      "required": ["type", "master_hosting"]
    },
    "audio_started": {
      "description": "Slave confirms it is streaming. mode=connect: the slave streams at the master's UDP port. mode=host: the slave bound its own UDP port and waits for the master's sealed hello packets. mode=relay: neither side hosts, so both reach the relay and pair on audio_session.",
      "type": "object",
      "properties": {
        "type": { "const": "audio_started" },
        "mode": { "enum": ["connect", "host", "relay"] },
        "port": { "type": "integer" },
        "remote_tts": { "type": "boolean", "description": "What the slave actually did, so the master never claims to hear a voice that is still arriving as text. Absent from older slaves; treat as false." }
      },
      "required": ["type", "mode", "port"]
    },
    "audio_error": {
      "type": "object",
      "properties": {
        "type": { "const": "audio_error" },
        "reason": { "enum": ["relay_unsupported", "host_start_failed", "dotnet_missing"], "description": "relay_unsupported now only occurs when neither side hosts and the master is too old to offer a relayed audio session. dotnet_missing is only ever sent by remremote versions before 2026.9.10, whose audio helper needed the .NET runtime." }
      },
      "required": ["type", "reason"]
    },
    "audio_stop": {
      "description": "Master tells the slave to stop streaming.",
      "type": "object",
      "properties": {
        "type": { "const": "audio_stop" }
      },
      "required": ["type"]
    },
    "audio_offer": {
      "description": "Slave wants to share its audio: the master answers with the normal audio_start handshake (or ignores it when already streaming).",
      "type": "object",
      "properties": {
        "type": { "const": "audio_offer" }
      },
      "required": ["type"]
    },
    "audio_stopped": {
      "description": "Slave stopped streaming on its own end (user toggle, or its helper died). The master tears its receiver down.",
      "type": "object",
      "properties": {
        "type": { "const": "audio_stopped" }
      },
      "required": ["type"]
    },
    "remote_tts": {
      "description": "Master announces its 'use the slave's own synthesizer' setting. Sent on connect and after every change, on either end.",
      "type": "object",
      "properties": {
        "type": { "const": "remote_tts" },
        "state": { "type": "boolean" }
      },
      "required": ["type", "state"]
    },
    "remote_tts_request": {
      "description": "Slave asks the master to set that setting. The master owns and stores it, applies the request, and announces the result with remote_tts — so only the request ever travels this way and there is no toggle loop.",
      "type": "object",
      "properties": {
        "type": { "const": "remote_tts_request" },
        "state": { "type": "boolean" }
      },
      "required": ["type", "state"]
    }
  }
}
```

Whether the master hears the slave's own synthesizer is a setting of the **master**: it is
that machine's user who decides how they want to listen, and only that machine stores it
(`[audio] use_remote_tts`). Either user may flip it — the slave sends
`remote_tts_request` and adopts the `remote_tts` answer — so both ends always agree
without either having to remember the other's state.

It changes nothing outside a stream. The slave stops forwarding speech, beeps and wave
files only once its sender is confirmed running, and resumes on every exit path (stop,
helper failure, helper death, disconnect). A slave that suppressed text speech without
audio to replace it would be unreadable. Because whether NVDA is part of the captured
audio is fixed when the sender starts, changing the setting mid-stream makes the master
tear the stream down and build it back up.

### Operating-system exchange (remremote extension)

On connecting — and again whenever a client joins — each remremote peer announces its
operating system, so the controlling side can adapt: a Mac controlling another Mac warns
once about the VoiceOver-key clash; a Windows machine controlling a Mac relays the NVDA
key (Insert) as the VoiceOver keys (control+alt → control+option), toggleable in the
add-on options; and controlling any Mac makes audio mandatory (it is the only way to hear
the Mac's screen reader), announced as "macOS does not support this." if a stop is
attempted. Peers that do not implement this extension simply never send it and the far
side keeps its default (non-Mac) behaviour.

```json
{
  "$schema": "http://json-schema.org/draft-07/schema#",
  "definitions": {
    "remremote_os": {
      "type": "object",
      "properties": {
        "type": { "const": "remremote_os" },
        "os": { "enum": ["windows", "macos"] }
      },
      "required": ["type", "os"]
    }
  }
}
```

### Clipboard synchronisation (remremote extension)

While enabled, each side pushes its clipboard to the other whenever it changes, so both
clipboards hold the same text. Text only — other clipboard formats are ignored. The
toggle is shared state: either side may flip it, and the peer adopts the same state
without echoing it back (which would ping-pong the toggle). Text updates are capped at
100000 characters so a huge paste cannot stall speech and braille behind it on the shared
control channel. Peers that do not implement this extension ignore both messages, so the
toggle simply has no effect on the far side.

```json
{
  "$schema": "http://json-schema.org/draft-07/schema#",
  "definitions": {
    "clipboard_sync": {
      "description": "Turn clipboard synchronisation on or off. Applied by the peer verbatim; never echoed back.",
      "type": "object",
      "properties": {
        "type": { "const": "clipboard_sync" },
        "state": { "type": "boolean" }
      },
      "required": ["type", "state"]
    },
    "clipboard_sync_text": {
      "description": "New clipboard text to apply. Ignored when the receiver has synchronisation off, or when the text matches what it last sent or applied (echo suppression).",
      "type": "object",
      "properties": {
        "type": { "const": "clipboard_sync_text" },
        "text": { "type": "string" }
      },
      "required": ["type", "text"]
    }
  }
}
```

## Security Considerations

- All connections are encrypted using SSL/TLS.
- Clients can verify the server's certificate fingerprint to prevent man-in-the-middle attacks.
- The channel key acts as a shared secret for authentication.

## Error Handling

- Connection errors trigger automatic reconnection attempts.
- Protocol errors are communicated using the `error` message type.

This protocol documentation provides a high-level overview of the NVDA Remote functionality. For detailed implementation, refer to the source code files, particularly `transport.py`, `session.py`, and `serializer.py`.
