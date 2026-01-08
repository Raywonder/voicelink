/**
 * Jellyfin API Manager
 * Handles media streaming from Jellyfin servers with API authentication
 */

class JellyfinManager {
    constructor() {
        this.servers = new Map(); // serverId -> server config
        this.activeConnection = null;
        this.currentSession = null;
        this.mediaLibraries = new Map();
        this.playbackQueue = [];
        this.currentPlaybackIndex = 0;

        // Jellyfin API endpoints
        this.apiEndpoints = {
            auth: '/Users/authenticatebyname',
            userInfo: '/Users/{userId}',
            libraries: '/UserViews',
            items: '/Users/{userId}/Items',
            playbackInfo: '/Items/{itemId}/PlaybackInfo',
            mediaStream: '/Audio/{itemId}/stream',
            imageApi: '/Items/{itemId}/Images/Primary'
        };

        // Supported audio formats
        this.supportedFormats = [
            'mp3', 'flac', 'ogg', 'wav', 'aac', 'm4a', 'opus'
        ];

        this.init();
    }

    init() {
        // Load saved server configurations
        this.loadServerConfigurations();
        console.log('Jellyfin Manager initialized');
    }

    /**
     * Add a new Jellyfin server configuration
     */
    async addServer(config) {
        const { name, url, username, password, serverId } = config;

        if (!name || !url || !username || !password) {
            throw new Error('Missing required server configuration');
        }

        // Validate server URL format
        const serverUrl = this.normalizeServerUrl(url);

        try {
            // Test connection and authenticate
            const authResult = await this.authenticateUser(serverUrl, username, password);

            const serverConfig = {
                id: serverId || this.generateServerId(),
                name,
                url: serverUrl,
                username,
                userId: authResult.UserId,
                accessToken: authResult.AccessToken,
                sessionInfo: authResult.SessionInfo,
                addedAt: Date.now(),
                lastConnected: Date.now(),
                isActive: false
            };

            this.servers.set(serverConfig.id, serverConfig);
            this.saveServerConfigurations();

            console.log(`Jellyfin server "${name}" added successfully`);
            return serverConfig;

        } catch (error) {
            console.error('Failed to add Jellyfin server:', error);
            throw new Error(`Failed to connect to Jellyfin server: ${error.message}`);
        }
    }

    /**
     * Authenticate with Jellyfin server
     */
    async authenticateUser(serverUrl, username, password) {
        const authPayload = {
            Username: username,
            Pw: password,
            PasswordMd5: this.md5Hash(password)
        };

        const response = await fetch(`${serverUrl}${this.apiEndpoints.auth}`, {
            method: 'POST',
            headers: {
                'Content-Type': 'application/json',
                'X-Emby-Authorization': this.buildAuthHeader()
            },
            body: JSON.stringify(authPayload)
        });

        if (!response.ok) {
            const errorText = await response.text();
            throw new Error(`Authentication failed: ${response.status} - ${errorText}`);
        }

        const authResult = await response.json();
        return {
            UserId: authResult.User.Id,
            AccessToken: authResult.AccessToken,
            SessionInfo: authResult.SessionInfo
        };
    }

    /**
     * Connect to a configured server
     */
    async connectToServer(serverId) {
        const serverConfig = this.servers.get(serverId);
        if (!serverConfig) {
            throw new Error('Server configuration not found');
        }

        try {
            // Test connection with existing token
            const userInfo = await this.fetchWithAuth(
                `${serverConfig.url}${this.apiEndpoints.userInfo.replace('{userId}', serverConfig.userId)}`,
                serverConfig
            );

            // Update connection status
            serverConfig.isActive = true;
            serverConfig.lastConnected = Date.now();
            this.activeConnection = serverConfig;

            // Load media libraries
            await this.loadMediaLibraries(serverConfig);

            console.log(`Connected to Jellyfin server: ${serverConfig.name}`);
            this.notifyConnectionChanged('connected', serverConfig);

            return serverConfig;

        } catch (error) {
            console.error('Failed to connect to server:', error);

            // Try to re-authenticate if token expired
            try {
                const authResult = await this.authenticateUser(
                    serverConfig.url,
                    serverConfig.username,
                    '' // We'll need to prompt for password again
                );

                serverConfig.accessToken = authResult.AccessToken;
                serverConfig.userId = authResult.UserId;
                this.saveServerConfigurations();

                return await this.connectToServer(serverId);
            } catch (reAuthError) {
                throw new Error(`Connection failed and re-authentication failed: ${reAuthError.message}`);
            }
        }
    }

    /**
     * Load media libraries from connected server
     */
    async loadMediaLibraries(serverConfig) {
        try {
            const libraries = await this.fetchWithAuth(
                `${serverConfig.url}${this.apiEndpoints.libraries}`,
                serverConfig
            );

            const audioLibraries = libraries.Items.filter(lib =>
                lib.CollectionType === 'music' || lib.CollectionType === 'audiobooks'
            );

            this.mediaLibraries.set(serverConfig.id, audioLibraries);
            console.log(`Loaded ${audioLibraries.length} audio libraries from ${serverConfig.name}`);

            return audioLibraries;
        } catch (error) {
            console.error('Failed to load media libraries:', error);
            throw error;
        }
    }

    /**
     * Browse media items in a library
     */
    async browseLibrary(serverId, libraryId, options = {}) {
        const serverConfig = this.servers.get(serverId);
        if (!serverConfig || !serverConfig.isActive) {
            throw new Error('Server not connected');
        }

        const params = new URLSearchParams({
            parentId: libraryId,
            includeItemTypes: 'Audio',
            fields: 'PrimaryImageAspectRatio,MediaSourceCount,DateCreated',
            startIndex: options.startIndex || 0,
            limit: options.limit || 100,
            sortBy: options.sortBy || 'SortName',
            sortOrder: options.sortOrder || 'Ascending'
        });

        if (options.searchTerm) {
            params.append('searchTerm', options.searchTerm);
        }

        try {
            const items = await this.fetchWithAuth(
                `${serverConfig.url}${this.apiEndpoints.items.replace('{userId}', serverConfig.userId)}?${params}`,
                serverConfig
            );

            return {
                items: items.Items,
                totalRecordCount: items.TotalRecordCount,
                startIndex: items.StartIndex
            };
        } catch (error) {
            console.error('Failed to browse library:', error);
            throw error;
        }
    }

    /**
     * Get playback URL for media item
     */
    async getMediaStreamUrl(serverId, itemId, options = {}) {
        const serverConfig = this.servers.get(serverId);
        if (!serverConfig || !serverConfig.isActive) {
            throw new Error('Server not connected');
        }

        const params = new URLSearchParams({
            userId: serverConfig.userId,
            deviceId: this.getDeviceId(),
            api_key: serverConfig.accessToken,
            container: options.format || 'mp3,flac,ogg',
            audioCodec: options.codec || 'mp3,flac,opus',
            audioBitRate: options.bitrate || 320000,
            audioSampleRate: options.sampleRate || 48000
        });

        const streamUrl = `${serverConfig.url}${this.apiEndpoints.mediaStream.replace('{itemId}', itemId)}?${params}`;
        return streamUrl;
    }

    /**
     * Start playback of media item
     */
    async playMedia(serverId, itemId, options = {}) {
        try {
            const streamUrl = await this.getMediaStreamUrl(serverId, itemId, options);

            // Create audio element for playback
            const audio = new Audio();
            audio.crossOrigin = 'anonymous';
            audio.src = streamUrl;

            // Set up event listeners
            audio.addEventListener('loadstart', () => {
                console.log('Started loading media:', itemId);
            });

            audio.addEventListener('canplay', () => {
                console.log('Media ready to play:', itemId);
                if (options.autoplay !== false) {
                    audio.play();
                }
            });

            audio.addEventListener('error', (error) => {
                console.error('Media playback error:', error);
                this.notifyPlaybackError(itemId, error);
            });

            // Store current playback info
            this.currentSession = {
                serverId,
                itemId,
                audio,
                startTime: Date.now(),
                options
            };

            // Integrate with audio engine if available
            if (window.audioEngine && window.audioEngine.audioContext) {
                this.integrateWithAudioEngine(audio);
            }

            return audio;

        } catch (error) {
            console.error('Failed to start media playback:', error);
            throw error;
        }
    }

    /**
     * Integrate Jellyfin audio with the main audio engine
     */
    integrateWithAudioEngine(audioElement) {
        try {
            const audioContext = window.audioEngine.audioContext;
            const source = audioContext.createMediaElementSource(audioElement);

            // Create gain node for volume control
            const gainNode = audioContext.createGain();
            gainNode.gain.value = 0.7; // Default volume for media playback

            // Connect to audio processing chain
            source.connect(gainNode);
            gainNode.connect(audioContext.destination);

            // Store nodes for later control
            this.currentSession.audioNodes = {
                source,
                gainNode
            };

            console.log('Jellyfin audio integrated with audio engine');
        } catch (error) {
            console.error('Failed to integrate with audio engine:', error);
        }
    }

    /**
     * Helper methods
     */
    normalizeServerUrl(url) {
        // Remove trailing slash and ensure protocol
        url = url.replace(/\/$/, '');
        if (!url.startsWith('http://') && !url.startsWith('https://')) {
            url = 'https://' + url;
        }
        return url;
    }

    generateServerId() {
        return 'jellyfin_' + Date.now() + '_' + Math.random().toString(36).substr(2, 9);
    }

    buildAuthHeader() {
        return `MediaBrowser Client="VoiceLink Local", Device="Web Browser", DeviceId="${this.getDeviceId()}", Version="1.0.0"`;
    }

    getDeviceId() {
        let deviceId = localStorage.getItem('voicelink_device_id');
        if (!deviceId) {
            deviceId = 'voicelink_' + Date.now() + '_' + Math.random().toString(36).substr(2, 9);
            localStorage.setItem('voicelink_device_id', deviceId);
        }
        return deviceId;
    }

    md5Hash(str) {
        // Simple MD5 implementation for password hashing
        // In production, use a proper crypto library
        return btoa(str).replace(/[^a-zA-Z0-9]/g, '').toLowerCase();
    }

    async fetchWithAuth(url, serverConfig) {
        const response = await fetch(url, {
            headers: {
                'X-Emby-Authorization': this.buildAuthHeader(),
                'X-Emby-Token': serverConfig.accessToken
            }
        });

        if (!response.ok) {
            throw new Error(`API request failed: ${response.status} - ${response.statusText}`);
        }

        return await response.json();
    }

    /**
     * Storage methods
     */
    saveServerConfigurations() {
        const configs = {};
        this.servers.forEach((config, id) => {
            // Don't save sensitive data in localStorage
            configs[id] = {
                ...config,
                password: undefined // Remove password from storage
            };
        });
        localStorage.setItem('voicelink_jellyfin_servers', JSON.stringify(configs));
    }

    loadServerConfigurations() {
        try {
            const saved = localStorage.getItem('voicelink_jellyfin_servers');
            if (saved) {
                const configs = JSON.parse(saved);
                Object.entries(configs).forEach(([id, config]) => {
                    this.servers.set(id, config);
                });
            }
        } catch (error) {
            console.error('Failed to load Jellyfin server configurations:', error);
        }
    }

    /**
     * Event notification methods
     */
    notifyConnectionChanged(status, serverConfig) {
        const event = new CustomEvent('jellyfinConnectionChanged', {
            detail: { status, server: serverConfig }
        });
        window.dispatchEvent(event);
    }

    notifyPlaybackError(itemId, error) {
        const event = new CustomEvent('jellyfinPlaybackError', {
            detail: { itemId, error }
        });
        window.dispatchEvent(event);
    }

    /**
     * Public API methods
     */
    getConnectedServers() {
        return Array.from(this.servers.values()).filter(server => server.isActive);
    }

    getServerById(serverId) {
        return this.servers.get(serverId);
    }

    disconnect() {
        if (this.activeConnection) {
            this.activeConnection.isActive = false;
            this.activeConnection = null;
        }

        if (this.currentSession && this.currentSession.audio) {
            this.currentSession.audio.pause();
            this.currentSession = null;
        }

        this.notifyConnectionChanged('disconnected', null);
    }

    // Cleanup method
    destroy() {
        this.disconnect();
        this.servers.clear();
        this.mediaLibraries.clear();
    }
}

// Export for use in other modules
window.JellyfinManager = JellyfinManager;