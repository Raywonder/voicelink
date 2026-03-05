# VoiceLink

VoiceLink is a native voice chat app for macOS and Windows, with a web client for quick access.

## Quick Start

1. Download VoiceLink for your platform.
2. Install and open the app.
3. Add your server URL (or use an invite link).
4. Sign in.
5. Join or create a room.

## Downloads

- macOS (Universal): https://voicelink.devinecreations.net/downloads/voicelink/VoiceLinkMacOS.zip
- macOS checksum: https://voicelink.devinecreations.net/downloads/voicelink/VoiceLinkMacOS.zip.sha256
- Windows app EXE (x64): https://voicelink.devinecreations.net/downloads/voicelink/VoiceLink-1.0.0-windows-portable.exe
- Windows app checksum: https://voicelink.devinecreations.net/downloads/voicelink/VoiceLink-1.0.0-windows-portable.exe.sha256
- Windows setup EXE (rebuilding): https://voicelink.devinecreations.net/downloads/voicelink/VoiceLink-1.0.0-windows-setup.exe
- Linux AppImage: https://voicelink.devinecreations.net/downloads/voicelink/VoiceLink-linux.AppImage
- Linux AppImage checksum: https://voicelink.devinecreations.net/downloads/voicelink/VoiceLink-linux.AppImage.sha256
- Linux .deb: https://voicelink.devinecreations.net/downloads/voicelink/voicelink-local_1.0.0_amd64.deb
- Linux .deb checksum: https://voicelink.devinecreations.net/downloads/voicelink/voicelink-local_1.0.0_amd64.deb.sha256
- Web client: https://voicelink.devinecreations.net/

Mirror:
- https://node2.voicelink.devinecreations.net/downloads/voicelink/VoiceLinkMacOS.zip
- https://node2.voicelink.devinecreations.net/downloads/voicelink/VoiceLink-1.0.0-windows-portable.exe

## Install

### macOS

1. Download `VoiceLinkMacOS.zip`.
2. Extract it.
3. Move `VoiceLink.app` to `/Applications`.
4. Open VoiceLink.

If macOS blocks the app, run:

```bash
xattr -cr /Applications/VoiceLink.app
```

### Windows

1. Download `VoiceLink-1.0.0-windows-portable.exe`.
2. Run the EXE and allow Windows SmartScreen if prompted.
3. Pin it to Start Menu or Taskbar if desired.

### Linux

1. Download `VoiceLink-linux.AppImage` or `voicelink-local_1.0.0_amd64.deb`.
2. AppImage:

```bash
chmod +x VoiceLink-linux.AppImage
./VoiceLink-linux.AppImage
```

3. Debian/Ubuntu:

```bash
sudo dpkg -i voicelink-local_1.0.0_amd64.deb
sudo apt-get -f install -y
```

## Get an Account / Sign In

Available login methods depend on how your server is configured.

### 1) Mastodon Login

- Choose Mastodon login in the app.
- Enter your instance domain (example: `mastodon.social`).
- Approve login in your browser.

### 2) Email Login (when enabled by server admin)

- Use email verification flow in the desktop app.
- Enter your email.
- Confirm with the code sent to your inbox.

### 3) SSO Login (when enabled)

- Some servers use SSO gateways (example: Authelia).
- Use the SSO sign-in button shown by that server.

### 4) Admin Invite / Magic Invite Link

- Open the invite link from the server owner.
- Complete account activation (email, username, password).
- Sign in with the new credentials.

## Connect to a Server

- Use a full URL (example: `https://voicelink.devinecreations.net`).
- Or use an invite/deep link (`vcl://...`).
- Desktop also supports legacy `voicelink://...` links.

## First Room Checklist

1. Sign in.
2. Join a public room or create your own.
3. Allow microphone access.
4. Test audio from settings.

## Need Help?

- Main downloads page: https://voicelink.devinecreations.net/downloads.html
- Server/community mirror: https://node2.voicelink.devinecreations.net/downloads.html

## Host Your Own Server (Linux)

- Guide: `docs/installation/HOST-LINUX-SERVER.md`
- Native installer: `installer/install.sh`
- Docker compose: `installer/docker-compose.server.yml`
- Public registration helper: `scripts/linux/register-public-server.sh`

## For Developers

- Main docs: `docs/`
- Setup guide: `SETUP.md`
- macOS packaging details: `MACOS_BUILD_INSTRUCTIONS.md`
- Windows packaging details: `WINDOWS_BUILD_INSTRUCTIONS.md`
