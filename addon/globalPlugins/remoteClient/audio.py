"""Remote audio streaming for remremote (TeleNVDA fork).

Streams the controlled (slave) computer's system audio to the controlling (master)
computer, excluding NVDA's own audio on the slave (speech already travels over the
control channel — hearing it twice would be useless).

The heavy lifting happens in a bundled .NET helper process, RemSound.Host.exe (see the
RemSound project: WASAPI process-loopback capture, Opus, AES-256-GCM over UDP). This
module only manages that subprocess (JSON lines over stdin/stdout) and the control-channel
handshake:

	master --> slave:  audio_start {master_hosting: bool, port: int|None}
	slave  --> master: audio_started {mode: "connect"|"host", port: int}
	slave  --> master: audio_error {reason: str}
	master --> slave:  audio_stop {}
	slave  --> master: audio_offer {}
	slave  --> master: audio_stopped {}

The switch belongs to the slave: it is that machine's own audio (and its own microphone-
adjacent privacy) being shared, so it may turn streaming on and off itself with the same
gesture, and its state is the truth. The master's gesture is a *request*: audio_start asks
the slave to start, audio_stop asks it to stop. The other direction is the mirror image —
audio_offer means "I want to stream, please ask me for it", which makes the master run the
exact same audio_start handshake it would run had its own user pressed the gesture, and
audio_stopped tells the master to tear its receiver down again. Doing it that way (rather
than the slave streaming unannounced) keeps one negotiation path: only the master knows
whether it hosts the connection, which is what decides who binds the UDP port.

Topology: the side that runs the TeleNVDA control server also owns the UDP audio port,
using the SAME port number as the TCP control server so users only ever forward one port.
The other side reaches out from an ephemeral port; when the receiver is the reaching side
it punches its NAT with sealed hello packets the helper generates (see RemSound.Host).
When neither side hosts (a relayed session), the audio goes through the relay: a local UDP
shim (RelayAudioProxy) registers an opaque session id with the relay and bridges the
unmodified helper, and the relay forwards the two ends' packets verbatim — it never holds
the password or decrypts anything, so the stream stays end-to-end encrypted.

The audio encryption password is the connection's encryption key when set, otherwise the
channel key — both sides always agree on those already.
"""

import base64
import json
import logging
import os
import select
import socket
import subprocess
import threading

import addonHandler
import globalVars
import gui
import ui
import wx

from . import configuration

logger = logging.getLogger(__name__)

try:
	addonHandler.initTranslation()
except addonHandler.AddonError:
	pass

HOST_SUBDIR = "audioHost"
HOST_EXE = "RemSound.Host.exe"
#: How long the master waits for the slave to answer audio_start before assuming the
#: other end doesn't understand the message (stock NVDA Remote / TeleNVDA silently
#: ignores unknown message types).
REPLY_TIMEOUT_MS = 8000
#: How long to wait between tearing a stream down and building it back up when the remote
#: TTS setting changed mid-stream, so the old sender has released the UDP port.
RESTART_DELAY_MS = 900
#: winget package id of the runtime RemSound.Host.exe needs.
WINGET_RUNTIME_ID = "Microsoft.DotNet.DesktopRuntime.10"
#: Evergreen direct-download link (same scheme dotnet-install uses) as a fallback when
#: winget is unavailable or fails.
RUNTIME_DOWNLOAD_URL = "https://aka.ms/dotnet/10.0/windowsdesktop-runtime-win-x64.exe"
#: Exit code the .NET apphost returns when the required framework is missing
#: (0x80008096, seen either sign-extended or raw depending on who reports it).
FRAMEWORK_MISSING_EXIT_CODES = (0x80008096, 0x80008096 - 2**32)


def host_exe_path():
	return os.path.join(os.path.dirname(os.path.abspath(__file__)), HOST_SUBDIR, HOST_EXE)


def runtime_missing():
	"""Cheap filesystem probe for the .NET 10 Desktop Runtime (no subprocess): look for a
	10.x folder under dotnet\\shared\\Microsoft.WindowsDesktop.App in the usual roots."""
	roots = []
	dotnet_root = os.environ.get("DOTNET_ROOT")
	if dotnet_root:
		roots.append(dotnet_root)
	program_files = os.environ.get("ProgramFiles")
	if program_files:
		roots.append(os.path.join(program_files, "dotnet"))
	for root in roots:
		shared = os.path.join(root, "shared", "Microsoft.WindowsDesktop.App")
		try:
			entries = os.listdir(shared)
		except OSError:
			continue
		if any(entry.startswith("10.") for entry in entries):
			return False
	return True


#: Registration framing for the dumb UDP relay: magic + version + 32-byte session id.
RELAY_MAGIC = b"RRLY"
RELAY_VERSION = 1
RELAY_REGISTER_INTERVAL = 2.0


class RelayAudioProxy:
    """A tiny local UDP shim so RemSound.Host can stream through the relay unchanged.

    RemSound.Host only knows how to reach a peer directly (connector mode: send to a
    host:port, learn the return path from sealed hellos). The relay, however, needs each
    side to announce an opaque session id so it can pair them. Rather than modify the
    compiled helper, we run this shim in the middle: RemSound.Host talks to us on
    127.0.0.1, we register the session with the relay and forward every packet verbatim
    between RemSound and the relay. End-to-end encryption is untouched — we only move
    bytes.
    """

    def __init__(self):
        self._local_sock = None
        self._relay_sock = None
        self._relay_addr = None
        self._session = None
        self._remote_side = None  # RemSound.Host's (learned) local address
        self._thread = None
        self._running = False

    def start(self, relay_host, relay_port, session_id):
        """Bind the shim and start forwarding; returns the local port RemSound must use."""
        self._session = session_id
        self._relay_addr = (relay_host, int(relay_port))
        self._local_sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self._local_sock.bind(("127.0.0.1", 0))
        self._relay_sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self._relay_sock.bind(("0.0.0.0", 0))
        self._running = True
        self._thread = threading.Thread(target=self._loop, daemon=True, name="remremoteRelayAudioProxy")
        self._thread.start()
        return self._local_sock.getsockname()[1]

    def _registration(self):
        return RELAY_MAGIC + bytes([RELAY_VERSION]) + self._session

    def _loop(self):
        last_register = 0.0
        while self._running:
            # Keep the pairing (and the NAT pinhole) alive.
            now = _monotonic()
            if now - last_register >= RELAY_REGISTER_INTERVAL:
                try:
                    self._relay_sock.sendto(self._registration(), self._relay_addr)
                except OSError:
                    pass
                last_register = now
            try:
                readers, _, _ = select.select([self._local_sock, self._relay_sock], [], [], 0.5)
            except (OSError, ValueError):
                break
            for sock in readers:
                try:
                    data, addr = sock.recvfrom(65536)
                except OSError:
                    continue
                if sock is self._local_sock:
                    # From RemSound.Host → remember where to send replies, forward to relay.
                    self._remote_side = addr
                    try:
                        self._relay_sock.sendto(data, self._relay_addr)
                    except OSError:
                        pass
                else:
                    # From the relay. Drop its registration acks; forward audio to RemSound.
                    if len(data) == 5 + 32 and data[:4] == RELAY_MAGIC:
                        continue
                    if self._remote_side is not None:
                        try:
                            self._local_sock.sendto(data, self._remote_side)
                        except OSError:
                            pass

    def stop(self):
        self._running = False
        for sock in (self._local_sock, self._relay_sock):
            if sock is not None:
                try:
                    sock.close()
                except OSError:
                    pass
        self._local_sock = None
        self._relay_sock = None


def _monotonic():
    import time
    return time.monotonic()


class AudioHostRunner:
	"""Owns one RemSound.Host.exe subprocess: spawn, JSON-line IPC, teardown.

	``on_event`` is called on a background reader thread with each decoded event dict;
	``on_exit`` is called (also on a background thread) with (returncode, stderr_tail)
	when the process ends. Callers marshal to the UI thread themselves.
	"""

	def __init__(self, on_event, on_exit):
		self.on_event = on_event
		self.on_exit = on_exit
		self.proc = None
		self._stderr_tail = []
		self._lock = threading.Lock()
		self.expected_exit = False

	def start(self):
		path = host_exe_path()
		if not os.path.isfile(path):
			raise FileNotFoundError(path)
		startupinfo = subprocess.STARTUPINFO()
		startupinfo.dwFlags |= subprocess.STARTF_USESHOWWINDOW
		self.proc = subprocess.Popen(
			[path],
			stdin=subprocess.PIPE,
			stdout=subprocess.PIPE,
			stderr=subprocess.PIPE,
			cwd=os.path.dirname(path),
			startupinfo=startupinfo,
			creationflags=subprocess.CREATE_NO_WINDOW,
		)
		threading.Thread(target=self._read_stdout, daemon=True, name="remremoteAudioHostReader").start()
		threading.Thread(target=self._read_stderr, daemon=True, name="remremoteAudioHostStderr").start()

	def send(self, **command):
		with self._lock:
			proc = self.proc
			if proc is None or proc.poll() is not None:
				raise OSError("audio host process is not running")
			proc.stdin.write((json.dumps(command) + "\n").encode("utf-8"))
			proc.stdin.flush()

	def stop(self):
		"""Graceful-then-forceful shutdown. Safe to call twice."""
		self.expected_exit = True
		proc = self.proc
		if proc is None:
			return
		try:
			self.send(cmd="quit")
		except OSError:
			pass
		try:
			proc.wait(timeout=2)
		except subprocess.TimeoutExpired:
			try:
				proc.kill()
			except OSError:
				pass
		self.proc = None

	def _read_stdout(self):
		proc = self.proc
		try:
			for line in proc.stdout:
				line = line.strip()
				if not line:
					continue
				try:
					event = json.loads(line.decode("utf-8"))
				except ValueError:
					logger.warning("audio host emitted non-JSON line: %r", line)
					continue
				try:
					self.on_event(event)
				except Exception:
					logger.exception("audio host event handler failed")
		except (OSError, ValueError):
			pass
		code = proc.wait()
		# A stop() we initiated ourselves is not an "unexpected death" — only report exits
		# nobody asked for. Checked here (not in the manager) because the manager drops its
		# runner reference before the process actually finishes quitting.
		if not self.expected_exit:
			self.on_exit(code, "\n".join(self._stderr_tail))

	def _read_stderr(self):
		proc = self.proc
		try:
			for line in proc.stderr:
				text = line.decode("utf-8", errors="replace").strip()
				if text:
					self._stderr_tail.append(text)
					del self._stderr_tail[:-10]
					logger.debug("audio host stderr: %s", text)
		except (OSError, ValueError):
			pass


class AudioManager:
	"""The add-on side of remote audio: handshake over the control channel plus the
	local helper process. One instance lives on the GlobalPlugin for the whole NVDA
	session; per-connection state resets via shutdown()."""

	def __init__(self, plugin):
		self.plugin = plugin
		self.runner = None
		#: True once audio is (being) streamed in either direction.
		self.active = False
		#: Master only: waiting for the slave's audio_started/audio_error reply.
		self.pending = False
		self._pending_timer = None
		#: Slave only: waiting for our local helper's "started" event before answering
		#: the master. Holds the (mode, port) tuple to send.
		self._pending_reply = None
		#: Slave only: we offered our audio and are waiting for the master's audio_start.
		self.offering = False
		#: Slave only: whether the stream currently starting carries our own synthesizer.
		self._pending_remote_tts = False
		#: Slave only: the controlling computer's "use the remote synthesizer" setting,
		#: mirrored. Never stored on this side — only the controller persists it.
		self.remote_tts_peer_state = False
		#: Slave only: False until the controller has told us its setting once, so the
		#: initial sync doesn't announce itself as a change.
		self._remote_tts_synced = False
		#: Slave only: the state we asked the controller for and are waiting on, so its
		#: answer is announced as our own action rather than as the peer's.
		self._remote_tts_requested = None
		#: Master only: pending stream rebuild after the setting changed mid-stream.
		self._restart_timer = None
		#: True while a background .NET runtime installation is in flight.
		self._install_running = False
		#: Local UDP shim bridging RemSound.Host to the relay (relayed sessions only).
		self._relay_proxy = None
		#: Master only: the session id sent in audio_start, reused if the reply is "relay".
		self._audio_session = None

	def _set_active(self, state):
		"""Single place where the streaming state changes, so the menu checkbox always
		follows reality — including when streaming stops because something failed."""
		self.active = state
		self.plugin.update_audio_menu(state)

	# === wiring ===

	def register_master(self, transport):
		transport.callback_manager.register_callback("msg_audio_started", self.on_audio_started)
		transport.callback_manager.register_callback("msg_audio_error", self.on_audio_error)
		transport.callback_manager.register_callback("msg_audio_offer", self.on_audio_offer)
		transport.callback_manager.register_callback("msg_audio_stopped", self.on_audio_stopped)
		# We own the remote-TTS setting; the controlled computer may ask us to flip it.
		transport.callback_manager.register_callback("msg_remote_tts_request", self.on_remote_tts_request)

	def register_slave(self, transport):
		transport.callback_manager.register_callback("msg_audio_start", self.on_audio_start)
		transport.callback_manager.register_callback("msg_audio_stop", self.on_audio_stop)
		transport.callback_manager.register_callback("msg_remote_tts", self.on_remote_tts_state)

	def _password(self, transport):
		return transport.encryption_key or transport.channel

	def _ensure_runner(self):
		if self.runner is not None and self.runner.proc is not None and self.runner.proc.poll() is None:
			return self.runner
		runner = AudioHostRunner(self._on_host_event, self._on_host_exit)
		runner.start()
		self.runner = runner
		return runner

	def _stop_runner(self):
		runner = self.runner
		self.runner = None
		if runner is not None:
			threading.Thread(target=runner.stop, daemon=True).start()
		self._stop_relay_proxy()

	def _stop_relay_proxy(self):
		proxy = self._relay_proxy
		self._relay_proxy = None
		if proxy is not None:
			threading.Thread(target=proxy.stop, daemon=True).start()

	def shutdown(self):
		"""Stop everything without touching the control channel (used on disconnect
		and add-on termination, when the channel may already be gone)."""
		self._cancel_pending_timer()
		self.pending = False
		self._pending_reply = None
		self.offering = False
		self._pending_remote_tts = False
		self._remote_tts_synced = False
		self._remote_tts_requested = None
		self.remote_tts_peer_state = False
		# Whatever happened, this machine speaks to the controller as text again. Leaving
		# the gate shut would make a controlled computer silently unreadable.
		self._set_speech_forwarding(True)
		self._set_active(False)
		self._stop_runner()

	# === toggling (gesture and menu item) ===

	def toggle(self):
		"""Flip audio streaming from whichever end this computer is. Controlling this
		machine's role, not the user's: on the controlling computer the gesture asks the
		other side to stream, on the controlled computer it starts or stops sharing its own
		audio. A machine that is both (chained sessions) is treated as the controller,
		since that is the session its user is actively working in."""
		plugin = self.plugin
		master = plugin.master_transport
		if master is not None and getattr(master, "connected", False):
			self.toggle_from_master()
			return
		slave = plugin.slave_transport
		if slave is not None and getattr(slave, "connected", False):
			self.toggle_from_slave()
			return
		# Translators: reported when trying to toggle remote audio while not connected.
		ui.message(_("Not connected."))

	# === "use the remote computer's own synthesizer" setting ===
	#
	# Owned by the CONTROLLING computer: it is the machine whose user decides how they want
	# to listen, and the only one that stores the setting. Either user may flip it — the
	# controlled computer sends a request and adopts the answer, so both ends always show
	# the same state without either having to trust the other's memory of it.
	#
	# It only ever *does* anything while audio is streaming: the controlled computer keeps
	# NVDA in the captured audio (instead of excluding its process tree) and stops sending
	# its speech as remote messages, so the controller hears the real voice of that machine.
	# Outside a stream nothing is suppressed — a controlled computer that went quiet without
	# audio to replace the text would be unusable.

	def remote_tts_enabled(self):
		"""Our stored preference. Meaningful on the controlling side; on the controlled side
		see remote_tts_peer_state instead."""
		try:
			return bool(configuration.get_config()["audio"]["use_remote_tts"])
		except KeyError:
			return False

	def remote_tts_state(self):
		"""The state to show the user on THIS machine, whichever end it is."""
		if self.plugin.master_transport is None and self.plugin.slave_transport is not None:
			return self.remote_tts_peer_state
		return self.remote_tts_enabled()

	def toggle_remote_tts(self):
		"""The gesture, on either machine."""
		plugin = self.plugin
		master = plugin.master_transport
		if master is not None and getattr(master, "connected", False):
			self.on_remote_tts_setting_changed(not self.remote_tts_enabled())
			return
		slave = plugin.slave_transport
		if slave is not None and getattr(slave, "connected", False):
			# We don't own it: ask, and change nothing until the controller answers.
			wanted = not self.remote_tts_peer_state
			try:
				self._remote_tts_requested = wanted
				slave.send(type="remote_tts_request", state=wanted)
			except (TypeError, OSError):
				self._remote_tts_requested = None
				logger.exception("could not send remote_tts_request")
				# Translators: reported when the remote speech setting could not be sent to the controlling computer.
				ui.message(_("Could not reach the controlling computer."))
			return
		# Not connected. This machine may be the controlling one next time, so let the user
		# set their preference now — it is stored either way.
		self.on_remote_tts_setting_changed(not self.remote_tts_enabled())

	def on_remote_tts_setting_changed(self, state, from_peer=False):
		"""Apply a new value of our own setting: store it, say so, tell the other end, and
		rebuild a running stream so it takes effect immediately. Also called by the settings
		panel after the checkbox was saved."""
		state = bool(state)
		conf = configuration.get_config()
		conf["audio"]["use_remote_tts"] = state
		if not configuration.readonly:
			conf.write()
		self.plugin.update_remote_tts_setting(state)
		self._announce_remote_tts(state, from_peer)
		self.send_remote_tts_state()
		self._reapply_remote_tts()

	def _announce_remote_tts(self, state, from_peer=False):
		if from_peer:
			if state:
				# Translators: reported when the controlled computer turned on using its own synthesizer.
				ui.message(_("Remote speech synthesizer turned on by the other computer"))
			else:
				# Translators: reported when the controlled computer turned off using its own synthesizer.
				ui.message(_("Remote speech synthesizer turned off by the other computer"))
		elif state:
			# Translators: reported when using the remote computer's own synthesizer is turned on.
			ui.message(_("Remote speech synthesizer on"))
		else:
			# Translators: reported when using the remote computer's own synthesizer is turned off.
			ui.message(_("Remote speech synthesizer off"))

	def send_remote_tts_state(self):
		"""Tell the controlled computer where the setting stands. Sent on connect and on
		every change, so it never has to guess before a stream starts."""
		transport = self.plugin.master_transport
		if transport is None or not getattr(transport, "connected", False):
			return
		try:
			transport.send(type="remote_tts", state=self.remote_tts_enabled())
		except (TypeError, OSError):
			logger.exception("could not send the remote TTS state")

	def on_remote_tts_request(self, state=None, **kwargs):
		"""The controlled computer's user pressed the gesture there. We own the setting, so
		we apply it; send_remote_tts_state then echoes the result back to update their
		mirror. Only the request travels that way, so there is no toggle loop."""
		if self.plugin.master_transport is None:
			return
		self.on_remote_tts_setting_changed(state, from_peer=True)

	def on_remote_tts_state(self, state=None, **kwargs):
		"""The controlling computer told us its setting (on connect, or after a change on
		either end). We only mirror it — nothing is stored on this side."""
		state = bool(state)
		changed = self._remote_tts_synced and state != self.remote_tts_peer_state
		# If this is the answer to our own request, it is our own doing — don't tell the
		# user the other computer did what they just asked for themselves.
		ours = self._remote_tts_requested is not None and state == self._remote_tts_requested
		self._remote_tts_requested = None
		self.remote_tts_peer_state = state
		self._remote_tts_synced = True
		self.plugin.update_remote_tts_setting(state)
		if changed or ours:
			self._announce_remote_tts(state, from_peer=not ours)

	def _reapply_remote_tts(self):
		"""Rebuild a running stream. Whether NVDA is part of the captured audio is decided
		when the sender starts, so a change cannot reach a stream that is already running."""
		self._cancel_pending_timer()
		if not (self.active or self.pending):
			return
		if self.plugin.master_transport is None:
			return
		self._stop_from_master(announce=False)
		# Let the stop reach the controlled computer and its helper actually exit before the
		# replacement binds the same UDP port.
		self._restart_timer = wx.CallLater(RESTART_DELAY_MS, self._restart_from_master)

	def _restart_from_master(self):
		self._restart_timer = None
		transport = self.plugin.master_transport
		if transport is None or not getattr(transport, "connected", False):
			return
		self._start_from_master(announce=False)

	def _set_speech_forwarding(self, enabled):
		"""Open or close the controlled machine's text speech channel. A no-op on the
		controlling side, which has no slave session to gate."""
		session = getattr(self.plugin, "slave_session", None)
		setter = getattr(session, "set_speech_forwarding", None)
		if setter is None:
			return
		try:
			setter(enabled)
		except (TypeError, OSError):
			logger.exception("could not change speech forwarding")

	# === master side ===

	def toggle_from_master(self):
		plugin = self.plugin
		transport = plugin.master_transport
		if transport is None or not getattr(transport, "connected", False):
			# Translators: reported when trying to toggle remote audio while not connected.
			ui.message(_("Not connected."))
			return
		if self.active or self.pending:
			self._stop_from_master()
		else:
			self._start_from_master()

	def _start_from_master(self, announce=True):
		plugin = self.plugin
		hosting = plugin.server is not None
		port = plugin.server.port if hosting else None
		self.pending = True
		# A fresh session id for this request. If neither side hosts, the connection is
		# relayed and both ends register this id with the relay so it can pair them.
		self._audio_session = base64.b64encode(os.urandom(32)).decode()
		# remote_tts travels with the request rather than relying on the state we pushed
		# earlier: the controlled computer must know before it starts its sender, and this
		# way the two can never race. Older peers simply ignore the extra field.
		plugin.master_transport.send(
			type="audio_start", master_hosting=hosting, port=port,
			remote_tts=self.remote_tts_enabled(),
			audio_session=self._audio_session,
		)
		self._pending_timer = wx.CallLater(REPLY_TIMEOUT_MS, self._on_reply_timeout)
		if announce:
			# Translators: reported when the user requests audio streaming from the remote computer.
			ui.message(_("Requesting remote audio..."))

	def _stop_from_master(self, announce=True):
		plugin = self.plugin
		self._cancel_pending_timer()
		self.pending = False
		self._set_active(False)
		try:
			plugin.master_transport.send(type="audio_stop")
		except (TypeError, OSError):
			logger.exception("could not send audio_stop")
		self._stop_runner()
		if announce:
			# Translators: reported when remote audio streaming has been turned off.
			ui.message(_("Remote audio off"))

	def _on_reply_timeout(self):
		if not self.pending:
			return
		self.pending = False
		self._stop_runner()
		# Translators: reported when the controlled computer never answered the audio request.
		ui.message(_("No response. The remote computer may not support audio streaming (remremote required on both ends)."))

	def on_audio_started(self, mode=None, port=None, remote_tts=None, **kwargs):
		if not self.pending:
			return
		self.pending = False
		self._cancel_pending_timer()
		plugin = self.plugin
		transport = plugin.master_transport
		if transport is None:
			return
		password = self._password(transport)
		try:
			runner = self._ensure_runner()
			if mode == "connect":
				# We host the connection: bind the UDP twin of our control-server port and
				# let the slave's audio stream find us there.
				runner.send(cmd="start-recv", password=password, bindPort=plugin.server.port)
			elif mode == "relay":
				# Relayed session: both ends meet at the relay (the same host we use for
				# control). A local shim registers our session id and bridges the helper.
				relay_host, relay_port = transport.address
				proxy = RelayAudioProxy()
				shim_port = proxy.start(relay_host, relay_port, base64.b64decode(self._audio_session))
				self._relay_proxy = proxy
				runner.send(cmd="start-recv", password=password, host="127.0.0.1", port=shim_port)
			else:
				# The slave hosts: reach out to its UDP port from an ephemeral port,
				# punching our NAT with sealed hellos.
				runner.send(cmd="start-recv", password=password, host=transport.address[0], port=int(port))
		except (OSError, FileNotFoundError, TypeError, ValueError):
			logger.exception("failed to start local audio receiver")
			if runtime_missing():
				self._offer_runtime_install()
			else:
				# Translators: reported when the local audio receiver could not be started.
				ui.message(_("Could not start the audio receiver. See the NVDA log for details."))
			try:
				transport.send(type="audio_stop")
			except (TypeError, OSError):
				pass
			return
		self._set_active(True)
		# The controlled computer reports what it actually did, so we never claim to be
		# hearing its own voice when it is in fact still sending text (an older remremote
		# there ignores the request and keeps forwarding speech).
		if remote_tts:
			# Translators: reported when remote audio streaming started using the remote computer's own synthesizer.
			ui.message(_("Remote audio on, using the remote computer's speech synthesizer"))
		elif self.remote_tts_enabled():
			# Translators: reported when the remote computer cannot use its own synthesizer for the stream.
			ui.message(_("Remote audio on. The remote computer cannot use its own speech synthesizer, so its speech still arrives as text."))
		else:
			# Translators: reported when remote audio streaming has been turned on.
			ui.message(_("Remote audio on"))

	def on_audio_offer(self, **kwargs):
		"""The controlled computer pressed the gesture on its end and wants to stream. Run
		the normal request handshake so it learns who hosts the UDP side, but stay quiet
		about it — on_audio_started announces the result a moment later either way."""
		plugin = self.plugin
		transport = plugin.master_transport
		if transport is None or not getattr(transport, "connected", False):
			return
		if self.active or self.pending:
			# Already streaming (or already asking): nothing to negotiate.
			return
		self._start_from_master(announce=False)

	def on_audio_stopped(self, **kwargs):
		"""The controlled computer stopped sharing on its own end."""
		if not self.active and not self.pending:
			return
		self._cancel_pending_timer()
		self.pending = False
		self._set_active(False)
		self._stop_runner()
		# Translators: reported when the controlled computer stopped sharing its audio.
		ui.message(_("The remote computer stopped sharing its audio"))

	def on_audio_error(self, reason=None, **kwargs):
		self._cancel_pending_timer()
		self.pending = False
		self._set_active(False)
		self._stop_runner()
		if reason == "relay_unsupported":
			# Translators: reported when audio streaming was requested over a relayed connection.
			message = _("Audio streaming is not available over relay connections yet. Use a direct connection (control server).")
		elif reason == "dotnet_missing":
			# Translators: reported when the remote computer lacks the .NET runtime for audio streaming.
			message = _("The remote computer cannot stream audio: the .NET 10 Desktop Runtime is missing there.")
		else:
			# Translators: reported when the remote computer failed to start audio streaming; {reason} is an error code.
			message = _("The remote computer could not start audio streaming ({reason}).").format(reason=reason)
		ui.message(message)

	# === slave side ===

	def toggle_from_slave(self):
		"""The controlled machine's own switch: this is our audio, so we may share it or
		take it back at any time, whether or not the controlling side asked for it."""
		transport = self.plugin.slave_transport
		if transport is None or not getattr(transport, "connected", False):
			# Translators: reported when trying to toggle remote audio while not connected.
			ui.message(_("Not connected."))
			return
		if globalVars.appArgs.secure:
			# The user session's copy owns the helper process and keeps streaming right
			# through UAC prompts; a second one here would only fight it for the UDP port.
			# Translators: reported when audio streaming is toggled from a secure desktop (e.g. a UAC prompt).
			ui.message(_("Audio streaming can only be switched from the normal desktop."))
			return
		if self.active or self.offering or self._pending_reply is not None:
			self._stop_from_slave()
		else:
			self._offer_from_slave()

	def _offer_from_slave(self):
		transport = self.plugin.slave_transport
		self.offering = True
		try:
			transport.send(type="audio_offer")
		except (TypeError, OSError):
			logger.exception("could not send audio_offer")
			self.offering = False
			# Translators: reported when the audio offer could not be sent to the controlling computer.
			ui.message(_("Could not offer the audio to the controlling computer."))
			return
		self._pending_timer = wx.CallLater(REPLY_TIMEOUT_MS, self._on_offer_timeout)
		# Translators: reported on the controlled computer when it offers its audio to the controller.
		ui.message(_("Offering audio to the controlling computer..."))

	def _stop_from_slave(self):
		transport = self.plugin.slave_transport
		self._cancel_pending_timer()
		self.offering = False
		self._pending_reply = None
		self._pending_remote_tts = False
		self._set_speech_forwarding(True)
		self._set_active(False)
		self._stop_runner()
		try:
			if transport is not None:
				transport.send(type="audio_stopped")
		except (TypeError, OSError):
			logger.exception("could not send audio_stopped")
		# Translators: reported on the controlled computer when it stops streaming its audio.
		ui.message(_("Stopped streaming audio to the controlling computer"))

	def _on_offer_timeout(self):
		if not self.offering:
			return
		self.offering = False
		# Translators: reported on the controlled computer when the controller never answered the audio offer.
		ui.message(_("No response. The controlling computer may not support audio streaming (remremote required on both ends)."))

	def on_audio_start(self, master_hosting=False, port=None, remote_tts=None, audio_session=None, **kwargs):
		plugin = self.plugin
		transport = plugin.slave_transport
		if transport is None:
			return
		# Either the controller asked unprompted, or this is the answer to our own offer.
		self._cancel_pending_timer()
		self.offering = False
		if remote_tts is not None:
			self.remote_tts_peer_state = bool(remote_tts)
			self._remote_tts_synced = True
		# When the controller wants to hear our own voice, NVDA has to stay IN the captured
		# audio — so no excludePid. Leaving it out makes the helper capture the whole default
		# output device, which is exactly what we want here.
		self._pending_remote_tts = self.remote_tts_peer_state
		exclude = {} if self._pending_remote_tts else {"excludePid": os.getpid()}
		password = self._password(transport)
		try:
			runner = self._ensure_runner()
		except (OSError, FileNotFoundError):
			logger.exception("audio host could not be started")
			self._send_slave_error(transport, "host_start_failed")
			return
		try:
			if master_hosting:
				# The master owns the well-known UDP port on its end; stream straight at it.
				target_port = int(port) if port else transport.address[1]
				self._pending_reply = ("connect", target_port)
				runner.send(
					cmd="start-send", password=password,
					host=transport.address[0], port=target_port,
					**exclude,
				)
			elif plugin.server is not None:
				# We host the connection: bind the UDP twin of our control-server port and
				# wait for the master's sealed hello to learn the return path.
				self._pending_reply = ("host", plugin.server.port)
				runner.send(
					cmd="start-send", password=password,
					bindPort=plugin.server.port,
					**exclude,
				)
			elif audio_session:
				# Neither side hosts: route the audio through the relay (the same host we
				# use for control). A local shim registers our session id and bridges the
				# helper to the relay, which pairs us with the master and forwards verbatim.
				relay_host, relay_port = transport.address
				proxy = RelayAudioProxy()
				shim_port = proxy.start(relay_host, relay_port, base64.b64decode(audio_session))
				self._relay_proxy = proxy
				self._pending_reply = ("relay", relay_port)
				runner.send(
					cmd="start-send", password=password,
					host="127.0.0.1", port=shim_port,
					**exclude,
				)
			else:
				# Neither side hosts and the master is too old to offer a relay session.
				self._send_slave_error(transport, "relay_unsupported")
				return
		except OSError:
			logger.exception("audio host rejected the start command")
			self._pending_reply = None
			self._send_slave_error(transport, "host_start_failed")
			return

	def on_audio_stop(self, **kwargs):
		if not self.active and self._pending_reply is None and not self.offering:
			return
		self._cancel_pending_timer()
		self.offering = False
		self._set_active(False)
		self._pending_reply = None
		self._pending_remote_tts = False
		# The controller can no longer hear us; speech goes back on the control channel.
		self._set_speech_forwarding(True)
		self._stop_runner()
		# Translators: reported on the controlled computer when the controller stopped audio streaming.
		ui.message(_("Stopped streaming audio to the controlling computer"))

	def _send_slave_error(self, transport, reason):
		try:
			transport.send(type="audio_error", reason=reason)
		except (TypeError, OSError):
			logger.exception("could not send audio_error")

	# === helper process events (background threads — marshal to the UI thread) ===

	def _on_host_event(self, event):
		name = event.get("event")
		if name == "started":
			wx.CallAfter(self._on_host_started, event)
		elif name == "error":
			logger.error("audio host error: %s", event.get("message"))
			wx.CallAfter(self._on_host_error, event)
		elif name == "warning":
			logger.warning("audio host warning: %s", event.get("message"))
			if event.get("code") == "exclude-unsupported":
				# Translators: reported on the controlled computer when NVDA's audio cannot be
				# excluded from the stream because Windows is too old.
				wx.CallAfter(ui.message, _("Warning: NVDA's own audio cannot be excluded from the stream on this version of Windows."))
		elif name == "peer":
			logger.info("audio peer confirmed: %s", event.get("endpoint"))
		elif name == "diag":
			logger.debug("audio host: %s", event.get("message"))
		elif name == "status":
			logger.debug("audio host status: %s", event)

	def _on_host_started(self, event):
		plugin = self.plugin
		if event.get("mode") == "send":
			reply = self._pending_reply
			self._pending_reply = None
			transport = plugin.slave_transport
			if reply is None or transport is None:
				return
			mode, port = reply
			self._set_active(True)
			# THE point at which our text speech goes quiet: not when the setting changed,
			# but now, with the sender confirmed running. Anything earlier could leave this
			# computer sending neither text nor audio if the helper failed to start.
			if self._pending_remote_tts:
				self._set_speech_forwarding(False)
			transport.send(
				type="audio_started", mode=mode, port=port,
				remote_tts=self._pending_remote_tts,
			)
			if self._pending_remote_tts:
				# Translators: reported on the controlled computer when it starts streaming with its own speech.
				ui.message(_("Streaming audio to the controlling computer, including this computer's speech"))
			else:
				# Translators: reported on the controlled computer when audio streaming starts.
				ui.message(_("Streaming audio to the controlling computer"))

	def _on_host_error(self, event):
		message = event.get("message") or "unknown error"
		plugin = self.plugin
		reply = self._pending_reply
		if reply is not None and plugin.slave_transport is not None:
			# The slave-side helper failed before we ever confirmed to the master.
			self._pending_reply = None
			self._pending_remote_tts = False
			self._set_speech_forwarding(True)
			self._send_slave_error(plugin.slave_transport, "host_start_failed")
			self._stop_runner()
			return
		# Translators: reported when the local audio helper reports an error; {error} is its message.
		ui.message(_("Audio error: {error}").format(error=message))

	def _on_host_exit(self, code, stderr_tail):
		logger.warning("audio host exited unexpectedly with code %s: %s", code, stderr_tail)
		low = stderr_tail.lower()
		dotnet_missing = (
			code in FRAMEWORK_MISSING_EXIT_CODES
			or "windowsdesktop.app" in low
			or ("install" in low and ".net" in low)
			or runtime_missing()
		)
		wx.CallAfter(self._on_host_died, dotnet_missing)

	def _on_host_died(self, dotnet_missing):
		plugin = self.plugin
		was_active = self.active
		reply = self._pending_reply
		self._pending_reply = None
		self.offering = False
		self._pending_remote_tts = False
		# The helper is gone, so nothing carries our voice any more — speak as text again,
		# or this computer would be silent to the controller with no way to notice why.
		self._set_speech_forwarding(True)
		self._set_active(False)
		self.runner = None
		self._stop_relay_proxy()
		if reply is not None and plugin.slave_transport is not None:
			self._send_slave_error(
				plugin.slave_transport,
				"dotnet_missing" if dotnet_missing else "host_start_failed",
			)
			# Fall through: the slave user is the one whose machine lacks the runtime, so
			# they get the install offer too — the master can only relay the bad news.
		elif was_active and plugin.slave_transport is not None:
			# We were the one streaming: tell the controller so its receiver (and its
			# checkbox) don't sit there waiting for audio that will never arrive.
			try:
				plugin.slave_transport.send(type="audio_stopped")
			except (TypeError, OSError):
				logger.exception("could not send audio_stopped")
		if dotnet_missing:
			self._offer_runtime_install()
		elif was_active:
			# Translators: reported when the audio helper process died while streaming.
			ui.message(_("Audio streaming stopped unexpectedly"))

	# === .NET runtime detection and guided installation ===

	def check_runtime_at_startup(self):
		"""Called once after NVDA startup: if the runtime for the bundled audio helper is
		missing, offer to install it — unless the user previously declined permanently."""
		if globalVars.appArgs.secure or configuration.readonly:
			return
		try:
			if configuration.get_config()["audio"]["runtime_prompt_dismissed"]:
				return
		except KeyError:
			pass
		if not runtime_missing():
			return
		# Give NVDA's own startup (and a possible autoconnect) a moment before going modal.
		wx.CallLater(3000, self._startup_runtime_prompt)

	def _startup_runtime_prompt(self):
		if runtime_missing() is False:
			return
		is_modal_active = getattr(getattr(gui, "message", None), "isModalMessageBoxActive", None)
		if is_modal_active is not None and is_modal_active():
			# Don't stack on top of another modal dialog at startup; the offer will come
			# back the next time audio is actually used.
			return
		result = gui.messageBox(
			# Translators: question asked at NVDA startup when the .NET runtime for audio streaming is missing.
			message=_("remremote's audio streaming needs the .NET 10 Desktop Runtime, which is not installed on this computer. Do you want to install it now? If you choose no, you won't be asked at startup again, but audio streaming will offer the installation when used."),
			# Translators: title of the missing runtime question.
			caption=_("Audio streaming component missing"),
			style=wx.YES | wx.NO | wx.ICON_QUESTION)
		if result == wx.YES:
			self._install_runtime_async()
		else:
			conf = configuration.get_config()
			conf["audio"]["runtime_prompt_dismissed"] = True
			conf.write()

	def _offer_runtime_install(self):
		if self._install_running:
			# Translators: reported when the runtime installation is still in progress.
			ui.message(_("The .NET runtime installation is still running. Please wait."))
			return
		result = gui.messageBox(
			# Translators: question asked when audio streaming failed because the .NET runtime is missing.
			message=_("Audio streaming needs the .NET 10 Desktop Runtime, which is not installed. Do you want to install it now?"),
			# Translators: title of the missing runtime question.
			caption=_("Audio streaming component missing"),
			style=wx.YES | wx.NO | wx.ICON_QUESTION)
		if result == wx.YES:
			self._install_runtime_async()

	def _install_runtime_async(self):
		self._install_running = True
		# Translators: reported while the .NET runtime is being installed in the background.
		ui.message(_("Installing the .NET 10 Desktop Runtime in the background. You may see a User Account Control prompt — please confirm it. You will be notified when the installation finishes."))
		threading.Thread(target=self._install_runtime, daemon=True, name="remremoteRuntimeInstall").start()

	def _install_runtime(self):
		ok = False
		try:
			startupinfo = subprocess.STARTUPINFO()
			startupinfo.dwFlags |= subprocess.STARTF_USESHOWWINDOW
			result = subprocess.run(
				["winget", "install", WINGET_RUNTIME_ID,
					"--accept-source-agreements", "--accept-package-agreements", "--silent"],
				capture_output=True, timeout=900,
				startupinfo=startupinfo, creationflags=subprocess.CREATE_NO_WINDOW,
			)
			logger.info("winget runtime install finished with code %s", result.returncode)
			ok = result.returncode == 0
		except (OSError, subprocess.TimeoutExpired):
			logger.exception("winget runtime installation failed")
		self._install_running = False
		# Trust the filesystem over winget's exit code (it reports oddities like
		# "already installed" as non-zero).
		if not runtime_missing():
			# Translators: reported when the .NET runtime finished installing.
			wx.CallAfter(ui.message, _("The .NET 10 Desktop Runtime has been installed. You can use audio streaming now."))
		elif ok:
			# winget claims success but the probe can't see it yet (per-machine path oddity).
			# Translators: reported when the runtime install finished but couldn't be verified.
			wx.CallAfter(ui.message, _("The runtime installation finished. If audio streaming still fails, please restart the computer."))
		else:
			wx.CallAfter(self._runtime_install_fallback)

	def _runtime_install_fallback(self):
		try:
			os.startfile(RUNTIME_DOWNLOAD_URL)
		except OSError:
			logger.exception("could not open runtime download URL")
		# Translators: reported when automatic runtime installation failed and the download page was opened instead.
		ui.message(_("Automatic installation did not work. The .NET 10 Desktop Runtime download has been started in your browser — please run the downloaded installer manually."))

	def _cancel_pending_timer(self):
		# Both timers die here: every explicit start, stop or error supersedes a pending
		# stream rebuild, so a queued restart must never fire behind the user's back.
		for name in ("_pending_timer", "_restart_timer"):
			timer = getattr(self, name, None)
			setattr(self, name, None)
			if timer is not None:
				try:
					timer.Stop()
				except RuntimeError:
					pass
