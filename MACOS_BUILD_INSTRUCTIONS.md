# macOS Build Instructions - VoiceLink Native

## Current Status: Active Native Source / Rebuild Required For Public Artifacts

### 📋 Project State
- ✅ Source code updated with latest fixes
- ✅ Project structure cleaned and organized
- ✅ Current `swift-native/VoiceLinkNative/Sources` compiles locally with `swift build`
- ✅ Current-source app was reinstalled locally for regression validation on 2026-03-20
- ✅ Live local macOS test confirmed restored audio/sound behavior
- ⚠️ Public macOS artifacts still need a fresh universal release rebuild from current source before replacement

### 🍎 Build Objective
Create/update macOS native app ZIP artifacts used by updater and downloads:
- `VoiceLinkMacOS.zip` (primary)
- `VoiceLink-macOS.zip` (alias for compatibility)

---

## 🛠️ Build Instructions

### Prerequisites
- macOS 11.0 (Big Sur) or later
- Xcode 14.0 or later
- Valid Apple Developer account (for code signing)
- Command Line Tools installed

### Build Steps

#### 0. Use The Correct Source Of Truth
- Treat `swift-native/VoiceLinkNative/Sources` as the authoritative macOS source.
- Do not recover behavior from:
  - `swift-native/VoiceLinkNative/build-temp`
  - `swift-native/VoiceLinkNative/VoiceLink-release.app`
- `swift-native/VoiceLinkNative/VoiceLink.app` may be used as the local rebuilt bundle snapshot, but source changes must come from `Sources`.

#### 1. Open Project in Xcode
```bash
# Navigate to package
cd ~/dev/apps/voicelink-local/swift-native/VoiceLinkNative
```

#### 2. Configure Build Settings
- **Scheme:** VoiceLinkNative
- **Configuration:** Release
- **Architecture:** Any Mac (Apple Silicon, Intel)
- **Team:** Your Apple Developer team (if code signing)
- **Bundle Identifier:** com.devinecreations.voicelink

#### 3. Build and Archive
```
Product → Archive
```
- Wait for archive to complete (2-5 minutes)
- Select latest archive in Organizer

#### 4. Export Application
- Window → Organizer
- Select latest archive
- Click "Distribute App"
- Choose: "Copy App"
- Destination: Choose location
- Click "Export"

#### 5. Create ZIP Archive
```bash
# Navigate to exported app
cd /path/to/exported/app/

# Create distributable ZIP(s)
zip -r VoiceLinkMacOS.zip VoiceLink.app
cp VoiceLinkMacOS.zip VoiceLink-macOS.zip

# Expected size: ~144-150 MB
```

---

## 🧪 Build Output Requirements

### Required Output
- **Files:** VoiceLinkMacOS.zip, VoiceLink-macOS.zip
- **Size:** ~144-150 MB (contains VoiceLink.app)
- **Contents:** VoiceLink.app bundle with all dependencies

### Code Signing (Optional but Recommended)
- **Without:** Users may need to run `xattr -cr VoiceLink.app`
- **With:** Automatic installation, no Gatekeeper warnings
- **Requirements:** Apple Developer account, paid certificate

---

## 📤 Upload Destination

### Server Upload
```bash
# Upload to filedump (from macOS terminal)
scp -P 450 -i ~/.ssh/raywonder \
  VoiceLinkMacOS.zip VoiceLink-macOS.zip \
  devinecr@64.20.46.178:/home/devinecr/downloads/voicelink/
```

### Auto-Updater API Update
Update manifests:
- `swift-native/VoiceLinkNative/latest-mac.yml` (`VoiceLinkMacOS.zip`)
- `swift-native/VoiceLinkNative/latest-mac.server.yml` (`VoiceLink-macOS.zip`, copyPartyURL -> `.zip`)

---

## 🧪 Testing Checklist

### Post-Build Verification
- [ ] ZIP archive contains VoiceLink.app bundle
- [ ] App launches without errors on macOS
- [ ] `Audio` menu shows `Refresh Audio Devices` and `Restart Audio Services`
- [ ] Settings -> Audio shows `Refresh Device List` and `Restart Audio Services`
- [ ] Device list repopulates after refresh/restart when CoreAudio was empty
- [ ] "Account" menu appears in menu bar
- [ ] Admin-capable account can open `Server Administration`
- [ ] Admin user actions reach backend: kick / ban / role / transmit
- [ ] Startup welcome sound plays when enabled
- [ ] Input monitoring and room audio both function in the rebuilt app
- [ ] Input monitoring still works while actively joined to a room
- [ ] Input/output sliders apply the internal `+15%` gain boost correctly without changing the visible slider percentage

### Distribution Testing
- [ ] ZIP can be downloaded and extracted
- [ ] App runs on fresh macOS machine
- [ ] Auto-updater can check for macOS updates
- [ ] Migration from Electron works correctly

---

## 🔄 Known Issues & Solutions

### "Command CodeSign failed"
**Issue:** Xcode cannot sign the app
**Solution:** Disable code signing in Build Settings, or add Apple Developer account

### "The app is damaged and can't be opened"
**Issue:** macOS Gatekeeper blocks unsigned app
**Solution:** Run `xattr -cr VoiceLink.app` to remove quarantine attribute

### "Xcode won't archive"
**Issue:** Build cache corruption
**Solution:** Clean build folder (Cmd+Shift+K) and try again

### "Authorization code exchange fails"
**Issue:** Network or server connectivity
**Solution:** Check internet connection and verify Mastodon instance URL

### "No audio devices were detected"
**Issue:** macOS CoreAudio is temporarily exposing an empty device list after reboot or route changes
**Solution:** Use the app's built-in recovery path first:
- `Audio` menu -> `Refresh Audio Devices`
- `Audio` menu -> `Restart Audio Services`
- Settings -> Audio -> `Refresh Device List`
- Settings -> Audio -> `Restart Audio Services`

If the OS still reports no devices after that, resolve the macOS audio stack before replacing public artifacts.

---

## 📞 Support Information

### Server Details
- **Host:** 64.20.46.178
- **SSH Port:** 450
- **SSH Key:** ~/.ssh/raywonder
- **User:** devinecr
- **Web Client:** https://voicelink.devinecreations.net/

### Quick Commands
```bash
# Check PM2 status
ssh -i ~/.ssh/raywonder -p 450 devinecr@64.20.46.178 "pm2 status"

# Restart service
ssh -i ~/.ssh/raywonder -p 450 devinecr@64.20.46.178 "pm2 restart voicelink-local-api"

# View logs
ssh -i ~/.ssh/raywonder -p 450 devinecr@64.20.46.178 "pm2 logs voicelink-local-api --lines 20"

# Test download
curl -I https://devinecreations.net/uploads/filedump/voicelink/VoiceLink-1.0.0-macos.zip
```

---

## 📋 Next Steps After macOS Build

1. **Archive/export** the fresh universal macOS app from current source
2. **Update** ZIP/pkg artifacts and checksum files
3. **Upload** validated artifacts to the server
4. **Update** `latest-mac.yml` and `latest-mac.server.yml`
5. **Verify** download/install and audio recovery controls on a clean machine
6. **Only then** replace public release files

---

## 🔄 Cross-Device Coordination

### Windows Build Status
- **Check:** WINDOWS_BUILD_INSTRUCTIONS.md
- **Status:** Pending Windows native build
- **Action:** Coordinate timing to avoid conflicts

### Shared Resources
- **Server:** Both devices upload to same location
- **Sync:** Use OPENCODE_STATUS.md for coordination
- **Files:** Both devices have identical project structure

---

## 📝 Notes

1. **Native Migration:** This is first native macOS release (v1.0.0)
2. **Electron Deprecation:** Auto-updater will force migration from Electron
3. **Future Policy:** All future releases will be native builds
4. **Documentation:** Generate user manual and API docs post-build

---

**Build Date:** 2026-01-23
**Target:** VoiceLink Native v1.0.0 macOS
**Priority:** HIGH - Complete native app migration
