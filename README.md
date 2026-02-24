# VoiceLink Local - P2P Voice Chat System

A comprehensive voice chat application with native desktop clients (not Electron), featuring 3D binaural audio, multi-channel support, VST plugin streaming, and advanced security features.

## Platform Priority Policy

- Desktop app is the primary VoiceLink experience.
- Desktop clients are native apps (macOS/Windows), not Electron.
- iOS builds should include the same desktop features as much as possible.
- Web app is secondary and receives a subset of features.
- Features not implemented for web must be hidden for web users.
- New feature work should target desktop first, then web support where practical.

## Latest macOS Native Update (Build 20, 2026-02-23)

- Startup no longer plays the default macOS fallback system tone when welcome audio is unavailable.
- Missing UI sounds now download in the background with a non-blocking in-app notice.
- Added reminder behavior for pending sound downloads on subsequent launches.
- Added built-in self-test scheduler and admin controls under Admin -> Self Tests.
- Added admin login fallback for `datboydommo@layor8.space`.

## Current Implementation Status (Audit: 2026-02-11)

- Active native desktop source is currently maintained in `../voicelink-local/swift-native/VoiceLinkNative/Sources` and `../voicelink-local/windows-native/VoiceLinkNative`.
- This repo currently still contains Electron build/runtime scripts in `package.json` for legacy compatibility and web-runtime packaging paths.
- In this repo, `swift-native/VoiceLinkNative` currently contains build artifacts and packaged outputs, not full source files.
- In this repo, `windows-native/VoiceLinkNative` currently contains build output/intermediate files, not full source files.

## Desktop + API Parity Checklist

Status labels:
- `[x]` implemented in active workspace (`../voicelink-local`)
- `[ ]` not yet synced/verified in this repo

### Desktop UX and Room Controls

- `[x]` Room preview/peek flow with privacy handling (`../voicelink-local/source/client/js/core/app.js`)
- `[x]` Double-Escape room actions menu (`../voicelink-local/source/client/js/core/app.js`)
- `[x]` Room lock/unlock actions and API calls (`../voicelink-local/source/client/js/core/app.js`, `../voicelink-local/source/routes/local-server.js`)
- `[x]` Room jukebox integration and controls (`../voicelink-local/source/client/js/core/app.js`, `../voicelink-local/source/client/js/media/jellyfin-manager.js`)
- `[x]` Auto-update check UX/settings for desktop (`../voicelink-local/source/client/index.html`, `../voicelink-local/swift-native/VoiceLinkNative/Sources/AutoUpdater.swift`)
- `[ ]` Sync these exact desktop UX flows into this repo's native source tree

### API Endpoints Required by Desktop

- `[x]` Auth/Authelia endpoints (`../voicelink-local/source/routes/local-server.js`)
- `[x]` Update check + downloads metadata endpoints (`../voicelink-local/source/routes/local-server.js`)
- `[x]` Room actions endpoints (lock/unlock/visibility/status) (`../voicelink-local/source/routes/local-server.js`)
- `[x]` Jellyfin/Jukebox room + queue + stream endpoints (`../voicelink-local/source/routes/local-server.js`)
- `[x]` Admin operations used by desktop UI (`../voicelink-local/source/routes/local-server.js`)
- `[x]` Wallet/ecripto integration endpoints (`../voicelink-local/source/routes/local-server.js`)
- `[ ]` Ensure parity between `server/routes/local-server.js`, `source/routes/local-server.js`, and `source/server/routes/local-server.js` in this repo

### QA and Release Hygiene

- `[ ]` Populate real tests under `tests/unit`, `tests/integration`, and `tests/e2e` (currently scaffold dirs)
- `[ ]` Remove stale artifact-only native trees from git tracking or replace with source-of-truth code
- `[ ]` Keep release docs aligned with ZIP-first macOS distribution policy

## Features

### Core Features
- **P2P Voice Communication**: Direct peer-to-peer voice chat using WebRTC
- **3D Binaural Audio**: Advanced spatial audio processing with HRTF
- **Multi-Channel Support**: Up to 64 input/output channels (mono, stereo, binaural)
- **VST Plugin Streaming**: Real-time audio effects processing and sharing
- **Comprehensive Settings**: Tabbed interface for all configuration options
- **Full Accessibility Support**: Complete screen reader integration with NVDA, system TTS, and ARIA compliance
- **Jellyfin Webhook Push**: Jellyfin webhook events are pushed in real time to connected desktop clients
- **Direct HTTPS Media Streaming**: Stream direct HTTPS media URLs to self or to an entire room
- **Optional Media Save**: Admin-configurable option to save direct URL media for future playback

### Audio Features
- 3D spatial audio with customizable room acoustics
- Advanced audio routing and channel matrix
- Built-in VST plugins (Reverb, Compressor, EQ, Delay, Chorus, etc.)
- Professional audio device management
- Audio testing suite with synthetic TTS generation
- Pink noise and tone generation for testing

### Security Features
- End-to-end encryption (AES-256, RSA-4096)
- Two-factor authentication (TOTP, SMS, Email, Hardware Keys, Biometric)
- Cross-platform keychain integration (iCloud, Windows Credential Manager, Linux Secret Service)
- Perfect Forward Secrecy support

### Server Access
- Multiple connection methods (Direct IP, Domain, Invite Links, QR Codes)
- Public and private server access
- VPN and proxy support
- Local network discovery
- Public server browser

### Administration
- Unified local/remote admin interface
- Real-time monitoring and control
- User and room management
- Audio system administration

## Project Structure

```
voicelink-local/
├── client/                     # Frontend application
│   ├── index.html             # Main HTML file
│   ├── css/                   # Stylesheets
│   ├── js/                    # JavaScript modules
│   │   ├── core/              # Core application logic
│   │   ├── audio/             # Audio processing modules
│   │   ├── network/           # Network and communication
│   │   ├── security/          # Security and encryption
│   │   ├── ui/                # User interface components
│   │   └── tests/             # Testing and audio tools
│   └── assets/                # Static assets
│       ├── audio/             # Audio test files
│       ├── images/            # Images and icons
│       └── fonts/             # Custom fonts
├── server/                    # Backend server
│   ├── routes/                # Server routes and handlers
│   ├── middleware/            # Express middleware
│   ├── models/                # Data models
│   └── utils/                 # Server utilities
├── build/                     # Build configurations
│   ├── dev/                   # Development builds
│   └── prod/                  # Production builds
├── tests/                     # Test suites
│   ├── unit/                  # Unit tests
│   ├── integration/           # Integration tests
│   └── e2e/                   # End-to-end tests
├── api/                       # API documentation
├── config/                    # Configuration files
└── docs/                      # Documentation
```

## Download & Installation

### Pre-built Applications (Recommended)

Download the latest release for your platform:

#### 🍎 **macOS**
- **Primary distribution artifact**: `VoiceLinkMacOS.zip`
- **Compatibility alias artifact**: `VoiceLink-macOS.zip`
- **Public download URL**: `https://voicelink.devinecreations.net/downloads/voicelink/VoiceLinkMacOS.zip`
- **Updater manifest**: `swift-native/VoiceLinkNative/latest-mac.yml`
- **Server updater manifest**: `swift-native/VoiceLinkNative/latest-mac.server.yml`
- **Installation**: Extract ZIP, place `VoiceLink.app` in `/Applications`, launch.

#### 🪟 **Windows**
- Windows desktop is currently not released for production users in this channel.

#### 🐧 **Linux**
- Linux desktop packages are not the active production distribution path in this channel.

### Permissions Troubleshooting (Room Settings / Delete)

If you see:
- `Room settings denied ... account is not recognized as owner/admin on this server`
- `Delete denied ... account is not recognized as owner/admin on this server`

VoiceLink only allows room-management actions when your current identity is recognized by the connected server as one of:
- Room owner/creator identity for that room
- Admin/owner role on that server instance
- Moderator/manager permissions allowed by the server role model

When using Mastodon or federated login, make sure you are signed into the same instance/account that created the room (or one granted admin/moderator rights on that server).

### Development Installation

1. Clone the repository:
```bash
git clone <repository-url>
cd voicelink-local
```

2. Install dependencies:
```bash
npm install
```

3. Start the application:
```bash
npm start
```

## Development

### Available Scripts

- `npm start` - Start the desktop client development runtime
- `npm run dev` - Start in development mode with hot reload
- `npm run build` - Build for production
- `npm run test` - Run test suite
- `npm run lint` - Run code linting
- `npm run package` - Package the application

### Architecture

#### Core Components

1. **Audio Engine** (`client/js/core/audio-engine.js`)
   - Core audio processing and device management
   - Input/output routing and gain control
   - Professional audio interface support

2. **Spatial Audio Engine** (`client/js/audio/spatial-audio.js`)
   - 3D binaural audio processing
   - HRTF-based positioning
   - Room acoustics simulation

3. **Multi-Channel Engine** (`client/js/audio/multi-channel-engine.js`)
   - 64-channel audio matrix
   - Channel routing and assignment
   - Professional audio workflows

4. **VST Streaming Engine** (`client/js/audio/vst-streaming-engine.js`)
   - Real-time audio effects processing
   - Plugin chain management
   - Cross-user effect streaming

5. **WebRTC Manager** (`client/js/network/webrtc-manager.js`)
   - P2P connection management
   - Audio stream handling
   - Network optimization

6. **Security Manager** (`client/js/security/security-encryption-manager.js`)
   - End-to-end encryption
   - Key management
   - Security policy enforcement

#### User Interface

1. **Settings Interface Manager** (`client/js/ui/settings-interface-manager.js`)
   - Comprehensive tabbed settings interface
   - Real-time configuration updates
   - Settings import/export

2. **Admin Interface** (`client/js/ui/unified-admin-interface.js`)
   - Server administration
   - User and room management
   - System monitoring

#### Testing & Audio Tools

1. **Audio Test Manager** (`client/js/tests/audio-test-manager.js`)
   - Audio playback testing
   - Device testing and calibration
   - Quality assurance tools

2. **Synthetic Audio Generator** (`client/js/tests/synthetic-audio-generator.js`)
   - TTS-based test generation
   - 3D positioning tests
   - Frequency and distance testing

## Configuration

### Audio Settings
Configure audio devices, channel routing, and processing in the comprehensive settings interface:
- Audio Devices: Input/output device selection and configuration
- Channel Matrix: 64-channel routing and assignments
- VST Plugins: Effects processing and streaming
- 3D Audio: Spatial processing and room acoustics

### Security Settings
Configure encryption and authentication:
- Encryption Level: Basic, Medium, or High security
- Two-Factor Authentication: Multiple methods supported
- Keychain Integration: Platform-specific credential storage

### Server Settings
Configure connection and networking:
- Connection Methods: Direct IP, domain, invite links, QR codes
- Proxy/VPN: Advanced networking options
- Discovery: Local and public server discovery

## API Integration

### TTS Integration (Synthetic Audio Generation)
To use synthetic audio generation features:

1. Get an API key from Eleven Labs or similar TTS service
2. Configure in Settings > Audio Testing > TTS Configuration
3. Generate custom test audio for 3D positioning and quality testing

### Third-Party Media Players
The application supports API integration with external media players and streaming services through the plugin system.

## Testing

### Audio Testing
The application includes comprehensive audio testing tools:

1. **Playback Tests**: Test speakers and audio routing
2. **Recording Tests**: Test microphones and input devices
3. **3D Spatial Tests**: Test binaural audio positioning
4. **Synthetic Tests**: Generate custom test audio with TTS

### Network Testing
Test P2P connections and network performance:
- Connection quality monitoring
- Latency and jitter measurement
- Bandwidth optimization

## Security

### Encryption
- AES-256-GCM for real-time audio encryption
- RSA-4096 for key exchange
- Perfect Forward Secrecy support

### Authentication
- Multiple 2FA methods supported
- Biometric authentication
- Hardware key support (WebAuthn)
- Cross-platform keychain integration

### Privacy
- No data collection or telemetry
- Local-first architecture
- End-to-end encryption by default

## Recent Updates (v1.0.0)

### 🔧 **Critical Fixes**
- **Fixed Room Creation**: Resolved issue where users were returned to main screen instead of joining created rooms
- **Fixed UI Sounds**: Restored all UI sound effects with improved fallback system and error handling
- **Fixed Audio Initialization**: Enhanced audio startup with better browser autoplay policy compliance
- **Improved Error Handling**: Added robust fallback systems for audio context failures

### 🚀 **Enhancements**
- Enhanced `joinRoom()` method with proper audio initialization sequencing
- Improved `playUISound` function with comprehensive error handling
- Better `setupAudioGestureHandler()` for reliable audio startup
- Added fallback audio systems for better reliability

### 🔄 **Technical Improvements**
- Fixed audio engine initialization timing issues
- Enhanced WebRTC connection reliability
- Improved browser compatibility for audio contexts
- Better handling of deferred audio initialization

## Troubleshooting

### Common Issues

1. **Audio Device Access**
   - Ensure microphone permissions are granted
   - Check audio device drivers
   - Verify device compatibility

2. **Connection Issues**
   - Check firewall settings
   - Verify network connectivity
   - Test with different connection methods

3. **Performance Issues**
   - Adjust buffer sizes in audio settings
   - Disable unnecessary VST plugins
   - Check system resource usage

### Logs and Debugging
- Enable verbose logging in development mode
- Check browser developer tools for errors
- Monitor network connections in admin interface

## Contributing

1. Fork the repository
2. Create a feature branch
3. Make your changes
4. Add tests for new features
5. Submit a pull request

## License

This project is licensed under the MIT License - see the LICENSE file for details.

## Acknowledgments

- Web Audio API for audio processing
- WebRTC for P2P communication
- Native desktop clients (macOS/Windows)
- SimplePeer for WebRTC abstraction
- Socket.IO for real-time communication

## Support

For issues and support:
1. Check the troubleshooting section
2. Search existing issues
3. Create a new issue with detailed information
4. Include system information and logs
