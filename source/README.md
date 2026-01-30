# VoiceLink Local - P2P Voice Chat System

A comprehensive voice chat application built with Electron, featuring 3D binaural audio, multi-channel support, VST plugin streaming, and advanced security features.

## Features

### Core Features
- **P2P Voice Communication**: Direct peer-to-peer voice chat using WebRTC
- **3D Binaural Audio**: Advanced spatial audio processing with HRTF
- **Multi-Channel Support**: Up to 64 input/output channels (mono, stereo, binaural)
- **VST Plugin Streaming**: Real-time audio effects processing and sharing
- **Comprehensive Settings**: Tabbed interface for all configuration options
- **Live Streaming Infrastructure**: Enhanced streaming manager with protocol detection
- **Voice Prompt System**: ElevenLabs-ready voice notification framework
- **Broadcast Manager**: Output streaming architecture for multiple protocols
- **Enhanced Room Interactions**: Advanced keyboard navigation and preview system
- **Professional Recording**: Multi-track recording with administrative controls
- **Invitation System**: Web UI and desktop app invitation management

### Audio Features
- 3D spatial audio with customizable room acoustics
- Advanced audio routing and channel matrix
- Built-in VST plugins (Reverb, Compressor, EQ, Delay, Chorus, Distortion, Pitch Shifter, Vocoder)
- Professional audio device management
- Audio testing suite with synthetic TTS generation
- Pink noise and tone generation for testing
- Voice prompt manager with audio ducking support
- Enhanced stream metadata detection
- Startup river ambience with seamless transitions
- Room audio preview system with "behind the door" effect

### Room Interaction Features
- **Keyboard-First Navigation**: Complete keyboard control for all room interactions
- **Room Preview System**: 30-second lo-fi audio previews without joining
- **Escape Key Menu**: Comprehensive room management through intuitive escape menu
- **Advanced Keyboard Shortcuts**: Enter to join, Shift+Enter to preview, Ctrl+Enter for occupancy
- **Context Menus**: Right-click or keyboard-activated context options
- **Private Messaging**: Ctrl+Shift+Enter for private communication options
- **Double-Escape Quick Exit**: Admin-only instant room exit functionality

### Recording & Collaboration
- **Multi-Track Recording**: Professional stem recording with per-user isolation
- **Interview Mode**: Optimized recording for podcasts and interviews
- **Live Event Recording**: Simultaneous streaming and backup recording
- **Recording Time Limits**: Configurable min/max recording durations
- **User Privacy Controls**: Individual opt-out from recording sessions
- **Administrative Policies**: Server-wide recording rules and restrictions

### Enhanced Streaming Components
- **LiveStreamingManager**: Enhanced with RTMP, SRT, WebRTC, HLS, NDI protocol support
- **BroadcastStreamingManager**: New component for output streaming to multiple platforms
- **VoicePromptManager**: Framework for ElevenLabs voice notifications
- **MediaStreamingInterface**: Updated UI with additional protocol options
- **Protocol Detection**: Auto-detection for various streaming formats

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
├── source/                     # All source code and development files
│   ├── client/                 # Frontend application
│   │   ├── index.html         # Main HTML file
│   │   ├── css/               # Stylesheets
│   │   ├── js/                # JavaScript modules
│   │   │   ├── core/          # Core application logic
│   │   │   ├── audio/         # Audio processing modules
│   │   │   ├── media/         # Streaming and media components
│   │   │   ├── ui/            # User interface components
│   │   │   └── network/       # Network and P2P management
│   │   └── assets/            # Static assets and voice prompts
│   ├── src/                   # Electron main process
│   ├── server/                # Backend server components
│   ├── api/                   # API definitions
│   ├── config/                # Configuration files
│   ├── tests/                 # Test files
│   └── docs/                  # Documentation
├── releases/                   # Final release packages (.dmg, .zip, .deb)
├── build-temp/                 # Temporary build artifacts
├── build.sh                   # Master build script
└── PROJECT_STRUCTURE.md       # Detailed project organization
```

## Installation

1. Clone the repository:
```bash
git clone <repository-url>
cd voicelink-local
```

2. Build the application:
```bash
# Build for macOS and install to /Applications
./build.sh mac install

# Or build for development
./build.sh dev

# Or build for all platforms
./build.sh all
```

3. For development:
```bash
# Install dependencies and start from source
cd source
npm install
npm start
```

## Development

### Build System

Use the master build script from the project root:

```bash
# Available build commands
./build.sh dev      # Development build
./build.sh prod     # Production build
./build.sh mac      # macOS build
./build.sh win      # Windows build
./build.sh linux    # Linux build
./build.sh all      # All platforms
./build.sh clean    # Clean artifacts
./build.sh test     # Run tests

# Add 'install' to automatically install Mac app
./build.sh mac install
```

### Available Scripts (from source/ directory)

- `npm start` - Start the Electron application
- `npm run dev` - Start in development mode
- `npm run build:mac` - Build for macOS
- `npm run build:all` - Build for all platforms
- `npm run test` - Run test suite
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

7. **Live Streaming Manager** (`client/js/media/live-streaming-manager.js`)
   - Enhanced with RTMP, SRT, WebRTC, HLS, NDI protocol support
   - Stream metadata detection and management
   - Quality control and format selection

8. **Broadcast Streaming Manager** (`client/js/media/broadcast-streaming-manager.js`)
   - Output streaming to multiple platforms
   - Multi-protocol encoder support
   - Professional broadcasting features

9. **Voice Prompt Manager** (`client/js/audio/voice-prompt-manager.js`)
   - ElevenLabs voice notification framework
   - Audio ducking and prompt queue management
   - Context-aware voice feedback

#### User Interface

1. **Settings Interface Manager** (`client/js/ui/settings-interface-manager.js`)
   - Comprehensive tabbed settings interface
   - Real-time configuration updates
   - Settings import/export

2. **Admin Interface** (`client/js/ui/unified-admin-interface.js`)
   - Server administration
   - User and room management
   - System monitoring

3. **Media Streaming Interface** (`client/js/ui/media-streaming-interface.js`)
   - Enhanced with additional protocol support
   - Unified Jellyfin and live streaming management
   - Tabbed interface for media control

#### Testing & Audio Tools

1. **Audio Test Manager** (`client/js/tests/audio-test-manager.js`)
   - Audio playback testing
   - Device testing and calibration
   - Quality assurance tools

2. **Synthetic Audio Generator** (`client/js/tests/synthetic-audio-generator.js`)
   - TTS-based test generation
   - 3D positioning tests
   - Frequency and distance testing

## User Guides

### Room Interaction Guide
For comprehensive information about the enhanced room interaction features, keyboard shortcuts, recording system, and invitation management, see the detailed [Room Interaction Guide](ROOM_INTERACTION_GUIDE.md).

**Key Features Covered:**
- Startup river ambience system
- Room preview ("behind the door" effect)
- Complete keyboard shortcut reference
- Escape key menu system
- Professional recording features
- Invitation and sharing system

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