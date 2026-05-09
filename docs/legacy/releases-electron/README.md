# VoiceLink - P2P Voice Chat System

A comprehensive voice chat application built with Electron, featuring 3D binaural audio, multi-channel support, VST plugin streaming, and advanced security features.

## Features

### Core Features
- **P2P Voice Communication**: Direct peer-to-peer voice chat using WebRTC
- **3D Binaural Audio**: Advanced spatial audio processing with HRTF
- **Multi-Channel Support**: Up to 64 input/output channels (mono, stereo, binaural)
- **VST Plugin Streaming**: Real-time audio effects processing and sharing
- **Comprehensive Settings**: Tabbed interface for all configuration options
- **Full Accessibility Support**: Complete screen reader integration with NVDA, system TTS, and ARIA compliance

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
- **Apple Silicon (M1/M2)**: [VoiceLink-1.0.0-arm64.dmg](releases/VoiceLink%20Local-1.0.0-arm64.dmg)
- **Intel Mac**: [VoiceLink-1.0.0.dmg](releases/VoiceLink%20Local-1.0.0.dmg)
- **Installation**: Double-click the DMG file and drag VoiceLink to Applications

#### 🪟 **Windows**
- **64-bit (Recommended)**: [VoiceLink-1.0.0-win.zip](releases/VoiceLink%20Local-1.0.0-win.zip)
- **32-bit**: [VoiceLink-1.0.0-ia32-win.zip](releases/VoiceLink%20Local-1.0.0-ia32-win.zip)
- **Installation**: Extract ZIP and run VoiceLink.exe

#### 🐧 **Linux**
- **AppImage (Universal)**: [VoiceLink-1.0.0.AppImage](releases/VoiceLink%20Local-1.0.0.AppImage)
- **Debian/Ubuntu**: [voicelink-local_1.0.0_amd64.deb](releases/voicelink-local_1.0.0_amd64.deb)
- **Generic Linux**: [voicelink-local-1.0.0.tar.gz](releases/voicelink-local-1.0.0.tar.gz)

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

- `npm start` - Start the Electron application
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
- Electron for cross-platform desktop support
- SimplePeer for WebRTC abstraction
- Socket.IO for real-time communication

## Support

For issues and support:
1. Check the troubleshooting section
2. Search existing issues
3. Create a new issue with detailed information
4. Include system information and logs