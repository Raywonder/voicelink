from __future__ import annotations

import json
import threading
import webbrowser
from dataclasses import dataclass
from pathlib import Path
from typing import Any
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
            return {"Authorization": f"Bearer {self.token}"}
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

    def health(self) -> Any:
        return self.get_json("/api/health")

    def config(self) -> Any:
        return self.get_json("/api/config")

    def admin_status(self) -> Any:
        return self.get_json("/api/admin/status")

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
        server_row.Add(wx.StaticText(panel, label="Access token"), 0, wx.ALIGN_CENTER_VERTICAL | wx.RIGHT, 6)
        self.access_token = wx.TextCtrl(panel, style=wx.TE_PASSWORD)
        server_row.Add(self.access_token, 1, wx.RIGHT, 8)
        self.connect_button = wx.Button(panel, label="Connect")
        server_row.Add(self.connect_button, 0)
        connection.Add(server_row, 0, wx.EXPAND | wx.ALL, 8)

        actions = wx.BoxSizer(wx.HORIZONTAL)
        self.refresh_button = wx.Button(panel, label="Refresh rooms")
        self.users_button = wx.Button(panel, label="Show room users")
        self.messages_button = wx.Button(panel, label="Show room messages")
        self.auth_button = wx.Button(panel, label="Open sign in")
        self.admin_button = wx.Button(panel, label="Open admin")
        for button in (self.refresh_button, self.users_button, self.messages_button, self.auth_button, self.admin_button):
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
        server_menu.Append(1003, "Open sign in")
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
        self.Bind(wx.EVT_MENU, lambda _event: self.open_admin(), id=1004)
        self.Bind(wx.EVT_MENU, lambda _event: wx.MessageBox("VoiceLinkWX native Windows preview", "About VoiceLink"), id=1005)

    def _bind_events(self) -> None:
        self.connect_button.Bind(wx.EVT_BUTTON, lambda _event: self.connect())
        self.refresh_button.Bind(wx.EVT_BUTTON, lambda _event: self.refresh_rooms())
        self.users_button.Bind(wx.EVT_BUTTON, lambda _event: self.show_room_users())
        self.messages_button.Bind(wx.EVT_BUTTON, lambda _event: self.show_room_messages())
        self.auth_button.Bind(wx.EVT_BUTTON, lambda _event: self.open_sign_in())
        self.admin_button.Bind(wx.EVT_BUTTON, lambda _event: self.open_admin())
        self.rooms_list.Bind(wx.EVT_LIST_ITEM_ACTIVATED, lambda _event: self.show_room_messages())
        self.Bind(wx.EVT_CLOSE, self._on_close)

    def _load_settings(self) -> None:
        try:
            data = json.loads(CONFIG_PATH.read_text(encoding="utf-8"))
        except Exception:
            return
        self.server_url.SetValue(data.get("server_url", DEFAULT_SERVER))
        self.access_token.SetValue(data.get("access_token", ""))

    def _save_settings(self) -> None:
        CONFIG_DIR.mkdir(parents=True, exist_ok=True)
        data = {
            "server_url": normalize_base_url(self.server_url.GetValue()),
            "access_token": self.access_token.GetValue().strip(),
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
        self.set_status(f"Error: {exc}")
        self.details.SetValue(f"{type(exc).__name__}: {exc}")

    def _handle_result(self, result: tuple[str, Any]) -> None:
        action, payload = result
        if action == "connected":
            health, config, admin = payload
            lines = [
                "Connected.",
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
        self.api.configure(self.server_url.GetValue(), self.access_token.GetValue())
        self._save_settings()

        def worker() -> tuple[str, Any]:
            return "connected", (self.api.health(), self.api.config(), self.api.admin_status())

        self.run_background("Connecting.", worker)

    def refresh_rooms(self) -> None:
        self.api.configure(self.server_url.GetValue(), self.access_token.GetValue())
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
        base = normalize_base_url(self.server_url.GetValue())
        webbrowser.open(f"{base}/api/auth/mastodon/login")

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
