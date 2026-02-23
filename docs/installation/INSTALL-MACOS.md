# VoiceLink - macOS Installation Guide

## System Requirements

- **macOS 10.14** or later
- **Intel Mac** or **Apple Silicon** (M1/M2/M3)
- **8GB RAM** minimum (16GB recommended)
- **1GB** available disk space

## Download Options

### Universal Build (Apple Silicon + Intel)
- **Primary ZIP**: `https://voicelink.devinecreations.net/downloads/voicelink/VoiceLinkMacOS.zip`
- **Alias ZIP**: `https://voicelink.devinecreations.net/downloads/voicelink/VoiceLink-macOS.zip`

## Installation Methods

### Method: ZIP Archive (Production)

1. **Download** `VoiceLinkMacOS.zip` (or `VoiceLink-macOS.zip`)
2. **Extract** the ZIP file to your desired location
3. **Move** `VoiceLink.app` to `/Applications`
4. **Launch** the application

## First Launch

### Gatekeeper Notice
On first launch, macOS may show a security warning:

1. **If you see "VoiceLink cannot be opened"**:
   - Go to **System Preferences** → **Security & Privacy**
   - Click **"Open Anyway"** next to the VoiceLink Local message
   - Click **"Open"** in the confirmation dialog

2. **Alternative method**:
   - Right-click the app and select **"Open"**
   - Click **"Open"** in the dialog

### Microphone Permissions
VoiceLink requires microphone access:

1. **Grant permission** when prompted
2. **If missed**: Go to **System Preferences** → **Security & Privacy** → **Privacy** → **Microphone**
3. **Check the box** next to VoiceLink

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

1. **Quit** VoiceLink completely
2. **Drag** VoiceLink.app to Trash
3. **Remove preferences** (optional):
   ```bash
   rm -rf ~/Library/Preferences/com.devinecreations.voicelink.*
   rm -rf ~/Library/Application\ Support/VoiceLink/
   ```

## Advanced Configuration

### Custom Audio Device Configuration
VoiceLink supports advanced audio routing. See the main documentation for details on:
- Multi-channel audio setup
- VST plugin configuration
- 3D spatial audio settings
- Professional audio workflows

### Command Line Options
Launch with custom settings:
```bash
/Applications/VoiceLink.app/Contents/MacOS/VoiceLink --audio-buffer=512 --sample-rate=48000
```

## Support

For macOS-specific issues:
- Check Console.app for error messages
- Verify system requirements
- Review microphone and audio interface setup
- Consult the main troubleshooting guide in README.md
