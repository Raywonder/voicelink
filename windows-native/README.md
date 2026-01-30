# VoiceLink Native for Windows

A native Windows desktop application for VoiceLink voice communication, built with .NET 8 and WPF.

## Features

- **Native Windows Experience**: Built with WPF for optimal Windows integration
- **Remote-First Connection**: Automatically connects to main server first, falls back to local
- **Server Management**: Connect to main, local, or custom servers
- **Room Management**: Create, join, and manage voice chat rooms
- **Admin Panel**: Server administration for authorized users
- **Remote Node Management**: Control remote nodes and schedule restarts
- **Authentication**: Support for pairing codes, email verification, and Mastodon OAuth
- **Accessibility**: Full keyboard navigation and screen reader support
- **System Tray**: Minimize to system tray with notifications
- **URL Scheme**: Handle `voicelink://` URLs for deep linking

## Requirements

- Windows 10 version 1809 or later
- [.NET 8 SDK](https://dotnet.microsoft.com/download/dotnet/8.0) (for building)
- [.NET 8 Runtime](https://dotnet.microsoft.com/download/dotnet/8.0/runtime) (for running)

## Building

### Using Command Prompt

```batch
build.bat
```

### Using PowerShell

```powershell
# Basic build
.\build.ps1

# Build with clean
.\build.ps1 -Clean

# Build and publish (creates self-contained executable)
.\build.ps1 -Publish

# Build Debug configuration
.\build.ps1 -Configuration Debug
```

### Using Visual Studio

1. Open `VoiceLinkNative.sln` in Visual Studio 2022
2. Select Release configuration
3. Build > Build Solution (Ctrl+Shift+B)

### Using .NET CLI

```bash
# Restore packages
dotnet restore VoiceLinkNative/VoiceLinkNative.csproj

# Build
dotnet build VoiceLinkNative/VoiceLinkNative.csproj -c Release

# Run
dotnet run --project VoiceLinkNative/VoiceLinkNative.csproj

# Publish self-contained executable
dotnet publish VoiceLinkNative/VoiceLinkNative.csproj -c Release -r win-x64 --self-contained true -o publish/win-x64 /p:PublishSingleFile=true
```

## Project Structure

```
windows-native/
├── VoiceLinkNative.sln          # Solution file
├── VoiceLinkNative/
│   ├── VoiceLinkNative.csproj   # Project file
│   ├── App.xaml                 # Application resources and styles
│   ├── App.xaml.cs              # Application startup
│   ├── Services/
│   │   ├── ServerManager.cs     # Socket.IO server connection
│   │   ├── AdminServerManager.cs # Admin API client
│   │   ├── AuthenticationManager.cs # Authentication handling
│   │   ├── SyncManager.cs       # Real-time sync events
│   │   └── NotificationService.cs # Windows notifications
│   ├── ViewModels/
│   │   ├── MainViewModel.cs     # Main window logic
│   │   ├── ServersViewModel.cs  # Server management
│   │   ├── RoomsViewModel.cs    # Room management
│   │   ├── AdminViewModel.cs    # Admin panel
│   │   └── SettingsViewModel.cs # Settings management
│   ├── Views/
│   │   ├── MainWindow.xaml      # Main application window
│   │   ├── ServersView.xaml     # Server connection UI
│   │   ├── RoomsView.xaml       # Room list and management
│   │   ├── AdminView.xaml       # Admin panel UI
│   │   └── SettingsView.xaml    # Settings UI
│   ├── Helpers/
│   │   └── Converters.cs        # XAML value converters
│   ├── Models/                  # Data models
│   └── Assets/                  # Icons and resources
├── build.bat                    # Windows batch build script
├── build.ps1                    # PowerShell build script
└── README.md                    # This file
```

## Keyboard Shortcuts

| Shortcut | Action |
|----------|--------|
| Ctrl+1 | Navigate to Servers |
| Ctrl+2 | Navigate to Rooms |
| Ctrl+3 | Navigate to Admin |
| Ctrl+4 | Navigate to Settings |
| Ctrl+M | Connect to Main Server |
| Ctrl+L | Connect to Local Server |

## Server URLs

- **Main Server**: `https://voicelink.devinecreations.net`
- **Local Server**: `http://localhost:4004`

## URL Scheme

The application registers the `voicelink://` URL scheme for deep linking:

- `voicelink://join/roomId` - Join a specific room
- `voicelink://server/url` - Connect to a specific server
- `voicelink://pair/code` - Use a pairing code

## Dependencies

- [SocketIOClient](https://github.com/doghappy/socket.io-client-csharp) - Socket.IO client for .NET
- [CommunityToolkit.Mvvm](https://github.com/CommunityToolkit/dotnet) - MVVM toolkit
- [Newtonsoft.Json](https://www.newtonsoft.com/json) - JSON serialization
- [Hardcodet.NotifyIcon.Wpf](https://github.com/hardcodet/wpf-notifyicon) - System tray support

## License

Copyright 2024-2025 Devine Creations. All rights reserved.
