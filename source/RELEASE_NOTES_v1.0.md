# VoiceLink Local v1.0.0 - Release Notes

## 🎉 First Stable Release - October 26, 2025

This is the first stable release of VoiceLink Local, a P2P voice chat application with advanced 3D spatial audio.

## ✅ What's Included

### **Core Features**
- **Local P2P Voice Chat Server** - No internet required
- **3D Spatial Audio** with HRTF processing
- **Professional Audio Effects** (15+ effects)
- **Multi-Channel Audio Routing** (up to 64 channels)
- **Text-to-Speech Announcements** (10+ languages)
- **PA System** with push-to-talk controls
- **Cross-Platform Support** (Mac, Windows, Linux)

### **System Tray Integration**
- Real-time server status display
- Connected users and room counts
- One-click server URL copying
- Web UI launcher
- Application settings access
- Update checker integration

### **Update System**
- **Automatic update checking** (every 24 hours)
- **Manual update checks** via menu
- **Multi-URL failover** support:
  - `https://devinecreations.net/downloads/voicelink-local/version.json`
  - `https://updates.devinecreations.net/voicelink-local/version.json`
  - `https://devinecreations.net/voicelink-local/version.json`

## 📦 Release Packages

### **macOS**
- **VoiceLink-Local-1.0.0-mac-x64.dmg** (Intel Macs)
- **VoiceLink-Local-1.0.0-mac-arm64.dmg** (Apple Silicon)
- **VoiceLink-Local-1.0.0-mac-x64.zip** (Intel Macs - Portable)
- **VoiceLink-Local-1.0.0-mac-arm64.zip** (Apple Silicon - Portable)
- Includes: `README.txt` with macOS-specific instructions

### **Windows**
- **VoiceLink-Local-1.0.0-win-x64-portable.exe** (64-bit Portable)
- **VoiceLink-Local-1.0.0-win-ia32-portable.exe** (32-bit Portable)
- **VoiceLink-Local-1.0.0-win-x64.zip** (64-bit Archive)
- **VoiceLink-Local-1.0.0-win-ia32.zip** (32-bit Archive)
- Includes: `README-Windows.txt` with Windows-specific setup

### **Linux**
- **VoiceLink-Local-1.0.0.AppImage** (Universal - Recommended)
- **voicelink-local_1.0.0_amd64.deb** (Ubuntu/Debian)
- **voicelink-local-1.0.0.tar.gz** (Generic Archive)
- Includes: `README-Linux.txt` with Linux-specific instructions

## 🔧 Technical Improvements

### **Audio Engine**
- ✅ Fixed browser audio initialization issues
- ✅ Graceful handling of browser security policies
- ✅ Eliminated "limited functionality" error messages
- ✅ Improved deferred audio loading

### **Settings Storage**
- ✅ **Fixed electron-store compatibility** (downgraded to v8.1.0)
- ✅ Settings now persist between sessions
- ✅ Auto-launch preferences saved
- ✅ No more storage errors

### **Menu Bar**
- ✅ **Clean text-only interface** (removed emojis)
- ✅ "Application Settings" instead of emoji buttons
- ✅ Real-time status updates
- ✅ Professional appearance

## 🌐 Server URL Guidelines

**IMPORTANT**: Always use IP addresses for connections:

### ✅ Correct Format
- `http://192.168.1.100:3000`
- `http://10.0.0.88:3000`

### ❌ Incorrect Format
- `http://MyComputer.local:3000`
- `http://hostname:3000`

**Why IP addresses only:**
- Universal compatibility across all devices
- Works with mobile devices and gaming consoles
- Reliable resolution on all networks
- No dependency on DNS/hostname resolution

## 🔄 Update Checker Details

The update system supports flexible URL patterns:

### **Primary URLs**
- Subdomain: `https://updates.devinecreations.net/voicelink-local/`
- Root domain: `https://devinecreations.net/downloads/voicelink-local/`
- Path-based: `https://devinecreations.net/voicelink-local/`

### **Expected JSON Format**
```json
{
  "version": "1.1.0",
  "releaseDate": "2024-11-15",
  "description": "New features and improvements",
  "downloads": {
    "macArm64": "https://devinecreations.net/downloads/.../mac-arm64.dmg",
    "macIntel": "https://devinecreations.net/downloads/.../mac-x64.dmg",
    "windowsX64": "https://devinecreations.net/downloads/.../win-x64.zip",
    "linuxX64": "https://devinecreations.net/downloads/.../linux-x64.tar.gz"
  }
}
```

## 🛠️ System Requirements

### **All Platforms**
- Modern web browser (Chrome, Firefox, Safari, Edge)
- Microphone and speakers/headphones
- Local network connection (WiFi/Ethernet)
- 200-400MB RAM depending on room size

### **Platform-Specific**
- **macOS**: 10.14+ (Intel or Apple Silicon)
- **Windows**: Windows 10+ (64-bit recommended)
- **Linux**: Ubuntu 18.04+, Debian 10+, or equivalent

## 🔐 Security & Privacy

- **Local network only** - no external data transmission
- **Optional encryption** for sensitive conversations
- **User-controlled access** - you decide who connects
- **No telemetry** or tracking
- **Open source** and auditable

## 📚 Documentation

Each platform includes comprehensive documentation:

### **macOS (.dmg)**
- `README.txt` - Quick start guide
- System tray setup instructions
- Firewall configuration tips

### **Windows (.zip/.exe)**
- `README-Windows.txt` - Windows-specific setup
- Firewall configuration steps
- Portable app instructions

### **Linux (.AppImage/.deb/.tar.gz)**
- `README-Linux.txt` - Linux distribution guides
- Package manager instructions
- Audio system configuration

## 🚀 Getting Started

1. **Download** the appropriate package for your platform
2. **Extract/Install** following platform-specific instructions
3. **Launch** VoiceLink Local
4. **Configure** firewall if needed (allows port 3000)
5. **Share** your server URL (shown in menu bar)
6. **Connect** friends via web browser or desktop app
7. **Enjoy** 3D spatial voice chat!

## 🔮 Future Updates

The update system is ready for future releases. Updates will be automatically detected and users will be notified with:

- **Download links** for their platform
- **Release notes** with new features
- **Critical update flags** for security fixes
- **Version comparison** to show improvements

## 📞 Support

- **GitHub Issues**: https://github.com/devinecreations/voicelink-local/issues
- **Email**: devinecr@raywonderis.me
- **Documentation**: Built-in help system and README files

---

**Thank you for using VoiceLink Local v1.0.0!**

This stable release represents months of development and testing. We hope you enjoy the advanced 3D spatial audio experience with your friends and colleagues.

*The VoiceLink team*