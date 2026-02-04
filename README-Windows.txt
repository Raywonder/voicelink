================================================================================
                          VoiceLink Local v1.0.0
                    P2P Voice Chat with 3D Spatial Audio
                              Windows Edition
================================================================================

QUICK START GUIDE FOR WINDOWS
------------------------------

Welcome to VoiceLink Local! This application creates a local voice chat server
with advanced 3D spatial audio for you and your friends.

WINDOWS INSTALLATION:
--------------------

1. Extract VoiceLink-Local-1.0.0-portable.exe from the ZIP file
2. Run VoiceLink-Local-1.0.0-portable.exe (no installation required)
3. Allow through Windows Firewall when prompted
4. Choose your startup preference from the options

FIREWALL SETUP (IMPORTANT):
---------------------------

Windows may block the server. To allow connections:

1. When Windows Firewall prompt appears, click "Allow access"
2. Or manually configure:
   - Open Windows Defender Firewall
   - Click "Allow an app through firewall"
   - Click "Change settings" then "Allow another app"
   - Browse and select VoiceLink Local
   - Check both "Private" and "Public" networks
   - Click OK

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
   - App runs silently in your system tray (bottom-right)
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
- Cross-platform support (Windows, Mac, Linux)

GETTING STARTED:
---------------

1. LAUNCH VoiceLink-Local-1.0.0-portable.exe
2. ALLOW through Windows Firewall
3. CHOOSE your startup preference
4. SHARE the server URL with friends (shown in tray or main window)
5. OTHERS connect via web browser or desktop app
6. START talking with 3D spatial audio!

SERVER ACCESS:
-------------

Your server will be accessible at: http://[YOUR-IP]:3000

IMPORTANT: Always use IP ADDRESS to connect (not computer names)

CORRECT: http://192.168.1.100:3000
CORRECT: http://10.0.0.88:3000
WRONG: http://MyComputer:3000
WRONG: http://DESKTOP-ABC123:3000

WHY IP ADDRESSES ONLY:
- Domain names may not resolve on all devices
- IP addresses work universally across all networks
- Ensures reliable connections from any device
- Works with mobile devices, gaming consoles, etc.

TO FIND YOUR IP:
- Check the system tray icon - right-click to see IP
- Or copy the full URL from tray menu (it uses IP automatically)
- Share this exact URL with others

System tray shows:
- Server status (Running/Stopped)
- Your server URL with IP address (click to copy)
- Connected users and active rooms
- Quick access to settings and controls

AUDIO FEATURES:
--------------

- Push-to-Talk: Use Ctrl, Windows key, Alt+Shift, F1, or Shift keys
- 3D Positioning: Users can move around in virtual space
- Audio Effects: 15+ professional effects (reverb, EQ, compressor, etc.)
- Room Acoustics: 5 room types for realistic sound environments
- Multi-Language TTS: Announcements in 10+ languages

WINDOWS-SPECIFIC FEATURES:
-------------------------

- Portable application (no installation required)
- Runs from any folder or USB drive
- Auto-start with Windows (optional)
- Windows notification support
- Native Windows audio device integration

SYSTEM REQUIREMENTS:
-------------------

- Windows 10 or later (64-bit recommended)
- Modern web browser (Chrome, Firefox, Edge)
- Microphone and speakers/headphones
- Local network connection (WiFi/Ethernet)
- 200-400MB RAM depending on room size
- Firewall access for port 3000

TROUBLESHOOTING:
---------------

- If audio doesn't work: Click anywhere in the app to enable audio
- If connection fails: Check Windows Firewall settings for port 3000
- If app won't start: Run as Administrator
- If performance issues: Reduce number of audio effects
- For help: Check the built-in manual or documentation

WINDOWS FIREWALL ISSUES:
-----------------------

If others can't connect:
1. Right-click Windows Start button
2. Select "Windows PowerShell (Admin)"
3. Run: netsh advfirewall firewall add rule name="VoiceLink" dir=in action=allow protocol=TCP localport=3000
4. Restart VoiceLink Local

PORT CHECKING:
- Open Command Prompt
- Run: netstat -an | findstr :3000
- Should show "LISTENING" if server is running

PRIVACY & SECURITY:
------------------

- All communication stays on your LOCAL network
- No data sent to external servers
- Optional encryption for sensitive conversations
- You control who can access your server
- Portable - leaves no traces when removed

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

================================================================================

Enjoy your VoiceLink Local experience on Windows!

The app will remember your preferences and start the way you prefer next time.

================================================================================