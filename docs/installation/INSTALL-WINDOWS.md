# VoiceLink Local - Windows Installation Guide

## System Requirements

- **Windows 10** (version 1903 or later) or **Windows 11**
- **x64** or **x86** (32-bit) processor
- **8GB RAM** minimum (16GB recommended)
- **500MB** available disk space
- **Audio device** with microphone support

## Download Options

### 64-bit Windows (Recommended)
- **ZIP Archive**: [VoiceLink Local-1.0.0-win.zip](../releases/VoiceLink%20Local-1.0.0-win.zip) (369MB)

### 32-bit Windows
- **ZIP Archive**: [VoiceLink Local-1.0.0-ia32-win.zip](../releases/VoiceLink%20Local-1.0.0-ia32-win.zip) (351MB)

## Installation

### Method 1: ZIP Archive (Recommended)

1. **Download** the appropriate ZIP file for your Windows version
2. **Right-click** the downloaded ZIP file
3. **Select** "Extract All..." or use your preferred extraction tool
4. **Choose** destination folder (e.g., `C:\Program Files\VoiceLink Local\`)
5. **Run** `VoiceLink Local.exe` from the extracted folder

### Method 2: Portable Installation

1. **Extract** to any folder (e.g., USB drive, Documents folder)
2. **Create** desktop shortcut by right-clicking `VoiceLink Local.exe`
3. **Select** "Create shortcut" and move to desktop

## First Launch

### Windows Defender SmartScreen
Windows may show a security warning on first launch:

1. **If you see "Windows protected your PC"**:
   - Click **"More info"**
   - Click **"Run anyway"**

2. **Alternative method**:
   - Right-click `VoiceLink Local.exe`
   - Select **"Properties"**
   - Check **"Unblock"** if present
   - Click **"OK"**

### Microphone Permissions
Windows 10/11 requires microphone access:

1. **Grant permission** when prompted by VoiceLink Local
2. **If missed**: Go to **Settings** → **Privacy** → **Microphone**
3. **Toggle** "Allow desktop apps to access your microphone" to **On**

### Windows Firewall
You may see a firewall prompt:

1. **Allow** VoiceLink Local through Windows Firewall
2. **Check both** "Private networks" and "Public networks" if you plan to use on different networks

## Audio Configuration

### Default Audio Settings
1. **Right-click** the speaker icon in system tray
2. **Select** "Open Sound settings"
3. **Set** your preferred input and output devices
4. **Test** microphone levels

### Professional Audio Interfaces
For ASIO-compatible audio interfaces:

1. **Install** manufacturer drivers before launching VoiceLink Local
2. **Configure** buffer sizes in your audio interface control panel
3. **Set** sample rate to 48kHz or 44.1kHz for best compatibility

### Advanced Audio Settings
- **Disable** audio enhancements in Windows sound settings
- **Set** exclusive mode for professional audio interfaces
- **Adjust** buffer sizes for optimal latency

## Troubleshooting

### Application Won't Start
- **Check Windows version**: Requires Windows 10 (1903+) or Windows 11
- **Verify architecture**: Use 64-bit version on 64-bit Windows
- **Run as Administrator**: Right-click → "Run as administrator"
- **Check antivirus software**: Add VoiceLink Local to exceptions

### Audio Issues
- **Check microphone permissions** in Windows Settings
- **Verify audio devices** are working in Windows Sound settings
- **Update audio drivers** through Device Manager
- **Disable audio enhancements** that may interfere
- **Try different audio sample rates**

### Performance Issues
- **Close** other audio applications
- **Increase** audio buffer sizes
- **Check** Task Manager for CPU/memory usage
- **Disable** Windows Game Mode if causing issues
- **Update graphics drivers**

### Connection Issues
- **Check Windows Firewall** settings
- **Verify** network connectivity
- **Try** different network configurations
- **Disable** VPN temporarily if having connection issues

## Uninstallation

### Complete Removal
1. **Close** VoiceLink Local completely
2. **Delete** the VoiceLink Local folder
3. **Remove** desktop shortcuts
4. **Clear** application data (optional):
   - Navigate to `%APPDATA%\VoiceLink Local\`
   - Delete the folder and contents

### Registry Cleanup (Optional)
Most users won't need this, but if experiencing issues:
1. **Press** Win+R, type `regedit`
2. **Navigate** to `HKEY_CURRENT_USER\Software\`
3. **Look for** VoiceLink-related entries and delete if present

## Advanced Configuration

### Command Line Options
Launch with custom settings:
```cmd
"VoiceLink Local.exe" --audio-buffer=512 --sample-rate=48000
```

### Batch File for Custom Launch
Create a `.bat` file with:
```batch
@echo off
cd /d "C:\Path\To\VoiceLink Local\"
"VoiceLink Local.exe" --audio-buffer=512
pause
```

### Professional Audio Setup
For professional audio workflows:
- Use ASIO drivers when available
- Configure low-latency monitoring
- Set up multi-channel audio routing
- Configure VST plugin paths

## Windows-Specific Features

### Windows Audio Session API (WASAPI)
VoiceLink Local uses WASAPI for:
- Low-latency audio processing
- Exclusive mode access to audio devices
- High-quality audio rendering

### Windows 11 Enhancements
- Better microphone access controls
- Improved audio device management
- Enhanced privacy settings

## Support

For Windows-specific issues:
- Check Windows Event Viewer for error messages
- Verify system requirements and compatibility
- Review audio device and driver setup
- Consult the main troubleshooting guide in README.md

### Common Error Codes
- **Error 0x80070005**: Run as Administrator
- **Audio initialization failed**: Check microphone permissions
- **Network connection error**: Check firewall settings