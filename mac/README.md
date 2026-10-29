# remremote for macOS

A native Swift app that connects to a computer running NVDA with the remremote add-on
(or TeleNVDA / NVDA Remote for the base features) and controls it from a Mac. It can also
take the controlled (slave) role over a relay, so a Mac can be assisted from Windows.

## Features

* **Control connection** compatible with NVDA Remote / TeleNVDA / remremote relay and
  direct-connection servers: TLS with certificate-fingerprint pinning for self-signed
  servers, optional AES-256-GCM session encryption (TeleNVDA "encryption password"),
  channel keys, MOTD handling.
* **Known computers in the macOS keychain.** Saved computers keep their channel key and
  encryption password as keychain items; only name/host/port live outside it.
* **F10 takes and releases control** (fn+F10 on Macs where F10 is a media key —
  whichever combination produces a real F10 key press). Only a *bare* F10 toggles:
  shift+F10 and every other modified F10 stays an ordinary combination and is forwarded
  like any other key. While controlling, all keys are captured and sent to the remote
  machine; releasing control releases any keys still held remotely.
* **NVDA key on Mac keyboards**: by default, holding Command+Option together acts as
  the NVDA key (Insert), since most Mac keyboards have none. Toggleable in the settings;
  a real Insert/Help key always works. Otherwise Command is the Windows key, Option is
  Alt, Control is Ctrl — the mapping is positional, so keep both keyboard layouts the
  same, as the manual already advises for Windows-to-Windows sessions.
* **Speech output selectable in the settings**: VoiceOver announcements (default; note
  the warning — VoiceOver honours neither interrupts nor pitch changes from the remote
  machine), or a direct TTS voice with rate and pitch, which fully honours cancel
  messages and pitch commands (e.g. capitals).
* **Remote audio streaming**: asks the controlled computer to stream its system audio
  (Opus over UDP, AES-256-GCM, RemSound wire format) and plays it with a small jitter
  buffer. The "use the remote computer's own speech synthesizer" option works exactly
  as on Windows — the Mac owns the setting, either side may flip it.
* **Clipboard sync** (text, both directions, 100 000-character cap) and one-shot
  "push clipboard" — in either role, so they work while this Mac is the controlled
  machine too.
* **File transfer**, the NVDA Remote way: "Send file…" picks a file and delivers it in a
  single control message (10 MB cap); an arriving file opens a save panel. Both roles.
* **Beeps** ("tone" messages) are synthesized locally; the add-on's connection sounds
  are bundled.
* **German and English**, following the system language; anything else falls back to
  English.

## Limitations

* The app does not host a control server, so a direct (non-relayed) connection has to be
  hosted by the other computer. Letting this Mac be controlled works over a relay only.
* No braille yet. The app announces a zero-cell display, so the controlled machine
  sends no braille data.
* `wave` messages (NVDA sound files) reference files on the controlled machine and are
  ignored.

## Building

Requires Xcode 16+ (the committed project) — or [XcodeGen](https://github.com/yonaskolb/XcodeGen)
to regenerate `remremote.xcodeproj` from `project.yml` after adding files:

```
cd mac
xcodegen generate   # only when project.yml or the file list changed
xcodebuild -project remremote.xcodeproj -scheme RemRemote build
```

Dependencies (resolved by Xcode via SPM): [swift-opus](https://github.com/alta/swift-opus)
(libopus, for the audio stream) and [CryptoSwift](https://github.com/krzyzanowskim/CryptoSwift)
(only for the control channel's AES-GCM layer, whose 16-byte nonces CryptoKit cannot
process).

The app is not sandboxed: the global key capture (CGEvent tap) requires it. On first
connection, grant the accessibility permission in System Settings → Privacy & Security →
Accessibility.

## Tests

```
xcodebuild -project remremote.xcodeproj -scheme RemRemote test
```

runs the interop tests: PBKDF2 vectors shared with the Windows/Apple RemSound
implementations, decryption of a message actually produced by PyCryptodome, RemSound
packet parsing, key map and speech-sequence checks.

An optional end-to-end test drives two transports through a real relay speaking the
wire protocol (TLS handshake against the add-on's self-signed certificate, fingerprint
pinning, join, encrypted round trip):

```
python3 Tests/mini_relay.py 16837 ../addon/globalPlugins/remoteClient/server.pem &
TEST_RUNNER_REMREMOTE_LIVE_TEST=1 xcodebuild -project remremote.xcodeproj \
  -scheme RemRemote test -only-testing:RemRemoteTests/LiveRelayTests
```
