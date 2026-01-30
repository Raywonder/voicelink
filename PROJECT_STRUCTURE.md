# VoiceLink Local - Project Structure

This document describes the reorganized project structure that separates source files from build artifacts.

## Directory Structure

```
voicelink-local/
├── source/                     # All source code and development files
│   ├── client/                 # Frontend web client
│   │   ├── js/                 # JavaScript modules
│   │   │   ├── core/           # Core application logic
│   │   │   ├── audio/          # Audio processing and streaming
│   │   │   ├── media/          # Media streaming (Jellyfin, live streams)
│   │   │   ├── ui/             # User interface components
│   │   │   └── network/        # Network and P2P management
│   │   ├── css/                # Stylesheets
│   │   └── *.html             # HTML templates
│   ├── src/                    # Electron main process
│   │   ├── main.js            # Main Electron entry point
│   │   └── preload.js         # Preload scripts
│   ├── server/                 # Backend server components
│   ├── api/                    # API definitions
│   ├── config/                 # Configuration files
│   ├── tests/                  # Test files
│   ├── assets/                 # Static assets (icons, images)
│   ├── docs/                   # Documentation
│   ├── package.json           # Dependencies and build scripts
│   ├── build.config.js        # Build configuration
│   └── *.md                   # Documentation files
├── releases/                   # Final release packages (.dmg, .zip, .deb, etc.)
├── build-temp/                 # Temporary build artifacts
│   ├── dev/                   # Development builds
│   ├── prod/                  # Production builds
│   └── dist-dev/              # Development distribution
├── build.sh                   # Master build script
└── PROJECT_STRUCTURE.md       # This file
```

## Key Components

### Existing Streaming Infrastructure

The project already has comprehensive streaming capabilities:

1. **LiveStreamingManager** (`source/client/js/media/live-streaming-manager.js`)
   - Handles Icecast, Shoutcast, and generic live streams
   - Real-time metadata fetching
   - Audio visualization and quality controls
   - Stream validation and error handling

2. **VSTStreamingEngine** (`source/client/js/audio/vst-streaming-engine.js`)
   - Real-time VST plugin streaming
   - Built-in effects (reverb, compressor, EQ, delay, chorus, distortion, pitch shifter, vocoder)
   - Latency compensation and compression
   - Parameter synchronization across users

3. **MediaStreamingInterface** (`source/client/js/ui/media-streaming-interface.js`)
   - Unified UI for Jellyfin and live streaming
   - Tabbed interface with playback controls
   - Settings management and visualization

## Build System

### Using the Build Script

The `build.sh` script provides a unified way to build the application:

```bash
# Build for development
./build.sh dev

# Build for macOS and install to /Applications
./build.sh mac install

# Build for all platforms and install Mac app
./build.sh all install

# Clean build artifacts
./build.sh clean

# Run tests
./build.sh test
```

### Build Outputs

- **Source builds**: Generated in `build-temp/`
- **Release packages**: Generated in `releases/`
- **macOS**: Automatically installed to `/Applications/` when using `install` flag

### Directory Benefits

1. **Clean Separation**: Source code is separated from build artifacts
2. **Easy Deployment**: Releases directory contains only final packages
3. **Development**: All source files are organized in the `source/` directory
4. **Automation**: Build script handles the entire build and installation process

## Development Workflow

1. **Development**: Work in the `source/` directory
2. **Building**: Use `./build.sh [platform] [install]` from project root
3. **Testing**: Built files are in `build-temp/`, releases in `releases/`
4. **Installation**: Use `install` flag to automatically update `/Applications/`

## Streaming Capabilities

The application includes comprehensive streaming infrastructure:

- **Live Stream Sources**: Icecast, Shoutcast, generic HTTP streams
- **VST Processing**: Real-time audio effects with streaming
- **Media Integration**: Jellyfin server integration
- **Quality Control**: Multiple bitrate options and formats
- **Visualization**: Real-time audio spectrum analysis
- **Metadata**: Automatic fetching from stream sources

All streaming components are fully implemented and ready for use or enhancement.