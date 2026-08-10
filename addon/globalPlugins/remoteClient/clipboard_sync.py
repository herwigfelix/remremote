"""Two-way clipboard synchronisation for remremote.

While enabled, copying text on either machine makes the same text appear in the other
machine's clipboard — no more reaching for "push clipboard" every time. Text only:
anything else in the clipboard (images, files) is ignored rather than mangled.

The toggle itself is shared state. Whichever side turns it on or off tells the other,
which applies the same state and updates its own menu, so the checkbox never disagrees
between the two computers.

Two message types on the existing JSON control channel:

	clipboard_sync      {state: bool}   toggle, applied by the peer without echoing back
	clipboard_sync_text {text: str}     a clipboard update to apply

Loop prevention: every text we send or apply is remembered in ``_last_text``. The
clipboard listener fires for our own writes too, but the text then equals ``_last_text``
and is dropped, so a change bounces exactly once in each direction and stops.

Clipboard changes are caught with ``AddClipboardFormatListener`` (event-driven, no
polling) on a hidden window, the same pattern ``url_handler`` already uses.
"""

import ctypes
import logging

import addonHandler
import api
import ui
import windowUtils
import wx

from . import cues

logger = logging.getLogger(__name__)

try:
	addonHandler.initTranslation()
except addonHandler.AddonError:
	pass

WM_CLIPBOARDUPDATE = 0x031D
#: Reading the clipboard the instant the notification arrives often fails — the app that
#: just wrote it may still hold it open. Wait a moment, then read (and retry once).
READ_DELAY_MS = 100
#: Upper bound on synced text. The control channel also carries speech and braille, and a
#: multi-megabyte paste would stall those behind it (the same reason file transfer warns
#: about blocking the session). Larger clipboards are left alone.
MAX_SYNC_LENGTH = 100000


class ClipboardListenerWindow(windowUtils.CustomWindow):
	"""Hidden window registered as a clipboard format listener."""

	className = "remremoteClipboardSync"

	def __init__(self, callback, *args, **kwargs):
		super().__init__(*args, **kwargs)
		self.callback = callback
		if not ctypes.windll.user32.AddClipboardFormatListener(self.handle):
			raise ctypes.WinError()

	def windowProc(self, hwnd, msg, wParam, lParam):
		if msg == WM_CLIPBOARDUPDATE:
			try:
				self.callback()
			except Exception:
				logger.exception("clipboard update handler failed")

	def destroy(self):
		try:
			ctypes.windll.user32.RemoveClipboardFormatListener(self.handle)
		except Exception:
			logger.exception("could not remove clipboard format listener")
		super().destroy()


class ClipboardSync:
	"""Owns the shared on/off state, the clipboard listener and the message plumbing.
	One instance lives on the GlobalPlugin for the whole NVDA session."""

	def __init__(self, plugin):
		self.plugin = plugin
		self.enabled = False
		self._window = None
		self._last_text = None

	# === wiring ===

	def register(self, transport):
		transport.callback_manager.register_callback("msg_clipboard_sync", self.on_remote_toggle)
		transport.callback_manager.register_callback("msg_clipboard_sync_text", self.on_remote_text)

	def _transport(self):
		plugin = self.plugin
		return plugin.slave_transport or plugin.master_transport

	def shutdown(self):
		"""Turn everything off locally without telling the peer — for disconnect and
		add-on termination, where the channel is gone or going."""
		self._stop_listening()
		self.enabled = False
		self._last_text = None
		self.plugin.update_clipboard_sync_menu(False)

	# === toggling ===

	def toggle(self):
		"""User action, from the menu item or the gesture."""
		transport = self._transport()
		if transport is None or not getattr(transport, "connected", False):
			# Translators: reported when toggling clipboard sync while not connected.
			ui.message(_("Not connected."))
			return
		self._apply(not self.enabled, from_peer=False)

	def on_remote_toggle(self, state=None, **kwargs):
		"""The other machine toggled; adopt the same state and stay quiet about it on the
		wire (echoing would ping-pong the toggle)."""
		if state is None or bool(state) == self.enabled:
			return
		self._apply(bool(state), from_peer=True)

	def _apply(self, state, from_peer):
		self.enabled = state
		if state:
			self._start_listening()
		else:
			self._stop_listening()
			self._last_text = None
		self.plugin.update_clipboard_sync_menu(state)
		if not from_peer:
			transport = self._transport()
			if transport is not None:
				transport.send(type="clipboard_sync", state=state)
		if state:
			if from_peer:
				# Translators: reported when the other computer turned clipboard sync on.
				ui.message(_("Clipboard sync turned on by the other computer"))
			else:
				# Translators: reported when clipboard sync has been turned on.
				ui.message(_("Clipboard sync on"))
			# Seed the peer with what we have, so both sides match straight away instead of
			# only after the next copy.
			if not from_peer:
				self._send_current_clipboard()
		else:
			if from_peer:
				# Translators: reported when the other computer turned clipboard sync off.
				ui.message(_("Clipboard sync turned off by the other computer"))
			else:
				# Translators: reported when clipboard sync has been turned off.
				ui.message(_("Clipboard sync off"))

	# === clipboard listener ===

	def _start_listening(self):
		if self._window is not None:
			return
		try:
			self._window = ClipboardListenerWindow(callback=self._on_clipboard_changed)
		except Exception:
			logger.exception("could not create the clipboard listener window")
			self._window = None
			# Translators: reported when the clipboard could not be monitored.
			ui.message(_("Could not monitor the clipboard on this computer."))

	def _stop_listening(self):
		window = self._window
		self._window = None
		if window is not None:
			try:
				window.destroy()
			except Exception:
				logger.exception("could not destroy the clipboard listener window")

	def _on_clipboard_changed(self):
		# Never read the clipboard inside the notification itself; see READ_DELAY_MS.
		wx.CallLater(READ_DELAY_MS, self._send_current_clipboard, True)

	def _send_current_clipboard(self, retry=False):
		if not self.enabled:
			return
		transport = self._transport()
		if transport is None or not getattr(transport, "connected", False):
			return
		try:
			text = api.getClipData()
		except OSError:
			# Somebody else still owns the clipboard. One retry, then give up until the
			# next change — a stuck clipboard must not turn into a retry storm.
			if retry:
				wx.CallLater(READ_DELAY_MS * 3, self._send_current_clipboard, False)
			return
		if not text or not isinstance(text, str):
			return  # empty, or non-text content we deliberately ignore
		if text == self._last_text:
			return  # our own write, or an unchanged clipboard
		if len(text) > MAX_SYNC_LENGTH:
			logger.info("clipboard sync: skipping %d characters (over the limit)", len(text))
			return
		self._last_text = text
		transport.send(type="clipboard_sync_text", text=text)

	def on_remote_text(self, text=None, **kwargs):
		if not self.enabled or not text or not isinstance(text, str):
			return
		if text == self._last_text:
			return
		# Set this BEFORE writing, so the notification our own write triggers is recognised
		# as ours and dropped.
		self._last_text = text
		try:
			api.copyToClip(text=text)
		except OSError:
			logger.exception("could not write the received clipboard text")
			return
		# A sound only: with sync on, a spoken message on every copy would be noise.
		cues.clipboard_received()
