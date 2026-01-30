/**
 * VoiceLink Local - Server Encryption Manager
 * Handles server-level encryption settings and per-user room privacy controls
 */

class ServerEncryptionManager {
    constructor() {
        this.serverEncryptionSettings = new Map();
        this.userRoomPrivacySettings = new Map();
        this.isServerOwner = false;
        this.currentServerId = null;
        this.currentUserId = null;

        this.encryptionChangeCallbacks = new Set();

        this.init();
    }

    init() {
        this.loadEncryptionSettings();
        this.setupEventListeners();
    }

    setupEventListeners() {
        // Listen for server connection events
        window.addEventListener('serverConnected', (event) => {
            this.currentServerId = event.detail.serverId;
            this.isServerOwner = event.detail.isOwner || false;
            this.loadServerEncryptionSettings(this.currentServerId);
        });

        // Listen for user authentication events
        window.addEventListener('userAuthenticated', (event) => {
            this.currentUserId = event.detail.userId;
            this.loadUserPrivacySettings(this.currentUserId);
        });

        // Listen for server disconnection
        window.addEventListener('serverDisconnected', () => {
            this.currentServerId = null;
            this.isServerOwner = false;
        });
    }

    // Server owner encryption controls
    enableServerEncryption(serverId = this.currentServerId, options = {}) {
        if (!this.isServerOwner) {
            throw new Error('Only server owners can modify encryption settings');
        }

        const encryptionConfig = {
            enabled: true,
            algorithm: options.algorithm || 'AES-256-GCM',
            keyRotationInterval: options.keyRotationInterval || 86400000, // 24 hours
            enforceForAllRooms: options.enforceForAllRooms || false,
            allowUserOverride: options.allowUserOverride !== false, // Default true
            createdAt: Date.now(),
            lastModified: Date.now(),
            ...options
        };

        this.serverEncryptionSettings.set(serverId, encryptionConfig);
        this.saveEncryptionSettings();
        this.notifyEncryptionChange(serverId, 'enabled', encryptionConfig);

        return encryptionConfig;
    }

    disableServerEncryption(serverId = this.currentServerId) {
        if (!this.isServerOwner) {
            throw new Error('Only server owners can modify encryption settings');
        }

        const currentConfig = this.serverEncryptionSettings.get(serverId);
        if (currentConfig) {
            currentConfig.enabled = false;
            currentConfig.lastModified = Date.now();
            this.serverEncryptionSettings.set(serverId, currentConfig);
            this.saveEncryptionSettings();
            this.notifyEncryptionChange(serverId, 'disabled', currentConfig);
        }

        return currentConfig;
    }

    updateServerEncryptionSettings(serverId = this.currentServerId, updates) {
        if (!this.isServerOwner) {
            throw new Error('Only server owners can modify encryption settings');
        }

        const currentConfig = this.serverEncryptionSettings.get(serverId) || {};
        const updatedConfig = {
            ...currentConfig,
            ...updates,
            lastModified: Date.now()
        };

        this.serverEncryptionSettings.set(serverId, updatedConfig);
        this.saveEncryptionSettings();
        this.notifyEncryptionChange(serverId, 'updated', updatedConfig);

        return updatedConfig;
    }

    // Per-user room privacy controls
    setUserRoomPrivacy(roomId, privacyLevel, options = {}) {
        if (!this.currentUserId) {
            throw new Error('User must be authenticated to set room privacy');
        }

        const privacyLevels = {
            'public': {
                level: 'public',
                description: 'Room is visible to all users',
                encryption: false,
                inviteOnly: false
            },
            'unlisted': {
                level: 'unlisted',
                description: 'Room is not listed but joinable with link',
                encryption: false,
                inviteOnly: false
            },
            'private': {
                level: 'private',
                description: 'Room requires invitation to join',
                encryption: true,
                inviteOnly: true
            },
            'encrypted': {
                level: 'encrypted',
                description: 'Room uses end-to-end encryption',
                encryption: true,
                inviteOnly: false
            },
            'secure': {
                level: 'secure',
                description: 'Room is private and encrypted',
                encryption: true,
                inviteOnly: true
            }
        };

        if (!privacyLevels[privacyLevel]) {
            throw new Error(`Invalid privacy level: ${privacyLevel}`);
        }

        const privacyConfig = {
            ...privacyLevels[privacyLevel],
            roomId,
            userId: this.currentUserId,
            serverId: this.currentServerId,
            createdAt: Date.now(),
            lastModified: Date.now(),
            ...options
        };

        // Check if server encryption settings allow user override
        const serverConfig = this.getServerEncryptionStatus(this.currentServerId);
        if (serverConfig.enabled && !serverConfig.allowUserOverride && !privacyConfig.encryption) {
            throw new Error('Server encryption is enforced - cannot create unencrypted rooms');
        }

        const userKey = `${this.currentUserId}_${this.currentServerId}`;
        if (!this.userRoomPrivacySettings.has(userKey)) {
            this.userRoomPrivacySettings.set(userKey, new Map());
        }

        this.userRoomPrivacySettings.get(userKey).set(roomId, privacyConfig);
        this.savePrivacySettings();

        return privacyConfig;
    }

    getUserRoomPrivacy(roomId, userId = this.currentUserId, serverId = this.currentServerId) {
        const userKey = `${userId}_${serverId}`;
        const userRooms = this.userRoomPrivacySettings.get(userKey);

        if (userRooms && userRooms.has(roomId)) {
            return userRooms.get(roomId);
        }

        // Return default privacy based on server settings
        const serverConfig = this.getServerEncryptionStatus(serverId);
        return {
            level: serverConfig.enabled ? 'encrypted' : 'public',
            encryption: serverConfig.enabled,
            inviteOnly: false,
            isDefault: true
        };
    }

    // Encryption status queries
    getServerEncryptionStatus(serverId = this.currentServerId) {
        const config = this.serverEncryptionSettings.get(serverId);

        if (!config) {
            return {
                enabled: false,
                supported: true,
                algorithm: null,
                allowUserOverride: true,
                enforceForAllRooms: false
            };
        }

        return {
            enabled: config.enabled,
            supported: true,
            algorithm: config.algorithm,
            allowUserOverride: config.allowUserOverride,
            enforceForAllRooms: config.enforceForAllRooms,
            keyRotationInterval: config.keyRotationInterval,
            lastModified: config.lastModified
        };
    }

    isRoomEncrypted(roomId, serverId = this.currentServerId) {
        const serverConfig = this.getServerEncryptionStatus(serverId);

        // If server enforces encryption for all rooms
        if (serverConfig.enabled && serverConfig.enforceForAllRooms) {
            return true;
        }

        // Check user-specific room privacy settings
        const roomPrivacy = this.getUserRoomPrivacy(roomId);
        return roomPrivacy.encryption;
    }

    getEncryptionStatusDisplay(serverId = this.currentServerId, roomId = null) {
        const serverStatus = this.getServerEncryptionStatus(serverId);

        let status = {
            server: {
                enabled: serverStatus.enabled,
                icon: serverStatus.enabled ? '🔒' : '🔓',
                text: serverStatus.enabled ? 'Server Encryption: ON' : 'Server Encryption: OFF',
                class: serverStatus.enabled ? 'encryption-enabled' : 'encryption-disabled'
            }
        };

        if (roomId) {
            const roomEncrypted = this.isRoomEncrypted(roomId, serverId);
            const roomPrivacy = this.getUserRoomPrivacy(roomId);

            status.room = {
                encrypted: roomEncrypted,
                privacy: roomPrivacy.level,
                icon: roomEncrypted ? '🔐' : (roomPrivacy.level === 'private' ? '👥' : '🌐'),
                text: this.getRoomStatusText(roomPrivacy),
                class: `room-${roomPrivacy.level}`
            };
        }

        return status;
    }

    getRoomStatusText(roomPrivacy) {
        const statusTexts = {
            'public': 'Public Room',
            'unlisted': 'Unlisted Room',
            'private': 'Private Room',
            'encrypted': 'Encrypted Room',
            'secure': 'Secure Room (Private + Encrypted)'
        };

        return statusTexts[roomPrivacy.level] || 'Unknown Privacy Level';
    }

    // Event management
    onEncryptionChange(callback) {
        this.encryptionChangeCallbacks.add(callback);
        return () => this.encryptionChangeCallbacks.delete(callback);
    }

    notifyEncryptionChange(serverId, action, config) {
        const event = {
            serverId,
            action, // 'enabled', 'disabled', 'updated'
            config,
            timestamp: Date.now()
        };

        this.encryptionChangeCallbacks.forEach(callback => {
            try {
                callback(event);
            } catch (error) {
                console.error('Error in encryption change callback:', error);
            }
        });

        // Dispatch custom event
        window.dispatchEvent(new CustomEvent('serverEncryptionChanged', {
            detail: event
        }));
    }

    // Persistence
    saveEncryptionSettings() {
        try {
            const settings = Object.fromEntries(this.serverEncryptionSettings);
            localStorage.setItem('vlServerEncryptionSettings', JSON.stringify(settings));
        } catch (error) {
            console.error('Failed to save encryption settings:', error);
        }
    }

    savePrivacySettings() {
        try {
            const settings = {};
            this.userRoomPrivacySettings.forEach((userRooms, userKey) => {
                settings[userKey] = Object.fromEntries(userRooms);
            });
            localStorage.setItem('vlUserRoomPrivacySettings', JSON.stringify(settings));
        } catch (error) {
            console.error('Failed to save privacy settings:', error);
        }
    }

    loadEncryptionSettings() {
        try {
            const stored = localStorage.getItem('vlServerEncryptionSettings');
            if (stored) {
                const settings = JSON.parse(stored);
                this.serverEncryptionSettings = new Map(Object.entries(settings));
            }
        } catch (error) {
            console.error('Failed to load encryption settings:', error);
        }
    }

    loadServerEncryptionSettings(serverId) {
        // This would typically fetch from server
        // For now, using local storage
        const config = this.serverEncryptionSettings.get(serverId);
        if (config) {
            this.notifyEncryptionChange(serverId, 'loaded', config);
        }
    }

    loadUserPrivacySettings(userId) {
        try {
            const stored = localStorage.getItem('vlUserRoomPrivacySettings');
            if (stored) {
                const settings = JSON.parse(stored);
                this.userRoomPrivacySettings.clear();

                Object.entries(settings).forEach(([userKey, userRooms]) => {
                    this.userRoomPrivacySettings.set(userKey, new Map(Object.entries(userRooms)));
                });
            }
        } catch (error) {
            console.error('Failed to load privacy settings:', error);
        }
    }

    // Utility methods
    canUserModifyEncryption(userId = this.currentUserId, serverId = this.currentServerId) {
        if (userId === this.currentUserId && this.isServerOwner) {
            return true;
        }

        const serverConfig = this.getServerEncryptionStatus(serverId);
        return serverConfig.allowUserOverride;
    }

    getAvailablePrivacyLevels(serverId = this.currentServerId) {
        const serverConfig = this.getServerEncryptionStatus(serverId);
        const allLevels = ['public', 'unlisted', 'private', 'encrypted', 'secure'];

        if (serverConfig.enabled && !serverConfig.allowUserOverride) {
            // Only encrypted options available
            return allLevels.filter(level =>
                ['private', 'encrypted', 'secure'].includes(level)
            );
        }

        return allLevels;
    }

    // Export/Import settings (for backup/restore)
    exportSettings() {
        return {
            serverEncryption: Object.fromEntries(this.serverEncryptionSettings),
            userPrivacy: Object.fromEntries(
                Array.from(this.userRoomPrivacySettings.entries()).map(([key, value]) => [
                    key,
                    Object.fromEntries(value)
                ])
            ),
            exportedAt: Date.now(),
            version: '1.0.0'
        };
    }

    importSettings(data) {
        if (data.version !== '1.0.0') {
            throw new Error('Incompatible settings version');
        }

        if (data.serverEncryption) {
            this.serverEncryptionSettings = new Map(Object.entries(data.serverEncryption));
        }

        if (data.userPrivacy) {
            this.userRoomPrivacySettings.clear();
            Object.entries(data.userPrivacy).forEach(([key, value]) => {
                this.userRoomPrivacySettings.set(key, new Map(Object.entries(value)));
            });
        }

        this.saveEncryptionSettings();
        this.savePrivacySettings();
    }
}

// Global instance
window.serverEncryptionManager = new ServerEncryptionManager();

// Export for module usage
if (typeof module !== 'undefined' && module.exports) {
    module.exports = ServerEncryptionManager;
}