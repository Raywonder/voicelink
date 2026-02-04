# WSL + Windows + Mac Development Setup Guide

This guide will help you set up a seamless development workflow between your Mac (primary), WSL (development), and Windows (build) machines.

## Prerequisites

### On Mac (Primary Machine)
- Git installed
- SSH access configured
- Terminal/SSH client access to other machines

### On Windows (Build Machine)  
- Windows 10/11 with PowerShell
- OpenSSH client installed (comes with Windows)
- Git installed
- Node.js installed
- Internet access

### On WSL (Development Environment)
- Ubuntu/WSL2 with sudo access
- Node.js and npm installed
- Git installed
- SSH daemon running

---

## Step 1: Configure SSH Key Authentication

### On Mac (Generate SSH keys if you don't have them):

```bash
# Generate SSH key pair
ssh-keygen -t rsa -b 4096 -C "your-email@example.com"

# Copy public key to clipboard for easy transfer
pbcopy < ~/.ssh/id_rsa.pub

# Display public key
cat ~/.ssh/id_rsa.pub
```

### Add SSH key to GitHub:
1. Copy the public key output above
2. Go to GitHub → Settings → SSH and GPG keys
3. Click "New SSH key" and paste the public key
4. Give it a descriptive name like "Mac MacBook Pro"

---

## Step 2: Configure WSL SSH Access

### Enable SSH daemon in WSL:

```bash
# Start SSH service
sudo service ssh start

# Enable SSH to start on boot
sudo systemctl enable ssh

# Check SSH status
sudo service ssh status
```

### Configure WSL SSH config:

```bash
# Create SSH config
nano ~/.ssh/config

# Add these entries:
Host mac-dev
    HostName 192.168.1.XXX  # Replace with your Mac's IP
    User your-mac-username
    IdentityFile ~/.ssh/id_rsa

Host windows-build 
    HostName 192.168.1.YYY  # Replace with your Windows IP
    User your-windows-username
    IdentityFile ~/.ssh/id_rsa
```

### Find your Mac's IP:
```bash
# On Mac: Go to System Preferences → Network → Wi-Fi
# Or use command line:
ifconfig | grep "inet " | grep -v 127.0.0.1
```

---

## Step 3: Configure Windows SSH Access

### Enable OpenSSH on Windows:

```powershell
# Run as Administrator
# Install OpenSSH if not available
dism.exe /Online /Get-Capabilities /Format:List | findstr /i "OpenSSH.Server~~~~"

# Install OpenSSH Server
Add-WindowsCapability -OnlineName SSH.Server~~~~1.0.0.0

# Start SSH service
Start-Service sshd

# Set to auto-start
Set-Service -Name sshd -StartupType Automatic
```

### Configure Windows Firewall:

```powershell
# Allow SSH through firewall
New-NetFirewallRule -DisplayName "SSH" -Direction Inbound -Protocol TCP -LocalPort 22 -Action Allow
```

### Create Windows User for SSH:

```powershell
# Create user for SSH access (run as Administrator)
New-LocalUser -Name "builduser" -Password "YourSecurePassword123!" -Description "VoiceLink Build User" -UserMayChangePassword $false
```

---

## Step 4: Test SSH Connections

### From Mac to WSL:

```bash
ssh mac-dev
# Should connect to your WSL machine
```

### From Mac to Windows:

```bash
ssh windows-build
# Should connect to your Windows machine
```

### From WSL to Mac:

```bash
# First time may need to accept host key
ssh mac-dev
# Then from WSL
```

### From WSL to Windows:

```bash
ssh windows-build
# Then from WSL
```

---

## Step 5: Sync Project Files

### Clone Repository to All Machines:

```bash
# On Mac, WSL, and Windows
git clone https://github.com/raywonder/voicelink.git
cd voicelink
npm install
```

### Set Up Git Remotes:

```bash
# On each machine, add each other as remotes
git remote add mac-origin git@github.com:raywonder/voicelink.git
git remote add wsl-origin git@github.com:raywonder/voicelink.git  
git remote add windows-origin git@github.com:raywonder/voicelink.git
```

---

## Step 6: VoiceLink Development Workflow

### Development on WSL (Recommended):

```bash
cd voicelink
# Use WSL for development and testing
npm run dev
# Test builds
npm run build:prod
```

### Building on Windows:

```powershell
# On Windows machine
cd C:\path\to\voicelink
# Run the Windows build script
.\build-windows.bat
```

### Testing on Mac:

```bash
# On Mac machine
cd voicelink
# Build for Mac testing
npm run build:mac
```

---

## Step 7: File Transfer Workflow

### Option A: Git Sync (Recommended)

```bash
# Commit and push changes from any machine
git add .
git commit -m "Update: Add license validation and UI controls"
git push origin main

# Pull and update on other machines
git pull origin main
```

### Option B: SCP/SFTP Transfer

```bash
# From Mac to Windows
scp -r /path/to/voicelink/* builduser@192.168.1.YYY:C:\VoiceLink\

# From Windows to Mac  
scp -r C:\VoiceLink\* your-mac-username@192.168.1.XXX:/path/to/voicelink/

# Using SFTP (GUI option)
# Use FileZilla, Cyberduck, or similar SFTP client
```

---

## Step 8: Web Server Deployment

### Upload Build Files to Web Directory:

```powershell
# From Windows machine
scp -r releases\* user@your-server.com:/var/www/voicelink-downloads/

# Or use WinSCP for GUI transfer
# Configure server permissions:
# chmod 755 for executable files
# chmod 644 for read-only files
```

### Update Web Pages:

```bash
# Update download links in your HTML/PHP pages
# Links should point to:
# - VoiceLink Local-1.0.4-setup.exe
# - VoiceLink Local-1.0.4-portable.exe  
# - VoiceLink Local-1.0.4-win.zip
# - VoiceLink Local-1.0.4-ia32-win.zip
# - source.tar.gz (for Mac builds)
```

---

## Step 9: Continuous Integration

### Automated Build Script:

```bash
# build-and-deploy.sh
#!/bin/bash
echo "Starting VoiceLink build process..."

# Build on Mac
if [[ "$OSTYPE" == "darwin"* ]]; then
    npm run build:mac
    echo "Mac build complete"
fi

# Build on Windows (triggered remotely)
if [[ "$1" == "windows" ]]; then
    ssh windows-build "cd C:\VoiceLink && .\build-windows.bat"
    echo "Windows build triggered"
fi

# Upload files
scp releases/* user@server.com:/var/www/voicelink-downloads/
echo "Files uploaded successfully"
```

---

## Network IP Reference

### Common Network Ranges:
- Home WiFi: 192.168.1.x
- Office WiFi: 192.168.0.x  
- Airport/WiFi: 10.0.0.x
- WSL2 bridged: Usually 192.168.50.x

### Port Forwarding (if needed):
- SSH: Port 22
- VoiceLink: Port 3001, 3010, 4004-4006
- Web Server: Port 80, 443

---

## Troubleshooting

### SSH Connection Issues:
```bash
# Check SSH service status
sudo service ssh status

# Check SSH daemon
ps aux | grep sshd

# Check firewall
sudo ufw status

# Restart SSH service
sudo service ssh restart
```

### Permission Issues:
```bash
# Fix file permissions
sudo chown -R your-username:your-group /path/to/voicelink
sudo chmod -R 755 /path/to/voicelink

# Fix WSL permission issues
sudo chmod +x /path/to/script.sh
```

### Build Issues:
```bash
# Clear npm cache
npm cache clean --force

# Delete node_modules
rm -rf node_modules

# Fresh install
npm install
```

---

## Security Notes

### SSH Key Security:
- Use unique SSH keys for each machine
- Never share private keys (id_rsa)
- Use strong passphrases for keys
- Regularly rotate SSH keys

### Network Security:
- Use VPN when on untrusted networks
- Configure firewall properly
- Keep systems updated

### File Security:
- Don't commit sensitive data (license keys, API keys)
- Use environment variables for secrets
- Set proper file permissions

---

## Quick Commands Reference

### SSH Commands:
```bash
ssh user@hostname                    # Connect to remote machine
scp file user@hostname:/path        # Copy file to remote
scp user@hostname:/path .        # Copy file from remote  
ssh user@hostname "command"          # Execute command remotely
rsync -avz source/ user@hostname:/dest/  # Sync directories
```

### Git Commands:
```bash
git remote -v                        # List remotes
git remote add <name> <url>          # Add remote
git push <remote> <branch>           # Push to remote
git pull <remote> <branch>           # Pull from remote
git stash && git stash pop         # Stash/unstash changes
```

### PowerShell Commands:
```powershell
Test-NetConnection -ComputerName    # Test connectivity
Get-NetIPAddress                   # Get IP addresses
New-NetFirewallRule               # Add firewall rule
Get-Service sshd                   # Check service status
```

Save this guide as `SETUP.md` in your project root for future reference!