# VoiceLink Local - Connection Instructions

## Connecting to a VoiceLink Server

### For Web Browser Clients (Recommended)

**Requirements:**
- Modern web browser (Chrome, Firefox, Safari, Edge)
- Same Wi-Fi network as the server
- JavaScript enabled

**Steps:**
1. **Get the server URL** from the host:
   - On Mac: VoiceLink app → Menubar icon → "Copy Server URL"
   - On Windows/Linux: VoiceLink app → Settings → "Copy Server URL"
   - Or ask the host for their IP address and port (usually 3000)

2. **Open your web browser** and navigate to:
   ```
   http://[SERVER-IP]:3000
   ```
   Example: `http://192.168.1.100:3000`

3. **Join or create a room:**
   - Browse available public rooms
   - Join by clicking "Join Room"
   - Or create a new room if permitted

4. **Enable microphone access** when prompted
   - Click "Allow" when browser asks for microphone permission
   - On iOS Safari: Tap to unmute audio if needed

### For VoiceLink Desktop Clients

**If you have VoiceLink installed on another computer:**

1. **Launch VoiceLink** on your device
2. **Connect to external server:**
   - Go to Settings → Server Settings
   - Set "Server Mode" to "Connect to External"
   - Enter the server URL: `http://[SERVER-IP]:3000`
   - Click "Connect"
3. **Join rooms** normally through the app interface

### For Mobile Devices (iOS/Android)

**Using Mobile Browser:**
1. **Open Safari (iOS) or Chrome (Android)**
2. **Navigate to the server URL:**
   ```
   http://[SERVER-IP]:3000
   ```
3. **Add to Home Screen** (optional):
   - iOS Safari: Share → "Add to Home Screen"
   - Android Chrome: Menu → "Add to Home Screen"
4. **Enable microphone** when prompted
5. **For iOS users:** Tap the screen to unmute audio if needed

### QR Code Connection

**If the host shares a QR code:**
1. **Open camera app** on your phone
2. **Scan the QR code** - it contains the server URL
3. **Tap the notification** to open in browser
4. **Follow the web browser steps** above

### Troubleshooting

**Can't connect to server:**
- Ensure you're on the same Wi-Fi network
- Check if the server is running (ask the host)
- Try refreshing the page
- Disable VPN if active

**No audio/microphone issues:**
- Check browser permissions (allow microphone)
- Try refreshing and re-allowing permissions
- On iOS: Tap screen to activate audio
- Check device volume and microphone settings

**Poor audio quality:**
- Move closer to Wi-Fi router
- Close other bandwidth-heavy applications
- Ask host to check server performance

### Network Requirements

- **Same Wi-Fi Network:** All participants must be connected to the same local network
- **Firewall:** Host may need to allow connections on the server port (default: 3000)
- **Bandwidth:** Recommended 1 Mbps per participant for optimal quality

### Supported Platforms

✅ **Fully Supported:**
- Chrome (Windows, Mac, Linux, Android)
- Firefox (Windows, Mac, Linux)
- Safari (Mac, iOS)
- Edge (Windows)

✅ **Mobile Web:**
- iOS Safari
- Android Chrome
- Most modern mobile browsers

✅ **Desktop Apps:**
- VoiceLink Local (Mac, Windows, Linux)

### Getting Help

If you need assistance:
1. **Check the help documentation** in the web interface
2. **Ask the server host** for connection details
3. **Try the web browser method first** - it's the most reliable
4. **Report issues** to the server administrator

---

**Note:** VoiceLink uses peer-to-peer technology for the best audio quality and lowest latency. All audio stays on your local network for privacy and performance.