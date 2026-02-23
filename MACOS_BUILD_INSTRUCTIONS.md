# macOS Build Instructions - VoiceLink Native

## Current Status: Ready for Native Build

### 📋 Project State
- ✅ Source code updated with latest fixes
- ✅ Project structure cleaned and organized
- ✅ Build artifacts removed (.build/, DerivedData/)
- ✅ Archives created for old versions
- ✅ Server updated with media playback fixes
- ✅ Cross-device coordination established

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

#### 1. Open Project in Xcode
```bash
# Navigate to project
cd /mnt/c/Users/40493/dev/apps/voicelink-local/swift-native/

# Open in Xcode
open VoiceLinkNative.xcodeproj
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
- [ ] "Account" menu appears in menu bar
- [ ] Can click "Login with Mastodon"
- [ ] Enter Mastodon instance (e.g., mastodon.social)
- [ ] Browser opens with OAuth authorization page
- [ ] After approving, app shows logged-in state
- [ ] User name and handle displayed in main menu
- [ ] Can create room as authenticated user
- [ ] Can logout successfully
- [ ] Credentials persist across app restarts

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

1. **Upload** ZIP archive to server filedump
2. **Update** auto-updater API with new version
3. **Restart** PM2 service to apply changes
4. **Test** download and installation
5. **Update** OPENCODE_STATUS.md with completion
6. **Coordinate** with Windows device for final sync

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
