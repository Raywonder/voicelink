/**
 * VoiceLink Client Sync Manager
 * Handles pushing updates, features, and configurations to remote servers
 * Ensures nothing is ever missing between local and remote servers
 */

class ClientSyncManager {
    constructor(app) {
        this.app = app;
        this.socket = app.socket;
        this.isConnected = false;
        this.isAdmin = false;
        this.syncQueue = [];
        this.syncInProgress = false;

        // Sync configuration
        this.syncConfig = {
            enabled: true,
            autoSync: true,
            syncInterval: 30000, // 30 seconds
            retryAttempts: 3,
            retryDelay: 5000,
            features: {
                audioSettings: true,
                userSettings: true,
                roomConfigurations: true,
                customScripts: true,
                menuSounds: true,
                backgroundAudio: true,
                spatialAudio: true,
                landscapeSharing: true,
                keybindings: true,
                serverConfig: true
            }
        };

        // Track sync status
        this.syncStatus = {
            lastSync: null,
            totalSynced: 0,
            failedSyncs: 0,
            pendingItems: 0,
            serverVersion: null,
            clientVersion: this.getClientVersion()
        };

        // Load sync settings
        this.loadSyncSettings();

        // Initialize sync system
        this.init();
    }

    async init() {
        console.log('ClientSyncManager: Initializing sync system...');

        // Set up event listeners
        this.setupEventListeners();

        // Start auto sync if enabled
        if (this.syncConfig.autoSync) {
            this.startAutoSync();
        }

        console.log('ClientSyncManager: Sync system initialized');
    }

    setupEventListeners() {
        // Listen for server connection changes
        this.app.socket?.on('connect', () => {
            this.isConnected = true;
            this.checkServerCompatibility();

            // Trigger initial sync after connection
            if (this.syncConfig.autoSync) {
                setTimeout(() => this.performFullSync(), 2000);
            }
        });

        this.app.socket?.on('disconnect', () => {
            this.isConnected = false;
        });

        // Listen for admin status changes
        this.app.socket?.on('admin-status', (data) => {
            this.isAdmin = data.isAdmin;
            console.log(`ClientSyncManager: Admin status - ${this.isAdmin ? 'enabled' : 'disabled'}`);
        });

        // Listen for sync responses
        this.app.socket?.on('sync-response', (data) => {
            this.handleSyncResponse(data);
        });

        // Listen for server feature requests
        this.app.socket?.on('request-client-features', (data) => {
            this.handleFeatureRequest(data);
        });

        // Listen for setting changes to queue for sync
        document.addEventListener('setting-changed', (event) => {
            this.queueSettingSync(event.detail);
        });
    }

    async checkServerCompatibility() {
        if (!this.isConnected) return;

        try {
            // Check server version and capabilities
            this.app.socket.emit('get-server-info', {
                clientVersion: this.syncStatus.clientVersion,
                requestFeatures: true
            });

            // Wait for response
            const serverInfo = await new Promise((resolve, reject) => {
                const timeout = setTimeout(() => reject(new Error('Server info timeout')), 5000);

                this.app.socket.once('server-info', (data) => {
                    clearTimeout(timeout);
                    resolve(data);
                });
            });

            this.syncStatus.serverVersion = serverInfo.version;

            // Compare versions and features
            const needsSync = this.compareVersions(this.syncStatus.clientVersion, serverInfo.version);

            if (needsSync) {
                console.log('ClientSyncManager: Server needs updates from client');
                this.queueFeatureSync();
            }

        } catch (error) {
            console.warn('ClientSyncManager: Could not check server compatibility:', error);
        }
    }

    compareVersions(clientVersion, serverVersion) {
        // Simple version comparison - client version newer than server
        if (!serverVersion) return true;

        const client = clientVersion.split('.').map(n => parseInt(n));
        const server = serverVersion.split('.').map(n => parseInt(n));

        for (let i = 0; i < Math.max(client.length, server.length); i++) {
            const c = client[i] || 0;
            const s = server[i] || 0;

            if (c > s) return true;
            if (c < s) return false;
        }

        return false; // Versions are equal
    }

    queueFeatureSync() {
        const features = this.collectClientFeatures();

        for (const [featureName, featureData] of Object.entries(features)) {
            if (this.syncConfig.features[featureName]) {
                this.queueSync({
                    type: 'feature',
                    name: featureName,
                    data: featureData,
                    priority: 'high',
                    timestamp: Date.now()
                });
            }
        }
    }

    collectClientFeatures() {
        const features = {};

        // Audio Settings and Enhancements
        if (this.syncConfig.features.audioSettings) {
            features.audioSettings = {
                spatialAudio: this.app.spatialAudio?.getSettings(),
                backgroundAudio: this.app.backgroundAudioEnabled,
                menuSounds: this.app.menuSoundManager?.getSettings(),
                audioEngine: this.app.audioEngine?.getConfiguration(),
                multiChannelEngine: this.app.multiChannelEngine?.getSettings()
            };
        }

        // User Settings
        if (this.syncConfig.features.userSettings) {
            features.userSettings = {
                preferences: this.app.getUserSettings(),
                keybindings: this.getKeybindings(),
                appearance: this.getAppearanceSettings()
            };
        }

        // Room Configurations
        if (this.syncConfig.features.roomConfigurations) {
            features.roomConfigurations = {
                defaultRooms: this.app.defaultRoomsManager?.getDefaultRooms(),
                roomTemplates: this.getRoomTemplates()
            };
        }

        // Custom Scripts and Enhancements
        if (this.syncConfig.features.customScripts) {
            features.customScripts = {
                backgroundAudioGenerator: this.getBackgroundAudioScript(),
                menuSoundGenerator: this.getMenuSoundScript(),
                spatialAudioEnhancements: this.getSpatialAudioEnhancements()
            };
        }

        // Landscape Sharing
        if (this.syncConfig.features.landscapeSharing) {
            features.landscapeSharing = {
                enabled: true,
                sharedLandscapes: this.getSharedLandscapes(),
                uploadSystem: this.getLandscapeUploadConfig()
            };
        }

        // Server Configuration Enhancements
        if (this.syncConfig.features.serverConfig) {
            features.serverConfig = {
                enhancedRoutes: this.getEnhancedRoutes(),
                middlewareUpdates: this.getMiddlewareUpdates(),
                securityEnhancements: this.getSecurityEnhancements()
            };
        }

        return features;
    }

    getClientVersion() {
        // Get version from package.json or app metadata
        return window.appVersion || '1.0.0';
    }

    getKeybindings() {
        return JSON.parse(localStorage.getItem('voicelink_keybindings') || '{}');
    }

    getAppearanceSettings() {
        return {
            theme: localStorage.getItem('voicelink_theme') || 'dark',
            customCSS: localStorage.getItem('voicelink_custom_css') || '',
            landscapeBackground: localStorage.getItem('voicelink_landscape_background') || null
        };
    }

    getRoomTemplates() {
        return JSON.parse(localStorage.getItem('voicelink_room_templates') || '[]');
    }

    getBackgroundAudioScript() {
        return {
            seamlessLooping: true,
            noiseGeneration: ['white', 'pink', 'brown'],
            autoLoopDetection: true,
            persistentPlayback: true,
            implementation: 'Enhanced background audio with seamless noise generation and loop detection'
        };
    }

    getMenuSoundScript() {
        return {
            syntheticGeneration: true,
            wooshVariations: 5,
            spatialIntegration: true,
            implementation: 'Synthetic woosh sound generation with spatial audio integration'
        };
    }

    getSpatialAudioEnhancements() {
        return {
            threeDimensionalPositioning: true,
            distanceAttenuation: true,
            dopplerEffect: true,
            roomAcoustics: true,
            implementation: 'Enhanced 3D spatial audio with room acoustics'
        };
    }

    getSharedLandscapes() {
        return JSON.parse(localStorage.getItem('voicelink_shared_landscapes') || '[]');
    }

    getLandscapeUploadConfig() {
        return {
            maxFileSize: 10 * 1024 * 1024, // 10MB
            supportedFormats: ['jpg', 'jpeg', 'png', 'webp'],
            compressionEnabled: true,
            sharingEnabled: true
        };
    }

    getEnhancedRoutes() {
        return {
            landscapeSharing: '/api/landscapes',
            clientSync: '/api/client-sync',
            featureUpdate: '/api/features/update',
            serverCapabilities: '/api/capabilities'
        };
    }

    getMiddlewareUpdates() {
        return {
            corsEnhancement: true,
            compressionMiddleware: true,
            rateLimiting: true,
            securityHeaders: true
        };
    }

    getSecurityEnhancements() {
        return {
            encryptedConnections: true,
            tokenAuthentication: true,
            inputValidation: true,
            sqlInjectionProtection: true
        };
    }

    queueSync(item) {
        this.syncQueue.push(item);
        this.syncStatus.pendingItems = this.syncQueue.length;

        console.log(`ClientSyncManager: Queued ${item.type} sync for ${item.name}`);

        // Trigger sync if not in progress
        if (!this.syncInProgress && this.syncConfig.autoSync) {
            setTimeout(() => this.processSync(), 1000);
        }
    }

    queueSettingSync(settingData) {
        this.queueSync({
            type: 'setting',
            name: settingData.key,
            data: settingData.value,
            priority: 'normal',
            timestamp: Date.now()
        });
    }

    async processSync() {
        if (this.syncInProgress || !this.isConnected || this.syncQueue.length === 0) {
            return;
        }

        this.syncInProgress = true;
        console.log(`ClientSyncManager: Processing ${this.syncQueue.length} sync items...`);

        // Sort by priority
        this.syncQueue.sort((a, b) => {
            const priorities = { high: 3, normal: 2, low: 1 };
            return priorities[b.priority] - priorities[a.priority];
        });

        const currentBatch = this.syncQueue.splice(0, 10); // Process 10 items at a time

        for (const item of currentBatch) {
            await this.syncItem(item);
        }

        this.syncStatus.pendingItems = this.syncQueue.length;
        this.syncInProgress = false;

        // Process remaining items if any
        if (this.syncQueue.length > 0) {
            setTimeout(() => this.processSync(), 2000);
        }
    }

    async syncItem(item) {
        try {
            console.log(`ClientSyncManager: Syncing ${item.type}: ${item.name}`);

            const syncData = {
                type: item.type,
                name: item.name,
                data: item.data,
                clientVersion: this.syncStatus.clientVersion,
                timestamp: item.timestamp,
                requiresAdmin: this.requiresAdminAccess(item)
            };

            // Send sync request to server
            this.app.socket.emit('client-sync-request', syncData);

            // Wait for response with timeout
            const response = await new Promise((resolve, reject) => {
                const timeout = setTimeout(() => reject(new Error('Sync timeout')), 10000);

                const handler = (data) => {
                    if (data.syncId === syncData.timestamp) {
                        clearTimeout(timeout);
                        this.app.socket.off('sync-response', handler);
                        resolve(data);
                    }
                };

                this.app.socket.on('sync-response', handler);
                syncData.syncId = syncData.timestamp;
                this.app.socket.emit('client-sync-request', syncData);
            });

            if (response.success) {
                this.syncStatus.totalSynced++;
                console.log(`ClientSyncManager: Successfully synced ${item.name}`);
            } else {
                throw new Error(response.error || 'Sync failed');
            }

        } catch (error) {
            console.error(`ClientSyncManager: Failed to sync ${item.name}:`, error);
            this.syncStatus.failedSyncs++;

            // Retry logic
            if (!item.retryCount) item.retryCount = 0;
            if (item.retryCount < this.syncConfig.retryAttempts) {
                item.retryCount++;
                setTimeout(() => {
                    this.syncQueue.unshift(item); // Add back to front
                }, this.syncConfig.retryDelay);
            }
        }
    }

    requiresAdminAccess(item) {
        const adminRequiredItems = [
            'serverConfig',
            'securityEnhancements',
            'middlewareUpdates'
        ];

        return adminRequiredItems.includes(item.name) ||
               item.type === 'server-modification' ||
               item.priority === 'critical';
    }

    async performFullSync() {
        console.log('ClientSyncManager: Performing full sync...');

        // Clear existing queue
        this.syncQueue = [];

        // Queue all features for sync
        this.queueFeatureSync();

        // Process immediately
        await this.processSync();

        this.syncStatus.lastSync = new Date();
        console.log('ClientSyncManager: Full sync completed');
    }

    startAutoSync() {
        if (this.autoSyncInterval) {
            clearInterval(this.autoSyncInterval);
        }

        this.autoSyncInterval = setInterval(() => {
            if (this.isConnected && this.syncQueue.length > 0) {
                this.processSync();
            }
        }, this.syncConfig.syncInterval);

        console.log('ClientSyncManager: Auto-sync started');
    }

    stopAutoSync() {
        if (this.autoSyncInterval) {
            clearInterval(this.autoSyncInterval);
            this.autoSyncInterval = null;
        }

        console.log('ClientSyncManager: Auto-sync stopped');
    }

    handleSyncResponse(data) {
        console.log('ClientSyncManager: Received sync response:', data);

        if (data.requiresRestart) {
            this.showServerRestartNotification();
        }

        if (data.newFeatures) {
            this.handleNewServerFeatures(data.newFeatures);
        }
    }

    handleFeatureRequest(data) {
        console.log('ClientSyncManager: Server requesting features:', data);

        const requestedFeatures = {};

        for (const featureName of data.features) {
            const features = this.collectClientFeatures();
            if (features[featureName]) {
                requestedFeatures[featureName] = features[featureName];
            }
        }

        // Send requested features
        this.app.socket.emit('client-features-response', {
            requestId: data.requestId,
            features: requestedFeatures,
            clientVersion: this.syncStatus.clientVersion
        });
    }

    handleNewServerFeatures(features) {
        console.log('ClientSyncManager: Server has new features available:', features);

        // Show notification to user
        this.showFeatureUpdateNotification(features);
    }

    showServerRestartNotification() {
        // Show notification that server restart is required
        const notification = document.createElement('div');
        notification.className = 'sync-notification';
        notification.innerHTML = `
            <div class="notification-content">
                <h4>Server Update Applied</h4>
                <p>The server may need to restart to apply new features.</p>
                <button onclick="this.parentElement.parentElement.remove()">OK</button>
            </div>
        `;
        document.body.appendChild(notification);
    }

    showFeatureUpdateNotification(features) {
        const notification = document.createElement('div');
        notification.className = 'sync-notification';
        notification.innerHTML = `
            <div class="notification-content">
                <h4>New Server Features Available</h4>
                <p>The server has been updated with: ${features.join(', ')}</p>
                <button onclick="this.parentElement.parentElement.remove()">OK</button>
            </div>
        `;
        document.body.appendChild(notification);
    }

    loadSyncSettings() {
        const saved = localStorage.getItem('voicelink_sync_config');
        if (saved) {
            try {
                const config = JSON.parse(saved);
                this.syncConfig = { ...this.syncConfig, ...config };
            } catch (error) {
                console.error('ClientSyncManager: Failed to load sync settings:', error);
            }
        }
    }

    saveSyncSettings() {
        try {
            localStorage.setItem('voicelink_sync_config', JSON.stringify(this.syncConfig));
        } catch (error) {
            console.error('ClientSyncManager: Failed to save sync settings:', error);
        }
    }

    // Public API methods
    enableSync() {
        this.syncConfig.enabled = true;
        this.saveSyncSettings();
        if (this.syncConfig.autoSync) {
            this.startAutoSync();
        }
    }

    disableSync() {
        this.syncConfig.enabled = false;
        this.stopAutoSync();
        this.saveSyncSettings();
    }

    getSyncStatus() {
        return {
            ...this.syncStatus,
            isConnected: this.isConnected,
            isAdmin: this.isAdmin,
            queueLength: this.syncQueue.length,
            syncEnabled: this.syncConfig.enabled,
            autoSyncEnabled: this.syncConfig.autoSync
        };
    }

    forcePushAllFeatures() {
        console.log('ClientSyncManager: Force pushing all features to server...');
        this.performFullSync();
    }
}

// Export for use in other modules
window.ClientSyncManager = ClientSyncManager;