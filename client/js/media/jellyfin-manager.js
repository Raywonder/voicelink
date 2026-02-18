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
     * @param {Object} serverConfig - Server configuration
     * @param {Object} options - Options for loading libraries
     * @param {boolean} options.showAll - Show all libraries (for admins)
     */
    async loadMediaLibraries(serverConfig, options = {}) {
        try {
            const libraries = await this.fetchWithAuth(
                `${serverConfig.url}${this.apiEndpoints.libraries}`,
                serverConfig
            );

            let filteredLibraries;

            if (options.showAll || this.isAdmin) {
                // Show all libraries for admins
                filteredLibraries = libraries.Items;
                console.log('[Jellyfin] Admin mode: showing all ' + libraries.Items.length + ' libraries');
            } else {
                // Filter to audio libraries for regular users
                filteredLibraries = libraries.Items.filter(lib =>
                    lib.CollectionType === 'music' ||
                    lib.CollectionType === 'audiobooks' ||
                    lib.CollectionType === 'playlists'
                );
            }

            this.mediaLibraries.set(serverConfig.id, filteredLibraries);
            console.log('Loaded ' + filteredLibraries.length + ' libraries from ' + serverConfig.name);

            return filteredLibraries;
        } catch (error) {
            console.error('Failed to load media libraries:', error);
            throw error;
        }
    }

    /**
     * Set admin mode to show all libraries
     */
    setAdminMode(isAdmin) {
        this.isAdmin = isAdmin;
        // Reload libraries if connected
        if (this.activeConnection) {
            this.loadMediaLibraries(this.activeConnection, { showAll: isAdmin });
        }
    }

    /**
     * Get all available libraries (admin view)
     */
    async getAllLibraries(serverId) {
        const serverConfig = this.servers.get(serverId);
        if (!serverConfig) {
            throw new Error('Server not found');
        }

        const libraries = await this.fetchWithAuth(
            serverConfig.url + this.apiEndpoints.libraries,
            serverConfig
        );

        return libraries.Items;
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

    // ============================================
    // AMBIENT MUSIC / DEFAULT ROOM MUSIC
    // ============================================

    /**
     * Default ambient music settings
     */
    ambientSettings = {
        enabled: true,
        volume: 0.3, // 30% volume for background music
        fadeInDuration: 2000, // 2 second fade in
        fadeOutDuration: 1500, // 1.5 second fade out
        defaultPath: '/home/*/apps/media/*', // Default music path pattern
        shuffle: true,
        currentTrack: null,
        isPaused: false,
        stoppedByAdmin: false,
        stoppedByUser: false
    }

    /**
     * Start ambient music when user joins a room
     * @param {string} roomId - Room being joined
     * @param {Object} options - Options for ambient music
     */
    async startAmbientMusic(roomId, options = {}) {
        // Check if ambient music is enabled
        if (!this.ambientSettings.enabled) {
            console.log('[Jellyfin] Ambient music disabled');
            return;
        }

        // Check if someone else is already playing something
        if (this.currentSession && !this.ambientSettings.isPaused) {
            console.log('[Jellyfin] Music already playing, skipping ambient');
            return;
        }

        // Check if admin stopped it
        if (this.ambientSettings.stoppedByAdmin) {
            console.log('[Jellyfin] Ambient music stopped by admin');
            return;
        }

        try {
            // Get ambient music tracks
            const tracks = await this.getAmbientTracks(options.libraryId);

            if (tracks.length === 0) {
                console.log('[Jellyfin] No ambient tracks found');
                return;
            }

            // Select track (random if shuffle enabled)
            let trackIndex = 0;
            if (this.ambientSettings.shuffle) {
                trackIndex = Math.floor(Math.random() * tracks.length);
            }

            const track = tracks[trackIndex];

            console.log('[Jellyfin] Starting ambient music: ' + track.Name);

            // Play with fade in
            await this.playAmbientTrack(track, {
                volume: options.volume || this.ambientSettings.volume,
                fadeIn: this.ambientSettings.fadeInDuration
            });

            // Mark as ambient session
            if (this.currentSession) {
                this.currentSession.isAmbient = true;
                this.currentSession.roomId = roomId;
            }

            this.ambientSettings.currentTrack = track;

        } catch (error) {
            console.error('[Jellyfin] Failed to start ambient music:', error);
        }
    }

    /**
     * Stop ambient music (with fade out)
     * @param {string} reason - Why it's being stopped (admin, user, newTrack)
     */
    async stopAmbientMusic(reason = 'user') {
        if (!this.currentSession || !this.currentSession.isAmbient) {
            return;
        }

        console.log('[Jellyfin] Stopping ambient music, reason: ' + reason);

        // Set flags based on reason
        if (reason === 'admin') {
            this.ambientSettings.stoppedByAdmin = true;
        } else if (reason === 'user') {
            this.ambientSettings.stoppedByUser = true;
        }

        // Fade out
        if (this.currentSession.audio && this.currentSession.audioNodes) {
            const gainNode = this.currentSession.audioNodes.gainNode;
            const currentVolume = gainNode.gain.value;
            const fadeOutTime = this.ambientSettings.fadeOutDuration / 1000;

            gainNode.gain.linearRampToValueAtTime(0, window.audioEngine.audioContext.currentTime + fadeOutTime);

            // Stop after fade
            setTimeout(() => {
                if (this.currentSession && this.currentSession.audio) {
                    this.currentSession.audio.pause();
                    this.currentSession = null;
                    this.ambientSettings.currentTrack = null;
                }
            }, this.ambientSettings.fadeOutDuration);

        } else if (this.currentSession && this.currentSession.audio) {
            this.currentSession.audio.pause();
            this.currentSession = null;
            this.ambientSettings.currentTrack = null;
        }
    }

    /**
     * Pause/resume ambient music when user plays something else
     */
    pauseAmbientForPlayback() {
        if (!this.currentSession || !this.currentSession.isAmbient) return;

        this.ambientSettings.isPaused = true;

        if (this.currentSession.audioNodes) {
            const gainNode = this.currentSession.audioNodes.gainNode;
            gainNode.gain.linearRampToValueAtTime(0.05, window.audioEngine.audioContext.currentTime + 1);
        }
    }

    /**
     * Resume ambient music after other playback stops
     */
    resumeAmbientMusic() {
        if (!this.currentSession || !this.currentSession.isAmbient) return;
        if (this.ambientSettings.stoppedByAdmin || this.ambientSettings.stoppedByUser) return;

        this.ambientSettings.isPaused = false;

        if (this.currentSession.audioNodes) {
            const gainNode = this.currentSession.audioNodes.gainNode;
            gainNode.gain.linearRampToValueAtTime(
                this.ambientSettings.volume,
                window.audioEngine.audioContext.currentTime + 1
            );
        }
    }

    /**
     * Get ambient tracks from library or default path
     */
    async getAmbientTracks(libraryId) {
        if (!this.activeConnection) {
            return [];
        }

        try {
            // If specific library provided, use that
            if (libraryId) {
                const result = await this.browseLibrary(this.activeConnection.id, libraryId, {
                    limit: 100,
                    sortBy: 'Random'
                });
                return result.items || [];
            }

            // Otherwise, get from first music library
            const libraries = this.mediaLibraries.get(this.activeConnection.id) || [];
            const musicLib = libraries.find(lib => lib.CollectionType === 'music');

            if (musicLib) {
                const result = await this.browseLibrary(this.activeConnection.id, musicLib.Id, {
                    limit: 50,
                    sortBy: 'Random'
                });
                return result.items || [];
            }

            return [];
        } catch (error) {
            console.error('[Jellyfin] Failed to get ambient tracks:', error);
            return [];
        }
    }

    /**
     * Play ambient track with optional fade in
     */
    async playAmbientTrack(track, options = {}) {
        const audio = await this.playMedia(this.activeConnection.id, track.Id, {
            autoplay: true
        });

        // Apply fade in
        if (options.fadeIn && this.currentSession && this.currentSession.audioNodes) {
            const gainNode = this.currentSession.audioNodes.gainNode;
            gainNode.gain.value = 0;
            gainNode.gain.linearRampToValueAtTime(
                options.volume || this.ambientSettings.volume,
                window.audioEngine.audioContext.currentTime + (options.fadeIn / 1000)
            );
        }

        // Auto-play next track when this one ends
        audio.addEventListener('ended', () => {
            if (this.ambientSettings.enabled && !this.ambientSettings.stoppedByAdmin) {
                this.playNextAmbientTrack();
            }
        });

        return audio;
    }

    /**
     * Play the next ambient track
     */
    async playNextAmbientTrack() {
        if (this.ambientSettings.stoppedByAdmin || this.ambientSettings.stoppedByUser) return;

        const tracks = await this.getAmbientTracks();
        if (tracks.length > 0) {
            const nextIndex = Math.floor(Math.random() * tracks.length);
            await this.playAmbientTrack(tracks[nextIndex], {
                volume: this.ambientSettings.volume
            });
        }
    }

    /**
     * Admin control: Enable/disable ambient music for room
     */
    setAmbientEnabled(enabled) {
        this.ambientSettings.enabled = enabled;
        if (!enabled) {
            this.stopAmbientMusic('admin');
        }
    }

    /**
     * Admin control: Reset stopped flags (allow ambient to play again)
     */
    resetAmbientMusic() {
        this.ambientSettings.stoppedByAdmin = false;
        this.ambientSettings.stoppedByUser = false;
        this.ambientSettings.isPaused = false;
    }
}

// Export for use in other modules
window.JellyfinManager = JellyfinManager;