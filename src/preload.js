const { contextBridge, ipcRenderer } = require('electron');

// Expose protected methods that allow the renderer process to use
// the ipcRenderer without exposing the entire object
contextBridge.exposeInMainWorld('electronAPI', {
    getAppVersion: () => ipcRenderer.invoke('get-app-version'),
    getServerStatus: () => ipcRenderer.invoke('get-server-status'),

    // Settings management
    getAllSettings: () => ipcRenderer.invoke('get-all-settings'),
    getSetting: (key) => ipcRenderer.invoke('get-setting', key),
    setSetting: (key, value) => ipcRenderer.invoke('set-setting', key, value),

    // Server information
    getServerInfo: () => ipcRenderer.invoke('get-server-info'),
    restartServer: () => ipcRenderer.invoke('restart-server'),
    copyServerUrl: () => ipcRenderer.invoke('copy-server-url'),
    showQRCode: () => ipcRenderer.invoke('show-qr-code'),

    // Network management
    getNetworkInterfaces: () => ipcRenderer.invoke('get-network-interfaces'),
    setNetworkInterface: (interfaceName) => ipcRenderer.invoke('set-network-interface', interfaceName),
    refreshNetworkInfo: () => ipcRenderer.invoke('refresh-network-info'),
    copyUrl: (urlType) => ipcRenderer.invoke('copy-url', urlType),

    // Auto launch management
    getAutoLaunchEnabled: () => ipcRenderer.invoke('get-auto-launch-enabled'),
    setAutoLaunchEnabled: (enabled) => ipcRenderer.invoke('set-auto-launch-enabled', enabled),

    // Window management
    minimizeToTray: () => ipcRenderer.invoke('minimize-to-tray'),
    showPreferences: () => ipcRenderer.invoke('show-preferences'),

    // Menu event listeners
    onMenuNewRoom: (callback) => ipcRenderer.on('menu-new-room', callback),
    onMenuJoinRoom: (callback) => ipcRenderer.on('menu-join-room', callback),
    onMenuSettings: (callback) => ipcRenderer.on('menu-settings', callback),
    onMenuTestMic: (callback) => ipcRenderer.on('menu-test-mic', callback),
    onMenuTestSpeakers: (callback) => ipcRenderer.on('menu-test-speakers', callback),
    onMenuAudioRouting: (callback) => ipcRenderer.on('menu-audio-routing', callback),

    // Network info update listener
    onNetworkInfoUpdated: (callback) => ipcRenderer.on('network-info-updated', (event, data) => callback(data))
});

// Expose Node.js info
contextBridge.exposeInMainWorld('nodeAPI', {
    platform: process.platform,
    versions: process.versions
});