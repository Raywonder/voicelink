# 🏗️ VoiceLink Platform-Specific Build Tasks

**Status:** Code complete, awaiting platform-specific compilation
**Last Updated:** January 23, 2026
**Session:** All authentication UI and bug fixes completed

---

## ✅ Completed This Session (WSL/Linux)

All code development is complete. The following tasks were finished:

- [x] Web client guest restrictions implemented
- [x] Fixed rooms not displaying (federation manager bug)
- [x] Fixed room joining (circular dependency issue)
- [x] macOS Swift app - Login UI created (`LoginView.swift`)
- [x] macOS Swift app - OAuth integration complete
- [x] Windows WPF app - Authentication fixed (`AuthenticationManager.cs`)
- [x] Windows WPF app - Login UI created (`LoginView.xaml`)
- [x] Jellyfin media streaming configured
- [x] Downloads system updated
- [x] All server files uploaded and PM2 restarted
- [x] Comprehensive documentation created (TXT, HTML, MD)

---

## ⚠️ Platform-Specific Tasks Remaining

### 🍎 MACOS BUILD TASKS (Requires macOS + Xcode)

**Location:** `/mnt/c/Users/40493/dev/apps/voicelink-local/swift-native/VoiceLinkNative/`

**Prerequisites:**
- macOS 11.0 (Big Sur) or later
- Xcode 13.0 or later
- Apple Developer account (for code signing)

**Build Steps:**

1. **Open Project in Xcode**
   ```bash
   # On macOS, navigate to:
   /mnt/c/Users/40493/dev/apps/voicelink-local/swift-native/
   # Or equivalent path on macOS filesystem

   # Open in Xcode:
   open VoiceLinkNative.xcodeproj
   ```

2. **Configure Build Settings**
   - Select scheme: `VoiceLinkNative`
   - Configuration: `Release`
   - Architecture: `Any Mac (Apple Silicon, Intel)`

3. **Build and Archive**
   ```
   Product → Archive
   ```

   Wait for archive to complete (~2-5 minutes)

4. **Export Application**
   - Window → Organizer
   - Select latest archive
   - Click "Distribute App"
   - Choose: "Copy App"
   - Destination: Choose location
   - Options: Leave defaults
   - Click "Export"

5. **Create ZIP Archive**
   ```bash
   cd /path/to/exported/app
   zip -r VoiceLink-1.0.1-macos.zip VoiceLink.app
   ```

6. **Verify Build**
   ```bash
   # Test the app
   open VoiceLink.app

   # Try Mastodon login
   # 1. Click "Login with Mastodon" in menu
   # 2. Enter instance (e.g., mastodon.social)
   # 3. Verify browser opens with OAuth
   # 4. Approve and check app shows logged-in state
   ```

7. **Upload to Server**
   ```bash
   # From macOS terminal (update path as needed):
   scp -P 450 -i ~/.ssh/raywonder \
     VoiceLink-1.0.1-macos.zip \
     devinecr@64.20.46.178:/home/devinecr/devinecreations.net/uploads/filedump/voicelink/
   ```

8. **Update Auto-Updater API**
   - File: `/mnt/c/Users/40493/dev/apps/voicelink-local/server/routes/local-server.js`
   - Lines: 742-761
   - Change:
     ```javascript
     macos: {
         version: '1.0.1',        // Updated from 1.0.0
         buildNumber: 2,          // Updated from 1
         downloadURL: 'https://devinecreations.net/uploads/filedump/voicelink/VoiceLink-1.0.1-macos.zip',
         releaseNotes: 'v1.0.1: Added Mastodon login UI with full OAuth support, bug fixes for room display and joining'
     }
     ```
   - Upload and restart PM2 (see Server Update section below)

**Expected Output:**
- `VoiceLink-1.0.1-macos.zip` (~144-150 MB)
- Contains `VoiceLink.app` bundle
- Code-signed (if Apple Developer account used)

**Known Issues:**
- May require disabling Gatekeeper if not code-signed:
  ```bash
  xattr -cr VoiceLink.app
  ```

---

### 🪟 WINDOWS BUILD TASKS (Requires Windows or .NET 8 SDK)

**Location:** `/mnt/c/Users/40493/dev/apps/voicelink-local/windows-native/VoiceLinkNative/`

**Prerequisites:**
- Windows 10/11 OR .NET 8 SDK on Linux
- Visual Studio 2022 (optional, for GUI)
- PowerShell or dotnet CLI

#### Option A: Build on Windows (Recommended)

1. **Open PowerShell as Administrator**
   ```powershell
   cd C:\Users\40493\dev\apps\voicelink-local\windows-native\
   ```

2. **Build with Script**
   ```powershell
   # Basic build
   .\build.ps1

   # Or build and publish self-contained exe
   .\build.ps1 -Publish
   ```

3. **Verify Build**
   ```powershell
   # Test the executable
   .\publish\win-x64\VoiceLinkNative.exe

   # Try Mastodon login
   # 1. Click "Login" in Account section
   # 2. Enter instance
   # 3. Click "Get Authorization Code" (opens browser)
   # 4. Copy code from browser
   # 5. Paste into app and click "Complete Login"
   # 6. Verify logged-in state
   ```

4. **Create Installer (Optional)**

   Using Inno Setup:
   ```powershell
   # Install Inno Setup from https://jrsoftware.org/isinfo.php

   # Create installer script: VoiceLink.iss
   # Compile with:
   iscc VoiceLink.iss
   ```

   Or just rename portable:
   ```powershell
   Copy-Item publish\win-x64\VoiceLinkNative.exe VoiceLink-1.0.4-windows-portable.exe
   ```

5. **Upload to Server**
   ```powershell
   # Using SCP from Windows (install OpenSSH client):
   scp -P 450 -i C:\Users\40493\.ssh\raywonder `
     VoiceLink-1.0.4-windows-portable.exe `
     devinecr@64.20.46.178:/home/devinecr/devinecreations.net/uploads/filedump/voicelink/
   ```

#### Option B: Build on Linux/WSL (If .NET 8 SDK installed)

1. **Install .NET 8 SDK** (if not installed)
   ```bash
   # Ubuntu/Debian
   wget https://dot.net/v1/dotnet-install.sh
   chmod +x dotnet-install.sh
   ./dotnet-install.sh --channel 8.0

   # Add to PATH
   export PATH="$HOME/.dotnet:$PATH"
   ```

2. **Build from WSL**
   ```bash
   cd /mnt/c/Users/40493/dev/apps/voicelink-local/windows-native/

   # Restore packages
   dotnet restore VoiceLinkNative/VoiceLinkNative.csproj

   # Build
   dotnet build VoiceLinkNative/VoiceLinkNative.csproj -c Release

   # Publish self-contained Windows executable
   dotnet publish VoiceLinkNative/VoiceLinkNative.csproj \
     -c Release \
     -r win-x64 \
     --self-contained true \
     -o publish/win-x64 \
     /p:PublishSingleFile=true
   ```

3. **Upload to Server**
   ```bash
   scp -P 450 -i ~/.ssh_keys/raywonder \
     publish/win-x64/VoiceLinkNative.exe \
     devinecr@64.20.46.178:/home/devinecr/devinecreations.net/uploads/filedump/voicelink/VoiceLink-1.0.4-windows-portable.exe
   ```

4. **Update Auto-Updater API**
   - File: `/mnt/c/Users/40493/dev/apps/voicelink-local/server/routes/local-server.js`
   - Lines: 742-761
   - Change:
     ```javascript
     windows: {
         version: '1.0.4',
         buildNumber: 4,
         downloadURL: 'https://devinecreations.net/uploads/filedump/voicelink/VoiceLink-1.0.4-windows-portable.exe',
         releaseNotes: 'v1.0.4: Added Mastodon authentication with proper OAuth flow, improved UI and security'
     }
     ```
   - Upload and restart PM2 (see Server Update section below)

**Expected Output:**
- `VoiceLinkNative.exe` (~80-100 MB self-contained)
- Includes .NET 8 runtime (no separate installation needed)

**Known Issues:**
- Windows Defender may flag unsigned executable
- Tell users to "Run anyway" or sign with certificate

---

## 📤 Server Update Procedure

After building and uploading new installers, update the server:

### 1. Upload Updated Server Files (if auto-updater API changed)

```bash
# From WSL
cd /mnt/c/Users/40493/dev/apps/voicelink-local/

# Upload updated local-server.js
rsync -avz -e "ssh -i ~/.ssh_keys/raywonder -p 450 -o StrictHostKeyChecking=no" \
  server/routes/local-server.js \
  devinecr@64.20.46.178:/home/devinecr/apps/voicelink-local/source/routes/
```

### 2. Restart PM2

```bash
ssh -i ~/.ssh_keys/raywonder -p 450 devinecr@64.20.46.178 \
  "pm2 restart voicelink-local-api"
```

### 3. Verify Auto-Updater

```bash
# Test macOS update check
curl -X POST https://voicelink.devinecreations.net/api/updates/check \
  -H "Content-Type: application/json" \
  -d '{"platform":"macos","currentVersion":"1.0.0","buildNumber":1}' \
  -s | jq

# Should return:
# {
#   "updateAvailable": true,
#   "version": "1.0.1",
#   "downloadURL": "https://devinecreations.net/uploads/filedump/voicelink/VoiceLink-1.0.1-macos.zip",
#   ...
# }

# Test Windows update check
curl -X POST https://voicelink.devinecreations.net/api/updates/check \
  -H "Content-Type: application/json" \
  -d '{"platform":"windows","currentVersion":"1.0.3","buildNumber":3}' \
  -s | jq

# Should return:
# {
#   "updateAvailable": true,
#   "version": "1.0.4",
#   ...
# }
```

### 4. Update Downloads Page (Optional)

Update `/client/index.html` to reference new versions:

```html
<a href="https://devinecreations.net/uploads/filedump/voicelink/VoiceLink-1.0.1-macos.zip" download>
    <span class="platform-icon">🍎</span> macOS v1.0.1
</a>
<a href="https://devinecreations.net/uploads/filedump/voicelink/VoiceLink-1.0.4-windows-portable.exe" download>
    <span class="platform-icon">🪟</span> Windows v1.0.4
</a>
```

Then upload:
```bash
rsync -avz -e "ssh -i ~/.ssh_keys/raywonder -p 450 -o StrictHostKeyChecking=no" \
  client/index.html \
  devinecr@64.20.46.178:/home/devinecr/public_html/voicelink-local/
```

---

## 🧪 Testing Checklist

### macOS App Testing
- [ ] App launches without errors
- [ ] "Account" menu appears in menu bar
- [ ] Can click "Login with Mastodon"
- [ ] Enter Mastodon instance (e.g., mastodon.social)
- [ ] Browser opens with OAuth authorization page
- [ ] After approving, app shows logged-in state
- [ ] User name and handle displayed in main menu
- [ ] Can create room as authenticated user
- [ ] Can logout successfully
- [ ] Credentials persist across app restarts

### Windows App Testing
- [ ] App launches without errors
- [ ] Account section visible in sidebar
- [ ] Can click "Login" button
- [ ] Enter Mastodon instance
- [ ] Click "Get Authorization Code" - browser opens
- [ ] Copy code from browser
- [ ] Paste code and click "Complete Login"
- [ ] App shows logged-in state with user name
- [ ] Can create room as authenticated user
- [ ] Can logout successfully
- [ ] Credentials persist across app restarts

### Auto-Updater Testing
- [ ] API returns correct version for macOS
- [ ] API returns correct version for Windows
- [ ] Download URLs work (curl -I returns 200 OK)
- [ ] Files actually download (test with wget/browser)

---

## 📋 File Checklist

### Files Ready for Upload to Server

All source code is complete and ready. Only compiled binaries need to be created:

**Source Code (Already on Server):**
- ✅ Web client files (index.html, app.js, etc.)
- ✅ Server files (local-server.js, federation-manager.js)
- ✅ Configuration (deploy.json with Jellyfin enabled)

**Native App Source (Complete, ready to build):**
- ✅ macOS Swift source: `/swift-native/VoiceLinkNative/Sources/`
- ✅ Windows WPF source: `/windows-native/VoiceLinkNative/`

**Documentation (Already created):**
- ✅ VOICELINK_SESSION_REPORT.txt (full report)
- ✅ VOICELINK_SESSION_REPORT.htm (HTML version)
- ✅ QUICKSTART_GUIDE.md (developer guide)
- ✅ PLATFORM_BUILD_TASKS.md (this file)

**Awaiting Creation:**
- ⚠️ VoiceLink-1.0.1-macos.zip (needs macOS build)
- ⚠️ VoiceLink-1.0.4-windows-portable.exe (needs Windows/.NET build)

---

## 🔧 Troubleshooting

### macOS Build Issues

**"Command CodeSign failed"**
- Solution: Disable code signing in Build Settings, or add Apple Developer account

**"The app is damaged and can't be opened"**
- Solution: Run `xattr -cr VoiceLink.app` to remove quarantine attribute

**"Xcode won't archive"**
- Solution: Clean build folder (Cmd+Shift+K) and try again

### Windows Build Issues

**".NET SDK not found"**
- Solution: Install from https://dotnet.microsoft.com/download/dotnet/8.0

**"XAML parse error"**
- Solution: Check LoginView.xaml for XML syntax errors
- Verify all namespaces are properly declared

**"Authorization code exchange fails"**
- Solution: Check internet connection
- Verify Mastodon instance URL is correct (no https://)

**"Executable won't run on other machines"**
- Solution: Use `--self-contained true` and `/p:PublishSingleFile=true`

---

## 📞 Support Information

### Server Access
```
Host: 64.20.46.178
SSH Port: 450
SSH Key: ~/.ssh_keys/raywonder
User: devinecr
Password: DomDomRW93!15218
```

### Quick Commands
```bash
# Check PM2 status
ssh -i ~/.ssh_keys/raywonder -p 450 devinecr@64.20.46.178 "pm2 status"

# View logs
ssh -i ~/.ssh_keys/raywonder -p 450 devinecr@64.20.46.178 "pm2 logs voicelink-local-api --lines 30"

# Test downloads
curl -I https://devinecreations.net/uploads/filedump/voicelink/VoiceLink-1.0.0-macos.zip
```

### API Endpoints
- Web Client: https://voicelink.devinecreations.net/
- Rooms API: https://voicelink.devinecreations.net/api/rooms
- Updates API: https://voicelink.devinecreations.net/api/updates/check
- Downloads API: https://voicelink.devinecreations.net/api/downloads

---

## ✅ Completion Checklist

When both builds are complete, mark these items:

- [ ] macOS app built and tested
- [ ] macOS zip uploaded to server filedump
- [ ] Windows app built and tested
- [ ] Windows exe uploaded to server filedump
- [ ] Auto-updater API updated with new versions
- [ ] PM2 restarted on server
- [ ] Both update checks return new versions
- [ ] Downloads page updated (optional)
- [ ] Both installers tested on fresh machines

**When all items are checked, VoiceLink v1.0.x is COMPLETE! 🎉**

---

**Generated:** January 23, 2026
**Session:** Complete code development session
**Status:** Code complete, awaiting platform-specific compilation
**Next:** Build on macOS (Xcode) and Windows (.NET 8)
