/**
 * VoiceLink Local - Main Electron Process
 * Handles window management, server startup, system integration, and menubar
 */

const { app, BrowserWindow, Menu, Tray, dialog, shell, ipcMain, nativeImage } = require('electron');
const path = require('path');
const fs = require('fs');
const os = require('os');
const { spawn, exec } = require('child_process');

// Server setup
const express = require('express');
const http = require('http');
const socketIo = require('socket.io');
const cors = require('cors');

// System integration
const AutoLaunch = require('auto-launch');
const RobustSettingsManager = require('./settings-manager');
const UpdateChecker = require('./update-checker');

class VoiceLinkApp {
    constructor() {
        this.mainWindow = null;
        this.tray = null;
        this.serverInstance = null;
        this.httpServer = null;
        this.socketServer = null;
        this.serverPort = 3000;
        this.rooms = new Map();
        this.users = new Map();

        // Configuration and state
        this.settings = new RobustSettingsManager();
        this.autoLauncher = null;
        this.updateChecker = new UpdateChecker();
        this.localIP = null;
        this.externalIP = null;
        this.serverStartTime = null;
        this.isServerRunning = false;

        this.isDev = process.argv.includes('--dev');
        this.isPortable = process.env.PORTABLE === 'true' || process.argv.includes('--portable');

        this.init();
    }

    init() {
        console.log('Initializing VoiceLink Local...');

        // Prevent background throttling to keep audio alive
        app.commandLine.appendSwitch('disable-background-timer-throttling');
        app.commandLine.appendSwitch('disable-backgrounding-occluded-windows');
        app.commandLine.appendSwitch('disable-renderer-backgrounding');

        // Implement single instance lock
        const gotTheLock = app.requestSingleInstanceLock();

        if (!gotTheLock) {
            console.log('Another instance is already running, exiting...');
            app.quit();
            return;
        }

        // Handle second-instance (when user tries to open app again)
        app.on('second-instance', (event, commandLine, workingDirectory) => {
            console.log('Second instance detected - focusing existing window');
            // If window exists, show and focus it
            if (this.mainWindow) {
                if (this.mainWindow.isMinimized()) {
                    this.mainWindow.restore();
                }
                if (!this.mainWindow.isVisible()) {
                    this.mainWindow.show();
                }
                this.mainWindow.focus();
                this.mainWindow.moveTop();
            }
        });

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
            // Get local IP addresses
            const networkInterfaces = os.networkInterfaces();
            for (const [name, interfaces] of Object.entries(networkInterfaces)) {
                for (const netInterface of interfaces) {
                    if (netInterface.family === 'IPv4' && !netInterface.internal) {
                        this.localIP = netInterface.address;
                        break;
                    }
                }
                if (this.localIP) break;
            }

            console.log('Local IP detected:', this.localIP);

            // Detect external IP (optional, for future use)
            this.detectExternalIP();

        } catch (error) {
            console.error('Failed to detect network info:', error);
            this.localIP = '127.0.0.1';
        }
    }

    async detectExternalIP() {
        try {
            // Note: This would require internet access
            // For now, we'll focus on local network functionality
            this.externalIP = null;
        } catch (error) {
            console.error('Failed to detect external IP:', error);
        }
    }

    setupAppEvents() {
        // App ready
        app.whenReady().then(() => {
            this.createTray();
            this.startServer();
            this.createMenu();

            // Check for startup settings
            const autoOpenWebUI = this.settings.get('autoOpenWebUIAndMinimize', false);
            const autoMinimize = this.settings.get('autoMinimize', false);

            // Create window only if not launched minimized or auto-open web UI is enabled
            if (!this.settings.get('startMinimized', false) && !autoMinimize || autoOpenWebUI || this.isDev) {
                this.createWindow();

                // Handle auto-open web UI functionality
                if (autoOpenWebUI) {
                    setTimeout(() => {
                        this.openWebUI();
                        if (this.mainWindow) {
                            this.mainWindow.hide();
                            this.showNotification('VoiceLink web interface opened. App minimized to tray.');
                        }
                    }, 2000); // Wait 2 seconds for server to be fully ready
                }
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
            } else if (process.platform === 'darwin') {
                // On macOS, ensure app continues running in dock/menubar
                console.log('All windows closed on macOS - app continues in menubar');
            }
            // Reset main window reference
            this.mainWindow = null;
        });

        // Before quit
        app.on('before-quit', (event) => {
            // On macOS, prevent quitting with Command+Q and minimize to tray instead
            if (process.platform === 'darwin' && !this.forceQuit) {
                event.preventDefault();
                if (this.mainWindow) {
                    this.mainWindow.hide();
                    if (!this.hasShownTrayNotification) {
                        this.showNotification('VoiceLink minimized to menubar. Use menubar icon to restore or quit.');
                        this.hasShownTrayNotification = true;
                    }
                }
                return;
            }
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
        const uptime = this.getUptime();

        const contextMenu = Menu.buildFromTemplate([
            {
                label: `VoiceLink Local v${app.getVersion()}`,
                enabled: false
            },
            { type: 'separator' },
            {
                label: `Server: ${this.isServerRunning ? 'Running' : 'Stopped'}`,
                enabled: false
            },
            {
                label: `${serverUrl}`,
                click: () => {
                    require('electron').clipboard.writeText(serverUrl);
                    this.showNotification('Server URL copied to clipboard');
                }
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
                label: '🖥️ Desktop Interface',
                submenu: [
                    {
                        label: 'Show Desktop App',
                        click: () => this.showMainWindow()
                    },
                    {
                        label: 'Application Settings...',
                        click: () => this.openPreferences()
                    }
                ]
            },
            {
                label: '🌐 Web Interface',
                submenu: [
                    {
                        label: 'Open Web UI',
                        click: () => this.openWebUI(),
                        enabled: this.isServerRunning
                    },
                    {
                        label: 'Copy Server URL',
                        click: () => {
                            require('electron').clipboard.writeText(serverUrl);
                            this.showNotification('Server URL copied to clipboard');
                        }
                    },
                    {
                        label: 'Share QR Code',
                        click: () => this.showQRCode()
                    }
                ]
            },
            { type: 'separator' },
            {
                label: 'Check for Updates...',
                click: () => this.updateChecker.checkForUpdatesManual()
            },
            { type: 'separator' },
            {
                label: 'Restart Server',
                click: () => this.restartServer()
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
                webSecurity: !this.isDev,
                backgroundThrottling: false // Keep audio alive in background
            },
            icon: this.getAppIcon(),
            show: false,
            titleBarStyle: process.platform === 'darwin' ? 'hiddenInset' : 'default',
            skipTaskbar: false, // Allow window to appear in dock on macOS
            minimizable: true,
            maximizable: true,
            closable: true
        });

        // Load the app
        const indexPath = path.join(__dirname, '..', 'client', 'index.html');
        this.mainWindow.loadFile(indexPath);

        // Show window when ready
        this.mainWindow.once('ready-to-show', () => {
            // Check for startup settings
            const autoMinimizeOnStart = this.settings.get('autoMinimizeOnStart', false);
            const startMinimized = this.settings.get('startMinimized', false);
            const autoMinimizeSetting = this.settings.get('autoMinimize', false);
            const autoOpenWebUI = this.settings.get('autoOpenWebUIAndMinimize', false);

            if (autoMinimizeOnStart || startMinimized || autoMinimizeSetting || autoOpenWebUI) {
                // Start minimized to tray
                if (!this.hasShownTrayNotification && !autoOpenWebUI) {
                    this.showNotification('VoiceLink started in menubar. Server is ready for connections.');
                    this.hasShownTrayNotification = true;
                }
                // Don't show the window - it stays hidden (unless auto-open web UI handles it)
            } else {
                this.mainWindow.show();
            }

            if (this.isDev) {
                this.mainWindow.webContents.openDevTools();
            }
        });

        // Handle window closed
        this.mainWindow.on('closed', () => {
            this.mainWindow = null;
        });

        // Handle close button (hide to tray instead of quit)
        this.mainWindow.on('close', (event) => {
            if (!this.forceQuit && this.settings.get('hideToTrayOnClose', true)) {
                event.preventDefault();

                // On macOS, properly hide the window without leaving blank windows
                if (process.platform === 'darwin') {
                    this.mainWindow.setClosable(false);
                    this.mainWindow.hide();
                    this.mainWindow.setClosable(true);
                } else {
                    this.mainWindow.hide();
                }

                // Always show notification when minimized
                const userCount = Array.from(this.rooms.values()).reduce((sum, room) => sum + room.users.size, 0);
                const message = userCount > 0
                    ? `VoiceLink minimized to menubar. ${userCount} user(s) still connected.`
                    : 'VoiceLink minimized to menubar. Server continues running.';
                this.showNotification(message);
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

    playConnectedSound() {
        try {
            // Check if sound effects are enabled in settings
            const enableSounds = this.settings.get('enableEffects', true);
            if (!enableSounds) {
                return;
            }

            // Path to the connected sound file
            const soundPath = path.join(__dirname, '..', 'assets', 'sounds', 'connected.wav');

            // Check if the sound file exists
            if (fs.existsSync(soundPath)) {
                // Use shell command to play the sound (cross-platform)

                if (process.platform === 'darwin') {
                    // macOS
                    exec(`afplay "${soundPath}"`, (error) => {
                        if (error) {
                            console.log('Note: Could not play connected sound:', error.message);
                        }
                    });
                } else if (process.platform === 'win32') {
                    // Windows
                    exec(`powershell -c "(New-Object Media.SoundPlayer '${soundPath}').PlaySync();"`, (error) => {
                        if (error) {
                            console.log('Note: Could not play connected sound:', error.message);
                        }
                    });
                } else {
                    // Linux
                    exec(`aplay "${soundPath}" 2>/dev/null || paplay "${soundPath}" 2>/dev/null`, (error) => {
                        if (error) {
                            console.log('Note: Could not play connected sound:', error.message);
                        }
                    });
                }

                console.log('Playing connected sound notification');
            } else {
                console.log('Connected sound file not found at:', soundPath);
            }
        } catch (error) {
            console.log('Error playing connected sound:', error.message);
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

            // Start listening
            await new Promise((resolve, reject) => {
                this.httpServer.listen(this.serverPort, (err) => {
                    if (err) {
                        reject(err);
                    } else {
                        this.isServerRunning = true;
                        this.serverStartTime = Date.now();
                        console.log(`Server running on port ${this.serverPort}`);
                        this.updateTrayMenu();

                        // Play connected sound when server starts successfully
                        this.playConnectedSound();

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
                this.httpServer.listen(this.serverPort, (err) => {
                    if (err) {
                        reject(err);
                    } else {
                        console.log(`Server running on port ${this.serverPort}`);
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
        // Set up session management for web UI authentication
        const session = require('express-session');
        this.serverInstance.use(session({
            secret: this.settings.get('webSessionSecret', 'voicelink-local-secret-' + Date.now()),
            resave: false,
            saveUninitialized: false,
            cookie: { secure: false, maxAge: 24 * 60 * 60 * 1000 } // 24 hours
        }));

        // Web UI login page
        this.serverInstance.get('/admin/login', (req, res) => {
            if (req.session.authenticated) {
                return res.redirect('/admin');
            }

            res.send(this.generateLoginPage());
        });

        // Web UI login handler
        this.serverInstance.post('/admin/login', (req, res) => {
            const { username, password } = req.body;
            const adminPassword = this.settings.get('webAdminPassword', null);

            // If no password is set, create a default one
            if (!adminPassword) {
                const defaultPassword = 'admin' + Math.random().toString(36).substr(2, 8);
                this.settings.set('webAdminPassword', defaultPassword);
                this.showNotification(`Web UI admin password set to: ${defaultPassword}`);
            }

            const currentPassword = this.settings.get('webAdminPassword');
            if (username === 'admin' && password === currentPassword) {
                req.session.authenticated = true;
                req.session.loginTime = Date.now();
                res.json({ success: true, redirect: '/admin' });
            } else {
                res.status(401).json({ success: false, error: 'Invalid credentials' });
            }
        });

        // Web UI logout
        this.serverInstance.get('/admin/logout', (req, res) => {
            req.session.destroy();
            res.redirect('/admin/login');
        });

        // Admin authentication middleware
        const requireAuth = (req, res, next) => {
            // Desktop app bypasses authentication
            const userAgent = req.get('User-Agent') || '';
            if (userAgent.includes('Electron')) {
                return next();
            }

            if (req.session.authenticated) {
                return next();
            }

            res.redirect('/admin/login');
        };

        // Admin panel route (protected)
        this.serverInstance.get('/admin', requireAuth, (req, res) => {
            res.send(this.generateAdminPanel());
        });

        // Health check
        this.serverInstance.get('/health', (req, res) => {
            res.json({ status: 'ok', timestamp: Date.now() });
        });

        // Get rooms
        this.serverInstance.get('/api/rooms', (req, res) => {
            const roomList = Array.from(this.rooms.values()).map(room => ({
                id: room.id,
                name: room.name,
                description: room.description,
                userCount: room.users.size,
                maxUsers: room.maxUsers,
                hasPassword: !!room.password,
                createdAt: room.createdAt
            }));

            res.json(roomList);
        });

        // Settings API endpoints (protected by auth middleware)
        this.serverInstance.get('/api/settings', requireAuth, (req, res) => {
            res.json(this.settings.getAll());
        });

        this.serverInstance.get('/api/settings/:key', requireAuth, (req, res) => {
            const { key } = req.params;
            const { defaultValue } = req.query;
            const value = this.settings.get(key, defaultValue);
            res.json({ key, value });
        });

        this.serverInstance.post('/api/settings/:key', requireAuth, (req, res) => {
            const { key } = req.params;
            const { value } = req.body;

            this.settings.set(key, value);
            this.updateTrayMenu(); // Update tray menu when settings change

            res.json({ success: true, key, value });
        });

        this.serverInstance.post('/api/settings', requireAuth, (req, res) => {
            const settings = req.body;

            Object.entries(settings).forEach(([key, value]) => {
                this.settings.set(key, value);
            });

            this.updateTrayMenu(); // Update tray menu when settings change

            res.json({ success: true, updated: Object.keys(settings).length });
        });

        // Create room
        this.serverInstance.post('/api/rooms', (req, res) => {
            const { name, description, password, maxUsers } = req.body;

            if (!name) {
                return res.status(400).json({ error: 'Room name is required' });
            }

            const roomId = this.generateRoomId();
            const room = {
                id: roomId,
                name,
                description: description || null,
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
                localIP: this.localIP,
                externalIP: this.externalIP,
                isPortable: this.isPortable,
                isDev: this.isDev,
                isRunning: this.isServerRunning,
                uptime: this.getUptime(),
                roomCount: this.rooms.size,
                userCount: Array.from(this.rooms.values()).reduce((sum, room) => sum + room.users.size, 0)
            };
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
                    },
                    { type: 'separator' },
                    {
                        label: 'Check for Updates...',
                        click: () => {
                            this.updateChecker.checkForUpdatesManual();
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
                        label: 'Preferences...',
                        accelerator: 'Cmd+,',
                        click: () => {
                            if (this.mainWindow) {
                                this.mainWindow.webContents.send('show-settings');
                            }
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
            webPreferences: {
                nodeIntegration: false,
                contextIsolation: true,
                preload: path.join(__dirname, 'preload.js')
            },
            title: 'VoiceLink Preferences',
            icon: this.getAppIcon(),
            show: false,
            resizable: true,
            minimizable: true,
            maximizable: true,
            closable: true
        });

        // Load preferences page
        const preferencesPath = path.join(__dirname, '..', 'client', 'preferences.html');
        this.preferencesWindow.loadFile(preferencesPath);

        // Show window when ready to prevent flash
        this.preferencesWindow.once('ready-to-show', () => {
            this.preferencesWindow.show();
            this.preferencesWindow.focus();
        });

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

    generateLoginPage() {
        return `
            <!DOCTYPE html>
            <html lang="en">
            <head>
                <meta charset="UTF-8">
                <meta name="viewport" content="width=device-width, initial-scale=1.0">
                <title>VoiceLink Admin Login</title>
                <style>
                    body {
                        font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
                        background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
                        margin: 0;
                        padding: 0;
                        height: 100vh;
                        display: flex;
                        justify-content: center;
                        align-items: center;
                    }
                    .login-container {
                        background: white;
                        border-radius: 12px;
                        padding: 2rem;
                        box-shadow: 0 10px 30px rgba(0,0,0,0.2);
                        width: 300px;
                        text-align: center;
                    }
                    .logo {
                        font-size: 2rem;
                        margin-bottom: 1rem;
                        color: #667eea;
                    }
                    h1 {
                        margin: 0 0 1.5rem 0;
                        color: #333;
                        font-size: 1.5rem;
                    }
                    .form-group {
                        margin-bottom: 1rem;
                        text-align: left;
                    }
                    label {
                        display: block;
                        margin-bottom: 0.5rem;
                        color: #555;
                        font-weight: 500;
                    }
                    input[type="text"], input[type="password"] {
                        width: 100%;
                        padding: 0.75rem;
                        border: 2px solid #ddd;
                        border-radius: 8px;
                        font-size: 1rem;
                        box-sizing: border-box;
                        transition: border-color 0.3s;
                    }
                    input[type="text"]:focus, input[type="password"]:focus {
                        outline: none;
                        border-color: #667eea;
                    }
                    .login-btn {
                        width: 100%;
                        padding: 0.75rem;
                        background: linear-gradient(45deg, #667eea, #764ba2);
                        color: white;
                        border: none;
                        border-radius: 8px;
                        font-size: 1rem;
                        cursor: pointer;
                        margin-top: 1rem;
                        transition: transform 0.2s;
                    }
                    .login-btn:hover {
                        transform: translateY(-2px);
                    }
                    .error {
                        color: #e74c3c;
                        margin-top: 1rem;
                        font-size: 0.9rem;
                    }
                    .info {
                        color: #666;
                        font-size: 0.8rem;
                        margin-top: 1rem;
                        line-height: 1.4;
                    }
                </style>
            </head>
            <body>
                <div class="login-container">
                    <div class="logo">🎤</div>
                    <h1>VoiceLink Admin</h1>
                    <form id="loginForm">
                        <div class="form-group">
                            <label for="username">Username:</label>
                            <input type="text" id="username" name="username" value="admin" required>
                        </div>
                        <div class="form-group">
                            <label for="password">Password:</label>
                            <input type="password" id="password" name="password" required>
                        </div>
                        <button type="submit" class="login-btn">Login</button>
                    </form>
                    <div id="error" class="error" style="display:none;"></div>
                    <div class="info">
                        Admin access is required to configure VoiceLink server settings via web interface.
                        Desktop app users have automatic admin privileges.
                    </div>
                </div>

                <script>
                    document.getElementById('loginForm').addEventListener('submit', async (e) => {
                        e.preventDefault();

                        const username = document.getElementById('username').value;
                        const password = document.getElementById('password').value;
                        const errorDiv = document.getElementById('error');

                        try {
                            const response = await fetch('/admin/login', {
                                method: 'POST',
                                headers: {
                                    'Content-Type': 'application/json',
                                },
                                body: JSON.stringify({ username, password })
                            });

                            const result = await response.json();

                            if (result.success) {
                                window.location.href = result.redirect;
                            } else {
                                errorDiv.textContent = result.error;
                                errorDiv.style.display = 'block';
                            }
                        } catch (error) {
                            errorDiv.textContent = 'Login failed. Please try again.';
                            errorDiv.style.display = 'block';
                        }
                    });
                </script>
            </body>
            </html>
        `;
    }

    generateAdminPanel() {
        const serverUrl = this.getServerURL();
        const uptime = this.getUptime();
        const userCount = Array.from(this.rooms.values()).reduce((sum, room) => sum + room.users.size, 0);
        const roomCount = this.rooms.size;
        const isFromDesktop = this.mainWindow && this.mainWindow.webContents;

        return `
            <!DOCTYPE html>
            <html lang="en">
            <head>
                <meta charset="UTF-8">
                <meta name="viewport" content="width=device-width, initial-scale=1.0">
                <title>VoiceLink Admin Panel</title>
                <style>
                    body {
                        font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
                        background: #f5f5f5;
                        margin: 0;
                        padding: 0;
                    }
                    .header {
                        background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
                        color: white;
                        padding: 1rem 2rem;
                        display: flex;
                        justify-content: space-between;
                        align-items: center;
                    }
                    .header h1 {
                        margin: 0;
                        font-size: 1.5rem;
                    }
                    .logout-btn {
                        background: rgba(255,255,255,0.2);
                        color: white;
                        border: 1px solid rgba(255,255,255,0.3);
                        padding: 0.5rem 1rem;
                        border-radius: 6px;
                        text-decoration: none;
                        transition: background 0.3s;
                    }
                    .logout-btn:hover {
                        background: rgba(255,255,255,0.3);
                    }
                    .container {
                        max-width: 1200px;
                        margin: 0 auto;
                        padding: 2rem;
                    }
                    .stats-grid {
                        display: grid;
                        grid-template-columns: repeat(auto-fit, minmax(200px, 1fr));
                        gap: 1rem;
                        margin-bottom: 2rem;
                    }
                    .stat-card {
                        background: white;
                        padding: 1.5rem;
                        border-radius: 12px;
                        box-shadow: 0 2px 10px rgba(0,0,0,0.1);
                        text-align: center;
                    }
                    .stat-number {
                        font-size: 2rem;
                        font-weight: bold;
                        color: #667eea;
                        margin-bottom: 0.5rem;
                    }
                    .stat-label {
                        color: #666;
                        font-size: 0.9rem;
                    }
                    .section {
                        background: white;
                        border-radius: 12px;
                        padding: 2rem;
                        margin-bottom: 2rem;
                        box-shadow: 0 2px 10px rgba(0,0,0,0.1);
                    }
                    .section h2 {
                        margin-top: 0;
                        color: #333;
                        border-bottom: 2px solid #667eea;
                        padding-bottom: 0.5rem;
                    }
                    .info-note {
                        background: #e8f4fd;
                        border-left: 4px solid #667eea;
                        padding: 1rem;
                        margin: 1rem 0;
                        border-radius: 4px;
                    }
                    .access-type {
                        display: inline-block;
                        padding: 0.25rem 0.75rem;
                        border-radius: 20px;
                        font-size: 0.8rem;
                        font-weight: bold;
                        margin-left: 1rem;
                    }
                    .desktop-access {
                        background: #2ecc71;
                        color: white;
                    }
                    .web-access {
                        background: #3498db;
                        color: white;
                    }
                </style>
            </head>
            <body>
                <div class="header">
                    <h1>🎤 VoiceLink Admin Panel
                        <span class="access-type ${isFromDesktop ? 'desktop-access' : 'web-access'}">
                            ${isFromDesktop ? '🖥️ Desktop' : '🌐 Web'} Access
                        </span>
                    </h1>
                    ${!isFromDesktop ? '<a href="/admin/logout" class="logout-btn">Logout</a>' : ''}
                </div>

                <div class="container">
                    <div class="stats-grid">
                        <div class="stat-card">
                            <div class="stat-number">${userCount}</div>
                            <div class="stat-label">Connected Users</div>
                        </div>
                        <div class="stat-card">
                            <div class="stat-number">${roomCount}</div>
                            <div class="stat-label">Active Rooms</div>
                        </div>
                        <div class="stat-card">
                            <div class="stat-number">${uptime}</div>
                            <div class="stat-label">Server Uptime</div>
                        </div>
                        <div class="stat-card">
                            <div class="stat-number">${this.isServerRunning ? 'Online' : 'Offline'}</div>
                            <div class="stat-label">Server Status</div>
                        </div>
                    </div>

                    <div class="section">
                        <h2>Server Information</h2>
                        <p><strong>Server URL:</strong> <a href="${serverUrl}" target="_blank">${serverUrl}</a></p>
                        <p><strong>Port:</strong> ${this.serverPort}</p>
                        <p><strong>Local IP:</strong> ${this.localIP || 'Detecting...'}</p>
                        <p><strong>Started:</strong> ${new Date(this.serverStartTime).toLocaleString()}</p>

                        <div class="info-note">
                            <strong>Access Control:</strong><br>
                            • Desktop app users have automatic admin privileges<br>
                            • Web users require authentication for admin functions<br>
                            • Same settings are shared between both interfaces
                        </div>
                    </div>

                    <div class="section">
                        <h2>Interface Options</h2>
                        <p><strong>🖥️ Desktop Interface:</strong> Full admin access with native app features</p>
                        <p><strong>🌐 Web Interface:</strong> Browser-based access for remote administration</p>

                        <div class="info-note">
                            Both interfaces use the same configuration and settings.
                            Changes made in one interface are immediately available in the other.
                        </div>
                    </div>
                </div>
            </body>
            </html>
        `;
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