/**
 * VoiceLink Local - Main Electron Process
 * Handles window management, server startup, system integration, and menubar
 */

const { app, BrowserWindow, Menu, Tray, dialog, shell, ipcMain, nativeImage } = require('electron');
const path = require('path');
const fs = require('fs');
const os = require('os');
const { spawn } = require('child_process');

// Server setup
const express = require('express');
const http = require('http');
const socketIo = require('socket.io');
const cors = require('cors');

// System integration
const AutoLaunch = require('auto-launch');
const RobustSettingsManager = require('./settings-manager');
const UpdateChecker = require('./update-checker');
const PortManager = require('./port-manager');

class VoiceLinkApp {
    constructor() {
        this.mainWindow = null;
        this.tray = null;
        this.serverInstance = null;
        this.httpServer = null;
        this.socketServer = null;
        this.serverPort = 4004; // Default to safer port, will be auto-detected
        this.portManager = new PortManager();
        this.rooms = new Map();
        this.users = new Map();

        // Configuration and state
        this.settings = new RobustSettingsManager();
        this.autoLauncher = null;
        this.updateChecker = new UpdateChecker();
        this.localIP = null;
        this.externalIP = null;
        this.networkInterfaces = []; // All available network interfaces
        this.selectedInterface = null; // Currently selected interface for hosting
        this.bindAddress = '0.0.0.0'; // IP address to bind server to
        this.isOnline = false; // Internet connectivity status
        this.serverStartTime = null;
        this.isServerRunning = false;

        this.isDev = process.argv.includes('--dev');
        this.isPortable = process.env.PORTABLE === 'true' || process.argv.includes('--portable');

        this.init();
    }

    init() {
        console.log('Initializing VoiceLink Local...');

        // Set app paths for portable mode
        if (this.isPortable) {
            this.setupPortablePaths();
        }

        // Initialize auto launcher
        this.setupAutoLaunch();

        // Get network information
        this.detectNetworkInfo();

        // Handle app events
        this.setupAppEvents();

        // Setup IPC handlers
        this.setupIPCHandlers();
    }

    setupPortablePaths() {
        // For portable mode, store data in app directory
        const appPath = path.dirname(app.getPath('exe'));
        const dataPath = path.join(appPath, 'data');

        // Ensure data directory exists
        if (!fs.existsSync(dataPath)) {
            fs.mkdirSync(dataPath, { recursive: true });
        }

        // Override user data path
        app.setPath('userData', dataPath);
        app.setPath('logs', path.join(dataPath, 'logs'));
        app.setPath('temp', path.join(dataPath, 'temp'));

        console.log('Portable mode enabled - Data path:', dataPath);
    }

    setupAutoLaunch() {
        this.autoLauncher = new AutoLaunch({
            name: 'VoiceLink Local',
            path: app.getPath('exe'),
            isHidden: true
        });

        // Check if auto launch is enabled
        this.autoLauncher.isEnabled().then((isEnabled) => {
            console.log('Auto launch enabled:', isEnabled);
        }).catch((err) => {
            console.error('Failed to check auto launch status:', err);
        });
    }

    async detectNetworkInfo() {
        try {
            // Get all network interfaces
            const interfaces = os.networkInterfaces();
            this.networkInterfaces = [];
            let firstLocalIP = null;

            // Add "All Interfaces" option first - this is the default
            this.networkInterfaces.push({
                name: 'all',
                displayName: 'All Interfaces (0.0.0.0)',
                address: '0.0.0.0',
                netmask: '0.0.0.0',
                mac: '',
                type: 'all'
            });

            for (const [name, netInterfaces] of Object.entries(interfaces)) {
                for (const netInterface of netInterfaces) {
                    if (netInterface.family === 'IPv4' && !netInterface.internal) {
                        // Detect interface type for better labeling
                        let type = 'local';
                        let displayName = name;

                        // Tailscale detection
                        if (name.toLowerCase().includes('tailscale') ||
                            name.toLowerCase() === 'utun' ||
                            netInterface.address.startsWith('100.')) {
                            type = 'tailscale';
                            displayName = `${name} (Tailscale VPN)`;
                        }
                        // Headscale/WireGuard detection
                        else if (name.toLowerCase().includes('wg') ||
                                 name.toLowerCase().includes('wireguard') ||
                                 name.toLowerCase().includes('headscale')) {
                            type = 'wireguard';
                            displayName = `${name} (WireGuard/Headscale)`;
                        }
                        // Standard Ethernet
                        else if (name.toLowerCase().includes('en') ||
                                 name.toLowerCase().includes('eth')) {
                            type = 'ethernet';
                            displayName = `${name} (Ethernet)`;
                        }
                        // WiFi
                        else if (name.toLowerCase().includes('wlan') ||
                                 name.toLowerCase().includes('wi-fi') ||
                                 name.toLowerCase().includes('airport')) {
                            type = 'wifi';
                            displayName = `${name} (WiFi)`;
                        }
                        // macOS utun interfaces (often VPN)
                        else if (name.startsWith('utun')) {
                            type = 'vpn';
                            displayName = `${name} (VPN Tunnel)`;
                        }

                        this.networkInterfaces.push({
                            name: name,
                            displayName: displayName,
                            address: netInterface.address,
                            netmask: netInterface.netmask,
                            mac: netInterface.mac,
                            type: type
                        });

                        // Track first non-VPN interface for display purposes
                        if (!firstLocalIP && type !== 'vpn') {
                            firstLocalIP = netInterface.address;
                        }
                    }
                }
            }

            // Default to "All Interfaces" for maximum accessibility
            this.selectedInterface = 'all';
            this.bindAddress = '0.0.0.0';
            // Use first real local IP for display purposes
            this.localIP = firstLocalIP || '127.0.0.1';

            console.log('Network interfaces detected:', this.networkInterfaces.length);
            console.log('Local IP for display:', this.localIP);
            console.log('Binding to:', this.bindAddress, '(All Interfaces)');

            // Detect external/public IP
            await this.detectExternalIP();

        } catch (error) {
            console.error('Failed to detect network info:', error);
            this.localIP = '127.0.0.1';
            this.selectedInterface = 'all';
            this.bindAddress = '0.0.0.0';
        }
    }

    async detectExternalIP() {
        const https = require('https');

        // Try multiple services for redundancy
        const ipServices = [
            { url: 'https://api.ipify.org?format=json', parser: (data) => JSON.parse(data).ip },
            { url: 'https://ipinfo.io/json', parser: (data) => JSON.parse(data).ip },
            { url: 'https://api.ip.sb/ip', parser: (data) => data.trim() }
        ];

        for (const service of ipServices) {
            try {
                const ip = await new Promise((resolve, reject) => {
                    const request = https.get(service.url, { timeout: 5000 }, (response) => {
                        if (response.statusCode !== 200) {
                            reject(new Error(`HTTP ${response.statusCode}`));
                            return;
                        }

                        let data = '';
                        response.on('data', chunk => data += chunk);
                        response.on('end', () => {
                            try {
                                resolve(service.parser(data));
                            } catch (e) {
                                reject(e);
                            }
                        });
                    });

                    request.on('error', reject);
                    request.on('timeout', () => {
                        request.destroy();
                        reject(new Error('Timeout'));
                    });
                });

                if (ip && /^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$/.test(ip)) {
                    this.externalIP = ip;
                    this.isOnline = true;
                    console.log('External IP detected:', this.externalIP);
                    // Notify renderer that network info has been updated
                    this.notifyNetworkInfoUpdate();
                    return;
                }
            } catch (error) {
                console.log(`IP service ${service.url} failed:`, error.message);
                continue;
            }
        }

        this.externalIP = null;
        this.isOnline = false;
        console.log('Could not detect external IP - may be offline or behind NAT');
        // Notify renderer even on failure so UI updates
        this.notifyNetworkInfoUpdate();
    }

    // Notify renderer when network info changes
    notifyNetworkInfoUpdate() {
        // Poll until window is actually ready and loaded
        let attempts = 0;
        const maxAttempts = 50; // 5 seconds max

        const checkAndSend = () => {
            attempts++;
            if (this.mainWindow && !this.mainWindow.isDestroyed() &&
                !this.mainWindow.webContents.isLoading()) {
                const data = {
                    localIP: this.localIP,
                    externalIP: this.externalIP,
                    isOnline: this.isOnline,
                    isServerRunning: this.isServerRunning,
                    port: this.serverPort,
                    networkInterfaces: this.getNetworkInterfaces(),
                    selectedInterface: this.selectedInterface
                };
                console.log('Sending network info update to renderer:', JSON.stringify(data));
                this.mainWindow.webContents.send('network-info-updated', data);
            } else if (attempts < maxAttempts) {
                setTimeout(checkAndSend, 100);
            } else {
                console.log('Window not ready after 5s, skipping network info update');
            }
        };

        // Start checking after initial delay
        setTimeout(checkAndSend, 200);
    }

    // Get all available network interfaces for UI
    getNetworkInterfaces() {
        return this.networkInterfaces.map(iface => ({
            name: iface.name,
            displayName: iface.displayName || iface.name,
            address: iface.address,
            type: iface.type || 'local',
            selected: iface.name === this.selectedInterface
        }));
    }

    // Set the network interface to use for hosting
    async setSelectedInterface(interfaceName) {
        const iface = this.networkInterfaces.find(i => i.name === interfaceName);
        if (iface) {
            const oldInterface = this.selectedInterface;
            this.selectedInterface = interfaceName;
            this.bindAddress = iface.address;

            // Update localIP for display (use actual IP if not binding to all)
            if (iface.address === '0.0.0.0') {
                // Find first real local IP for display purposes
                const realIface = this.networkInterfaces.find(i =>
                    i.name !== 'all' && i.type !== 'vpn'
                );
                this.localIP = realIface ? realIface.address : '127.0.0.1';
            } else {
                this.localIP = iface.address;
            }

            console.log(`Selected interface: ${interfaceName} (bind: ${this.bindAddress}, display: ${this.localIP})`);
            this.updateTrayMenu();

            // Restart server if it was running and interface changed
            if (this.isServerRunning && oldInterface !== interfaceName) {
                console.log('Interface changed, restarting server...');
                await this.restartServer();
            }

            // Notify renderer of the update
            this.notifyNetworkInfoUpdate();

            return { success: true, bindAddress: this.bindAddress, displayIP: this.localIP };
        }
        return { success: false, error: 'Interface not found' };
    }

    setupAppEvents() {
        // App ready
        app.whenReady().then(() => {
            this.createTray();
            this.startServer();
            this.createMenu();

            // Create window only if not launched minimized
            if (!this.settings.get('startMinimized', false) || this.isDev) {
                this.createWindow();
            }

            // Start update checker
            if (this.settings.get('autoUpdateCheck', true)) {
                this.updateChecker.startAutoCheck();
            }

            app.on('activate', () => {
                if (BrowserWindow.getAllWindows().length === 0) {
                    this.createWindow();
                }
            });
        });

        // All windows closed
        app.on('window-all-closed', () => {
            // On macOS, keep the app running in menubar when windows are closed
            if (process.platform !== 'darwin' && !this.settings.get('keepInMenubar', true)) {
                this.cleanup();
                app.quit();
            }
            // Reset main window reference
            this.mainWindow = null;
        });

        // Before quit
        app.on('before-quit', () => {
            this.cleanup();
        });

        // Handle certificate errors for development
        app.on('certificate-error', (event, webContents, url, error, certificate, callback) => {
            if (this.isDev) {
                event.preventDefault();
                callback(true);
            } else {
                callback(false);
            }
        });

        // Register voicelink:// protocol handler
        if (process.defaultApp) {
            if (process.argv.length >= 2) {
                app.setAsDefaultProtocolClient('voicelink', process.execPath, [path.resolve(process.argv[1])]);
            }
        } else {
            app.setAsDefaultProtocolClient('voicelink');
        }

        // Handle protocol URL on macOS
        app.on('open-url', (event, url) => {
            event.preventDefault();
            this.handleProtocolUrl(url);
        });

        // Handle protocol URL on Windows/Linux (via second-instance)
        const gotTheLock = app.requestSingleInstanceLock();
        if (!gotTheLock) {
            app.quit();
        } else {
            app.on('second-instance', (event, commandLine, workingDirectory) => {
                // Find the protocol URL in command line args
                const url = commandLine.find(arg => arg.startsWith('voicelink://'));
                if (url) {
                    this.handleProtocolUrl(url);
                }
                // Focus window if exists
                if (this.mainWindow) {
                    if (this.mainWindow.isMinimized()) this.mainWindow.restore();
                    this.mainWindow.focus();
                }
            });
        }
    }

    // Handle voicelink:// protocol URLs
    handleProtocolUrl(url) {
        console.log('Handling protocol URL:', url);
        try {
            const parsed = new URL(url);
            const action = parsed.hostname; // e.g., 'join'
            const roomId = parsed.pathname.replace(/^\//, ''); // e.g., 'room-id'
            const serverUrl = parsed.searchParams.get('server');

            if (action === 'join' && roomId) {
                // Show window if hidden
                if (!this.mainWindow) {
                    this.createWindow();
                }
                if (this.mainWindow.isMinimized()) this.mainWindow.restore();
                this.mainWindow.focus();

                // Send join command to renderer
                this.mainWindow.webContents.once('did-finish-load', () => {
                    this.mainWindow.webContents.send('protocol-join-room', {
                        roomId,
                        serverUrl: serverUrl || null
                    });
                });

                // If already loaded, send immediately
                if (!this.mainWindow.webContents.isLoading()) {
                    this.mainWindow.webContents.send('protocol-join-room', {
                        roomId,
                        serverUrl: serverUrl || null
                    });
                }
            }
        } catch (err) {
            console.error('Error parsing protocol URL:', err);
        }
    }

    createTray() {
        console.log('Creating system tray...');

        // Create tray icon
        const iconPath = path.join(__dirname, '..', 'assets', 'menubar-icon.png');
        const trayIcon = nativeImage.createFromPath(iconPath);

        // Set template to true for proper dark mode support on macOS
        trayIcon.setTemplateImage(true);

        this.tray = new Tray(trayIcon);
        this.tray.setToolTip('VoiceLink Local - P2P Voice Chat Server');

        // Create context menu
        this.updateTrayMenu();

        // Handle tray click (show/hide window)
        this.tray.on('click', () => {
            this.toggleMainWindow();
        });

        console.log('System tray created');
    }

    updateTrayMenu() {
        const roomCount = this.rooms.size;
        const userCount = Array.from(this.rooms.values()).reduce((sum, room) => sum + room.users.size, 0);
        const serverUrl = this.getServerURL();
        const publicUrl = this.externalIP ? `http://${this.externalIP}:${this.serverPort}` : null;
        const uptime = this.getUptime();

        // Build network interface submenu with better display
        const networkSubmenu = this.networkInterfaces.map(iface => {
            let label = iface.displayName || iface.name;
            // Show IP address for specific interfaces (not "all")
            if (iface.name !== 'all' && iface.address) {
                label = `${iface.displayName} - ${iface.address}`;
            }
            return {
                label: label,
                type: 'radio',
                checked: iface.name === this.selectedInterface,
                click: () => this.setSelectedInterface(iface.name)
            };
        });

        // Build copy URL submenu
        const copyUrlSubmenu = [
            {
                label: `Local: ${serverUrl}`,
                click: () => {
                    require('electron').clipboard.writeText(serverUrl);
                    this.showNotification('Local URL copied to clipboard');
                }
            },
            {
                label: `Localhost: http://localhost:${this.serverPort}`,
                click: () => {
                    require('electron').clipboard.writeText(`http://localhost:${this.serverPort}`);
                    this.showNotification('Localhost URL copied to clipboard');
                }
            }
        ];

        if (publicUrl) {
            copyUrlSubmenu.push({
                label: `Public: ${publicUrl}`,
                click: () => {
                    require('electron').clipboard.writeText(publicUrl);
                    this.showNotification('Public URL copied to clipboard (requires port forwarding)');
                }
            });
        }

        // Get current binding display
        const bindingDisplay = this.selectedInterface === 'all'
            ? 'All Networks'
            : this.networkInterfaces.find(i => i.name === this.selectedInterface)?.displayName || this.selectedInterface;

        const contextMenu = Menu.buildFromTemplate([
            {
                label: `VoiceLink Local v${app.getVersion()}`,
                enabled: false
            },
            { type: 'separator' },
            {
                label: `Server: ${this.isServerRunning ? '🟢 Running' : '🔴 Stopped'}`,
                enabled: false
            },
            {
                label: `Listening: ${bindingDisplay}`,
                enabled: false
            },
            {
                label: `Internet: ${this.isOnline ? '🟢 Online' : '🔴 Offline'}`,
                enabled: false
            },
            {
                label: `Local IP: ${this.localIP || 'Not detected'}`,
                enabled: false
            },
            {
                label: `Public IP: ${this.externalIP || 'Not available'}`,
                enabled: false
            },
            {
                label: `Users: ${userCount} | Rooms: ${roomCount}`,
                enabled: false
            },
            {
                label: `Uptime: ${uptime}`,
                enabled: false
            },
            { type: 'separator' },
            {
                label: 'Show VoiceLink',
                click: () => this.showMainWindow()
            },
            {
                label: 'Application Settings...',
                click: () => this.openPreferences()
            },
            {
                label: 'Check for Updates...',
                click: () => this.updateChecker.checkForUpdatesManual()
            },
            { type: 'separator' },
            {
                label: 'Copy Server URL',
                submenu: copyUrlSubmenu
            },
            {
                label: 'Network Interface',
                submenu: networkSubmenu.length > 0 ? networkSubmenu : [{ label: 'No interfaces found', enabled: false }]
            },
            {
                label: 'Refresh Network Info',
                click: () => {
                    this.detectNetworkInfo().then(() => {
                        this.updateTrayMenu();
                        this.showNotification('Network info refreshed');
                    });
                }
            },
            { type: 'separator' },
            {
                label: 'Share QR Code',
                click: () => this.showQRCode()
            },
            {
                label: 'Open Web UI',
                click: () => this.openWebUI(),
                enabled: this.isServerRunning
            },
            { type: 'separator' },
            {
                label: 'Start Server',
                click: () => this.startServer(),
                enabled: !this.isServerRunning
            },
            {
                label: 'Restart Server',
                click: () => this.restartServer(),
                enabled: this.isServerRunning
            },
            {
                label: 'Stop Server',
                click: () => this.stopServer(),
                enabled: this.isServerRunning
            },
            { type: 'separator' },
            {
                label: 'Quit VoiceLink',
                click: () => {
                    this.forceQuit = true;
                    app.quit();
                }
            }
        ]);

        this.tray.setContextMenu(contextMenu);
    }

    toggleMainWindow() {
        if (this.mainWindow && this.mainWindow.isVisible()) {
            this.mainWindow.hide();
        } else {
            this.showMainWindow();
        }
    }

    showMainWindow() {
        if (!this.mainWindow) {
            this.createWindow();
        } else {
            this.mainWindow.show();
            this.mainWindow.focus();
        }
    }

    createWindow() {
        console.log('Creating main window...');

        this.mainWindow = new BrowserWindow({
            width: 1200,
            height: 800,
            minWidth: 800,
            minHeight: 600,
            webPreferences: {
                nodeIntegration: false,
                contextIsolation: true,
                enableRemoteModule: false,
                preload: path.join(__dirname, 'preload.js'),
                webSecurity: false  // Allow cross-origin requests to main server
            },
            icon: this.getAppIcon(),
            show: false,
            titleBarStyle: process.platform === 'darwin' ? 'hiddenInset' : 'default'
        });

        // Load the app
        const indexPath = path.join(__dirname, '..', 'client', 'index.html');
        this.mainWindow.loadFile(indexPath);

        // Show window when ready
        this.mainWindow.once('ready-to-show', () => {
            // Check for auto-minimize setting (but always show in dev mode)
            const autoMinimizeOnStart = this.settings.get('autoMinimizeOnStart', false);
            const startMinimized = this.settings.get('startMinimized', false);

            if ((autoMinimizeOnStart || startMinimized) && !this.isDev) {
                // Start minimized to tray (but not in dev mode)
                if (!this.hasShownTrayNotification) {
                    this.showNotification('VoiceLink started in menubar. Server is ready for connections.');
                    this.hasShownTrayNotification = true;
                }
                // Don't show the window - it stays hidden
            } else {
                this.mainWindow.show();
            }

            if (this.isDev) {
                this.mainWindow.webContents.openDevTools();
            }
        });

        // Send network info when page is fully loaded
        this.mainWindow.webContents.on('did-finish-load', () => {
            console.log('Window content loaded, sending network info...');
            // Send current network info to renderer
            const data = {
                localIP: this.localIP,
                externalIP: this.externalIP,
                isOnline: this.isOnline,
                isServerRunning: this.isServerRunning,
                port: this.serverPort,
                networkInterfaces: this.getNetworkInterfaces(),
                selectedInterface: this.selectedInterface
            };
            this.mainWindow.webContents.send('network-info-updated', data);
        });

        // Handle window closed
        this.mainWindow.on('closed', () => {
            this.mainWindow = null;
        });

        // Handle close button (hide to tray instead of quit)
        this.mainWindow.on('close', (event) => {
            if (!this.forceQuit && this.settings.get('hideToTrayOnClose', true)) {
                event.preventDefault();
                this.mainWindow.hide();

                // Show notification on first hide
                if (!this.hasShownTrayNotification) {
                    this.showNotification('VoiceLink is still running in the menubar');
                    this.hasShownTrayNotification = true;
                }
            }
        });

        // Handle external links
        this.mainWindow.webContents.setWindowOpenHandler(({ url }) => {
            shell.openExternal(url);
            return { action: 'deny' };
        });

        console.log('Main window created');
    }

    getAppIcon() {
        const iconPath = path.join(__dirname, '..', 'assets');

        if (process.platform === 'win32') {
            return path.join(iconPath, 'icon.ico');
        } else if (process.platform === 'darwin') {
            return path.join(iconPath, 'icon.icns');
        } else {
            return path.join(iconPath, 'icon.png');
        }
    }

    async startServer() {
        console.log('Starting local server...');

        try {
            // Create Express app
            this.serverInstance = express();

            // Middleware
            this.serverInstance.use(cors({
                origin: "*",
                methods: ["GET", "POST"],
                credentials: true
            }));

            this.serverInstance.use(express.json());
            this.serverInstance.use(express.static(path.join(__dirname, '..', 'client')));

            // Create HTTP server
            this.httpServer = http.createServer(this.serverInstance);

            // Setup Socket.IO
            this.socketServer = socketIo(this.httpServer, {
                cors: {
                    origin: "*",
                    methods: ["GET", "POST"],
                    credentials: true
                }
            });

            // Setup routes
            this.setupServerRoutes();
            this.setupSocketHandlers();

            // Start listening on selected interface
            await new Promise((resolve, reject) => {
                const bindAddr = this.bindAddress || '0.0.0.0';
                this.httpServer.listen(this.serverPort, bindAddr, (err) => {
                    if (err) {
                        reject(err);
                    } else {
                        this.isServerRunning = true;
                        this.serverStartTime = Date.now();
                        console.log(`Server running on ${bindAddr}:${this.serverPort}`);
                        this.updateTrayMenu();
                        resolve();
                    }
                });
            });

        } catch (error) {
            console.error('Failed to start server:', error);

            // Try alternative port
            this.serverPort = 3001;
            await this.startServerWithRetry();
        }
    }

    async startServerWithRetry() {
        try {
            await new Promise((resolve, reject) => {
                const bindAddr = this.bindAddress || '0.0.0.0';
                this.httpServer.listen(this.serverPort, bindAddr, (err) => {
                    if (err) {
                        reject(err);
                    } else {
                        this.isServerRunning = true;
                        this.serverStartTime = Date.now();
                        console.log(`Server running on ${bindAddr}:${this.serverPort}`);
                        this.updateTrayMenu();
                        resolve();
                    }
                });
            });
        } catch (error) {
            console.error('Failed to start server on alternative port:', error);
            dialog.showErrorBox('Server Error', 'Failed to start local server. Please check if ports 3000-3001 are available.');
        }
    }

    setupServerRoutes() {
        // Health check
        this.serverInstance.get('/health', (req, res) => {
            res.json({ status: 'ok', timestamp: Date.now() });
        });

        // API status endpoint
        this.serverInstance.get('/api/status', (req, res) => {
            res.json({
                server: 'VoiceLink Local',
                version: '1.0.3',
                status: 'running',
                uptime: this.getUptime(),
                rooms: this.rooms.size,
                port: this.serverPort,
                localIP: this.localIP,
                externalIP: this.externalIP,
                isOnline: this.isOnline
            });
        });

        // Get rooms
        this.serverInstance.get('/api/rooms', (req, res) => {
            const roomList = Array.from(this.rooms.values()).map(room => ({
                id: room.id,
                name: room.name,
                userCount: room.users.size,
                maxUsers: room.maxUsers,
                hasPassword: !!room.password,
                createdAt: room.createdAt,
                // Include visibility properties for client filtering
                visibility: room.visibility || 'public',
                visibleToGuests: room.visibleToGuests !== false,
                isDefault: room.isDefault || false
            }));

            res.json(roomList);
        });

        // Create room
        this.serverInstance.post('/api/rooms', (req, res) => {
            const { name, password, maxUsers } = req.body;

            if (!name) {
                return res.status(400).json({ error: 'Room name is required' });
            }

            const roomId = this.generateRoomId();
            const room = {
                id: roomId,
                name,
                password: password || null,
                maxUsers: maxUsers || 10,
                users: new Map(),
                createdAt: Date.now(),
                host: null
            };

            this.rooms.set(roomId, room);

            res.json({
                roomId,
                name: room.name,
                maxUsers: room.maxUsers
            });
        });
    }

    setupSocketHandlers() {
        this.socketServer.on('connection', (socket) => {
            console.log('User connected:', socket.id);

            // Join room
            socket.on('join-room', (data) => {
                const { roomId, userName, password } = data;
                const room = this.rooms.get(roomId);

                if (!room) {
                    socket.emit('join-error', { message: 'Room not found' });
                    return;
                }

                if (room.password && room.password !== password) {
                    socket.emit('join-error', { message: 'Invalid password' });
                    return;
                }

                if (room.users.size >= room.maxUsers) {
                    socket.emit('join-error', { message: 'Room is full' });
                    return;
                }

                // Add user to room
                const user = {
                    id: socket.id,
                    name: userName,
                    joinedAt: Date.now()
                };

                room.users.set(socket.id, user);
                socket.join(roomId);
                socket.roomId = roomId;

                // Set host if first user
                if (!room.host) {
                    room.host = socket.id;
                    user.isHost = true;
                }

                // Notify room
                socket.emit('join-success', {
                    roomId,
                    userId: socket.id,
                    isHost: user.isHost || false
                });

                this.socketServer.to(roomId).emit('user-joined', {
                    user,
                    userCount: room.users.size
                });

                console.log(`User ${userName} joined room ${roomId}`);
            });

            // Leave room
            socket.on('leave-room', () => {
                this.handleUserLeave(socket);
            });

            // WebRTC signaling
            socket.on('webrtc-signal', (data) => {
                socket.to(data.targetId).emit('webrtc-signal', {
                    signal: data.signal,
                    fromId: socket.id
                });
            });

            // Chat message
            socket.on('chat-message', (data) => {
                if (socket.roomId) {
                    this.socketServer.to(socket.roomId).emit('chat-message', {
                        message: data.message,
                        userId: socket.id,
                        userName: data.userName,
                        timestamp: Date.now()
                    });
                }
            });

            // Disconnect
            socket.on('disconnect', () => {
                this.handleUserLeave(socket);
                console.log('User disconnected:', socket.id);
            });
        });
    }

    handleUserLeave(socket) {
        if (socket.roomId) {
            const room = this.rooms.get(socket.roomId);
            if (room) {
                room.users.delete(socket.id);

                // Transfer host if needed
                if (room.host === socket.id && room.users.size > 0) {
                    const newHost = Array.from(room.users.keys())[0];
                    room.host = newHost;
                    const newHostUser = room.users.get(newHost);
                    newHostUser.isHost = true;

                    this.socketServer.to(newHost).emit('host-transferred');
                }

                // Remove room if empty
                if (room.users.size === 0) {
                    this.rooms.delete(socket.roomId);
                } else {
                    // Notify remaining users
                    this.socketServer.to(socket.roomId).emit('user-left', {
                        userId: socket.id,
                        userCount: room.users.size
                    });
                }
            }
        }
    }

    setupIPCHandlers() {
        // Get server info
        ipcMain.handle('get-server-info', () => {
            return {
                port: this.serverPort,
                url: this.getServerURL(),
                localUrl: `http://localhost:${this.serverPort}`,
                publicUrl: this.externalIP ? `http://${this.externalIP}:${this.serverPort}` : null,
                localIP: this.localIP,
                externalIP: this.externalIP,
                isOnline: this.isOnline,
                networkInterfaces: this.getNetworkInterfaces(),
                selectedInterface: this.selectedInterface,
                isPortable: this.isPortable,
                isDev: this.isDev,
                isRunning: this.isServerRunning,
                uptime: this.getUptime(),
                roomCount: this.rooms.size,
                userCount: Array.from(this.rooms.values()).reduce((sum, room) => sum + room.users.size, 0)
            };
        });

        // Get network interfaces
        ipcMain.handle('get-network-interfaces', () => {
            return this.getNetworkInterfaces();
        });

        // Set selected network interface
        ipcMain.handle('set-network-interface', (event, interfaceName) => {
            return this.setSelectedInterface(interfaceName);
        });

        // Refresh network info
        ipcMain.handle('refresh-network-info', async () => {
            await this.detectNetworkInfo();
            return {
                localIP: this.localIP,
                externalIP: this.externalIP,
                isOnline: this.isOnline,
                networkInterfaces: this.getNetworkInterfaces()
            };
        });

        // Copy URL to clipboard
        ipcMain.handle('copy-url', (event, urlType) => {
            let url;
            switch (urlType) {
                case 'public':
                    url = this.externalIP ? `http://${this.externalIP}:${this.serverPort}` : null;
                    break;
                case 'localhost':
                    url = `http://localhost:${this.serverPort}`;
                    break;
                case 'local':
                default:
                    url = this.getServerURL();
                    break;
            }
            if (url) {
                require('electron').clipboard.writeText(url);
                return { success: true, url };
            }
            return { success: false, error: 'URL not available' };
        });

        // Open external URL
        ipcMain.handle('open-external', (event, url) => {
            shell.openExternal(url);
        });

        // Show message box
        ipcMain.handle('show-message-box', (event, options) => {
            return dialog.showMessageBox(this.mainWindow, options);
        });

        // Get app info
        ipcMain.handle('get-app-info', () => {
            return {
                name: app.getName(),
                version: app.getVersion(),
                platform: process.platform,
                arch: process.arch,
                isPortable: this.isPortable
            };
        });

        // Auto-launch management
        ipcMain.handle('get-auto-launch-enabled', async () => {
            try {
                return await this.autoLauncher.isEnabled();
            } catch (error) {
                console.error('Failed to check auto launch status:', error);
                return false;
            }
        });

        ipcMain.handle('set-auto-launch-enabled', async (event, enabled) => {
            try {
                if (enabled) {
                    await this.autoLauncher.enable();
                } else {
                    await this.autoLauncher.disable();
                }
                return true;
            } catch (error) {
                console.error('Failed to set auto launch:', error);
                return false;
            }
        });

        // Settings management
        ipcMain.handle('get-setting', (event, key, defaultValue) => {
            return this.settings.get(key, defaultValue);
        });

        ipcMain.handle('set-setting', (event, key, value) => {
            this.settings.set(key, value);
            this.updateTrayMenu(); // Update tray menu when settings change
            return true;
        });

        ipcMain.handle('get-all-settings', () => {
            return this.settings.getAll();
        });

        // Server management
        ipcMain.handle('restart-server', async () => {
            try {
                await this.restartServer();
                return true;
            } catch (error) {
                console.error('Failed to restart server via IPC:', error);
                return false;
            }
        });

        ipcMain.handle('stop-server', async () => {
            try {
                await this.stopServer();
                return true;
            } catch (error) {
                console.error('Failed to stop server via IPC:', error);
                return false;
            }
        });

        ipcMain.handle('start-server', async () => {
            try {
                if (!this.isServerRunning) {
                    await this.startServer();
                    return true;
                } else {
                    console.log('Server is already running');
                    return true;
                }
            } catch (error) {
                console.error('Failed to start server via IPC:', error);
                return false;
            }
        });

        // Tray and window management
        ipcMain.handle('hide-to-tray', () => {
            if (this.mainWindow) {
                this.mainWindow.hide();
                return true;
            }
            return false;
        });

        ipcMain.handle('minimize-to-tray', () => {
            if (this.mainWindow) {
                this.mainWindow.hide();
                if (!this.hasShownTrayNotification) {
                    this.showNotification('VoiceLink is now running in the menubar');
                    this.hasShownTrayNotification = true;
                }
                return true;
            }
            return false;
        });

        ipcMain.handle('show-preferences', () => {
            this.showPreferences();
            return true;
        });

        ipcMain.handle('show-qr-code', () => {
            this.showQRCode();
            return true;
        });

        ipcMain.handle('copy-server-url', () => {
            const url = this.getServerURL();
            require('electron').clipboard.writeText(url);
            this.showNotification('Server URL copied to clipboard');
            return url;
        });

        ipcMain.handle('open-web-ui', () => {
            this.openWebUI();
            return true;
        });

        // Update checker handlers
        ipcMain.handle('check-for-updates', async () => {
            try {
                await this.updateChecker.checkForUpdatesManual();
                return true;
            } catch (error) {
                console.error('Update check failed:', error);
                return false;
            }
        });

        ipcMain.handle('get-update-settings', () => {
            return {
                autoUpdateCheck: this.settings.get('autoUpdateCheck', true),
                currentVersion: app.getVersion()
            };
        });

        ipcMain.handle('set-auto-update-check', (event, enabled) => {
            this.settings.set('autoUpdateCheck', enabled);
            if (enabled) {
                this.updateChecker.startAutoCheck();
            }
            return true;
        });
    }

    createMenu() {
        const template = [
            {
                label: 'File',
                submenu: [
                    {
                        label: 'New Room',
                        accelerator: 'CmdOrCtrl+N',
                        click: () => {
                            this.mainWindow.webContents.send('menu-action', 'new-room');
                        }
                    },
                    {
                        label: 'Join Room',
                        accelerator: 'CmdOrCtrl+J',
                        click: () => {
                            this.mainWindow.webContents.send('menu-action', 'join-room');
                        }
                    },
                    { type: 'separator' },
                    {
                        label: 'Check for Updates...',
                        click: () => {
                            this.updateChecker.checkForUpdatesManual();
                        }
                    },
                    { type: 'separator' },
                    {
                        label: 'Exit',
                        accelerator: process.platform === 'darwin' ? 'Cmd+Q' : 'Ctrl+Q',
                        click: () => {
                            app.quit();
                        }
                    }
                ]
            },
            {
                label: 'View',
                submenu: [
                    { role: 'reload' },
                    { role: 'forceReload' },
                    { role: 'toggleDevTools' },
                    { type: 'separator' },
                    { role: 'resetZoom' },
                    { role: 'zoomIn' },
                    { role: 'zoomOut' },
                    { type: 'separator' },
                    { role: 'togglefullscreen' }
                ]
            },
            {
                label: 'Audio',
                submenu: [
                    {
                        label: 'Settings',
                        accelerator: 'CmdOrCtrl+,',
                        click: () => {
                            this.mainWindow.webContents.send('menu-action', 'audio-settings');
                        }
                    },
                    {
                        label: 'Test Audio',
                        click: () => {
                            this.mainWindow.webContents.send('menu-action', 'test-audio');
                        }
                    }
                ]
            },
            {
                label: 'Help',
                submenu: [
                    {
                        label: 'About',
                        click: () => {
                            this.showAboutDialog();
                        }
                    },
                    {
                        label: 'Documentation',
                        click: () => {
                            shell.openExternal('https://github.com/devinecreations/voicelink-local');
                        }
                    }
                ]
            }
        ];

        // macOS specific menu adjustments
        if (process.platform === 'darwin') {
            template.unshift({
                label: app.getName(),
                submenu: [
                    { role: 'about' },
                    { type: 'separator' },
                    {
                        label: 'Check for Updates...',
                        click: () => {
                            this.updateChecker.checkForUpdatesManual();
                        }
                    },
                    { type: 'separator' },
                    { role: 'services' },
                    { type: 'separator' },
                    { role: 'hide' },
                    { role: 'hideOthers' },
                    { role: 'unhide' },
                    { type: 'separator' },
                    { role: 'quit' }
                ]
            });
        }

        const menu = Menu.buildFromTemplate(template);
        Menu.setApplicationMenu(menu);
    }

    showAboutDialog() {
        dialog.showMessageBox(this.mainWindow, {
            type: 'info',
            title: 'About VoiceLink Local',
            message: 'VoiceLink Local',
            detail: `Version: ${app.getVersion()}\nA P2P voice chat application with 3D spatial audio\n\nDeveloped by DevineCreations`,
            buttons: ['OK']
        });
    }

    generateRoomId() {
        const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
        let result = '';
        for (let i = 0; i < 6; i++) {
            result += chars.charAt(Math.floor(Math.random() * chars.length));
        }
        return result;
    }

    // Utility methods for tray menu and server management
    getServerURL() {
        const ip = this.localIP || 'localhost';
        return `http://${ip}:${this.serverPort}`;
    }

    getUptime() {
        if (!this.serverStartTime) return 'Not running';

        const uptime = Date.now() - this.serverStartTime;
        const seconds = Math.floor(uptime / 1000);
        const minutes = Math.floor(seconds / 60);
        const hours = Math.floor(minutes / 60);

        if (hours > 0) {
            return `${hours}h ${minutes % 60}m`;
        } else if (minutes > 0) {
            return `${minutes}m ${seconds % 60}s`;
        } else {
            return `${seconds}s`;
        }
    }

    showNotification(message) {
        if (this.tray) {
            this.tray.displayBalloon({
                title: 'VoiceLink Local',
                content: message,
                iconType: 'info'
            });
        }
    }

    async openPreferences() {
        // Create preferences window
        const prefsWindow = new BrowserWindow({
            width: 600,
            height: 500,
            parent: this.mainWindow,
            modal: true,
            webPreferences: {
                nodeIntegration: false,
                contextIsolation: true,
                preload: path.join(__dirname, 'preload.js')
            },
            title: 'VoiceLink Preferences'
        });

        // Load preferences page (we'll create this)
        const prefsPath = path.join(__dirname, '..', 'client', 'preferences.html');
        prefsWindow.loadFile(prefsPath);

        prefsWindow.on('closed', () => {
            // Update settings after preferences window closes
            this.updateTrayMenu();
        });
    }

    openWebUI() {
        const serverUrl = this.getServerURL();

        try {
            // Open the web UI in the default browser
            shell.openExternal(serverUrl);
            this.showNotification('Web UI opened in browser');
        } catch (error) {
            console.error('Failed to open web UI:', error);
            this.showNotification('Failed to open web UI');
        }
    }

    showQRCode() {
        const serverUrl = this.getServerURL();

        // Create QR code window
        const qrWindow = new BrowserWindow({
            width: 400,
            height: 500,
            parent: this.mainWindow,
            modal: true,
            webPreferences: {
                nodeIntegration: false,
                contextIsolation: true
            },
            title: 'Share Server - QR Code'
        });

        // Create a simple HTML page with QR code
        const qrHtml = `
            <!DOCTYPE html>
            <html>
            <head>
                <title>VoiceLink Server QR Code</title>
                <style>
                    body {
                        font-family: -apple-system, BlinkMacSystemFont, sans-serif;
                        text-align: center;
                        padding: 20px;
                        background: #f5f5f5;
                    }
                    .container { background: white; padding: 30px; border-radius: 10px; box-shadow: 0 2px 10px rgba(0,0,0,0.1); }
                    .url {
                        background: #e8e8e8;
                        padding: 10px;
                        border-radius: 5px;
                        font-family: monospace;
                        margin: 20px 0;
                        word-break: break-all;
                    }
                    button {
                        background: #007AFF;
                        color: white;
                        border: none;
                        padding: 10px 20px;
                        border-radius: 5px;
                        cursor: pointer;
                        margin: 5px;
                    }
                    button:hover { background: #0056CC; }
                </style>
            </head>
            <body>
                <div class="container">
                    <h2>VoiceLink Local Server</h2>
                    <p>Share this URL with others to connect:</p>
                    <div class="url">${serverUrl}</div>
                    <div id="qr-code" style="margin: 20px 0;">
                        <!-- QR code would go here - for now showing URL -->
                        <div style="border: 2px dashed #ccc; padding: 40px; margin: 20px 0;">
                            <p>QR Code</p>
                            <p style="font-size: 12px; color: #666;">Scan with mobile device</p>
                            <p style="font-size: 10px; color: #999;">${serverUrl}</p>
                        </div>
                    </div>
                    <button onclick="navigator.clipboard.writeText('${serverUrl}'); alert('URL copied!')">
                        Copy URL
                    </button>
                    <button onclick="window.close()">Close</button>
                </div>
            </body>
            </html>
        `;

        qrWindow.loadURL(`data:text/html;charset=utf-8,${encodeURIComponent(qrHtml)}`);
    }

    showPreferences() {
        // Check if preferences window already exists
        if (this.preferencesWindow && !this.preferencesWindow.isDestroyed()) {
            this.preferencesWindow.focus();
            return;
        }

        // Create preferences window
        this.preferencesWindow = new BrowserWindow({
            width: 800,
            height: 700,
            parent: this.mainWindow,
            webPreferences: {
                nodeIntegration: false,
                contextIsolation: true,
                preload: path.join(__dirname, 'preload.js')
            },
            title: 'VoiceLink Preferences'
        });

        // Load preferences page
        const preferencesPath = path.join(__dirname, '..', 'client', 'preferences.html');
        this.preferencesWindow.loadFile(preferencesPath);

        // Handle window closed
        this.preferencesWindow.on('closed', () => {
            this.preferencesWindow = null;
        });
    }

    async restartServer() {
        console.log('Restarting server...');

        try {
            await this.stopServer();
            await new Promise(resolve => setTimeout(resolve, 1000)); // Wait 1 second
            await this.startServer();
            this.showNotification('Server restarted successfully');
        } catch (error) {
            console.error('Failed to restart server:', error);
            this.showNotification('Failed to restart server');
        }
    }

    async stopServer() {
        console.log('Stopping server...');

        try {
            if (this.httpServer) {
                this.httpServer.close();
            }
            if (this.socketServer) {
                this.socketServer.close();
            }

            this.isServerRunning = false;
            this.serverStartTime = null;
            this.updateTrayMenu();

            console.log('Server stopped');
            this.showNotification('Server stopped');
        } catch (error) {
            console.error('Failed to stop server:', error);
        }
    }

    cleanup() {
        console.log('Cleaning up...');

        if (this.httpServer) {
            this.httpServer.close();
        }

        if (this.socketServer) {
            this.socketServer.close();
        }
    }
}

// Create app instance
const voiceLinkApp = new VoiceLinkApp();

// Handle uncaught exceptions
process.on('uncaughtException', (error) => {
    console.error('Uncaught Exception:', error);
});

process.on('unhandledRejection', (reason, promise) => {
    console.error('Unhandled Rejection at:', promise, 'reason:', reason);
});
