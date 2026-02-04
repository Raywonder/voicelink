# VoiceLink Local - Room Interaction Guide

A comprehensive guide to the enhanced room interaction features including keyboard shortcuts, room preview system, escape key menu management, invitation system, and recording capabilities.

## Table of Contents

1. [Startup Experience](#startup-experience)
2. [Room Navigation & Preview](#room-navigation--preview)
3. [Keyboard Shortcuts](#keyboard-shortcuts)
4. [Context Menus](#context-menus)
5. [Escape Key Menu System](#escape-key-menu-system)
6. [Room Invitation System](#room-invitation-system)
7. [Recording Features](#recording-features)
8. [Future Features](#future-features)

---

## Startup Experience

### River Ambience System
When you first open VoiceLink Local, you'll hear a calm river ambience playing at -20dB on loop. This represents "time flowing back and forth" and creates a peaceful startup environment.

**Features:**
- **Automatic Playback**: Starts immediately when the app opens
- **Volume Level**: Set to -20dB for subtle background presence
- **Seamless Transition**: Fades away smoothly when you choose a room
- **River Sound**: Calming water flow representing the passage of time

**Note**: The river ambience only plays on the main menu screen and will automatically stop when you enter any room.

---

## Room Navigation & Preview

### Room Audio Preview System ("Glance" Feature)
Experience rooms before joining with the innovative "behind the door" preview system.

**How It Works:**
- **30-Second Previews**: Get a taste of room audio for exactly 30 seconds
- **Lo-Fi Effect**: Audio is filtered to sound like you're listening "behind the door"
- **No Joining Required**: Preview without actually entering the room
- **Automatic Timeout**: Preview ends automatically after 30 seconds

**Lo-Fi Audio Processing:**
- Low-pass filter at 800Hz for muffled effect
- Reduced audio quality to simulate distance
- Background positioning to maintain spatial awareness
- Clear distinction between preview and actual room audio

---

## Keyboard Shortcuts

### Room List Navigation
When browsing rooms, use these keyboard shortcuts for enhanced interaction:

| Shortcut | Action | Description |
|----------|--------|-------------|
| **Enter** | Join Room | Enter the selected room normally |
| **Shift + Enter** | Preview Room | Start 30-second audio preview |
| **Ctrl + Enter** | Check Occupancy | Announce how many people are in the room |
| **Ctrl + Shift + Enter** | Private Messaging | Access private messaging options |
| **Escape** | Context Menu | Open room context menu with options |

### In-Room Shortcuts
Once you're inside a room:

| Shortcut | Action | Description |
|----------|--------|-------------|
| **Escape** | Room Menu | Open in-room management menu |
| **Double Escape** | Exit Room (Admin) | Quick exit for room administrators |

### Preview Controls
During room preview:

| Shortcut | Action | Description |
|----------|--------|-------------|
| **Escape** | End Preview | Stop preview and return to room list |
| **Enter** | Join Room | End preview and join the room |

---

## Context Menus

### Room Context Menu
Right-click on any room or use the **Escape** key to access context options:

**Available Options:**
- **👁️ Preview Room** - Start 30-second audio preview
- **🚪 Join Room** - Enter the room normally
- **👥 Check Occupancy** - See how many users are currently in the room
- **💬 Private Message** - Send private messages to room users
- **❌ Close Menu** - Close the context menu

**Navigation:**
- Use **arrow keys** to navigate menu options
- Press **Enter** to select an option
- Press **Escape** to close the menu

---

## Escape Key Menu System

### Single Escape - Room Management Menu
Press **Escape** once while in a room to access the comprehensive room management system:

**Standard Options:**
- **⚙️ Room Settings** - Configure room parameters
- **👥 Manage Users** - User administration tools
- **📧 Invite Users** - Send room invitations
- **🎙️ Recording** - Recording controls and options
- **🎧 Audio Settings** - Open audio configuration
- **🔇 Toggle Mute** - Mute/unmute your microphone
- **🚪 Leave Room** - Exit the current room
- **❌ Close Menu** - Close the menu

**Admin-Only Options:**
- **👑 Admin Panel** - Advanced room administration

### Double Escape - Quick Exit (Admin Only)
For room administrators, pressing **Escape** twice quickly (within 500ms) provides instant room exit:

**Features:**
- **500ms Detection Window**: Must press Escape twice within half a second
- **Admin-Only**: Only available to room administrators/creators
- **Instant Exit**: Bypasses confirmation dialogs
- **Visual Feedback**: Shows "Double escape detected - Leaving room..." notification

**Menu Navigation:**
- **Arrow Keys**: Navigate up/down through options
- **Enter**: Select current option
- **Escape**: Close menu

---

## Room Invitation System

### Invitation Dialog
Access the invitation system through the **Escape menu > 📧 Invite Users** or during room management.

**Invitation Types:**

#### 🌐 Web UI Access
For users who want to join through a web browser:
- **Direct Web Link**: `[server]/join/[room-id]`
- **Instant Access**: No app installation required
- **Browser Compatible**: Works on any modern web browser
- **One-Click Copy**: Copy link to clipboard

#### 📱 Desktop App Access
For users with the VoiceLink Local app installed:
- **App Deep Link**: `[server]/room/[room-id]`
- **Enhanced Features**: Full desktop app capabilities
- **Better Performance**: Native app performance
- **Advanced Audio**: Full spatial audio features

#### 📥 Download Links
For new users who need the app:
- **Download Link**: `[server]/download/voicelink-local`
- **Auto-Detection**: Server detects user's operating system
- **Installation Guides**: Step-by-step setup instructions

**Sharing Features:**
- **Copy to Clipboard**: One-click copying for all link types
- **Multiple Format Support**: Text, QR codes, and direct sharing
- **Contextual Help**: Explains when to use each link type
- **Server Integration**: Works with CopyParty builtin server

---

## Recording Features

### Recording System Overview
VoiceLink Local includes professional-grade recording capabilities for interviews, events, and collaborative sessions.

**Access Recording Controls:**
- Navigate to **Escape Menu > 🎙️ Recording**
- Only available when multiple users are present in the room

### Recording Modes

#### 🎵 Stereo Mix Recording
- **Description**: Records all audio mixed together in stereo
- **Use Case**: General conversations, meetings
- **Output**: Single stereo audio file
- **Processing**: Real-time mixing of all participants

#### 🎛️ Multi-track Recording (Stems)
- **Description**: Records each user as separate audio tracks
- **Use Case**: Professional editing, post-production
- **Output**: Separate audio file per participant
- **Processing**: Individual track isolation for each user

#### 🎤 Interview Style Recording
- **Description**: Optimized for interviews with enhanced voice clarity
- **Use Case**: Podcasts, interviews, voice content
- **Output**: Enhanced stereo with voice processing
- **Processing**: Automatic voice enhancement and noise reduction

#### 📡 Live Event Recording
- **Description**: Real-time streaming with backup recording
- **Use Case**: Live events, broadcasts, streaming
- **Output**: Live stream + backup recording file
- **Processing**: Simultaneous streaming and local recording

### Output Formats
Support for professional audio formats:
- **WAV**: Uncompressed, highest quality
- **MP3**: Compressed, smaller file size
- **FLAC**: Lossless compression
- **AAC**: High-quality compression

### Recording Limits & Controls
**Recording Time Management:**
- **Unlimited**: No time restrictions (server default)
- **Time Limited**: Set minimum and maximum recording duration
- **Size Limited**: Limit recordings by file size
- **Per Session Limited**: Restrictions apply per recording session

**Time Limit Configuration:**
- **Minimum Time**: Shortest allowed recording (1-1440 minutes)
- **Maximum Time**: Longest allowed recording (1-1440 minutes)
- **Server Enforcement**: Admin-set limits override user preferences
- **Smart Validation**: Automatically adjusts max time to match min time if conflicting

**User Privacy Controls:**
- **Recording Consent**: Individual users can opt out of being recorded
- **Session-Based**: Permission applies only to current session
- **Visual Indicator**: Clear notification when recording permission changes
- **Exclude Option**: Checkbox to exclude your audio from all recordings

### Recording Restrictions
**Single User Protection:**
- Recording is disabled when you're alone in a room
- Shows message: "⚠️ You are the only one in this room. You cannot record an empty room with just yourself!"
- Ensures recordings contain meaningful conversation

**Administrative Controls:**
- **Server-Wide Limits**: Admins can set recording policies per server
- **User Permissions**: Individual recording rights management
- **Storage Quotas**: Disk space and file count limitations
- **Quality Settings**: Bitrate and format restrictions

**Requirements:**
- At least 2 users must be present in the room
- All participants must have recording permission enabled
- Proper audio permissions must be granted
- Sufficient disk space for recording files
- Server recording policy must allow recording

---

## Future Features

### Planned for v2.0/v3.0

#### Spatial Proximity Voice Chat
- **X/Y Movement**: Users can move around in virtual space
- **Proximity Communication**: Walk up to users for private conversations
- **Dynamic Audio**: Background audio fades and EQs based on distance
- **Visual Positioning**: See user positions in virtual room space

#### Server-Based Audio System
- **CopyParty Integration**: Replace local sounds with server owner's choices
- **Automatic Streaming**: Server handles audio streaming and caching
- **Dynamic Downloads**: Background downloading of server-specific sounds
- **Seamless Switching**: Automatic adaptation to different servers

#### Enhanced Private Messaging
- **Multiple Communication Methods**: Whisper, SMS, direct call options
- **Selective Audio Routing**: Private conversations with room audio muting
- **Context-Aware Messaging**: Smart message routing based on user status

#### Advanced Room Features
- **Room Templates**: Pre-configured room setups
- **Acoustic Modeling**: Real-world room acoustic simulation
- **Dynamic Environments**: Changing room acoustics based on activity
- **Custom Soundscapes**: User-defined ambient environments

---

## Technical Implementation Notes

### Audio Processing
- **Web Audio API**: Core audio processing engine
- **Spatial Audio Engine**: 3D binaural audio with HRTF
- **Real-time Processing**: Low-latency audio effects and routing
- **Multi-channel Support**: Up to 64 channels for professional use

### Network Architecture
- **WebRTC P2P**: Direct peer-to-peer communication
- **Socket.IO**: Real-time signaling and control
- **Adaptive Quality**: Dynamic audio quality based on network conditions
- **Connection Recovery**: Automatic reconnection and quality adjustment

### User Interface
- **Keyboard-First Design**: Complete keyboard navigation support
- **Context-Aware Menus**: Dynamic options based on user permissions
- **Progressive Enhancement**: Graceful degradation for different capabilities
- **Accessibility**: Screen reader and assistive technology support

---

## Support and Troubleshooting

### Common Issues

#### Preview System
- **No Audio in Preview**: Check audio permissions and device selection
- **Preview Doesn't Start**: Ensure room has active audio or users
- **Lo-Fi Effect Too Strong**: This is intentional - join room for full quality

#### Recording Problems
- **Recording Disabled**: Ensure multiple users are in the room
- **Poor Recording Quality**: Check input levels and recording format
- **Storage Issues**: Verify sufficient disk space for recordings

#### Keyboard Shortcuts
- **Shortcuts Not Working**: Check for conflicting system shortcuts
- **Menu Navigation Issues**: Ensure application has focus
- **Escape Key Problems**: Wait for previous action to complete

### Getting Help
1. Check this guide for feature explanations
2. Review audio settings and permissions
3. Test with different users and rooms
4. Contact support with specific error details

---

## Conclusion

VoiceLink Local's enhanced room interaction system provides a comprehensive, keyboard-driven approach to voice chat management. From the peaceful startup river ambience to professional recording capabilities, every feature is designed to enhance your collaborative audio experience.

The preview system lets you "listen behind the door" before entering rooms, while the escape key menu system provides quick access to all room management features. Combined with the invitation system and recording capabilities, VoiceLink Local offers a professional-grade voice chat solution for any collaborative need.

**Key Benefits:**
- **Intuitive Navigation**: Keyboard shortcuts for power users
- **Professional Features**: Recording and invitation systems
- **User-Friendly Design**: Context menus and visual feedback
- **Future-Ready**: Architecture designed for upcoming spatial features

For additional support or feature requests, please refer to the main documentation or contact the development team.