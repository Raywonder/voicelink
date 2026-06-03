# VoiceLink WinUI Client

This is the native Windows WinUI 3 migration path for VoiceLink. It is intentionally separate from the older WPF `windows-native` client and is built from the Mac mini `cleanup/native-desktop-admin-split` source line.

## Current Scope

- WinUI 3 shell with Servers, Rooms, Messages, Admin, and Settings sections.
- Socket.IO connection service for the main VoiceLink server, local server, room refresh, room join, and chat messages.
- NVDA direct announcements through `nvdaControllerClient64.dll`, with UI Automation live-region fallback.
- Local API startup fallback matching the existing Windows-native service behavior.

## Build

```powershell
.\build.ps1
```

The working inner-loop build disables MSIX generation because this Windows install currently fails in the SDK MSIX recipe task while loading the MRM support library. The app code itself compiles cleanly with the no-package build.

## AccessKit Note

AccessKit currently provides Windows UI Automation platform support and C/Python bindings. There is not a native WinUI/.NET package wired here yet. The WinUI app uses native WinUI accessibility semantics and NVDA controller announcements now; a future AccessKit bridge should use the C binding if VoiceLink later adds custom-rendered controls that need an explicit accessibility tree.
