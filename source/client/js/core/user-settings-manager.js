/**
 * User Settings Manager
 * Manages persistent user settings with global and per-server/room configurations
 */

class UserSettingsManager {
    constructor() {
        this.globalSettings = new Map();
        this.serverSettings = new Map(); // serverId -> settings
        this.roomSettings = new Map(); // roomId -> settings
        this.currentServerId = null;
        this.currentRoomId = null;

        // Available user status types
        this.statusTypes = {
            online: {
                label: 'Online',
                color: '#00ff00',
                icon: '🟢',
                description: 'Available and active'
            },
            away: {
                label: 'Away',
                color: '#ffff00',
                icon: '🟡',
                description: 'Away from computer'
            },
            busy: {
                label: 'Busy',
                color: '#ff6600',
                icon: '🟠',
                description: 'Do not disturb'
            },
            working: {
                label: 'Working',
                color: '#0066ff',
                icon: '🔵',
                description: 'Working - limited availability'
            },
            gaming: {
                label: 'Gaming',
                color: '#9900ff',
                icon: '🎮',
                description: 'Gaming - may not respond'
            },
            streaming: {
                label: 'Streaming',
                color: '#ff0066',
                icon: '📺',
                description: 'Live streaming'
            },
            recording: {
                label: 'Recording',
                color: '#ff0000',
                icon: '🔴',
                description: 'Recording audio/video'
            },
            meeting: {
                label: 'In Meeting',
                color: '#990000',
                icon: '📞',
                description: 'In a meeting'
            },
            offline: {
                label: 'Offline',
                color: '#666666',
                icon: '⚫',
                description: 'Not available'
            },
            invisible: {
                label: 'Invisible',
                color: '#333333',
                icon: '👻',
                description: 'Appear offline to others'
            }
        };

        // Default global settings
        this.defaultGlobalSettings = {
            // User Identity
            nickname: 'User',
            displayName: '',
            avatar: '',

            // Status & Presence
            status: 'online',
            customStatus: '',
            statusMessage: '',
            signature: '',

            // Privacy Settings
            showOnlineStatus: true,
            allowDirectMessages: true,
            showTypingIndicator: true,
            showLastSeen: true,

            // Audio Preferences
            defaultVolume: 100,
            microphoneGain: 100,
            pushToTalkKey: 'Space',
            voiceActivation: false,
            noiseSuppression: true,
            echoCancellation: true,

            // Appearance
            theme: 'dark',
            fontSize: 'medium',
            compactMode: false,
            showAvatars: true,

            // Notifications
            soundNotifications: true,
            desktopNotifications: true,
            mentionSound: true,
            joinLeaveNotifications: false,

            // Behavior
            autoJoinLastRoom: false,
            rememberWindowSize: true,
            minimizeToTray: false,
            startMinimized: false,

            // Media Streaming
            defaultStreamQuality: 'medium',
            crossfadeEnabled: false,
            autoPlayNext: true,
            saveQueue: true,
            spatialAudioMedia: true,
            duckingMedia: false,
            mediaCacheSize: 100,
            enableVisualization: true
        };

        // Per-server/room overrideable settings
        this.serverOverrideableSettings = [
            'nickname',
            'displayName',
            'status',
            'customStatus',
            'statusMessage',
            'signature',
            'defaultVolume',
            'pushToTalkKey',
            'voiceActivation'
        ];

        this.init();
    }

    init() {
        // Initialize global settings with defaults
        Object.entries(this.defaultGlobalSettings).forEach(([key, value]) => {
            this.globalSettings.set(key, value);
        });

        // Load saved settings
        this.loadAllSettings();

        console.log('User Settings Manager initialized');
    }

    /**
     * Get effective setting value (checks room -> server -> global hierarchy)
     */
    getSetting(key) {
        // Check room-specific setting first
        if (this.currentRoomId && this.roomSettings.has(this.currentRoomId)) {
            const roomSettings = this.roomSettings.get(this.currentRoomId);
            if (roomSettings.has(key)) {
                return roomSettings.get(key);
            }
        }

        // Check server-specific setting
        if (this.currentServerId && this.serverSettings.has(this.currentServerId)) {
            const serverSettings = this.serverSettings.get(this.currentServerId);
            if (serverSettings.has(key)) {
                return serverSettings.get(key);
            }
        }

        // Fall back to global setting
        return this.globalSettings.get(key);
    }

    /**
     * Set global setting
     */
    setGlobalSetting(key, value) {
        this.globalSettings.set(key, value);
        this.saveGlobalSettings();
        this.notifySettingChanged(key, value, 'global');
    }

    /**
     * Set server-specific setting
     */
    setServerSetting(serverId, key, value) {
        if (!this.serverOverrideableSettings.includes(key)) {
            console.warn(`Setting ${key} is not overrideable per server`);
            return;
        }

        if (!this.serverSettings.has(serverId)) {
            this.serverSettings.set(serverId, new Map());
        }

        this.serverSettings.get(serverId).set(key, value);
        this.saveServerSettings(serverId);
        this.notifySettingChanged(key, value, 'server', serverId);
    }

    /**
     * Set room-specific setting
     */
    setRoomSetting(roomId, key, value) {
        if (!this.serverOverrideableSettings.includes(key)) {
            console.warn(`Setting ${key} is not overrideable per room`);
            return;
        }

        if (!this.roomSettings.has(roomId)) {
            this.roomSettings.set(roomId, new Map());
        }

        this.roomSettings.get(roomId).set(key, value);
        this.saveRoomSettings(roomId);
        this.notifySettingChanged(key, value, 'room', roomId);
    }

    /**
     * Remove server/room specific setting (fall back to higher level)
     */
    removeServerSetting(serverId, key) {
        if (this.serverSettings.has(serverId)) {
            this.serverSettings.get(serverId).delete(key);
            this.saveServerSettings(serverId);
        }
    }

    removeRoomSetting(roomId, key) {
        if (this.roomSettings.has(roomId)) {
            this.roomSettings.get(roomId).delete(key);
            this.saveRoomSettings(roomId);
        }
    }

    /**
     * Set current context (server/room)
     */
    setCurrentContext(serverId, roomId = null) {
        this.currentServerId = serverId;
        this.currentRoomId = roomId;
        console.log(`Context set to server: ${serverId}, room: ${roomId}`);
    }

    /**
     * Get user status information
     */
    getStatusInfo() {
        const statusKey = this.getSetting('status');
        const statusInfo = this.statusTypes[statusKey] || this.statusTypes.online;

        return {
            status: statusKey,
            ...statusInfo,
            customMessage: this.getSetting('customStatus'),
            statusMessage: this.getSetting('statusMessage')
        };
    }

    /**
     * Set user status
     */
    setStatus(status, customMessage = '', context = 'global', contextId = null) {
        if (!this.statusTypes[status]) {
            console.warn(`Unknown status type: ${status}`);
            return;
        }

        if (context === 'global') {
            this.setGlobalSetting('status', status);
            if (customMessage) {
                this.setGlobalSetting('customStatus', customMessage);
            }
        } else if (context === 'server' && contextId) {
            this.setServerSetting(contextId, 'status', status);
            if (customMessage) {
                this.setServerSetting(contextId, 'customStatus', customMessage);
            }
        } else if (context === 'room' && contextId) {
            this.setRoomSetting(contextId, 'status', status);
            if (customMessage) {
                this.setRoomSetting(contextId, 'customStatus', customMessage);
            }
        }
    }

    /**
     * Get user profile information
     */
    getUserProfile() {
        return {
            nickname: this.getSetting('nickname'),
            displayName: this.getSetting('displayName'),
            avatar: this.getSetting('avatar'),
            signature: this.getSetting('signature'),
            status: this.getStatusInfo()
        };
    }

    /**
     * Set user signature (supports links and formatting)
     */
    setSignature(signature, context = 'global', contextId = null) {
        // Validate and sanitize signature (allow links but prevent XSS)
        const sanitizedSignature = this.sanitizeSignature(signature);

        if (context === 'global') {
            this.setGlobalSetting('signature', sanitizedSignature);
        } else if (context === 'server' && contextId) {
            this.setServerSetting(contextId, 'signature', sanitizedSignature);
        } else if (context === 'room' && contextId) {
            this.setRoomSetting(contextId, 'signature', sanitizedSignature);
        }
    }

    /**
     * Sanitize signature content (allow safe HTML/links)
     */
    sanitizeSignature(signature) {
        // Basic sanitization - in production, use a proper HTML sanitizer
        return signature
            .replace(/<script[^>]*>.*?<\/script>/gi, '')
            .replace(/javascript:/gi, '')
            .replace(/on\w+\s*=/gi, '')
            .trim();
    }

    /**
     * Parse signature for display (convert links to clickable)
     */
    parseSignatureForDisplay(signature) {
        if (!signature) return '';

        // Convert URLs to clickable links
        const urlRegex = /(https?:\/\/[^\s]+)/g;
        return signature.replace(urlRegex, '<a href="$1" target="_blank" rel="noopener noreferrer">$1</a>');
    }

    /**
     * Get all settings for export/backup
     */
    exportAllSettings() {
        return {
            global: Object.fromEntries(this.globalSettings),
            servers: Object.fromEntries(
                Array.from(this.serverSettings.entries()).map(([id, settings]) => [
                    id, Object.fromEntries(settings)
                ])
            ),
            rooms: Object.fromEntries(
                Array.from(this.roomSettings.entries()).map(([id, settings]) => [
                    id, Object.fromEntries(settings)
                ])
            ),
            timestamp: Date.now(),
            version: '1.0.0'
        };
    }

    /**
     * Import settings from backup
     */
    importAllSettings(settingsData) {
        try {
            if (settingsData.global) {
                Object.entries(settingsData.global).forEach(([key, value]) => {
                    this.globalSettings.set(key, value);
                });
            }

            if (settingsData.servers) {
                Object.entries(settingsData.servers).forEach(([serverId, settings]) => {
                    const serverMap = new Map(Object.entries(settings));
                    this.serverSettings.set(serverId, serverMap);
                });
            }

            if (settingsData.rooms) {
                Object.entries(settingsData.rooms).forEach(([roomId, settings]) => {
                    const roomMap = new Map(Object.entries(settings));
                    this.roomSettings.set(roomId, roomMap);
                });
            }

            this.saveAllSettings();
            console.log('Settings imported successfully');
            return true;
        } catch (error) {
            console.error('Failed to import settings:', error);
            return false;
        }
    }

    /**
     * Save settings to localStorage
     */
    saveGlobalSettings() {
        const settings = Object.fromEntries(this.globalSettings);
        localStorage.setItem('voicelink_global_settings', JSON.stringify(settings));
    }

    saveServerSettings(serverId) {
        const serverSettings = {};
        if (this.serverSettings.has(serverId)) {
            serverSettings[serverId] = Object.fromEntries(this.serverSettings.get(serverId));
        }

        // Load existing server settings and update
        try {
            const existing = JSON.parse(localStorage.getItem('voicelink_server_settings') || '{}');
            Object.assign(existing, serverSettings);
            localStorage.setItem('voicelink_server_settings', JSON.stringify(existing));
        } catch (error) {
            localStorage.setItem('voicelink_server_settings', JSON.stringify(serverSettings));
        }
    }

    saveRoomSettings(roomId) {
        const roomSettings = {};
        if (this.roomSettings.has(roomId)) {
            roomSettings[roomId] = Object.fromEntries(this.roomSettings.get(roomId));
        }

        // Load existing room settings and update
        try {
            const existing = JSON.parse(localStorage.getItem('voicelink_room_settings') || '{}');
            Object.assign(existing, roomSettings);
            localStorage.setItem('voicelink_room_settings', JSON.stringify(existing));
        } catch (error) {
            localStorage.setItem('voicelink_room_settings', JSON.stringify(roomSettings));
        }
    }

    saveAllSettings() {
        this.saveGlobalSettings();

        // Save all server settings
        Array.from(this.serverSettings.keys()).forEach(serverId => {
            this.saveServerSettings(serverId);
        });

        // Save all room settings
        Array.from(this.roomSettings.keys()).forEach(roomId => {
            this.saveRoomSettings(roomId);
        });
    }

    /**
     * Load settings from localStorage
     */
    loadAllSettings() {
        this.loadGlobalSettings();
        this.loadServerSettings();
        this.loadRoomSettings();
    }

    loadGlobalSettings() {
        try {
            const saved = localStorage.getItem('voicelink_global_settings');
            if (saved) {
                const settings = JSON.parse(saved);
                Object.entries(settings).forEach(([key, value]) => {
                    this.globalSettings.set(key, value);
                });
            }
        } catch (error) {
            console.error('Failed to load global settings:', error);
        }
    }

    loadServerSettings() {
        try {
            const saved = localStorage.getItem('voicelink_server_settings');
            if (saved) {
                const settings = JSON.parse(saved);
                Object.entries(settings).forEach(([serverId, serverSettings]) => {
                    const serverMap = new Map(Object.entries(serverSettings));
                    this.serverSettings.set(serverId, serverMap);
                });
            }
        } catch (error) {
            console.error('Failed to load server settings:', error);
        }
    }

    loadRoomSettings() {
        try {
            const saved = localStorage.getItem('voicelink_room_settings');
            if (saved) {
                const settings = JSON.parse(saved);
                Object.entries(settings).forEach(([roomId, roomSettings]) => {
                    const roomMap = new Map(Object.entries(roomSettings));
                    this.roomSettings.set(roomId, roomMap);
                });
            }
        } catch (error) {
            console.error('Failed to load room settings:', error);
        }
    }

    /**
     * Notify about setting changes
     */
    notifySettingChanged(key, value, context, contextId = null) {
        const event = new CustomEvent('userSettingChanged', {
            detail: { key, value, context, contextId }
        });
        window.dispatchEvent(event);
    }

    /**
     * Get status types for UI
     */
    getAvailableStatusTypes() {
        return this.statusTypes;
    }

    /**
     * Get overrideable settings list
     */
    getOverrideableSettings() {
        return this.serverOverrideableSettings;
    }

    /**
     * Reset settings to defaults
     */
    resetToDefaults(context = 'global', contextId = null) {
        if (context === 'global') {
            this.globalSettings.clear();
            Object.entries(this.defaultGlobalSettings).forEach(([key, value]) => {
                this.globalSettings.set(key, value);
            });
            this.saveGlobalSettings();
        } else if (context === 'server' && contextId) {
            this.serverSettings.delete(contextId);
            this.saveServerSettings(contextId);
        } else if (context === 'room' && contextId) {
            this.roomSettings.delete(contextId);
            this.saveRoomSettings(contextId);
        }
    }
}

// Export for use in other modules
window.UserSettingsManager = UserSettingsManager;