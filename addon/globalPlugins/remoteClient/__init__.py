import addonHandler
import api
import configobj
import core
import braille
import ctypes
import ctypes.wintypes
import globalVars
import gui
from gui import NVDASettingsDialog
import IAccessibleHandler
import json
import logging
import os
import queueHandler
try:
	from winAPI.secureDesktop import post_secureDesktopStateChange
except:
	post_secureDesktopStateChange = None
try:
	from utils import security
except:
	pass
import buildVersion
import shlobj
import speech
import socket
import ssl
import sys
import threading
import ui
import uuid
import wx
import base64
from config import conf as nvda_conf
from globalPluginHandler import GlobalPlugin as _GlobalPlugin
from keyboardHandler import KeyboardInputGesture
from logHandler import log
from scriptHandler import script
from winUser import WM_QUIT

logger = logging.getLogger(__name__)

from . import audio
from . import bridge
from . import clipboard_sync
from . import configuration
from . import cues
from . import dialogs
if buildVersion.version_year < 2025:
	from . import keyboard_hook
else:
	import inputCore
from . import local_machine
from . import serializer
from . import server
from . import url_handler
from .socket_utils import SERVER_PORT, address_to_hostport, hostport_to_address, wrap_socket
from .transport import RelayTransport, TransportEvents

from .session import MasterSession, SlaveSession
try:
	addonHandler.initTranslation()
except addonHandler.AddonError:
	log.warning(
		"Unable to initialise translations. This may be because the addon is running from NVDA scratchpad."
	)
speakOnDemand = {"speakOnDemand": True} if buildVersion.version_year >= 2024 else {}
if buildVersion.version_year < 2025:
	logging.getLogger("keyboard_hook").addHandler(logging.StreamHandler(sys.stdout))

client = None

class GlobalPlugin(_GlobalPlugin):
	# Translators: script category for add-on gestures
	scriptCategory = _("remremote")

	def __init__(self, *args, **kwargs):
		global client
		super().__init__(*args, **kwargs)
		# remremote is a renamed fork of TeleNVDA, which in turn forked NVDA Remote — all
		# three patch the same NVDA internals and fight over the same sockets, so refuse to
		# run alongside either of them.
		for addon in addonHandler.getAvailableAddons():
			if addon.name in ("remote", "TeleNVDA") and not addon.isDisabled:
				raise RuntimeError("remremote cannot be used while NVDA Remote or TeleNVDA is running. Please, disable that add-on and restart NVDA.")
		self.local_machine = local_machine.LocalMachine()
		self.audio = audio.AudioManager(self)
		self.clipboard_sync = clipboard_sync.ClipboardSync(self)
		self.slave_session = None
		self.master_session = None
		self.create_menu()
		NVDASettingsDialog.categoryClasses.append(dialogs.OptionsDialog)
		self.connecting = False
		self.muted = False # Used to know if mute remote was activated manually
		self.url_handler_window = url_handler.URLHandlerWindow(callback=self.verify_connect)
		url_handler.register_url_handler()
		self.master_transport = None
		self.slave_transport = None
		self.server = None
		self.hook_thread = None
		self.sending_keys = False
		self.key_modifiers = set()
		self.hostPendingModifiers = set()
		self.ignoreGesture = False
		self.guestScripts = (self.script_sendKeys, self.script_ignoreNextGesture)
		self.sd_server = None
		self.sd_relay = None
		self.sd_bridge = None
		try:
			configuration.get_config()
		except configobj.ParseError:
			os.remove(os.path.abspath(os.path.join(globalVars.appArgs.configPath, configuration.CONFIG_FILE_NAME)))
			queueHandler.queueFunction(queueHandler.eventQueue, wx.CallAfter, wx.MessageBox, _("Your NVDA Remote configuration was corrupted and has been reset."), _("NVDA Remote Configuration Error"), wx.OK|wx.ICON_EXCLAMATION)
		if hasattr(shlobj, 'SHGetKnownFolderPath'):
			self.temp_location = os.path.join(shlobj.SHGetKnownFolderPath(shlobj.FolderId.PROGRAM_DATA), 'temp')
		else:
			self.temp_location = os.path.join(shlobj.SHGetFolderPath(0, shlobj.CSIDL_COMMON_APPDATA), 'temp')
		self.ipc_file = os.path.join(self.temp_location, 'remote.ipc')
		self.sd_focused = False
		# True while this copy of NVDA is only bridged into a session owned by the user
		# session, as opposed to owning a connection of its own (sign-in screen).
		self.sd_handover = False
		if post_secureDesktopStateChange:
			post_secureDesktopStateChange.register(self.onSecureDesktopChange)
		if hasattr(globalVars, 'teleNVDA'):
			self.postStartupHandler()
		core.postNvdaStartup.register(self.postStartupHandler)
		globalVars.teleNVDA = None
		client = self

	def postStartupHandler(self):
		cs = configuration.get_config()['controlserver']
		if globalVars.appArgs.secure and self.handle_secure_desktop():
			# We joined the bridge that the copy of NVDA in the user session set up for
			# us, so this desktop is already part of the running session. Autoconnecting
			# on top of that would be harmful: with a self-hosted server it would fight
			# the user session for the port, and otherwise it would join the remote
			# session a second time as an independent client.
			return
		# Falling through is deliberate: on the sign-in screen there is no user session to
		# hand over from, so autoconnect is the only way in.
		if cs['autoconnect'] and not self.master_session and not self.slave_session:
			wx.CallLater(50,self.perform_autoconnect)
		self.audio.check_runtime_at_startup()

	def perform_autoconnect(self):
		cs = configuration.get_config()['controlserver']
		channel = cs['key']
		encryption_key = cs['encryption_key']
		if cs['self_hosted']:
			port = cs['port']
			address = ('localhost',port)
			UPNP = cs['UPNP']
			if not self.start_control_server(port, channel, UPNP):
				return
		else:
			address = address_to_hostport(cs['host'])
		if cs['connection_type']==0:
			self.connect_as_slave(address, channel, encryption_key)
		else:
			self.connect_as_master(address, channel, encryption_key)

	def create_menu(self):
		self.menu = wx.Menu()
		tools_menu = gui.mainFrame.sysTrayIcon.toolsMenu
		# Translators: Item in TeleNVDA submenu to connect to a remote computer.
		self.connect_item = self.menu.Append(wx.ID_ANY, _("Connect..."), _("Remotely connect to another computer running NVDA Remote Access or TeleNVDA"))
		gui.mainFrame.sysTrayIcon.Bind(wx.EVT_MENU, self.do_connect, self.connect_item)
		# Translators: Item in TeleNVDA submenu to disconnect from a remote computer.
		self.disconnect_item = self.menu.Append(wx.ID_ANY, _("Disconnect"), _("Disconnect from another computer running NVDA Remote Access or TeleNVDA"))
		gui.mainFrame.sysTrayIcon.Bind(wx.EVT_MENU, self.on_disconnect_item, self.disconnect_item)
		self.menu.Remove(self.disconnect_item.Id)
		# Translators: Menu item in TeleNVDA submenu to mute speech and sounds from the remote computer.
		self.mute_item = self.menu.Append(wx.ID_ANY, _("Mute remote"), _("Mute speech and sounds from the remote computer"))
		self.mute_item.Enable(False)
		gui.mainFrame.sysTrayIcon.Bind(wx.EVT_MENU, self.on_mute_item, self.mute_item)
		# Translators: Checkable menu item in remremote submenu to stream the remote computer's audio.
		self.audio_item = self.menu.Append(wx.ID_ANY, _("Stream remote &audio"), _("Play the audio of the remote computer on this computer"), kind=wx.ITEM_CHECK)
		self.audio_item.Enable(False)
		gui.mainFrame.sysTrayIcon.Bind(wx.EVT_MENU, self.on_audio_item, self.audio_item)
		# Translators: Menu item in TeleNVDA submenu to push clipboard content to the remote computer.
		self.push_clipboard_item = self.menu.Append(wx.ID_ANY, _("&Push clipboard"), _("Push the clipboard to the other machine"))
		self.push_clipboard_item.Enable(False)
		gui.mainFrame.sysTrayIcon.Bind(wx.EVT_MENU, self.on_push_clipboard_item, self.push_clipboard_item)
		# Translators: Checkable menu item in remremote submenu to keep both clipboards synchronised.
		self.clipboard_sync_item = self.menu.Append(wx.ID_ANY, _("&Keep clipboard in sync"), _("Automatically keep the clipboards of both computers identical (text only)"), kind=wx.ITEM_CHECK)
		self.clipboard_sync_item.Enable(False)
		gui.mainFrame.sysTrayIcon.Bind(wx.EVT_MENU, self.on_clipboard_sync_item, self.clipboard_sync_item)
		# Translators: Menu item in TeleNVDA submenu to send a file to the remote computer.
		self.send_file_item = self.menu.Append(wx.ID_ANY, _("Send &file..."), _("Send a file to the other machine"))
		self.send_file_item.Enable(False)
		gui.mainFrame.sysTrayIcon.Bind(wx.EVT_MENU, self.on_send_file_item, self.send_file_item)
		self.copyLinkMenu = wx.Menu()
		# Translators: Menu item in TeleNVDA submenu to copy a link to the current session compatible with NVDA Remote.
		self.copy_link_remote_item = self.copyLinkMenu .Append(wx.ID_ANY, _("NVDA &Remote protocol (recommended)"), _("Copy a link to the remote session compatible with both NVDA Remote and TeleNVDA"))
		self.copy_link_remote_item.Enable(False)
		gui.mainFrame.sysTrayIcon.Bind(wx.EVT_MENU, self.on_copy_link_remote_item, self.copy_link_remote_item)
		# Translators: Menu item in TeleNVDA submenu to copy a link to the current session compatible with TeleNVDA.
		self.copy_link_tele_item = self.copyLinkMenu .Append(wx.ID_ANY, _("&TeleNVDA protocol"), _("Copy a link to the remote session compatible only with TeleNVDA"))
		self.copy_link_tele_item.Enable(False)
		gui.mainFrame.sysTrayIcon.Bind(wx.EVT_MENU, self.on_copy_link_tele_item, self.copy_link_tele_item)
		# Translators: Menu item in TeleNVDA submenu to copy a link to the current session.
		self.copy_link_item=self.menu.AppendSubMenu(self.copyLinkMenu, _("Copy &link"), _("Copy a link to the remote session"))
		# Translators: Menu item in TeleNVDA submenu to open add-on options.
		self.options_item = self.menu.Append(wx.ID_ANY, _("&Options..."), _("Options"))
		gui.mainFrame.sysTrayIcon.Bind(wx.EVT_MENU, self.on_options_item, self.options_item)
		# Translators: Menu item in TeleNVDA submenu to send Control+Alt+Delete to the remote computer.
		self.send_ctrl_alt_del_item = self.menu.Append(wx.ID_ANY, _("Send Ctrl+Alt+Del"), _("Send Ctrl+Alt+Del"))
		gui.mainFrame.sysTrayIcon.Bind(wx.EVT_MENU, self.on_send_ctrl_alt_del, self.send_ctrl_alt_del_item)
		self.send_ctrl_alt_del_item.Enable(False)
		# Translators: Menu item in remremote submenu to create Windows Firewall rules for the control server hosted on this computer.
		self.firewall_item = self.menu.Append(wx.ID_ANY, _("Create firewall &rules for the control server (User Account Control may be required)"), _("Allow incoming connections to the control server hosted on this computer through the Windows Firewall"))
		# Only meaningful while we actually host a server — inbound rules are pointless
		# otherwise, and the rules are scoped to the running server's port.
		self.firewall_item.Enable(False)
		gui.mainFrame.sysTrayIcon.Bind(wx.EVT_MENU, self.on_firewall_item, self.firewall_item)

		# Translators: Label of menu in NVDA tools menu.
		self.remote_item=tools_menu.AppendSubMenu(self.menu, _("R&emote"), _("remremote"))

	def terminate(self):
		global client
		if post_secureDesktopStateChange:
			post_secureDesktopStateChange.unregister(self.onSecureDesktopChange)
		self.disconnect()
		self.audio.shutdown()
		self.clipboard_sync.shutdown()
		self.local_machine.terminate()
		self.local_machine = None
		NVDASettingsDialog.categoryClasses.remove(dialogs.OptionsDialog)
		self.copyLinkMenu.Remove(self.copy_link_remote_item.Id)
		self.copy_link_remote_item.Destroy()
		self.copy_link_remote_item=None
		self.copyLinkMenu.Remove(self.copy_link_tele_item.Id)
		self.copy_link_tele_item.Destroy()
		self.copy_link_tele_item=None
		try:
			self.menu.Remove(self.connect_item.Id)
			self.menu.Remove(self.disconnect_item.Id)
		except:
			pass
		self.connect_item.Destroy()
		self.connect_item=None
		self.disconnect_item.Destroy()
		self.disconnect_item=None
		self.menu.Remove(self.mute_item.Id)
		self.mute_item.Destroy()
		self.mute_item=None
		self.menu.Remove(self.audio_item.Id)
		self.audio_item.Destroy()
		self.audio_item=None
		self.menu.Remove(self.push_clipboard_item.Id)
		self.push_clipboard_item.Destroy()
		self.push_clipboard_item=None
		self.menu.Remove(self.clipboard_sync_item.Id)
		self.clipboard_sync_item.Destroy()
		self.clipboard_sync_item=None
		self.menu.Remove(self.send_file_item.Id)
		self.send_file_item.Destroy()
		self.send_file_item=None
		self.menu.Remove(self.copy_link_item.Id)
		self.copy_link_item.Destroy()
		self.copy_link_item = None
		self.menu.Remove(self.options_item.Id)
		self.options_item.Destroy()
		self.options_item=None
		self.menu.Remove(self.send_ctrl_alt_del_item.Id)
		self.send_ctrl_alt_del_item.Destroy()
		self.send_ctrl_alt_del_item=None
		self.menu.Remove(self.firewall_item.Id)
		self.firewall_item.Destroy()
		self.firewall_item=None
		tools_menu = gui.mainFrame.sysTrayIcon.toolsMenu
		tools_menu.Remove(self.remote_item.Id)
		self.remote_item.Destroy()
		self.remote_item=None
		try:
			self.menu.Destroy()
			self.copyLinkMenu.Destroy()
		except (RuntimeError, AttributeError):
			pass
		try:
			os.unlink(self.ipc_file)
		except:
			pass
		self.menu=None
		url_handler.unregister_url_handler()
		self.url_handler_window.destroy()
		self.url_handler_window=None
		core.postNvdaStartup.unregister(self.postStartupHandler)
		client = None

	def on_disconnect_item(self, evt):
		if evt:
			evt.Skip()
		def disconnect_as_slave_with_alert():
			if (self.slave_transport is not None
				and configuration.get_config()['ui']['alert_before_slave_disconnect']
				and not gui.message.isModalMessageBoxActive()):  # Check if a modal message box is open
				result = gui.messageBox(
					# Translators: question before disconnecting
					message=_("Are you sure you want to disconnect the controlled computer?"),
					# Translators: question title
					caption=_("Warning!"),
					style=wx.YES | wx.NO | wx.ICON_WARNING
				)
				if result == wx.YES:
					self.disconnect()
			elif (self.master_transport is not None
				  or (self.slave_transport is not None
					  and not configuration.get_config()['ui']['alert_before_slave_disconnect'])):
				self.disconnect()
		wx.CallAfter(disconnect_as_slave_with_alert)

	def on_mute_item(self, evt):
		if evt:
			evt.Skip()
		if not self.muted:
			# Translators: Menu item in TeleNVDA submenu to unmute speech and sounds from the remote computer.
			self.mute_item.SetItemLabel(_("Unmute remote"))
			ui.message(_("Mute speech and sounds from the remote computer"))
			if not configuration.get_config()['ui']['mute_when_controlling_local_machine']:
				self.local_machine.is_muted = True
			self.muted = True
		else:
			# Translators: Menu item in TeleNVDA submenu to mute speech and sounds from the remote computer.
			self.mute_item.SetItemLabel(_("Mute remote"))
			ui.message(_("Unmute speech and sounds from the remote computer"))
			if not configuration.get_config()['ui']['mute_when_controlling_local_machine']:
				self.local_machine.is_muted = False
			self.muted = False

	def on_audio_item(self, evt):
		if evt:
			evt.Skip()
		self.audio.toggle()
		# The checkbox must follow the real state, not the click: starting always involves
		# the other machine and may fail or time out, whichever end asked for it.
		self.update_audio_menu(self.audio.active)

	def on_clipboard_sync_item(self, evt):
		if evt:
			evt.Skip()
		self.clipboard_sync.toggle()

	def set_audio_item_role(self, as_slave):
		"""Label the audio item for the end we are on: the controlling computer plays the
		other machine's audio, the controlled computer shares its own. Same item, same
		gesture — only the wording differs."""
		item = getattr(self, 'audio_item', None)
		if not (getattr(self, 'menu', None) and item):
			return
		if as_slave:
			# Translators: Checkable menu item in remremote submenu, on the controlled computer, to share its audio.
			item.SetItemLabel(_("Stream &audio to the controlling computer"))
			# Translators: description of the audio menu item on the controlled computer.
			item.SetHelp(_("Play the audio of this computer on the controlling computer"))
		else:
			# Translators: Checkable menu item in remremote submenu to stream the remote computer's audio.
			item.SetItemLabel(_("Stream remote &audio"))
			# Translators: description of the remote audio menu item
			item.SetHelp(_("Play the audio of the remote computer on this computer"))

	def update_audio_menu(self, state):
		"""Reflect the true audio streaming state in the menu. Called by the audio manager
		whenever the state changes, including when the change came from a failure. Tolerates
		being called before the menu exists (managers are constructed first) and after it is
		torn down."""
		item = getattr(self, 'audio_item', None)
		if getattr(self, 'menu', None) and item:
			item.Check(bool(state))

	def update_remote_tts_setting(self, state):
		"""Keep the settings panel's checkbox truthful when the setting was changed from
		outside the dialog — by the gesture, or by the other computer. The panel has no
		menu item; it may simply not be on screen, which is the common case."""
		panel = dialogs.OptionsDialog.active_panel
		if panel is None:
			return
		try:
			panel.use_remote_tts.SetValue(bool(state))
		except RuntimeError:
			# The panel was destroyed between the check and here.
			dialogs.OptionsDialog.active_panel = None

	def update_clipboard_sync_menu(self, state):
		"""Reflect the shared clipboard-sync state in the menu — also when the other
		computer was the one that toggled it. Same lifetime tolerance as above."""
		item = getattr(self, 'clipboard_sync_item', None)
		if getattr(self, 'menu', None) and item:
			item.Check(bool(state))

	def on_push_clipboard_item(self, evt):
		connector = self.slave_transport or self.master_transport
		try:
			connector.send(type='set_clipboard_text', text=api.getClipData())
			cues.clipboard_pushed()
		except TypeError:
			log.exception("Unable to push clipboard")


	def on_send_file_item(self, evt):
		connector = self.slave_transport or self.master_transport
		if not getattr(connector, 'connected', False):
			ui.message(_("Not connected."))
			return
		if globalVars.appArgs.secure:
			return
		# Check if a file dialog is already open
		if getattr(self, 'is_send_file_dialog_open', False):
			return
		# Set the flag to True, indicating that the file dialog is open
		setattr(self, 'is_send_file_dialog_open', True)
		fd = wx.FileDialog(gui.mainFrame,
			# Translators: message displayed in transfer file dialog when sending a file
			message=_("Choose the file you want to send to the remote computer"),
			# Translators: supported file types when sending or receiving files
			wildcard=_("All files (*.*)") + "|*.*",
			defaultDir=os.environ['userprofile'], style=wx.FD_OPEN | wx.FD_FILE_MUST_EXIST | wx.FD_PREVIEW)
		if fd.ShowModal() != wx.ID_OK:
			# Reset the flag to False after the file dialog is closed
			setattr(self, 'is_send_file_dialog_open', False)
			return
		# Reset the flag to False after the file dialog is closed
		setattr(self, 'is_send_file_dialog_open', False)
		filename = os.path.basename(fd.GetPath())
		try:
			f = open(fd.GetPath(), "rb")
			file_content = f.read()
			f.close()
		except:
			logger.exception("Unable to read the specified file")
		if len(file_content) > 10485760:
			gui.messageBox(
				# Translators: error message when a file is too big
				message=_("This file is too large. Only files smaller than 10 MB are supported."),
				# Translators: error message caption
				caption=_("Error"),
				style=wx.ICON_ERROR)
			return
		result = gui.messageBox(
			# Translators: question before sending a file
			message=_("The session will be blocked until the transfer is complete. Are you sure you want to continue?"),
			# Translators: question title
			caption=_("Warning!"),
			style=wx.YES | wx.NO | wx.ICON_WARNING)
		if result == wx.YES:
			file_content = base64.b64encode(file_content)
			connector.send(type='file_transfer', name=filename, content=file_content.decode("utf-8"))
			cues.clipboard_pushed()
			# Translators: message spoken when the file has been sent successfully
			ui.message(_("File sent"))

	@script(
		# Translators: report number of connected computers gesture description
		_("Reports number of computers connected to a session"),
		**speakOnDemand)
	def script_reportConnectedClients(self, gesture):
		session = self.master_session or self.slave_session
		if not session:
			ui.message(_("Not connected."))
			return
		# TRANSLATORS: message reported when get number of clients gesture is pressed
		ui.message(ngettext("This is the only computer connected to this session", "There are {} computers connected to this session", session.client_count).format(session.client_count))

	@script(
		# Translators: send file gesture description
		_("Sends the specified file to the remote machine"),
		gesture="kb:control+shift+NVDA+f",
		**speakOnDemand)
	def script_send_file(self, gesture):
		wx.CallAfter(self.on_send_file_item, None)

	@script(
		# Translators: push clipboard gesture description
		_("Sends the contents of the clipboard to the remote machine"),
		gesture="kb:control+shift+NVDA+c",
		**speakOnDemand)
	def script_push_clipboard(self, gesture):
		connector = self.slave_transport or self.master_transport
		if not getattr(connector,'connected',False):
			ui.message(_("Not connected."))
			return
		try:
			connector.send(type='set_clipboard_text', text=api.getClipData())
			cues.clipboard_pushed()
			ui.message(_("Clipboard pushed"))
		except (TypeError, OSError):
			ui.message(_("Unable to push clipboard"))

	def on_copy_link_remote_item(self, evt):
		session = self.master_session or self.slave_session
		url = session.get_connection_info().get_url_to_connect(0)
		api.copyToClip(str(url))

	def on_copy_link_tele_item(self, evt):
		session = self.master_session or self.slave_session
		url = session.get_connection_info().get_url_to_connect(1)
		api.copyToClip(str(url))

	def on_options_item(self, evt):
		wx.CallAfter(gui.mainFrame.popupSettingsDialog if hasattr(gui.mainFrame, "popupSettingsDialog") else gui.mainFrame._popupSettingsDialog, gui.NVDASettingsDialog, dialogs.OptionsDialog)
		evt.Skip()

	def on_send_ctrl_alt_del(self, evt):
		self.master_transport.send('send_SAS')
		# Translators: message spoken when the Ctrl+Alt+Delete has been sent to the remote machine successfully
		ui.message(_("Ctrl+Alt+Delete has been sent to the remote machine"))

	def disconnect(self):
		if self.master_transport is None and self.slave_transport is None:
			return
		if self.server is not None:
			self.server.close()
			self.server = None
			if self.menu and self.firewall_item:
				self.firewall_item.Enable(False)
		if self.master_transport is not None:
			self.disconnect_as_master()
		if self.slave_transport is not None:
			self.disconnect_as_slave()
		# Translators: Presented when disconnected from the remote computer.
		ui.message(_("Disconnected!"))
		cues.disconnected()
		if self.menu.FindItemById(self.disconnect_item.Id):
			self.menu.Remove(self.disconnect_item.Id)
		if not self.menu.FindItemById(self.connect_item.Id):
			self.menu.Insert(0, self.connect_item)
		self.push_clipboard_item.Enable(False)
		self.send_file_item.Enable(False)
		self.copy_link_remote_item.Enable(False)
		self.copy_link_tele_item.Enable(False)
		self.audio_item.Enable(False)
		self.audio_item.Check(False)
		self.set_audio_item_role(as_slave=False)
		self.clipboard_sync_item.Enable(False)
		self.clipboard_sync_item.Check(False)

	def disconnect_as_master(self):
		self.audio.shutdown()
		self.clipboard_sync.shutdown()
		self.master_transport.close()
		self.master_transport = None
		self.master_session = None

	def disconnecting_as_master(self):
		if self.menu:
			if not self.menu.FindItemById(self.connect_item.Id):
				self.menu.Insert(0, self.connect_item)
			if self.menu.FindItemById(self.disconnect_item.Id):
				self.menu.Remove(self.disconnect_item.Id)
			# Translators: Menu item in TeleNVDA submenu to mute speech and sounds from the remote computer.
			self.mute_item.SetItemLabel(_("Mute remote"))
			self.mute_item.Enable(False)
			self.push_clipboard_item.Enable(False)
			self.send_file_item.Enable(False)
			self.copy_link_remote_item.Enable(False)
			self.copy_link_tele_item.Enable(False)
			self.send_ctrl_alt_del_item.Enable(False)
			self.audio_item.Enable(False)
			self.audio_item.Check(False)
			self.set_audio_item_role(as_slave=False)
			self.clipboard_sync_item.Enable(False)
			self.clipboard_sync_item.Check(False)
		if self.local_machine:
			self.local_machine.is_muted = False
		self.sending_keys = False
		self.muted = False
		if buildVersion.version_year < 2025:
			if self.hook_thread is not None:
				ctypes.windll.user32.PostThreadMessageW(self.hook_thread.ident, WM_QUIT, 0, 0)
				self.hook_thread.join()
				self.hook_thread = None
		self.key_modifiers = set()

	def disconnect_as_slave(self):
		self.audio.shutdown()
		self.clipboard_sync.shutdown()
		self.slave_transport.close()
		self.slave_transport = None
		self.slave_session = None

	def on_connected_as_master_failed(self):
		if self.master_transport.successful_connects == 0:
			self.disconnect_as_master()
			# Translators: Title of the connection error dialog.
			gui.messageBox(parent=gui.mainFrame, caption=_("Error Connecting"),
			# Translators: Message shown when cannot connect to the remote computer.
			message=_("Unable to connect to the remote computer"), style=wx.OK | wx.ICON_WARNING)

	def do_connect(self, evt):
		if evt:
			evt.Skip()
		# Check if the connect dialog is already open
		if getattr(self, 'is_connect_dialog_open', False):
			return
		# Set the flag to True, indicating that the connect dialog is open
		setattr(self, 'is_connect_dialog_open', True)
		last_cons = configuration.get_config()['connections']['last_connected']
		# Translators: Title of the connect dialog.
		dlg = dialogs.DirectConnectDialog(parent=gui.mainFrame, id=wx.ID_ANY, title=_("Connect"))
		dlg.panel.host.SetItems(list(reversed(last_cons)))
		dlg.panel.host.SetSelection(0)
		def handle_dlg_complete(dlg_result):
			if dlg_result != wx.ID_OK:
				# Reset the flag to False when the dialog is closed
				setattr(self, 'is_connect_dialog_open', False)
				return
			if dlg.client_or_server.GetSelection() == 0: #client
				host = dlg.panel.host.GetValue()
				server_addr, port = address_to_hostport(host)
				channel = dlg.panel.key.GetValue()
				encryption_key = dlg.panel.encryption_key.GetValue()
				if dlg.connection_type.GetSelection() == 0:
					self.connect_as_master((server_addr, port), channel, encryption_key)
				else:
					self.connect_as_slave((server_addr, port), channel, encryption_key)
			else: #We want a server
				channel = dlg.panel.key.GetValue()
				encryption_key = dlg.panel.encryption_key.GetValue()
				server_port = int(dlg.panel.port.GetValue())
				useUPNP = bool(dlg.panel.useUPNP.GetValue())
				if not useUPNP:
					useUPNP = gui.messageBox(
						# Translators: question asked before starting a control server, offering to forward the port automatically.
						message=_("remremote can try to automatically forward port {port} in your router using UPnP: TCP for the control connection and UDP for remote audio streaming. Do you want to do this now?").format(port=server_port),
						# Translators: title of the automatic port forwarding question.
						caption=_("Automatic port forwarding"),
						style=wx.YES | wx.NO | wx.ICON_QUESTION) == wx.YES
				if not self.start_control_server(server_port, channel, useUPNP=useUPNP):
					setattr(self, 'is_connect_dialog_open', False)
					return
				if dlg.connection_type.GetSelection() == 0:
					self.connect_as_master(('127.0.0.1', int(dlg.panel.port.GetValue())), channel, insecure=True, encryption_key=encryption_key)
				else:
					self.connect_as_slave(('127.0.0.1', int(dlg.panel.port.GetValue())), channel, insecure=True, encryption_key=encryption_key)
			# Reset the flag to False when the dialog is closed
			setattr(self, 'is_connect_dialog_open', False)
		gui.runScriptModalDialog(dlg, callback=handle_dlg_complete)

	def on_connected_as_master(self):
		configuration.write_connection_to_config(self.master_transport.address)
		if not self.menu.FindItemById(self.disconnect_item.Id):
			self.menu.Insert(0, self.disconnect_item)
		if self.menu.FindItemById(self.connect_item.Id):
			self.menu.Remove(self.connect_item.Id)
		self.mute_item.Enable(True)
		self.push_clipboard_item.Enable(True)
		if not globalVars.appArgs.secure:
			self.send_file_item.Enable(True)
		self.copy_link_remote_item.Enable(True)
		self.copy_link_tele_item.Enable(True)
		self.send_ctrl_alt_del_item.Enable(True)
		# Audio streaming is the controlled machine's switch, but the controlling side may
		# ask for it — from the menu item or the gesture.
		self.set_audio_item_role(as_slave=False)
		self.audio_item.Enable(True)
		self.clipboard_sync_item.Enable(True)
		# We own the "use the remote synthesizer" setting: tell the controlled computer where
		# it stands, so its own gesture toggles from the right value and its user is never
		# shown a state we don't agree with.
		self.audio.send_remote_tts_state()
		if buildVersion.version_year < 2025:
			# We might have already created a hook thread before if we're restoring an
			# interrupted connection. We must not create another.
			if not self.hook_thread:
				self.hook_thread = threading.Thread(target=self.hook)
				self.hook_thread.daemon = True
				self.hook_thread.start()
		# Translators: Presented when connected to the remote computer.
		ui.message(_("Connected!"))
		cues.connected()
		if configuration.get_config()['ui']['mute_when_controlling_local_machine'] and not self.sending_keys:
			self.local_machine.is_muted = True

	def on_disconnected_as_master(self):
		# Translators: Presented when connection to a remote computer was interupted.
		ui.message(_("Connection interrupted"))

	def connect_as_master(self, address, key, encryption_key, insecure=False):
		transport = RelayTransport(address=address, serializer=serializer.JSONSerializer(), channel=key, connection_type='master', insecure=insecure, encryption_key=encryption_key)
		self.master_session = MasterSession(transport=transport, local_machine=self.local_machine)
		transport.callback_manager.register_callback(TransportEvents.CERTIFICATE_AUTHENTICATION_FAILED, self.on_certificate_as_master_failed)
		transport.callback_manager.register_callback(TransportEvents.CONNECTED, self.on_connected_as_master)
		transport.callback_manager.register_callback(TransportEvents.CONNECTION_FAILED, self.on_connected_as_master_failed)
		transport.callback_manager.register_callback(TransportEvents.CLOSING, self.disconnecting_as_master)
		transport.callback_manager.register_callback(TransportEvents.DISCONNECTED, self.on_disconnected_as_master)
		self.audio.register_master(transport)
		self.clipboard_sync.register(transport)
		self.master_transport = transport
		self.master_transport.reconnector_thread.start()

	def connect_as_slave(self, address, key, encryption_key, insecure=False):
		# The secure desktop copy joins its local bridge unattended; a modal dialog there
		# would silently block the handover, and the setting it asks about belongs to the
		# user session anyway.
		if not globalVars.appArgs.secure and not nvda_conf['keyboard']['handleInjectedKeys'] and gui.messageBox(
		# Translators: A message to warn the user that handle keys from other applications should be on.
		message=_("The option to handle keys from other applications is disabled in your NVDA keyboard settings. In order to allow the keyboard of this machine to be controlled, this option should be enabled. Would you like to do this now?"),
		# Translators: The title of the warning dialog displayed when handle keys from other applications is disabled.
		caption=_("Warning"),style=wx.YES|wx.NO|wx.ICON_WARNING)==wx.YES:
			nvda_conf['keyboard']['handleInjectedKeys']=True
		transport = RelayTransport(serializer=serializer.JSONSerializer(), address=address, channel=key, connection_type='slave', insecure=insecure, encryption_key=encryption_key)
		self.slave_session = SlaveSession(transport=transport, local_machine=self.local_machine)
		self.slave_transport = transport
		transport.callback_manager.register_callback(TransportEvents.CERTIFICATE_AUTHENTICATION_FAILED, self.on_certificate_as_slave_failed)
		self.slave_transport.callback_manager.register_callback(TransportEvents.CONNECTED, self.on_connected_as_slave)
		# Not on the secure desktop: the user session is still streaming audio from its own
		# helper process, and a second one would fight it for the same UDP port. Clipboard
		# sync belongs to the user session for the same reason.
		if not globalVars.appArgs.secure:
			self.audio.register_slave(transport)
			self.clipboard_sync.register(transport)
		self.slave_transport.reconnector_thread.start()
		if not self.menu.FindItemById(self.disconnect_item.Id):
			self.menu.Insert(0, self.disconnect_item)
		if self.menu.FindItemById(self.connect_item.Id):
			self.menu.Remove(self.connect_item.Id)

	def handle_certificate_failed(self, transport):
		self.last_fail_address = transport.address
		self.last_fail_key = transport.channel
		self.last_fail_encryption_key = getattr(transport, 'encryption_key', '')
		self.disconnect()
		try:
			cert_hash = transport.last_fail_fingerprint
			wnd = dialogs.CertificateUnauthorizedDialog(None, fingerprint=cert_hash)
			a = wnd.ShowModal()
			if a == wx.ID_YES:
				config = configuration.get_config()
				config['trusted_certs'][hostport_to_address(self.last_fail_address)]=cert_hash
				config.write()
			if a == wx.ID_YES or a == wx.ID_NO: return True
		except Exception as ex:
			log.error(ex)
		return False

	def on_certificate_as_master_failed(self):
		if self.handle_certificate_failed(self.master_transport):
			# The user accepted the certificate: reconnect with the same encryption key,
			# this time without certificate verification.
			self.connect_as_master(self.last_fail_address, self.last_fail_key, self.last_fail_encryption_key, insecure=True)

	def on_certificate_as_slave_failed(self):
		if self.handle_certificate_failed(self.slave_transport):
			self.connect_as_slave(self.last_fail_address, self.last_fail_key, self.last_fail_encryption_key, insecure=True)

	def on_connected_as_slave(self):
		log.info("Control connector connected")
		cues.control_server_connected()
		if not self.sd_handover:
			# Announce a real connection, but stay quiet for the internal handover to a
			# secure desktop — that one fires on every single UAC prompt, where the cue
			# above is feedback enough.
			# Translators: Presented in direct (client to server) remote connection when the controlled computer is ready.
			speech.speakMessage(_("Connected to control server"))
		self.push_clipboard_item.Enable(True)
		if not globalVars.appArgs.secure:
			self.send_file_item.Enable(True)
		self.copy_link_remote_item.Enable(True)
		self.copy_link_tele_item.Enable(True)
		# Clipboard sync is symmetric — the controlled machine may toggle it too.
		self.clipboard_sync_item.Enable(True)
		# The audio being shared is this machine's own, so its user owns the switch. Not on
		# the secure desktop, where no helper process of ours runs (see connect_as_slave).
		if not globalVars.appArgs.secure:
			self.set_audio_item_role(as_slave=True)
			self.audio_item.Enable(True)
		configuration.write_connection_to_config(self.slave_transport.address)

	def start_control_server(self, server_port, channel, useUPNP=False):
		"""Starts hosting a control server. Returns False if the port could not be bound,
		in which case the caller must not go on to connect to it."""
		if self.server is not None:
			# Already hosting — most likely a second autoconnect attempt. Reusing the
			# running server is right; binding the port again would just fail.
			return True
		self.maybe_offer_firewall_exception(server_port)
		try:
			self.server = server.Server(server_port, channel, UPNP=useUPNP)
		except OSError:
			log.exception("Could not start the control server on port %s" % server_port)
			self.server = None
			# Translators: reported when the control server could not be started; {port} is the port number.
			ui.message(_("Could not start the control server on port {port}. Another program — or another copy of NVDA — may already be using it.").format(port=server_port))
			return False
		server_thread = threading.Thread(target=self.server.run)
		server_thread.daemon = True
		server_thread.start()
		if self.menu and self.firewall_item:
			self.firewall_item.Enable(True)
		return True

	def on_firewall_item(self, evt):
		if evt:
			evt.Skip()
		if self.server is None:
			# Translators: reported when firewall rules are requested while not hosting a control server.
			ui.message(_("No control server is running on this computer."))
			return
		self.add_firewall_exceptions(self.server.port)

	def maybe_offer_firewall_exception(self, port):
		"""One-time offer, on the very first start of a self-hosted control server, to add
		Windows Firewall exceptions for NVDA (inbound TCP control connections) and the audio
		helper (inbound UDP audio). Asked exactly once; the answer is acted on immediately and
		the question is never repeated either way."""
		if globalVars.appArgs.secure or configuration.readonly:
			# We could neither remember the answer nor sensibly show a dialog here; the
			# menu item stays available for a deliberate manual run.
			return
		config = configuration.get_config()
		if config['firewall']['prompt_shown']:
			return
		config['firewall']['prompt_shown'] = True
		if not configuration.readonly:
			config.write()
		result = gui.messageBox(
			# Translators: question asked the first time the user hosts a control server, offering to add firewall exceptions.
			message=_("Since you are hosting a control server for the first time: should remremote add itself to the Windows Firewall exceptions, so that incoming control and audio connections are not blocked? This may trigger a User Account Control prompt which you will need to confirm."),
			# Translators: title of the firewall exception question.
			caption=_("Windows Firewall"),
			style=wx.YES | wx.NO | wx.ICON_QUESTION)
		if result != wx.YES:
			return
		self.add_firewall_exceptions(port)

	def add_firewall_exceptions(self, port):
		"""Adds inbound allow rules on the given port for nvda.exe (TCP control) and the bundled
		audio helper (UDP audio) via an elevated netsh — one cmd.exe invocation, one UAC prompt.
		Control and audio share the same port number, so one number covers the whole session.

		Every pre-existing inbound rule for those two programs is deleted first. This is not
		just duplicate hygiene: Windows Firewall gives BLOCK rules precedence over allow
		rules, so a leftover block rule for nvda.exe — which Windows creates silently
		whenever someone dismisses its "allow this app?" prompt — makes an added allow rule
		useless and leaves the port unreachable from outside while looking perfectly
		forwarded in the router. Deleting first and re-adding is the only reliable fix.
		profile=any so the rules also apply when Windows has classified the network as
		public, which is where those block rules usually live.
		"""
		buf = ctypes.create_unicode_buffer(260)
		ctypes.windll.kernel32.GetModuleFileNameW(None, buf, 260)
		nvda_exe = buf.value
		host_exe = audio.host_exe_path()
		commands = (
			f'netsh advfirewall firewall delete rule name=all dir=in program="{nvda_exe}"'
			f' & netsh advfirewall firewall delete rule name=all dir=in program="{host_exe}"'
			' & netsh advfirewall firewall delete rule name="remremote control"'
			' & netsh advfirewall firewall delete rule name="remremote audio"'
			f' & netsh advfirewall firewall add rule name="remremote control" dir=in action=allow protocol=tcp localport={port} profile=any program="{nvda_exe}"'
			f' & netsh advfirewall firewall add rule name="remremote audio" dir=in action=allow protocol=udp localport={port} profile=any program="{host_exe}"'
		)
		ret = ctypes.windll.shell32.ShellExecuteW(None, "runas", "cmd.exe", "/c " + commands, None, 0)
		if ret <= 32:
			# Launch failed or the user dismissed the UAC prompt.
			# Translators: reported when the firewall exceptions could not be added.
			ui.message(_("Could not add the firewall exceptions. You can add NVDA and the audio helper to the Windows Firewall manually."))
		else:
			# Translators: reported after requesting the firewall exceptions.
			ui.message(_("Firewall exceptions requested. Please confirm the User Account Control prompt if it appears."))

	def hook(self):
		log.debug("Hook thread start")
		keyhook = keyboard_hook.KeyboardHook()
		keyhook.register_callback(self.hook_callback)
		msg = ctypes.wintypes.MSG()
		while ctypes.windll.user32.GetMessageW(ctypes.byref(msg), None, 0, 0):
			pass
		log.debug("Hook thread end")
		keyhook.free()

	def hook_callback(self, **kwargs):
		#Prevent disabling sending keys if another key is held down
		if not self.sending_keys:
			return False
		keyCode = (kwargs['vk_code'], kwargs['extended'])
		if not kwargs['pressed'] and keyCode in self.hostPendingModifiers:
			self.hostPendingModifiers.discard(keyCode)
			return False
		gesture = KeyboardInputGesture(self.key_modifiers, keyCode[0], kwargs['scan_code'], keyCode[1])
		if gesture.isModifier:
			if kwargs['pressed']:
				self.key_modifiers.add(keyCode)
			else:
				self.key_modifiers.discard(keyCode)
		elif kwargs['pressed']:
			script = gesture.script
			if self.ignoreGesture:
				self.ignoreGesture = False
			elif script in self.guestScripts:
				wx.CallAfter(script, gesture)
				return True
		self.master_transport.send(type="key", **kwargs)
		return True #Don't pass it on

	def set_receiving_braille(self, state):
		if state and self.master_session.patch_callbacks_added and braille.handler.enabled:
			self.master_session.patcher.patch_braille_input()
			if buildVersion.version_year < 2023:
				braille.handler.enabled = False
				if braille.handler._cursorBlinkTimer:
					braille.handler._cursorBlinkTimer.Stop()
					braille.handler._cursorBlinkTimer=None
				if braille.handler.buffer is braille.handler.messageBuffer:
					braille.handler.buffer.clear()
					braille.handler.buffer = braille.handler.mainBuffer
					if braille.handler._messageCallLater:
						braille.handler._messageCallLater.Stop()
						braille.handler._messageCallLater = None
			self.local_machine.receiving_braille=True
		elif not state:
			self.master_session.patcher.unpatch_braille_input()
			if buildVersion.version_year < 2023:
				braille.handler.enabled = bool(braille.handler.displaySize)
			self.local_machine.receiving_braille=False

	def onSecureDesktopChange(self, isSecureDesktop: bool):
		'''
		@param isSecureDesktop: True if the new desktop is the secure desktop.
		'''
		if isSecureDesktop:
			self.enter_secure_desktop()
		else:
			self.leave_secure_desktop()

	def event_gainFocus(self, obj, nextHandler):
		if not hasattr(IAccessibleHandler, 'SecureDesktopNVDAObject'):
			nextHandler()
			return
		if isinstance(obj, IAccessibleHandler.SecureDesktopNVDAObject):
			self.sd_focused = True
			self.enter_secure_desktop()
		elif self.sd_focused and not isinstance(obj, IAccessibleHandler.SecureDesktopNVDAObject):
			#event_leaveFocus won't work for some reason
			self.sd_focused = False
			self.leave_secure_desktop()
		nextHandler()

	def enter_secure_desktop(self):
		"""function ran when entering a secure desktop."""
		if self.slave_transport is None:
			return
		if self.sd_server is not None:
			# A second desktop change event must not start a second relay behind the
			# first one's back — that would leak the server and its thread.
			return
		try:
			if not os.path.exists(self.temp_location):
				os.makedirs(self.temp_location)
			channel = str(uuid.uuid4())
			# Loopback only, for both families: nothing outside this machine has any
			# business talking to the handover relay.
			self.sd_server = server.Server(port=0, password=channel, bind_host='127.0.0.1', bind_host6='::1')
			port = self.sd_server.server_socket.getsockname()[1]
			server_thread = threading.Thread(target=self.sd_server.run)
			server_thread.daemon = True
			server_thread.start()
			self.sd_relay = RelayTransport(address=('127.0.0.1', port), serializer=serializer.JSONSerializer(), channel=channel, insecure=True)
			self.sd_relay.callback_manager.register_callback('msg_client_joined', self.on_master_display_change)
			self.slave_transport.callback_manager.register_callback('msg_set_braille_info', self.on_master_display_change)
			self.sd_bridge = bridge.BridgeTransport(self.slave_transport, self.sd_relay)
			relay_thread = threading.Thread(target=self.sd_relay.run)
			relay_thread.daemon = True
			relay_thread.start()
			data = [port, channel]
			# Written last: its presence is what tells the secure desktop copy of NVDA
			# that there is a working relay to join.
			with open(self.ipc_file, 'w') as fp:
				json.dump(data, fp)
		except Exception:
			log.exception("Could not prepare the secure desktop handover")
			self.cleanup_secure_desktop()

	def leave_secure_desktop(self):
		if self.sd_server is None:
			return #Nothing to do
		self.cleanup_secure_desktop()
		if self.slave_session is not None:
			self.slave_session.set_display_size()

	def cleanup_secure_desktop(self):
		"""Tear down whatever parts of the handover exist, in any order of partial setup."""
		if self.sd_bridge is not None:
			self.sd_bridge.disconnect()
			self.sd_bridge = None
		if self.sd_server is not None:
			self.sd_server.close()
			self.sd_server = None
		if self.sd_relay is not None:
			self.sd_relay.close()
			self.sd_relay = None
		if self.slave_transport is not None:
			try:
				self.slave_transport.callback_manager.unregister_callback('msg_set_braille_info', self.on_master_display_change)
			except ValueError:
				pass  # setup never got this far
		try:
			os.unlink(self.ipc_file)
		except OSError:
			pass

	def on_master_display_change(self, **kwargs):
		self.sd_relay.send(type='set_display_size', sizes=self.slave_session.master_display_sizes)

	SD_CONNECT_BLOCK_TIMEOUT = 1
	def handle_secure_desktop(self):
		"""Join the local bridge that the user session set up, so the remote side keeps
		seeing this machine while a secure desktop (UAC, sign-in screen) is up.

		Returns True only if we actually joined it. False means there was nothing to join
		— on the sign-in screen there is no user session at all — and the caller is then
		free to establish a connection of its own."""
		try:
			with open(self.ipc_file) as fp:
				data = json.load(fp)
			os.unlink(self.ipc_file)
		except FileNotFoundError:
			# No session was active when the secure desktop appeared: nothing to join.
			return False
		except (OSError, ValueError):
			log.exception("Could not read the secure desktop handover file")
			return False
		try:
			port, channel = data
			test_socket=socket.socket(socket.AF_INET, socket.SOCK_STREAM)
			test_socket=wrap_socket(test_socket, ssl_version=ssl.PROTOCOL_TLS_CLIENT)
			test_socket.connect(('127.0.0.1', port))
			test_socket.close()
			# The bridge is a plain loopback relay: the user session's transport already
			# decrypted everything, so this hop carries no application layer key.
			self.sd_handover = True
			self.connect_as_slave(('127.0.0.1', port), channel, encryption_key='', insecure=True)
			# So we don't miss the first output when switching to a secure desktop,
			# block the main thread until the connection is established. We're
			# connecting to localhost, so this should be pretty fast. Use a short
			# timeout, though.
			self.slave_transport.connected_event.wait(self.SD_CONNECT_BLOCK_TIMEOUT)
			return True
		except Exception:
			# Never let this kill the plugin, but do leave a trace: a silent failure here
			# looks to the user exactly like "the add-on does nothing in the UAC dialog".
			log.exception("Could not join the remote session on the secure desktop")
			self.sd_handover = False
			return False

	def verify_connect(self, con_info):
		if self.is_connected() or self.connecting:
			gui.messageBox(_("remremote is already connected. Disconnect before opening a new connection."), _("remremote Already Connected"), wx.OK|wx.ICON_WARNING)
			return
		self.connecting = True
		server_addr = con_info.get_address()
		key = con_info.key
		encryption_key = con_info.encryption_key
		if con_info.mode == 'master':
			message = _("Do you wish to control the machine on server {server} with key {key}?").format(server=server_addr, key=key)
		elif con_info.mode == 'slave':
			message = _("Do you wish to allow this machine to be controlled on server {server} with key {key}?").format(server=server_addr, key=key)
		if gui.messageBox(message, _("remremote Connection Request"), wx.YES|wx.NO|wx.NO_DEFAULT|wx.ICON_WARNING) != wx.YES:
			self.connecting = False
			return
		if con_info.mode == 'master':
			self.connect_as_master((con_info.hostname, con_info.port), key=key, encryption_key=encryption_key)
		elif con_info.mode == 'slave':
			self.connect_as_slave((con_info.hostname, con_info.port), key=key, encryption_key=encryption_key)
		self.connecting = False

	def is_connected(self):
		connector = self.slave_transport or self.master_transport
		if connector is not None:
			return connector.connected
		return False

	@script(
		# Translators: Copy link compatible with NVDA Remote gesture description
		description=_("Copies a link to the remote session to the clipboard compatible with both NVDA Remote and TeleNVDA"),
		**speakOnDemand)
	def script_copy_remote_link(self, gesture):
		connector = self.slave_transport or self.master_transport
		if not getattr(connector,'connected',False):
			ui.message(_("Not connected."))
			return
		self.on_copy_link_remote_item(None)
		ui.message(_("Copied link"))

	@script(
		# Translators: Copy link compatible with TeleNVDA gesture description
		description=_("Copies a link to the remote session to the clipboard compatible only with TeleNVDA"),
		**speakOnDemand)
	def script_copy_tele_link(self, gesture):
		connector = self.slave_transport or self.master_transport
		if not getattr(connector,'connected',False):
			ui.message(_("Not connected."))
			return
		self.on_copy_link_tele_item(None)
		ui.message(_("Copied link"))

	@script(
		# Translators: description for the Connect gesture
		_("""Opens a dialog to start a remote session"""),
		gesture="kb:alt+NVDA+pageUp",
		**speakOnDemand)
	def script_connect(self, gesture):
		if self.master_transport or self.slave_transport:
			ui.message(_("remremote Already Connected"))
			return
		self.do_connect(None)

	@script(
		# Translators: description for the Disconnect gesture
		_("""Disconnect a remote session"""),
		gesture="kb:alt+NVDA+pageDown",
		**speakOnDemand)
	def script_disconnect(self, gesture):
		if self.master_transport is None and self.slave_transport is None:
			ui.message(_("Not connected."))
			return
		self.on_disconnect_item(None)

	@script(
		# Translators: gesture description for the ignoreNextGesture script
		_("""Set the host to ignore the next gesture completely, sending next gesture to the guest as is. Useful when you need to use the gesture asigned to toggle between guest and host, in the guest machine."""),
		gesture = "kb:control+f11",
		**speakOnDemand)
	def script_ignoreNextGesture(self, gesture):
		if not self.master_transport or not self.sending_keys:
			return gesture.send()
		self.ignoreGesture = True
		# Translators: Report when the next gesture will be send to the guest ignoring everything else.
		ui.message(_("Send next gesture to the guest"))

	@script(
		# Translators: Documentation string for the script that toggles the control between guest and host machine.
		description=_("Toggles the control between guest and host machine"),
		gesture="kb:f11",
		**speakOnDemand)
	def script_sendKeys(self, gesture):
		if not self.master_transport:
			gesture.send()
			return
		self.sending_keys = not self.sending_keys
		self.set_receiving_braille(self.sending_keys)
		if self.sending_keys:
			if buildVersion.version_year==2022 and buildVersion.version_major==4:
				security.postSessionLockStateChanged.register(self.onSessionLockStateChange)
			elif buildVersion.version_year>=2023:
				security.post_sessionLockStateChanged.register(self.onSessionLockStateChange)
			self.hostPendingModifiers = gesture.modifiers
			# Translators: Presented when sending keyboard keys from the controlling computer to the controlled computer.
			ui.message(_("Controlling remote machine."))
			if buildVersion.version_year >= 2025:
				inputCore.decide_handleRawKey.register(self.handleRawKeys)
			if configuration.get_config()['ui']['mute_when_controlling_local_machine'] and not self.muted:
				# Only change this value if user didn't explicitly mute the remote machine
				self.local_machine.is_muted = False
		else:
			# release all pressed keys in the guest.
			for k in self.key_modifiers:
				self.master_transport.send(type="key", vk_code=k[0], extended=k[1], pressed=False)
			self.key_modifiers = set()
			if buildVersion.version_year==2022 and buildVersion.version_major==4:
				security.postSessionLockStateChanged.unregister(self.onSessionLockStateChange)
			elif buildVersion.version_year>=2023:
				security.post_sessionLockStateChanged.unregister(self.onSessionLockStateChange)
			# Translators: Presented when keyboard control is back to the controlling computer.
			ui.message(_("Controlling local machine."))
			if buildVersion.version_year >= 2025:
				inputCore.decide_handleRawKey.unregister(self.handleRawKeys)
			if configuration.get_config()['ui']['mute_when_controlling_local_machine'] and not self.muted:
				self.local_machine.is_muted = True

	def handleRawKeys(self, vkCode, scanCode, extended, pressed):
		keyCode = (vkCode, extended)
		if not pressed and keyCode in self.hostPendingModifiers:
			self.hostPendingModifiers.discard(keyCode)
			return True
		gesture = KeyboardInputGesture(self.key_modifiers, keyCode[0], scanCode, keyCode[1])
		if gesture.isModifier:
			if pressed:
				self.key_modifiers.add(keyCode)
			else:
				self.key_modifiers.discard(keyCode)
		elif pressed:
			script = gesture.script
			if self.ignoreGesture:
				self.ignoreGesture = False
			elif script in self.guestScripts:
				wx.CallAfter(script, gesture)
				return False
		self.master_transport.send(type="key", vk_code=vkCode, scan_code=scanCode, extended=extended, pressed=pressed)
		return False

	def onSessionLockStateChange(self, isNowLocked):
		if isNowLocked:
			self.script_sendKeys(None)

	@script(
		# Translators: gesture description for the toggle remote mute script
		description=_("""Mute or unmute the speech coming from the remote computer"""),
		**speakOnDemand)
	def script_toggle_remote_mute(self, gesture):
		if not self.is_connected() or self.connecting or self.slave_transport: return
		self.on_mute_item(None)

	@script(
		# Translators: gesture description for the toggle remote audio script
		description=_("""Turn streaming of the controlled computer's audio on or off"""),
		gesture="kb:control+shift+NVDA+a",
		**speakOnDemand)
	def script_toggle_remote_audio(self, gesture):
		# Works on both ends: on the controlled computer it shares (or takes back) its own
		# audio, on the controlling computer it asks that machine to share. Pressed with key
		# forwarding on, it travels to the controlled computer and toggles it right there.
		if self.connecting:
			return
		self.on_audio_item(None)

	@script(
		# Translators: gesture description for the clipboard sync toggle
		description=_("""Turn synchronisation of both computers' clipboards on or off"""),
		gesture="kb:control+shift+NVDA+k",
		**speakOnDemand)
	def script_toggle_clipboard_sync(self, gesture):
		if self.connecting:
			return
		self.clipboard_sync.toggle()

	@script(
		# Translators: gesture description for the remote speech synthesizer toggle
		description=_("""Turn using the speech synthesizer of the remote computer during audio streaming on or off"""),
		gesture="kb:control+shift+NVDA+s",
		**speakOnDemand)
	def script_toggle_remote_tts(self, gesture):
		# Usable from both ends, like the audio toggle itself: only the controlling computer
		# stores the setting, the controlled one asks it to flip.
		if self.connecting:
			return
		self.audio.toggle_remote_tts()

	@script(
		# Translators: send Ctrl+Alt+Delete gesture description
		description=_("""Sends Ctrl+Alt+Delete to the remote machine"""),
		**speakOnDemand)
	def script_send_ctrl_alt_del(self, gesture):
		if not self.is_connected() or self.connecting or self.slave_transport: return
		self.on_send_ctrl_alt_del(None)

	@script(
		# Translators: open addon settings gesture description
		description=_("""Opens the addon settings panel inside NVDA settings dialog"""))
	def script_options(self, gesture):
		self.on_options_item(None)

	@script(
		# Translators: gesture description for the repair firewall exceptions script
		description=_("""Adds or repairs the Windows Firewall exceptions for remremote"""),
		**speakOnDemand)
	def script_add_firewall_exceptions(self, gesture):
		# Deliberately bypasses the one-time prompt flag: this is the manual escape hatch for
		# when incoming connections are blocked despite a working router port forward (usually
		# a stale Windows block rule for nvda.exe — see add_firewall_exceptions).
		self.on_firewall_item(None)
