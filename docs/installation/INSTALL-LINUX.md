# VoiceLink Local - Linux Installation Guide

## System Requirements

- **Linux Distribution**: Ubuntu 18.04+, Debian 10+, Fedora 30+, or equivalent
- **Architecture**: x86_64 (64-bit)
- **Kernel**: 4.15 or later
- **RAM**: 8GB minimum (16GB recommended)
- **Disk Space**: 500MB available
- **Audio**: ALSA, PulseAudio, or JACK support

## Download Options

### AppImage (Universal - Recommended)
- **AppImage**: [VoiceLink Local-1.0.0.AppImage](../releases/VoiceLink%20Local-1.0.0.AppImage) (351MB)
- Works on any Linux distribution with glibc 2.27+

### Debian/Ubuntu Package
- **DEB Package**: [voicelink-local_1.0.0_amd64.deb](../releases/voicelink-local_1.0.0_amd64.deb) (294MB)
- For Debian, Ubuntu, and derivatives

### Generic Linux Archive
- **TAR.GZ**: [voicelink-local-1.0.0.tar.gz](../releases/voicelink-local-1.0.0.tar.gz) (348MB)
- For manual installation on any Linux distribution

## Installation Methods

### Method 1: AppImage (Recommended)

The AppImage format works on most Linux distributions without installation:

1. **Download** the AppImage file
2. **Make executable**:
   ```bash
   chmod +x VoiceLink\ Local-1.0.0.AppImage
   ```
3. **Run** the application:
   ```bash
   ./VoiceLink\ Local-1.0.0.AppImage
   ```

#### Optional: Desktop Integration
```bash
# Move to applications directory
sudo mv VoiceLink\ Local-1.0.0.AppImage /opt/voicelink-local.appimage

# Create desktop entry
cat > ~/.local/share/applications/voicelink-local.desktop << EOF
[Desktop Entry]
Type=Application
Name=VoiceLink Local
Comment=P2P Voice Chat with 3D Audio
Exec=/opt/voicelink-local.appimage
Icon=voicelink-local
Categories=AudioVideo;Audio;Network;
StartupNotify=true
EOF
```

### Method 2: Debian/Ubuntu Package

For Debian-based distributions:

1. **Download** the DEB package
2. **Install** using dpkg:
   ```bash
   sudo dpkg -i voicelink-local_1.0.0_amd64.deb
   ```
3. **Fix dependencies** if needed:
   ```bash
   sudo apt-get install -f
   ```
4. **Launch** from applications menu or command line:
   ```bash
   voicelink-local
   ```

### Method 3: Generic Linux Archive

For other distributions or manual installation:

1. **Extract** the archive:
   ```bash
   tar -xzf voicelink-local-1.0.0.tar.gz
   ```
2. **Move** to desired location:
   ```bash
   sudo mv voicelink-local /opt/
   ```
3. **Create** symbolic link:
   ```bash
   sudo ln -s /opt/voicelink-local/voicelink-local /usr/local/bin/
   ```
4. **Run** the application:
   ```bash
   voicelink-local
   ```

## Audio System Configuration

### PulseAudio (Default for most distributions)

VoiceLink Local works with PulseAudio out of the box:

```bash
# Check PulseAudio is running
pulseaudio --check

# List audio devices
pactl list short sources
pactl list short sinks

# Set default devices if needed
pactl set-default-source alsa_input.pci-0000_00_1f.3.analog-stereo
pactl set-default-sink alsa_output.pci-0000_00_1f.3.analog-stereo
```

### JACK Audio (Professional Setup)

For low-latency professional audio:

1. **Install JACK**:
   ```bash
   # Ubuntu/Debian
   sudo apt install jackd2 qjackctl

   # Fedora
   sudo dnf install jack-audio-connection-kit qjackctl

   # Arch Linux
   sudo pacman -S jack2 qjackctl
   ```

2. **Configure JACK**:
   ```bash
   # Start JACK with low latency
   jackd -d alsa -r 48000 -p 128 -n 2
   ```

3. **Launch** VoiceLink Local after JACK is running

### ALSA (Low-level configuration)

For direct ALSA access:

```bash
# List audio devices
aplay -l
arecord -l

# Test audio output
speaker-test -c2

# Test microphone
arecord -f cd -d 5 test.wav && aplay test.wav
```

## Permissions and Security

### Audio Device Access

Add user to audio group:
```bash
sudo usermod -a -G audio $USER
```

### Microphone Permissions

For distributions with strict security policies:
```bash
# Check microphone access
pactl list short sources

# Test microphone
arecord -f S16_LE -r 44100 -c 2 -d 5 test.wav
```

### Firewall Configuration

Allow VoiceLink Local through firewall:
```bash
# UFW (Ubuntu)
sudo ufw allow 'VoiceLink Local'

# FirewallD (Fedora/CentOS)
sudo firewall-cmd --permanent --add-port=3000-65535/tcp
sudo firewall-cmd --permanent --add-port=3000-65535/udp
sudo firewall-cmd --reload

# iptables (manual)
sudo iptables -A INPUT -p tcp --dport 3000:65535 -j ACCEPT
sudo iptables -A INPUT -p udp --dport 3000:65535 -j ACCEPT
```

## Desktop Environment Integration

### GNOME

VoiceLink Local integrates with GNOME's audio controls and notifications.

### KDE Plasma

Works with KDE's audio system and can be added to the system tray.

### Xfce/LXDE

Basic audio integration. Use PulseAudio mixer for audio control.

## Troubleshooting

### Application Won't Start

1. **Check dependencies**:
   ```bash
   ldd VoiceLink\ Local-1.0.0.AppImage
   ```

2. **Verify glibc version**:
   ```bash
   ldd --version
   ```

3. **Run with debug output**:
   ```bash
   ./VoiceLink\ Local-1.0.0.AppImage --verbose
   ```

### Audio Issues

1. **Check audio system**:
   ```bash
   # PulseAudio
   pulseaudio --check
   pactl info

   # ALSA
   cat /proc/asound/cards

   # JACK
   jack_control status
   ```

2. **Test microphone**:
   ```bash
   arecord -f cd -d 5 /tmp/test.wav && aplay /tmp/test.wav
   ```

3. **Check permissions**:
   ```bash
   groups $USER  # Should include 'audio'
   ```

### Network Issues

1. **Check firewall**:
   ```bash
   sudo netstat -tulpn | grep voicelink
   ```

2. **Test connectivity**:
   ```bash
   ping google.com
   telnet chat-server.example.com 443
   ```

### Performance Issues

1. **Check system resources**:
   ```bash
   top
   free -h
   df -h
   ```

2. **Audio latency optimization**:
   ```bash
   # Reduce audio latency
   echo 'options snd-hda-intel position_fix=1' | sudo tee -a /etc/modprobe.d/alsa-base.conf
   ```

## Distribution-Specific Notes

### Ubuntu/Debian
- Use the DEB package for best integration
- PulseAudio is default audio system
- May need to install additional codecs

### Fedora/CentOS/RHEL
- Use AppImage or compile from source
- SELinux may need configuration
- Firewall is enabled by default

### Arch Linux
- Use AppImage or AUR package
- JACK support readily available
- Minimal by default, may need audio packages

### openSUSE
- Use AppImage
- YaST can configure audio systems
- Firewall configuration through YaST

## Uninstallation

### AppImage
Simply delete the AppImage file and any desktop entries.

### DEB Package
```bash
sudo apt remove voicelink-local
```

### Manual Installation
```bash
sudo rm -rf /opt/voicelink-local
sudo rm /usr/local/bin/voicelink-local
rm ~/.local/share/applications/voicelink-local.desktop
```

## Advanced Configuration

### Custom Audio Backend
```bash
# Force specific audio backend
export VOICELINK_AUDIO_BACKEND=pulse
./VoiceLink\ Local-1.0.0.AppImage

# Available backends: pulse, alsa, jack
```

### Environment Variables
```bash
# Custom configuration directory
export VOICELINK_CONFIG_DIR=~/.config/voicelink-local

# Debug mode
export VOICELINK_DEBUG=1

# Custom audio device
export VOICELINK_AUDIO_DEVICE="hw:0,0"
```

## Support

For Linux-specific issues:
- Check system logs: `journalctl -u voicelink-local`
- Verify audio system configuration
- Test with different audio backends
- Consult distribution-specific forums
- Review the main troubleshooting guide in README.md