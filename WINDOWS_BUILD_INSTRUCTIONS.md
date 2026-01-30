# Windows Build Instructions - VoiceLink v1.0 Native

## Current Status: Ready for Native Build

### 📋 Project State
- ✅ Source code updated with latest fixes
- ✅ Project structure cleaned and organized
- ✅ Build artifacts removed
- ✅ Archives created for old versions
- ✅ Server updated with media playback fixes

### 🎯 Build Objective
Create Windows native executable: **v1.0-windows.exe** (or portable)

---

## 🛠️ Build Instructions

### Prerequisites
- Windows 10/11 OR .NET 8 SDK installed
- PowerShell or Command Prompt
- OpenSSH client (for upload)

### Build Steps

#### Option 1: Windows PowerShell (Recommended)
```powershell
# Navigate to project directory
cd C:\Users\40493\dev\apps\voicelink-local\windows-native\

# Build with provided script
.\build.ps1

# OR build and publish
.\build.ps1 -Publish

# Output: publish\win-x64\VoiceLinkNative.exe (~80-100 MB)
```

#### Option 2: Cross-platform with .NET SDK
```bash
# Navigate to project directory
cd /mnt/c/Users/40493/dev/apps/voicelink-local/windows-native/

# Restore dependencies
dotnet restore VoiceLinkNative/VoiceLinkNative.csproj

# Build self-contained executable
dotnet publish VoiceLinkNative/VoiceLinkNative.csproj \
  -c Release \
  -r win-x64 \
  --self-contained true \
  -o publish/win-x64 \
  /p:PublishSingleFile=true

# Output: publish/win-x64/VoiceLinkNative.exe
```

---

## 📦 Build Output Requirements

### Required Output
- **File:** VoiceLink-1.0.0-windows.exe OR VoiceLink-1.0-windows-portable.exe
- **Size:** ~80-100 MB (self-contained)
- **Includes:** .NET 8 runtime (no separate installation needed)

### Upload Destination
```bash
# Upload to server (replace with actual path on Windows)
scp -P 450 -i C:\Users\40493\.ssh\raywonder \
  VoiceLink-1.0.0-windows.exe \
  devinecr@64.20.46.178:/home/devinecr/devinecreations.net/uploads/filedump/voicelink/
```

---

## 🧪 Testing Checklist

### Post-Build Verification
- [ ] Executable launches without errors
- [ ] Mastodon login screen appears
- [ ] Can enter instance and click "Get Authorization Code"
- [ ] Browser opens with OAuth page
- [ ] Can paste authorization code and complete login
- [ ] App shows logged-in state with user info
- [ ] Can create room as authenticated user
- [ ] Can logout successfully
- [ ] Credentials persist across app restarts

### Installation Testing
- [ ] Can be installed on fresh Windows machine
- [ ] Windows Defender allows execution (or can be bypassed)
- [ ] Auto-updater can check for updates
- [ ] Migration from Electron works correctly

---

## 🔧 Post-Build Tasks

### 1. Update Auto-Updater API
Edit `/home/devinecr/apps/voicelink-local/source/routes/local-server.js`:
```javascript
windows: {
    version: '1.0.0',
    buildNumber: 5,  // Increment from current 3
    downloadURL: 'https://devinecreations.net/uploads/filedump/voicelink/VoiceLink-1.0.0-windows.exe',
    releaseNotes: 'v1.0.0: First native Windows release, improved audio playback, enhanced error handling'
}
```

### 2. Restart PM2 Service
```bash
ssh -i ~/.ssh/raywonder -p 450 devinecr@64.20.46.178 "pm2 restart voicelink-local-api"
```

### 3. Update Coordination Status
Update OPENCODE_STATUS.md:
- Mark Windows build as completed
- Note build date and version
- Update cross-device sync status

---

## 🔄 Known Issues & Solutions

### Windows Defender Warning
**Issue:** Windows Defender flags unsigned executable  
**Solution:** Users click "Run anyway" or obtain code signing certificate

### .NET Runtime Missing
**Issue:** .NET 8 not installed on target machine  
**Solution:** Use `--self-contained true` (included in build commands)

### OAuth Browser Issues
**Issue:** Browser doesn't open for OAuth  
**Solution:** Check internet connection and firewall settings

---

## 📞 Support Information

### Server Details
- **Host:** 64.20.46.178
- **SSH Port:** 450
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
```

---

## 📋 Next Steps After Windows Build

1. **Upload** the built executable to server
2. **Test** download and installation on fresh machine
3. **Update** auto-updater API
4. **Coordinate** with macOS device for Mac build
5. **Verify** cross-device sync status

---

**Build Date:** 2026-01-23  
**Target:** VoiceLink Native v1.0.0 Windows  
**Priority:** HIGH - Complete before Mac build coordination