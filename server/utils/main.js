const { app, BrowserWindow, Menu, ipcMain } = require('electron');
const path = require('path');
const { spawn } = require('child_process');

let mainWindow;
let localServer;

class VoiceLinkLocal {
    constructor() {
        this.setupApp();
        this.setupIPC();
        this.startLocalServer();
    }

    setupApp() {
        app.whenReady().then(() => {
            this.createWindow();
            this.setupMenus();
        });

        app.on('window-all-closed', () => {
            if (localServer) {
                localServer.kill();
            }
            if (process.platform !== 'darwin') {
                app.quit();
            }
        });

        app.on('activate', () => {
            if (BrowserWindow.getAllWindows().length === 0) {
                this.createWindow();
            }
        });
    }

    createWindow() {
        mainWindow = new BrowserWindow({
            width: 1400,
            height: 900,
            minWidth: 1000,
            minHeight: 700,
            webPreferences: {
                nodeIntegration: false,
                contextIsolation: true,
                enableRemoteModule: false,
                preload: path.join(__dirname, 'preload.js'),
                webSecurity: false // Allow localhost connections
            },
            titleBarStyle: process.platform === 'darwin' ? 'hiddenInset' : 'default',
            icon: path.join(__dirname, '..', 'assets', 'icon.png'),
            show: false
        });

        // Wait for local server to start
        setTimeout(() => {
            mainWindow.loadURL('http://localhost:3001');
        }, 2000);

        mainWindow.once('ready-to-show', () => {
            mainWindow.show();
            if (process.argv.includes('--dev')) {
                mainWindow.webContents.openDevTools();
            }
        });

        mainWindow.on('closed', () => {
            mainWindow = null;
        });
    }

    startLocalServer() {
        console.log('Starting VoiceLink local server...');
        localServer = spawn('node', [path.join(__dirname, '..', 'server', 'local-server.js')], {
            cwd: path.join(__dirname, '..'),
            stdio: 'inherit'
        });

        localServer.on('error', (err) => {
            console.error('Failed to start local server:', err);
        });

        localServer.on('close', (code) => {
            console.log(`Local server exited with code ${code}`);
        });
    }

    setupMenus() {
        const template = [
            {
                label: 'VoiceLink',
                submenu: [
                    {
                        label: 'New Room',
                        accelerator: 'CmdOrCtrl+N',
                        click: () => {
                            if (mainWindow) {
                                mainWindow.webContents.send('menu-new-room');
                            }
                        }
                    },
                    {
                        label: 'Join Room',
                        accelerator: 'CmdOrCtrl+J',
                        click: () => {
                            if (mainWindow) {
                                mainWindow.webContents.send('menu-join-room');
                            }
                        }
                    },
                    { type: 'separator' },
                    {
                        label: 'Settings',
                        accelerator: 'CmdOrCtrl+,',
                        click: () => {
                            if (mainWindow) {
                                mainWindow.webContents.send('menu-settings');
                            }
                        }
                    },
                    { type: 'separator' },
                    { role: 'quit' }
                ]
            },
            {
                label: 'Audio',
                submenu: [
                    {
                        label: 'Test Microphone',
                        click: () => {
                            if (mainWindow) {
                                mainWindow.webContents.send('menu-test-mic');
                            }
                        }
                    },
                    {
                        label: 'Test Speakers',
                        click: () => {
                            if (mainWindow) {
                                mainWindow.webContents.send('menu-test-speakers');
                            }
                        }
                    },
                    { type: 'separator' },
                    {
                        label: 'Audio Routing',
                        click: () => {
                            if (mainWindow) {
                                mainWindow.webContents.send('menu-audio-routing');
                            }
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
            }
        ];

        if (process.platform === 'darwin') {
            template[0].label = app.getName();
            template[0].submenu.unshift(
                { role: 'about' },
                { type: 'separator' }
            );
        }

        const menu = Menu.buildFromTemplate(template);
        Menu.setApplicationMenu(menu);
    }

    setupIPC() {
        ipcMain.handle('get-app-version', () => {
            return app.getVersion();
        });

        ipcMain.handle('get-server-status', () => {
            return localServer ? 'running' : 'stopped';
        });
    }
}

// Initialize the application
new VoiceLinkLocal();

module.exports = VoiceLinkLocal;