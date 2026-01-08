================================================================================
                          VoiceLink Local v1.0.0
                    P2P Voice Chat with 3D Spatial Audio
                               Linux Edition
================================================================================

QUICK START GUIDE FOR LINUX
----------------------------

Welcome to VoiceLink Local! This application creates a local voice chat server
with advanced 3D spatial audio for you and your friends.

LINUX INSTALLATION:
-------------------

Choose your preferred format:

AppImage (Recommended):
1. Download VoiceLink-Local-1.0.0.AppImage
2. Make executable: chmod +x VoiceLink-Local-1.0.0.AppImage
3. Run: ./VoiceLink-Local-1.0.0.AppImage

DEB Package (Ubuntu/Debian):
1. Download voicelink-local_1.0.0_amd64.deb
2. Install: sudo dpkg -i voicelink-local_1.0.0_amd64.deb
3. Run: voicelink-local

TAR.GZ Archive:
1. Extract: tar -xzf voicelink-local-1.0.0.tar.gz
2. cd voicelink-local-1.0.0
3. Run: ./voicelink-local

FIREWALL SETUP (IMPORTANT):
---------------------------

Linux may block the server. To allow connections:

UFW (Ubuntu/Debian):
sudo ufw allow 3000/tcp

Firewalld (CentOS/RHEL/Fedora):
sudo firewall-cmd --permanent --add-port=3000/tcp
sudo firewall-cmd --reload

IPTables (Manual):
sudo iptables -A INPUT -p tcp --dport 3000 -j ACCEPT

FIRST LAUNCH OPTIONS:
--------------------

When you launch VoiceLink Local, you'll have several options:

1. VIEW MANUAL FIRST (Recommended for new users)
   - Opens the comprehensive user manual
   - Server starts automatically in background
   - Learn about all features before diving in

2. SKIP TO APP
   - Jump straight into the application
   - Discover features as you explore
   - Manual available anytime from menu

3. MINIMIZE TO SYSTEM TRAY
   - App runs silently in your system tray
   - Server starts and waits for connections
   - Access controls via tray icon

4. QUIT APPLICATION
   - Exit VoiceLink Local
   - No server will be running

WHAT VOICELINK LOCAL DOES:
--------------------------

- Creates a LOCAL voice chat server on your network
- No internet required - works on WiFi/LAN
- Advanced 3D spatial audio (users have positions in virtual space)
- Professional audio effects and processing
- Multi-channel audio routing (up to 64 channels)
- Text-to-speech announcements with multiple languages
- PA system with push-to-talk controls
- Secure with optional encryption and 2FA
- Cross-platform support (Linux, Mac, Windows)

GETTING STARTED:
---------------

1. LAUNCH VoiceLink Local (see installation methods above)
2. CONFIGURE firewall if needed
3. CHOOSE your startup preference
4. SHARE the server URL with friends (shown in tray or main window)
5. OTHERS connect via web browser or desktop app
6. START talking with 3D spatial audio!

SERVER ACCESS:
-------------

Your server will be accessible at: http://[YOUR-IP]:3000

IMPORTANT: Always use IP ADDRESS to connect (not hostnames)

CORRECT: http://192.168.1.100:3000
CORRECT: http://10.0.0.88:3000
WRONG: http://mylinuxbox:3000
WRONG: http://ubuntu-desktop.local:3000

WHY IP ADDRESSES ONLY:
- Hostnames may not resolve on all devices
- IP addresses work universally across all networks
- Ensures reliable connections from any device
- Works with mobile devices, gaming consoles, etc.

TO FIND YOUR IP:
- Check the system tray - right-click to see IP
- Or run: ip addr show | grep inet
- Or run: hostname -I
- Share this exact URL with others

System tray shows:
- Server status (Running/Stopped)
- Your server URL with IP address (click to copy)
- Connected users and active rooms
- Quick access to settings and controls

AUDIO FEATURES:
--------------

- Push-to-Talk: Use Ctrl, Super key, Alt+Shift, F1, or Shift keys
- 3D Positioning: Users can move around in virtual space
- Audio Effects: 15+ professional effects (reverb, EQ, compressor, etc.)
- Room Acoustics: 5 room types for realistic sound environments
- Multi-Language TTS: Announcements in 10+ languages

LINUX-SPECIFIC FEATURES:
------------------------

- Multiple package formats (AppImage, DEB, TAR.GZ)
- Native PulseAudio/ALSA integration
- Desktop integration (if installed via DEB)
- System tray support (requires system tray)
- Command-line friendly

SYSTEM REQUIREMENTS:
-------------------

- Linux x64 (Ubuntu 18.04+, Debian 10+, CentOS 8+, or equivalent)
- Modern web browser (Firefox, Chrome, Chromium)
- Microphone and speakers/headphones
- Local network connection (WiFi/Ethernet)
- 200-400MB RAM depending on room size
- Firewall access for port 3000

AUDIO SYSTEM SETUP:
------------------

PulseAudio (Most Distributions):
- Usually works out of the box
- Check: pulseaudio --check -v

ALSA (Advanced):
- May need manual configuration
- Check: aplay -l (list devices)

Jack (Professional Audio):
- Advanced setup required
- Ensure Jack is running before launching

TROUBLESHOOTING:
---------------

- If audio doesn't work: Click anywhere in the app to enable audio
- If connection fails: Check firewall settings for port 3000
- If app won't start: Check executable permissions
- If no system tray: Install a system tray (like stalonetray)
- If performance issues: Reduce number of audio effects
- For help: Check the built-in manual or documentation

COMMON LINUX ISSUES:
-------------------

AppImage won't run:
- Install: sudo apt install fuse (Ubuntu/Debian)
- Or: sudo yum install fuse (CentOS/RHEL)

No audio devices:
- Check: pactl list short sources
- Check: pactl list short sinks
- Restart PulseAudio: pulseaudio -k && pulseaudio --start

Permission issues:
- Add user to audio group: sudo usermod -a -G audio $USER
- Log out and back in

PORT CHECKING:
- Check if running: netstat -tlnp | grep :3000
- Should show "LISTEN" if server is running

DESKTOP INTEGRATION:
-------------------

DEB package provides:
- Application menu entry
- MIME type associations
- Auto-start options
- Proper uninstall support

AppImage provides:
- Portable operation
- No system changes
- Easy version management

PRIVACY & SECURITY:
------------------

- All communication stays on your LOCAL network
- No data sent to external servers
- Optional encryption for sensitive conversations
- You control who can access your server
- Open source and auditable

ADVANCED FEATURES:
-----------------

- VST Plugin support for professional audio processing
- Multi-channel routing for complex audio setups
- Built-in audio testing and calibration tools
- Customizable push-to-talk key combinations
- Room templates and quick-join options

DOCUMENTATION:
-------------

Complete documentation available:
- In-app manual (Help menu)
- README.md in application folder
- Online at: github.com/devinecreations/voicelink-local

SUPPORT:
-------

For questions, bug reports, or feature requests:
- GitHub Issues: github.com/devinecreations/voicelink-local/issues
- Email: devinecr@raywonderis.me

BUILDING FROM SOURCE:
--------------------

Dependencies:
- Node.js 16+
- npm
- Git

Build steps:
git clone https://github.com/devinecreations/voicelink-local.git
cd voicelink-local
npm install
npm run build:linux

================================================================================

Enjoy your VoiceLink Local experience on Linux!

The app will remember your preferences and start the way you prefer next time.

================================================================================