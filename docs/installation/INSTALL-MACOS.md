# VoiceLink Local - macOS Installation Guide

## System Requirements

- **macOS 10.14** or later
- **Intel Mac** or **Apple Silicon** (M1/M2/M3)
- **8GB RAM** minimum (16GB recommended)
- **500MB** available disk space

## Download Options

### Apple Silicon (M1/M2/M3) - Recommended
- **DMG Installer**: [VoiceLink Local-1.0.0-arm64.dmg](../releases/VoiceLink%20Local-1.0.0-arm64.dmg) (349MB)
- **ZIP Archive**: [VoiceLink Local-1.0.0-arm64-mac.zip](../releases/VoiceLink%20Local-1.0.0-arm64-mac.zip) (344MB)

### Intel Mac
- **DMG Installer**: [VoiceLink Local-1.0.0.dmg](../releases/VoiceLink%20Local-1.0.0.dmg) (354MB)
- **ZIP Archive**: [VoiceLink Local-1.0.0-mac.zip](../releases/VoiceLink%20Local-1.0.0-mac.zip) (349MB)

## Installation Methods

### Method 1: DMG Installer (Recommended)

1. **Download** the appropriate DMG file for your Mac
2. **Double-click** the downloaded DMG file
3. **Drag** VoiceLink Local to the Applications folder
4. **Eject** the DMG by clicking the eject button in Finder
5. **Launch** VoiceLink Local from Applications folder

### Method 2: ZIP Archive

1. **Download** the appropriate ZIP file for your Mac
2. **Extract** the ZIP file to your desired location
3. **Move** the VoiceLink Local.app to Applications folder (optional)
4. **Launch** the application

## First Launch

### Gatekeeper Notice
On first launch, macOS may show a security warning:

1. **If you see "VoiceLink Local cannot be opened"**:
   - Go to **System Preferences** → **Security & Privacy**
   - Click **"Open Anyway"** next to the VoiceLink Local message
   - Click **"Open"** in the confirmation dialog

2. **Alternative method**:
   - Right-click the app and select **"Open"**
   - Click **"Open"** in the dialog

### Microphone Permissions
VoiceLink Local requires microphone access:

1. **Grant permission** when prompted
2. **If missed**: Go to **System Preferences** → **Security & Privacy** → **Privacy** → **Microphone**
3. **Check the box** next to VoiceLink Local

## Audio Configuration

### Recommended Audio Settings
1. Open **Audio MIDI Setup** (found in `/Applications/Utilities/`)
2. Select your audio interface
3. Set **Sample Rate** to **48kHz** or **44.1kHz**
4. Set **Bit Depth** to **24-bit** or **16-bit**

### Professional Audio Interfaces
For best results with professional audio interfaces:
- Install manufacturer drivers before launching VoiceLink Local
- Configure buffer sizes in your audio interface control panel
- Use aggregate devices for multiple audio interfaces

## Troubleshooting

### App Won't Launch
- **Check macOS version**: Requires macOS 10.14 or later
- **Verify architecture**: Use ARM version for Apple Silicon, Intel version for Intel Macs
- **Reset permissions**: Try moving app to Trash and reinstalling

### Audio Issues
- **Check microphone permissions** in System Preferences
- **Verify audio interface** is properly connected and recognized
- **Try different sample rates** in Audio MIDI Setup
- **Restart audio services**: `sudo launchctl stop com.apple.audio.coreaudiod && sudo launchctl start com.apple.audio.coreaudiod`

### Performance Issues
- **Close other audio applications** that might conflict
- **Increase buffer sizes** in audio settings
- **Check Activity Monitor** for CPU/memory usage
- **Restart the application** if audio becomes glitchy

## Uninstallation

1. **Quit** VoiceLink Local completely
2. **Drag** VoiceLink Local.app to Trash
3. **Remove preferences** (optional):
   ```bash
   rm -rf ~/Library/Preferences/com.voicelink.local.*
   rm -rf ~/Library/Application\ Support/VoiceLink\ Local/
   ```

## Advanced Configuration

### Custom Audio Device Configuration
VoiceLink Local supports advanced audio routing. See the main documentation for details on:
- Multi-channel audio setup
- VST plugin configuration
- 3D spatial audio settings
- Professional audio workflows

### Command Line Options
Launch with custom settings:
```bash
/Applications/VoiceLink\ Local.app/Contents/MacOS/VoiceLink\ Local --audio-buffer=512 --sample-rate=48000
```

## Support

For macOS-specific issues:
- Check Console.app for error messages
- Verify system requirements
- Review microphone and audio interface setup
- Consult the main troubleshooting guide in README.md