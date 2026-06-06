from __future__ import annotations

import json
import threading
import webbrowser
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Callable
from urllib.parse import quote

import requests
import wx


APP_NAME = "VoiceLinkWX"
DEFAULT_SERVER = "https://voicelink.devinecreations.net"
CONFIG_DIR = Path.home() / "AppData" / "Roaming" / "VoiceLinkWX"
CONFIG_PATH = CONFIG_DIR / "settings.json"


def normalize_base_url(value: str) -> str:
    value = value.strip()
    if not value:
        return DEFAULT_SERVER
    if not value.startswith(("http://", "https://")):
        value = "https://" + value
    return value.rstrip("/")


def display_value(value: Any) -> str:
    if value is None:
        return ""
    if isinstance(value, (list, tuple)):
        return ", ".join(display_value(item) for item in value)
    if isinstance(value, dict):
        for key in ("name", "displayName", "username", "id"):
            if key in value:
                return display_value(value[key])
        return json.dumps(value, ensure_ascii=False)
    return str(value)


def list_from_payload(payload: Any, keys: tuple[str, ...]) -> list[Any]:
    if isinstance(payload, list):
        return payload
    if isinstance(payload, dict):
        for key in keys:
            value = payload.get(key)
            if isinstance(value, list):
                return value
    return []


@dataclass
class RoomRecord:
    room_id: str
    name: str
    description: str
    raw: dict[str, Any]


class VoiceLinkApi:
    def __init__(self) -> None:
        self.session = requests.Session()
        self.session.headers.update({"User-Agent": f"{APP_NAME}/0.1"})
        self.base_url = DEFAULT_SERVER
        self.token = ""

    def configure(self, base_url: str, token: str = "") -> None:
        self.base_url = normalize_base_url(base_url)
        self.token = token.strip()

    def _headers(self) -> dict[str, str]:
        if self.token:
            return {
                "Authorization": f"Bearer {self.token}",
                "x-session-token": self.token,
                "x-voicelink-auth-level": "account",
            }
        return {}

    def get_json(self, path: str, timeout: float = 15.0) -> Any:
        response = self.session.get(
            f"{self.base_url}{path}",
            headers=self._headers(),
            timeout=timeout,
        )
        response.raise_for_status()
        if not response.content:
            return {}
        return response.json()

    def post_json(self, path: str, payload: dict[str, Any], timeout: float = 20.0) -> Any:
        response = self.session.post(
            f"{self.base_url}{path}",
            json=payload,
            headers=self._headers(),
            timeout=timeout,
        )
        response.raise_for_status()
        if not response.content:
            return {}
        return response.json()

    def health(self) -> Any:
        return self.get_json("/api/health")

    def config(self) -> Any:
        return self.get_json("/api/config")

    def admin_status(self) -> Any:
        return self.get_json("/api/admin/status")

    def auth_providers(self) -> dict[str, Any]:
        try:
            payload = self.get_json("/api/auth/providers")
            return payload if isinstance(payload, dict) else {}
        except Exception:
            return {}

    def oauth_providers(self) -> dict[str, Any]:
        try:
            payload = self.get_json("/api/auth/oauth/providers")
            return payload if isinstance(payload, dict) else {}
        except Exception:
            return {}

    def validate_current_session(self) -> dict[str, Any]:
        if not self.token:
            return {"valid": False, "error": "No saved session token."}
        checks: tuple[tuple[str, str], ...] = (
            ("whmcs", f"/api/auth/whmcs/session/{quote(self.token, safe='')}"),
            ("local", "/api/auth/local/me"),
            ("api", f"/api/auth/session/{quote(self.token, safe='')}"),
        )
        last_error = ""
        for provider, path in checks:
            try:
                payload = self.get_json(path, timeout=8.0)
                if isinstance(payload, dict) and (payload.get("valid") is True or payload.get("success") is True):
                    return {
                        "valid": True,
                        "provider": provider,
                        "user": payload.get("user") or payload,
                        "expiresAt": payload.get("expiresAt"),
                    }
            except requests.HTTPError as exc:
                last_error = self.extract_error(exc)
            except Exception as exc:
                last_error = str(exc)
        return {"valid": False, "error": last_error or "Saved session is invalid or expired."}

    def login_whmcs(
        self,
        identity: str,
        password: str,
        two_factor_code: str = "",
        portal_site: str = "devine-creations",
        remember: bool = True,
    ) -> dict[str, Any]:
        payload: dict[str, Any] = {
            "identity": identity,
            "password": password,
            "portalSite": portal_site,
            "remember": remember,
        }
        if two_factor_code:
            payload["twoFactorCode"] = two_factor_code
        result = self.post_json("/api/auth/whmcs/login", payload)
        return result if isinstance(result, dict) else {}

    def login_local(self, identity: str, password: str, two_factor_code: str = "") -> dict[str, Any]:
        payload: dict[str, Any] = {
            "identity": identity,
            "password": password,
        }
        if two_factor_code:
            payload["twoFactorCode"] = two_factor_code
        result = self.post_json("/api/auth/local/login", payload)
        return result if isinstance(result, dict) else {}

    def logout_whmcs(self) -> dict[str, Any]:
        result = self.post_json("/api/auth/whmcs/logout", {"token": self.token})
        return result if isinstance(result, dict) else {}

    def rooms(self) -> list[RoomRecord]:
        payload = self.get_json("/api/rooms?source=app&client=windows-wxpython&sort=name")
        rooms = list_from_payload(payload, ("rooms", "data", "items"))
        records: list[RoomRecord] = []
        for room in rooms:
            if not isinstance(room, dict):
                continue
            room_id = display_value(
                room.get("id")
                or room.get("roomId")
                or room.get("_id")
                or room.get("slug")
                or room.get("name")
            )
            name = display_value(room.get("name") or room.get("title") or room_id)
            description = display_value(room.get("description") or room.get("topic") or room.get("status"))
            if room_id:
                records.append(RoomRecord(room_id=room_id, name=name, description=description, raw=room))
        return records

    def room_users(self, room_id: str) -> list[Any]:
        encoded = quote(room_id, safe="")
        payload = self.get_json(f"/api/rooms/{encoded}/users")
        return list_from_payload(payload, ("users", "participants", "data", "items"))

    def room_messages(self, room_id: str) -> list[Any]:
        encoded = quote(room_id, safe="")
        payload = self.get_json(f"/api/rooms/{encoded}/messages?limit=200")
        return list_from_payload(payload, ("messages", "data", "items"))

    @staticmethod
    def extract_error(exc: Exception) -> str:
        if isinstance(exc, requests.HTTPError) and exc.response is not None:
            try:
                payload = exc.response.json()
                if isinstance(payload, dict):
                    return display_value(
                        payload.get("error")
                        or payload.get("message")
                        or payload.get("reason")
                        or f"HTTP {exc.response.status_code}"
                    )
            except Exception:
                pass
            return f"HTTP {exc.response.status_code}: {exc.response.text[:300]}"
        return str(exc)


class AuthDialog(wx.Dialog):
    def __init__(
        self,
        parent: wx.Window,
        api: VoiceLinkApi,
        base_url: str,
        token: str,
        save_callback: Callable[[str], None],
    ) -> None:
        super().__init__(parent, title="VoiceLink Sign In", size=(620, 520))
        self.api = api
        self.base_url = normalize_base_url(base_url)
        self.token = token.strip()
        self.save_callback = save_callback

        panel = wx.Panel(self)
        root = wx.BoxSizer(wx.VERTICAL)

        self.status = wx.StaticText(panel, label="Choose a sign-in method.")
        root.Add(self.status, 0, wx.EXPAND | wx.ALL, 8)

        self.notebook = wx.Notebook(panel)
        self._build_whmcs_page(self.notebook)
        self._build_local_page(self.notebook)
        self._build_browser_page(self.notebook)
        self._build_session_page(self.notebook)
        root.Add(self.notebook, 1, wx.EXPAND | wx.LEFT | wx.RIGHT | wx.BOTTOM, 8)

        buttons = wx.StdDialogButtonSizer()
        close_button = wx.Button(panel, wx.ID_CLOSE, "Close")
        buttons.AddButton(close_button)
        buttons.Realize()
        root.Add(buttons, 0, wx.ALIGN_RIGHT | wx.ALL, 8)
        close_button.Bind(wx.EVT_BUTTON, lambda _event: self.EndModal(wx.ID_CLOSE))

        panel.SetSizer(root)
        self.CentreOnParent()
        self._load_provider_buttons()

    def _build_whmcs_page(self, notebook: wx.Notebook) -> None:
        page = wx.Panel(notebook)
        sizer = wx.BoxSizer(wx.VERTICAL)
        self.whmcs_identity = wx.TextCtrl(page)
        self.whmcs_password = wx.TextCtrl(page, style=wx.TE_PASSWORD)
        self.whmcs_two_factor = wx.TextCtrl(page)
        self.whmcs_portal = wx.Choice(page, choices=["devine-creations", "tappedin", "default"])
        self.whmcs_portal.SetSelection(0)
        self.whmcs_remember = wx.CheckBox(page, label="Keep me signed in on this computer")
        self.whmcs_remember.SetValue(True)

        self._add_labeled_control(sizer, page, "Email or username", self.whmcs_identity)
        self._add_labeled_control(sizer, page, "Password", self.whmcs_password)
        self._add_labeled_control(sizer, page, "Two-factor code, if required", self.whmcs_two_factor)
        self._add_labeled_control(sizer, page, "Client portal", self.whmcs_portal)
        sizer.Add(self.whmcs_remember, 0, wx.ALL, 8)
        button = wx.Button(page, label="Sign in with Client Account")
        sizer.Add(button, 0, wx.ALL, 8)
        button.Bind(wx.EVT_BUTTON, lambda _event: self._login_whmcs())
        page.SetSizer(sizer)
        notebook.AddPage(page, "Client Account")

    def _build_local_page(self, notebook: wx.Notebook) -> None:
        page = wx.Panel(notebook)
        sizer = wx.BoxSizer(wx.VERTICAL)
        self.local_identity = wx.TextCtrl(page)
        self.local_password = wx.TextCtrl(page, style=wx.TE_PASSWORD)
        self.local_two_factor = wx.TextCtrl(page)
        self._add_labeled_control(sizer, page, "Email or username", self.local_identity)
        self._add_labeled_control(sizer, page, "Password", self.local_password)
        self._add_labeled_control(sizer, page, "Two-factor code, if required", self.local_two_factor)
        button = wx.Button(page, label="Sign in with VoiceLink Account")
        sizer.Add(button, 0, wx.ALL, 8)
        button.Bind(wx.EVT_BUTTON, lambda _event: self._login_local())
        page.SetSizer(sizer)
        notebook.AddPage(page, "VoiceLink Account")

    def _build_browser_page(self, notebook: wx.Notebook) -> None:
        page = wx.Panel(notebook)
        self.browser_sizer = wx.BoxSizer(wx.VERTICAL)
        self.browser_sizer.Add(
            wx.StaticText(page, label="Browser sign-in methods use the server's configured OAuth providers."),
            0,
            wx.EXPAND | wx.ALL,
            8,
        )
        self.browser_sizer.Add(
            wx.StaticText(page, label="After browser authentication, return here and use the session tab if the server gives you a session token."),
            0,
            wx.EXPAND | wx.LEFT | wx.RIGHT | wx.BOTTOM,
            8,
        )
        page.SetSizer(self.browser_sizer)
        notebook.AddPage(page, "Browser Sign In")

    def _build_session_page(self, notebook: wx.Notebook) -> None:
        page = wx.Panel(notebook)
        sizer = wx.BoxSizer(wx.VERTICAL)
        self.session_token = wx.TextCtrl(page, value=self.token, style=wx.TE_PASSWORD)
        self._add_labeled_control(sizer, page, "Session token", self.session_token)
        validate_button = wx.Button(page, label="Validate and Save Session")
        logout_button = wx.Button(page, label="Forget Saved Session")
        sizer.Add(validate_button, 0, wx.ALL, 8)
        sizer.Add(logout_button, 0, wx.LEFT | wx.RIGHT | wx.BOTTOM, 8)
        validate_button.Bind(wx.EVT_BUTTON, lambda _event: self._validate_session())
        logout_button.Bind(wx.EVT_BUTTON, lambda _event: self._save_session(""))
        page.SetSizer(sizer)
        notebook.AddPage(page, "Session")

    @staticmethod
    def _add_labeled_control(sizer: wx.BoxSizer, parent: wx.Window, label: str, control: wx.Window) -> None:
        sizer.Add(wx.StaticText(parent, label=label), 0, wx.LEFT | wx.RIGHT | wx.TOP, 8)
        sizer.Add(control, 0, wx.EXPAND | wx.LEFT | wx.RIGHT | wx.BOTTOM, 8)

    def _set_status(self, message: str) -> None:
        self.status.SetLabel(message)

    def _load_provider_buttons(self) -> None:
        try:
            self.api.configure(self.base_url, self.token)
            payload = self.api.oauth_providers() or self.api.auth_providers()
            providers = list_from_payload(payload, ("providers",))
        except Exception as exc:
            self.browser_sizer.Add(wx.StaticText(self.notebook.GetPage(2), label=f"Unable to load providers: {exc}"), 0, wx.ALL, 8)
            return

        added = False
        for provider in providers:
            if not isinstance(provider, dict):
                continue
            name = display_value(provider.get("name") or provider.get("id") or provider.get("provider")).strip()
            provider_id = display_value(provider.get("id") or provider.get("provider") or name).strip().lower()
            enabled = provider.get("enabled", True) is not False and provider.get("supported", True) is not False
            login_url = display_value(provider.get("loginUrl") or provider.get("url") or "").strip()
            if not provider_id and not login_url:
                continue
            if not login_url:
                login_url = self._login_url_for_provider(provider_id)
            label = f"Open {name or provider_id} sign in"
            if not enabled:
                label += " (not enabled on this server)"
            button = wx.Button(self.notebook.GetPage(2), label=label)
            button.Enable(enabled)
            button.Bind(wx.EVT_BUTTON, lambda _event, url=login_url: webbrowser.open(url))
            self.browser_sizer.Add(button, 0, wx.LEFT | wx.RIGHT | wx.BOTTOM, 8)
            added = True

        if not added:
            button = wx.Button(self.notebook.GetPage(2), label="Open Mastodon sign in")
            button.Bind(wx.EVT_BUTTON, lambda _event: webbrowser.open(self._login_url_for_provider("mastodon")))
            self.browser_sizer.Add(button, 0, wx.ALL, 8)
        self.notebook.GetPage(2).Layout()

    def _login_url_for_provider(self, provider_id: str) -> str:
        provider_id = provider_id.strip().lower()
        if provider_id == "mastodon":
            return f"{self.base_url}/api/auth/mastodon/login"
        if provider_id:
            return f"{self.base_url}/auth/{quote(provider_id, safe='')}"
        return f"{self.base_url}/login"

    def _login_whmcs(self) -> None:
        self.api.configure(self.base_url, "")
        try:
            result = self.api.login_whmcs(
                self.whmcs_identity.GetValue(),
                self.whmcs_password.GetValue(),
                self.whmcs_two_factor.GetValue(),
                self.whmcs_portal.GetStringSelection() or "devine-creations",
                self.whmcs_remember.GetValue(),
            )
            token = display_value(result.get("token") or result.get("accessToken")).strip()
            if not token:
                raise RuntimeError(display_value(result.get("error") or result.get("message") or "Server did not return a session token."))
            self._save_session(token)
        except Exception as exc:
            self._set_status(VoiceLinkApi.extract_error(exc))

    def _login_local(self) -> None:
        self.api.configure(self.base_url, "")
        try:
            result = self.api.login_local(
                self.local_identity.GetValue(),
                self.local_password.GetValue(),
                self.local_two_factor.GetValue(),
            )
            token = display_value(result.get("accessToken") or result.get("token")).strip()
            if not token:
                raise RuntimeError(display_value(result.get("error") or result.get("message") or "Server did not return a session token."))
            self._save_session(token)
        except Exception as exc:
            self._set_status(VoiceLinkApi.extract_error(exc))

    def _validate_session(self) -> None:
        token = self.session_token.GetValue().strip()
        self.api.configure(self.base_url, token)
        result = self.api.validate_current_session()
        if result.get("valid") is True:
            self._save_session(token)
            provider = display_value(result.get("provider"))
            self._set_status(f"Session validated using {provider or 'server'} authentication.")
        else:
            self._set_status(display_value(result.get("error") or "Session is invalid or expired."))

    def _save_session(self, token: str) -> None:
        self.token = token.strip()
        self.session_token.SetValue(self.token)
        self.save_callback(self.token)
        self._set_status("Signed in." if self.token else "Saved session removed.")


class MainFrame(wx.Frame):
    def __init__(self) -> None:
        super().__init__(None, title="VoiceLink for Windows", size=(980, 680))
        self.api = VoiceLinkApi()
        self.rooms: list[RoomRecord] = []

        panel = wx.Panel(self)
        root = wx.BoxSizer(wx.VERTICAL)

        connection = wx.StaticBoxSizer(wx.StaticBox(panel, label="Server"), wx.VERTICAL)
        server_row = wx.BoxSizer(wx.HORIZONTAL)
        server_row.Add(wx.StaticText(panel, label="Server URL"), 0, wx.ALIGN_CENTER_VERTICAL | wx.RIGHT, 6)
        self.server_url = wx.TextCtrl(panel, value=DEFAULT_SERVER)
        server_row.Add(self.server_url, 1, wx.RIGHT, 8)
        self.connect_button = wx.Button(panel, label="Connect")
        server_row.Add(self.connect_button, 0)
        connection.Add(server_row, 0, wx.EXPAND | wx.ALL, 8)

        actions = wx.BoxSizer(wx.HORIZONTAL)
        self.refresh_button = wx.Button(panel, label="Refresh rooms")
        self.users_button = wx.Button(panel, label="Show room users")
        self.messages_button = wx.Button(panel, label="Show room messages")
        self.auth_button = wx.Button(panel, label="Sign in")
        self.logout_button = wx.Button(panel, label="Sign out")
        self.admin_button = wx.Button(panel, label="Open admin")
        for button in (self.refresh_button, self.users_button, self.messages_button, self.auth_button, self.logout_button, self.admin_button):
            actions.Add(button, 0, wx.RIGHT, 8)
        connection.Add(actions, 0, wx.LEFT | wx.RIGHT | wx.BOTTOM, 8)
        root.Add(connection, 0, wx.EXPAND | wx.ALL, 8)

        self.status_text = wx.StaticText(panel, label="Not connected.")
        root.Add(self.status_text, 0, wx.LEFT | wx.RIGHT | wx.BOTTOM, 8)

        splitter = wx.SplitterWindow(panel)
        self.rooms_list = wx.ListCtrl(splitter, style=wx.LC_REPORT | wx.LC_SINGLE_SEL)
        self.rooms_list.InsertColumn(0, "Room", width=240)
        self.rooms_list.InsertColumn(1, "Description", width=420)
        self.details = wx.TextCtrl(splitter, style=wx.TE_MULTILINE | wx.TE_READONLY | wx.TE_RICH2)
        splitter.SplitVertically(self.rooms_list, self.details, 390)
        root.Add(splitter, 1, wx.EXPAND | wx.LEFT | wx.RIGHT | wx.BOTTOM, 8)

        panel.SetSizer(root)
        self._build_menu()
        self._bind_events()
        self._load_settings()
        self.Centre()

    def _build_menu(self) -> None:
        menu_bar = wx.MenuBar()
        file_menu = wx.Menu()
        file_menu.Append(wx.ID_EXIT, "Exit\tAlt+F4")
        server_menu = wx.Menu()
        server_menu.Append(1001, "Connect\tCtrl+L")
        server_menu.Append(1002, "Refresh rooms\tF5")
        server_menu.Append(1003, "Sign in\tCtrl+Shift+L")
        server_menu.Append(1006, "Sign out")
        server_menu.Append(1004, "Open admin")
        help_menu = wx.Menu()
        help_menu.Append(1005, "About VoiceLink")
        menu_bar.Append(file_menu, "File")
        menu_bar.Append(server_menu, "Server")
        menu_bar.Append(help_menu, "Help")
        self.SetMenuBar(menu_bar)

        self.Bind(wx.EVT_MENU, lambda _event: self.Close(), id=wx.ID_EXIT)
        self.Bind(wx.EVT_MENU, lambda _event: self.connect(), id=1001)
        self.Bind(wx.EVT_MENU, lambda _event: self.refresh_rooms(), id=1002)
        self.Bind(wx.EVT_MENU, lambda _event: self.open_sign_in(), id=1003)
        self.Bind(wx.EVT_MENU, lambda _event: self.logout(), id=1006)
        self.Bind(wx.EVT_MENU, lambda _event: self.open_admin(), id=1004)
        self.Bind(wx.EVT_MENU, lambda _event: wx.MessageBox("VoiceLinkWX native Windows preview", "About VoiceLink"), id=1005)

    def _bind_events(self) -> None:
        self.connect_button.Bind(wx.EVT_BUTTON, lambda _event: self.connect())
        self.refresh_button.Bind(wx.EVT_BUTTON, lambda _event: self.refresh_rooms())
        self.users_button.Bind(wx.EVT_BUTTON, lambda _event: self.show_room_users())
        self.messages_button.Bind(wx.EVT_BUTTON, lambda _event: self.show_room_messages())
        self.auth_button.Bind(wx.EVT_BUTTON, lambda _event: self.open_sign_in())
        self.logout_button.Bind(wx.EVT_BUTTON, lambda _event: self.logout())
        self.admin_button.Bind(wx.EVT_BUTTON, lambda _event: self.open_admin())
        self.rooms_list.Bind(wx.EVT_LIST_ITEM_ACTIVATED, lambda _event: self.show_room_messages())
        self.Bind(wx.EVT_CLOSE, self._on_close)

    def _load_settings(self) -> None:
        try:
            data = json.loads(CONFIG_PATH.read_text(encoding="utf-8"))
        except Exception:
            return
        self.server_url.SetValue(data.get("server_url", DEFAULT_SERVER))
        token = data.get("access_token", "") or data.get("session_token", "")
        self.api.configure(self.server_url.GetValue(), token)

    def _save_settings(self) -> None:
        CONFIG_DIR.mkdir(parents=True, exist_ok=True)
        data = {
            "server_url": normalize_base_url(self.server_url.GetValue()),
            "session_token": self.api.token,
        }
        CONFIG_PATH.write_text(json.dumps(data, indent=2), encoding="utf-8")

    def _on_close(self, event: wx.CloseEvent) -> None:
        self._save_settings()
        event.Skip()

    def set_status(self, message: str) -> None:
        self.status_text.SetLabel(message)
        self.SetStatusText(message) if self.GetStatusBar() else None

    def run_background(self, label: str, worker) -> None:
        self.set_status(label)

        def task() -> None:
            try:
                result = worker()
                wx.CallAfter(self._handle_result, result)
            except Exception as exc:
                wx.CallAfter(self._handle_error, exc)

        threading.Thread(target=task, daemon=True).start()

    def _handle_error(self, exc: Exception) -> None:
        message = VoiceLinkApi.extract_error(exc)
        if "401" in message or "403" in message or "authentication" in message.lower() or "unauthorized" in message.lower():
            message = f"{message}\n\nUse Server, Sign in to authenticate with this VoiceLink server."
        self.set_status(f"Error: {message.splitlines()[0] if message else exc}")
        self.details.SetValue(message or f"{type(exc).__name__}: {exc}")

    def _handle_result(self, result: tuple[str, Any]) -> None:
        action, payload = result
        if action == "connected":
            health, config, admin, session = payload
            session_line = "Guest access."
            if session.get("valid") is True:
                user = session.get("user") if isinstance(session.get("user"), dict) else {}
                user_label = display_value(user.get("displayName") or user.get("username") or user.get("email") or session.get("provider"))
                session_line = f"Signed in as {user_label}."
            elif self.api.token:
                session_line = f"Saved session was not accepted: {display_value(session.get('error'))}"
            lines = [
                "Connected.",
                session_line,
                "",
                "Health:",
                json.dumps(health, indent=2, ensure_ascii=False),
                "",
                "Config:",
                json.dumps(config, indent=2, ensure_ascii=False),
                "",
                "Admin status:",
                json.dumps(admin, indent=2, ensure_ascii=False),
            ]
            self.details.SetValue("\n".join(lines))
            self.set_status("Connected. Refreshing rooms.")
            self.refresh_rooms()
        elif action == "rooms":
            self.rooms = payload
            self.rooms_list.DeleteAllItems()
            for index, room in enumerate(self.rooms):
                self.rooms_list.InsertItem(index, room.name)
                self.rooms_list.SetItem(index, 1, room.description)
            self.set_status(f"{len(self.rooms)} rooms loaded.")
            if self.rooms:
                self.rooms_list.Focus(0)
                self.rooms_list.Select(0)
        elif action == "users":
            self.details.SetValue(self._format_records("Room users", payload))
            self.set_status("Room users loaded.")
        elif action == "messages":
            self.details.SetValue(self._format_records("Room messages", payload))
            self.set_status("Room messages loaded.")

    def _selected_room(self) -> RoomRecord | None:
        index = self.rooms_list.GetFirstSelected()
        if index < 0 or index >= len(self.rooms):
            wx.MessageBox("Select a room first.", "VoiceLink", wx.OK | wx.ICON_INFORMATION)
            return None
        return self.rooms[index]

    def _format_records(self, title: str, records: list[Any]) -> str:
        if not records:
            return f"{title}\n\nNo records returned."
        lines = [title, ""]
        for index, record in enumerate(records, start=1):
            if isinstance(record, dict):
                name = record.get("displayName") or record.get("username") or record.get("name") or record.get("sender") or record.get("user") or f"Item {index}"
                text = record.get("text") or record.get("message") or record.get("content") or record.get("status") or ""
                if text:
                    lines.append(f"{index}. {display_value(name)}: {display_value(text)}")
                else:
                    lines.append(f"{index}. {json.dumps(record, ensure_ascii=False)}")
            else:
                lines.append(f"{index}. {display_value(record)}")
        return "\n".join(lines)

    def connect(self) -> None:
        self.api.configure(self.server_url.GetValue(), self.api.token)
        self._save_settings()

        def worker() -> tuple[str, Any]:
            session = self.api.validate_current_session() if self.api.token else {"valid": False}
            return "connected", (self.api.health(), self.api.config(), self.api.admin_status(), session)

        self.run_background("Connecting.", worker)

    def refresh_rooms(self) -> None:
        self.api.configure(self.server_url.GetValue(), self.api.token)
        self.run_background("Loading rooms.", lambda: ("rooms", self.api.rooms()))

    def show_room_users(self) -> None:
        room = self._selected_room()
        if not room:
            return
        self.run_background("Loading room users.", lambda: ("users", self.api.room_users(room.room_id)))

    def show_room_messages(self) -> None:
        room = self._selected_room()
        if not room:
            return
        self.run_background("Loading room messages.", lambda: ("messages", self.api.room_messages(room.room_id)))

    def open_sign_in(self) -> None:
        dialog = AuthDialog(
            self,
            self.api,
            self.server_url.GetValue(),
            self.api.token,
            self._update_session_token,
        )
        try:
            dialog.ShowModal()
        finally:
            dialog.Destroy()
        self.connect()

    def _update_session_token(self, token: str) -> None:
        self.api.configure(self.server_url.GetValue(), token)
        self._save_settings()

    def logout(self) -> None:
        if self.api.token:
            try:
                self.api.logout_whmcs()
            except Exception:
                pass
        self._update_session_token("")
        self.set_status("Signed out. Guest access will be used if the server allows it.")
        self.details.SetValue("Signed out.")

    def open_admin(self) -> None:
        base = normalize_base_url(self.server_url.GetValue())
        webbrowser.open(f"{base}/admin")


class VoiceLinkApp(wx.App):
    def OnInit(self) -> bool:
        frame = MainFrame()
        frame.CreateStatusBar()
        frame.Show()
        return True


if __name__ == "__main__":
    app = VoiceLinkApp(False)
    app.MainLoop()
