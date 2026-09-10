"""Remote audio streaming for remremote (TeleNVDA fork).

Streams the controlled (slave) computer's system audio to the controlling (master)
computer, excluding NVDA's own audio on the slave (speech already travels over the
control channel — hearing it twice would be useless).

The heavy lifting happens in remremote's own audio engine, a Rust library loaded straight
into NVDA (audioEngine/remremote_audio-*.dll, sources in the repository's audio/
directory): WASAPI process-loopback capture, Opus, AES-256-GCM over UDP, in the RemSound
wire format the Mac app speaks too. No helper process and no runtime to install. This
module only drives that library (a JSON config in, JSON events back on a callback) and
runs the control-channel handshake:

	master --> slave:  audio_start {master_hosting: bool, port: int|None}
	slave  --> master: audio_started {mode: "connect"|"host"|"relay", port: int}
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
it punches its NAT with sealed hello packets the engine generates. When neither side hosts
(a relayed session), both ends register an opaque session id with the relay, which
forwards their packets verbatim — it never holds the password or decrypts anything, so the
stream stays end-to-end encrypted.

The audio encryption password is the connection's encryption key when set, otherwise the
channel key — both sides always agree on those already.
"""

import base64
import ctypes
import json
import logging
import os
import sys
import threading

import addonHandler
import globalVars
import gui
import ui
import wx
from config import conf as nvda_conf

from . import configuration

try:
	# NVDA's own log: a plain logging.getLogger() has no handler inside NVDA, so its
	# output would vanish — and the engine's events are exactly what support needs to see.
	from logHandler import log as logger
except ImportError:
	logger = logging.getLogger(__name__)

try:
	addonHandler.initTranslation()
except addonHandler.AddonError:
	pass

ENGINE_SUBDIR = "audioEngine"
#: How long the master waits for the slave to answer audio_start before assuming the
#: other end doesn't understand the message (stock NVDA Remote / TeleNVDA silently
#: ignores unknown message types).
REPLY_TIMEOUT_MS = 8000
#: How long to wait between tearing a stream down and building it back up when the remote
#: TTS setting changed mid-stream, so the old sender has released the UDP port.
RESTART_DELAY_MS = 900
#: Jitter-buffer depth (ms) the receiver uses for RELAYED audio. Relayed streams arrive in
#: periodic bursts (the far sender's scheduling plus the relay hop), so the buffer must be
#: deep enough to ride out a burst — measured up to ~100 ms — without underrunning. Direct
#: connections keep the engine's low-latency default.
RELAY_JITTER_MS = 150


def engine_dll_path():
	"""The engine build matching this NVDA's architecture (64-bit NVDA since 2026, 32-bit
	before; the add-on ships both)."""
	arch = "x64" if sys.maxsize > 2 ** 32 else "x86"
	return os.path.join(os.path.dirname(os.path.abspath(__file__)), ENGINE_SUBDIR, f"remremote_audio-{arch}.dll")


_EVENT_CALLBACK = ctypes.CFUNCTYPE(None, ctypes.c_void_p, ctypes.c_char_p)


def nvda_output_device():
	"""The output device NVDA is set to use, as engine config fields: the endpoint id
	NVDA 2025.1+ stores under audio.outputDevice, or the WinMM device name older versions
	store under speech.outputDevice. Empty when NVDA uses the system default."""
	try:
		device = nvda_conf["audio"]["outputDevice"]
		if device and device != "default":
			return {"outputDevice": device}
		return {}
	except KeyError:
		pass
	try:
		device = nvda_conf["speech"]["outputDevice"]
		if device and device != "Microsoft Sound Mapper":
			return {"outputDeviceName": device}
	except KeyError:
		pass
	return {}


class AudioEngine:
	"""One running send or receive pipeline inside the audio engine library.

	``on_event`` is called on one of the engine's background threads with each decoded
	event dict (started, peer, status, warning, error, diag). Callers marshal to the UI
	thread themselves. After ``stop()`` returns, no further events are delivered.
	"""

	_lib = None

	@classmethod
	def library(cls):
		if cls._lib is None:
			path = engine_dll_path()
			if not os.path.isfile(path):
				raise FileNotFoundError(path)
			lib = ctypes.CDLL(path)
			lib.remremote_audio_version.argtypes = []
			lib.remremote_audio_version.restype = ctypes.c_char_p
			lib.remremote_audio_start.argtypes = [ctypes.c_char_p, _EVENT_CALLBACK, ctypes.c_void_p]
			lib.remremote_audio_start.restype = ctypes.c_void_p
			lib.remremote_audio_stop.argtypes = [ctypes.c_void_p]
			lib.remremote_audio_stop.restype = None
			lib.remremote_audio_last_error.argtypes = [ctypes.c_char_p, ctypes.c_size_t]
			lib.remremote_audio_last_error.restype = ctypes.c_size_t
			logger.info("audio engine %s loaded from %s", lib.remremote_audio_version().decode("utf-8", "replace"), path)
			cls._lib = lib
		return cls._lib

	@classmethod
	def available(cls):
		try:
			cls.library()
		except OSError:
			return False
		return True

	def __init__(self, on_event):
		self.on_event = on_event
		self.handle = None
		# The engine calls this from its own threads for as long as it runs; the reference
		# has to outlive the stream, so it lives on the instance.
		self._callback = _EVENT_CALLBACK(self._dispatch)

	def _dispatch(self, user_data, text):
		try:
			event = json.loads(text.decode("utf-8"))
		except (ValueError, AttributeError, UnicodeDecodeError):
			logger.warning("audio engine emitted a non-JSON event: %r", text)
			return
		try:
			self.on_event(event)
		except Exception:
			logger.exception("audio engine event handler failed")

	@property
	def running(self):
		return self.handle is not None

	def start(self, **config):
		"""Start a pipeline; ``config`` is the engine's JSON config (mode, password, bindPort,
		host, port, excludePid, maxLatency, relaySession). Raises OSError with the engine's
		own message when it cannot start."""
		lib = self.library()
		self.stop()
		handle = lib.remremote_audio_start(json.dumps(config).encode("utf-8"), self._callback, None)
		if not handle:
			buf = ctypes.create_string_buffer(2048)
			lib.remremote_audio_last_error(buf, len(buf))
			raise OSError(buf.value.decode("utf-8", "replace") or "the audio engine failed to start")
		self.handle = handle

	def stop(self):
		"""Stops the pipeline and joins its threads. Safe to call twice."""
		handle, self.handle = self.handle, None
		if handle:
			self.library().remremote_audio_stop(handle)


class AudioManager:
	"""The add-on side of remote audio: handshake over the control channel plus the
	local helper process. One instance lives on the GlobalPlugin for the whole NVDA
	session; per-connection state resets via shutdown()."""

	def __init__(self, plugin):
		self.plugin = plugin
		#: The engine pipeline of the current stream (sender on the slave, receiver on the master).
		self.engine = None
		self._status_events = 0
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
		#: Master only: the session id sent in audio_start, reused if the reply is "relay".
		self._audio_session = None
		#: Master only: True when the controlled computer is a Mac — audio is then the only
		#: way to hear it, so it is switched on automatically and cannot be turned off.
		self.forced = False

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

	def _new_engine(self):
		"""A fresh pipeline for the stream about to start; whatever ran before is stopped."""
		self._stop_engine()
		engine = AudioEngine(self._on_engine_event)
		self.engine = engine
		self._status_events = 0
		return engine

	def _stop_engine(self):
		engine = self.engine
		self.engine = None
		if engine is not None:
			# Stopping joins the engine's threads (a few hundred ms at most); keep that off
			# the UI thread. Events from the old pipeline are ignored: it is no longer ours.
			threading.Thread(target=engine.stop, daemon=True).start()

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
		self.forced = False
		# Whatever happened, this machine speaks to the controller as text again. Leaving
		# the gate shut would make a controlled computer silently unreadable.
		self._set_speech_forwarding(True)
		self._set_active(False)
		self._stop_engine()

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

	def reset_master_audio(self):
		"""Tear down any master-side stream and clear the forced lock. Used when the
		controlled machine leaves: a plain disconnect never sends audio_stop, so without
		this the stream would stay 'active' and a reconnect's forced-audio request would be
		suppressed by that stale state (the audio never restarts)."""
		self.forced = False
		self._cancel_pending_timer()
		self.pending = False
		self._set_active(False)
		self._stop_engine()

	def set_forced(self, state):
		"""Controlling a Mac: audio is the only way to hear it, so switch it on and keep it
		on. Idempotent, but always (re)requests the stream when it should be on and isn't —
		so a Mac that joins after the controller was already connected still gets its audio
		requested, even if the forced flag was left set from an earlier session."""
		self.forced = bool(state)
		if self.forced and not (self.active or self.pending):
			transport = self.plugin.master_transport
			if transport is not None and getattr(transport, "connected", False):
				self._start_from_master(announce=False)

	def toggle_from_master(self):
		plugin = self.plugin
		transport = plugin.master_transport
		if transport is None or not getattr(transport, "connected", False):
			# Translators: reported when trying to toggle remote audio while not connected.
			ui.message(_("Not connected."))
			return
		if self.forced:
			# Controlling a Mac: audio cannot be turned off.
			if not (self.active or self.pending):
				self._start_from_master(announce=False)
			# Translators: reported when trying to turn off audio while controlling a Mac.
			ui.message(_("macOS does not support this."))
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
		self._stop_engine()
		if announce:
			# Translators: reported when remote audio streaming has been turned off.
			ui.message(_("Remote audio off"))

	def _on_reply_timeout(self):
		if not self.pending:
			return
		self.pending = False
		self._stop_engine()
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
		# The remote audio plays where NVDA's own audio does: the device from NVDA's audio
		# settings, not necessarily the Windows default.
		device = nvda_output_device()
		try:
			engine = self._new_engine()
			if mode == "connect":
				# We host the connection: bind the UDP twin of our control-server port and
				# let the slave's audio stream find us there.
				engine.start(mode="recv", password=password, bindPort=plugin.server.port, **device)
			elif mode == "relay":
				# Relayed session: both ends meet at the relay (the same host we use for
				# control), registering the session id so it can pair us with the sender.
				relay_host, relay_port = transport.address
				engine.start(
					mode="recv", password=password, host=relay_host, port=int(relay_port),
					relaySession=self._audio_session, maxLatency=RELAY_JITTER_MS, **device,
				)
			else:
				# The slave hosts: reach out to its UDP port from an ephemeral port,
				# punching our NAT with sealed hellos.
				engine.start(mode="recv", password=password, host=transport.address[0], port=int(port), **device)
		except (OSError, TypeError, ValueError) as error:
			logger.exception("failed to start local audio receiver")
			self._stop_engine()
			# Translators: reported when the local audio receiver could not be started; {error} is the engine's message.
			ui.message(_("Could not start the audio receiver: {error}").format(error=error))
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
		self._stop_engine()
		# Translators: reported when the controlled computer stopped sharing its audio.
		ui.message(_("The remote computer stopped sharing its audio"))

	def on_audio_error(self, reason=None, **kwargs):
		self._cancel_pending_timer()
		self.pending = False
		self._set_active(False)
		self._stop_engine()
		if reason == "relay_unsupported":
			# Translators: reported when audio streaming was requested over a relayed connection.
			message = _("Audio streaming is not available over relay connections yet. Use a direct connection (control server).")
		elif reason == "dotnet_missing":
			# Older remremote versions needed a runtime for their audio helper; a peer still
			# running one of them may report that.
			# Translators: reported when an older remote computer lacks the .NET runtime its audio helper needed.
			message = _("The remote computer cannot stream audio: it runs an older remremote whose audio helper needs the .NET 10 Desktop Runtime, which is missing there.")
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
		self._stop_engine()
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
		# audio — so no excludePid. Leaving it out makes the engine capture the whole default
		# output device, which is exactly what we want here.
		self._pending_remote_tts = self.remote_tts_peer_state
		# ... and in that case the whole device that NVDA's own audio goes to is captured,
		# so its voice is in the stream even when NVDA plays on a device other than the
		# Windows default.
		exclude = nvda_output_device() if self._pending_remote_tts else {"excludePid": os.getpid()}
		password = self._password(transport)
		try:
			engine = self._new_engine()
			if master_hosting:
				# The master owns the well-known UDP port on its end; stream straight at it.
				target_port = int(port) if port else transport.address[1]
				self._pending_reply = ("connect", target_port)
				engine.start(
					mode="send", password=password,
					host=transport.address[0], port=target_port,
					**exclude,
				)
			elif plugin.server is not None:
				# We host the connection: bind the UDP twin of our control-server port and
				# wait for the master's sealed hello to learn the return path.
				self._pending_reply = ("host", plugin.server.port)
				engine.start(
					mode="send", password=password,
					bindPort=plugin.server.port,
					**exclude,
				)
			elif audio_session:
				# Neither side hosts: route the audio through the relay (the same host we
				# use for control), registering the session id so it pairs us with the
				# master and forwards our packets verbatim.
				relay_host, relay_port = transport.address
				self._pending_reply = ("relay", relay_port)
				engine.start(
					mode="send", password=password,
					host=relay_host, port=int(relay_port), relaySession=audio_session,
					**exclude,
				)
			else:
				# Neither side hosts and the master is too old to offer a relay session.
				self._send_slave_error(transport, "relay_unsupported")
				return
		except (OSError, TypeError, ValueError):
			logger.exception("the audio engine could not start the sender")
			self._pending_reply = None
			self._stop_engine()
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
		self._stop_engine()
		# Translators: reported on the controlled computer when the controller stopped audio streaming.
		ui.message(_("Stopped streaming audio to the controlling computer"))

	def _send_slave_error(self, transport, reason):
		try:
			transport.send(type="audio_error", reason=reason)
		except (TypeError, OSError):
			logger.exception("could not send audio_error")

	# === engine events (background threads — marshal to the UI thread) ===

	def _on_engine_event(self, event):
		name = event.get("event")
		if name == "started":
			wx.CallAfter(self._on_engine_started, event)
		elif name == "error":
			logger.error("audio engine error: %s", event.get("message"))
			if event.get("fatal"):
				wx.CallAfter(self._on_engine_died, event.get("message") or "unknown error")
			else:
				wx.CallAfter(self._on_engine_error, event)
		elif name == "warning":
			logger.warning("audio engine warning: %s", event.get("message"))
			if event.get("code") == "exclude-unsupported":
				# Translators: reported on the controlled computer when NVDA's audio cannot be
				# excluded from the stream because Windows is too old.
				wx.CallAfter(ui.message, _("Warning: NVDA's own audio cannot be excluded from the stream on this version of Windows."))
			elif event.get("code") == "device-missing":
				# Translators: reported when the output device from NVDA's audio settings is unavailable for remote audio.
				wx.CallAfter(ui.message, _("Warning: the output device selected in NVDA's audio settings is unavailable; remote audio uses the default output device."))
		elif name == "peer":
			logger.info("audio peer confirmed: %s", event.get("endpoint"))
		elif name == "diag":
			logger.debug("audio engine: %s", event.get("message"))
		elif name == "status":
			# One line every ~30 s at info level (the engine reports every 2 s), so a log from
			# a user always shows whether audio actually flowed; the rest at debug.
			self._status_events += 1
			if self._status_events % 15 == 1:
				logger.info("audio engine status: %s", event)
			else:
				logger.debug("audio engine status: %s", event)

	def _on_engine_started(self, event):
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
			# computer sending neither text nor audio if the engine failed to start.
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

	def _on_engine_error(self, event):
		"""A non-fatal problem the user should hear about (e.g. the two passwords differ)."""
		message = event.get("message") or "unknown error"
		# Translators: reported when the audio engine reports an error; {error} is its message.
		ui.message(_("Audio error: {error}").format(error=message))

	def _on_engine_died(self, message):
		"""The running pipeline stopped on its own (a device vanished, capture failed)."""
		logger.warning("audio engine pipeline stopped unexpectedly: %s", message)
		plugin = self.plugin
		was_active = self.active
		reply = self._pending_reply
		self._pending_reply = None
		self.offering = False
		self._pending_remote_tts = False
		# The pipeline is gone, so nothing carries our voice any more — speak as text again,
		# or this computer would be silent to the controller with no way to notice why.
		self._set_speech_forwarding(True)
		self._set_active(False)
		self._stop_engine()
		if reply is not None and plugin.slave_transport is not None:
			# Died before we ever confirmed to the master.
			self._send_slave_error(plugin.slave_transport, "host_start_failed")
			return
		if was_active and plugin.slave_transport is not None:
			# We were the one streaming: tell the controller so its receiver (and its
			# checkbox) don't sit there waiting for audio that will never arrive.
			try:
				plugin.slave_transport.send(type="audio_stopped")
			except (TypeError, OSError):
				logger.exception("could not send audio_stopped")
		if was_active:
			# Translators: reported when the audio pipeline stopped while streaming; {error} is the engine's message.
			ui.message(_("Audio streaming stopped unexpectedly: {error}").format(error=message))

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
