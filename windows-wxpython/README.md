# VoiceLink Windows wxPython client

This is a native Windows wxPython build path for VoiceLink. It is intentionally
separate from the existing WPF and WinUI clients so the Windows accessibility
surface can be tested without regressing those clients.

Current scope:

- Connect to a VoiceLink server URL.
- Check `/api/health`, `/api/config`, and `/api/admin/status`.
- List public rooms from `/api/rooms`.
- Show room users and recent messages from `/api/rooms/{id}/users` and
  `/api/rooms/{id}/messages`.
- Open server authentication and admin pages in the default browser.

Build:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\build-windows.ps1
```

The script writes portable artifacts to `E:\Downloads\VoiceLinkWX` by default.
