/**
 * VoiceLink Local Application
 * Main application controller
 */

class VoiceLinkApp {
    constructor() {
        this.socket = null;
        this.audioEngine = null;
        this.spatialAudio = null;
        this.webrtcManager = null;

        this.currentRoom = null;
        this.currentUser = null;
        this.users = new Map();
        this.multiDeviceState = {
            activeDevices: [],
            lastEvent: null
        };

        // Audio playback management
        this.currentAudio = null;
        this.isAudioPlaying = false;

        // Room data cache for join screen
        this.roomDataCache = new Map();

        this.ui = {
            currentScreen: 'loading-screen',
            screens: [
                'loading-screen',
                'main-menu',
                'create-room-screen',
                'join-room-screen',
                'voice-chat-screen',
                'settings-screen'
            ]
        };

        this.init();
    }

    /**
     * Get the API base URL for making HTTP requests
     * Handles both nginx proxy (no port) and direct connections (with port)
     */
    getApiBaseUrl() {
        const protocol = window.location.protocol;
        const host = this.socket?.io?.opts?.hostname || window.location.hostname || 'localhost';
        const socketPort = this.socket?.io?.opts?.port;
        const locationPort = window.location.port;

        // If we have a socket port (direct connection), use it
        // If we have a location port (non-standard port), use it
        // Otherwise, we're behind a proxy on standard ports, no port needed
        if (socketPort) {
            return `${protocol}//${host}:${socketPort}`;
        } else if (locationPort) {
            return `${protocol}//${host}:${locationPort}`;
        } else {
            // Standard port (80/443), no port needed in URL
            return `${protocol}//${host}`;
        }
    }

    getNativeAPI() {
        return window.nativeAPI || null;
    }

    async openExternal(url) {
        const nativeAPI = this.getNativeAPI();
        if (nativeAPI?.openExternal) {
            return nativeAPI.openExternal(url);
        }
        window.open(url, '_blank', 'noopener,noreferrer');
        return null;
    }

    async init() {
        console.log('Initializing VoiceLink Local...');

        // IMMEDIATE: Hide platform-specific elements based on environment
        // This must run FIRST to prevent flash of unwanted content
        const nativeAPI = window.nativeAPI || null;
        const isNativeApp = !!nativeAPI;
        console.log('IMMEDIATE platform check:', { isNativeApp });

        if (isNativeApp) {
            // Desktop app: hide web-only elements (download links, login benefits for guests)
            document.getElementById('login-benefits')?.remove();
            document.getElementById('download-app-section')?.remove();
            document.querySelectorAll('.web-only').forEach(el => el.remove());
            // Swap label visibility for desktop
            document.querySelectorAll('.web-label').forEach(el => el.style.display = 'none');
            document.querySelectorAll('.desktop-label').forEach(el => el.style.display = 'inline');
            console.log('Desktop mode: removed web-only elements');
        } else {
            // Web browser: hide desktop-only elements
            document.getElementById('copy-local-url-btn')?.remove();
            document.getElementById('copy-localhost-url-btn')?.remove();
            document.getElementById('refresh-network-btn')?.remove();
            document.querySelectorAll('.desktop-only').forEach(el => el.remove());
            document.querySelector('.network-interface-section')?.remove();
            console.log('Web mode: removed desktop-only elements');

            // Web browser: hide auth-required elements for guests (until they log in)
            // Check if user is authenticated via Mastodon OAuth
            const isAuthenticated = localStorage.getItem('mastodon_access_token') ||
                sessionStorage.getItem('mastodon_access_token') ||
                localStorage.getItem('voicelink_whmcs_token') ||
                sessionStorage.getItem('voicelink_whmcs_token');
            if (!isAuthenticated) {
                document.querySelectorAll('.auth-required').forEach(el => {
                    el.style.display = 'none';
                    el.dataset.hiddenForAuth = 'true';
                });
                console.log('Web guest mode: hidden auth-required elements (Settings, etc.)');

                // Listen for successful login to show auth-required elements
                window.addEventListener('mastodon-login', () => {
                    document.querySelectorAll('[data-hidden-for-auth="true"]').forEach(el => {
                        el.style.display = '';
                        delete el.dataset.hiddenForAuth;
                    });
                    // Also hide login benefits after successful auth
                    document.getElementById('login-benefits')?.remove();
                    console.log('User authenticated: showing auth-required elements');
                }, { once: true });
            }
        }

        try {
            // CRITICAL: Register IPC listener FIRST before any async operations
            // This ensures we don't miss network info updates from main process
            if (nativeAPI?.onNetworkInfoUpdated) {
                nativeAPI.onNetworkInfoUpdated((data) => {
                    console.log('Network info updated from main process:', data);
                    this.handleNetworkInfoUpdate(data);
                });
                console.log('Network info IPC listener registered');
            }

            // Initialize iOS compatibility first
            if (typeof iOSCompatibility !== 'undefined') {
                window.iosCompatibility = new iOSCompatibility();
                console.log('iOS compatibility layer initialized');
            }

            // Connect to local server first (this doesn't require audio permissions)
            await this.connectToServer();

            // Initialize audio systems (with error handling for Chrome)
            await this.initializeAudioSystems();

            // Initialize advanced systems
            this.initializeAdvancedSystems();

            // Setup UI event listeners
            this.setupUIEventListeners();

            // Setup network event handlers (for Electron)
            this.setupNetworkEventHandlers();

            // Initial network info update (listener already registered at start of init)
            this.updateNetworkInfo();

            // Load rooms
            await this.loadRooms();

            // Check for demo mode (interactive documentation testing)
            const urlParams = new URLSearchParams(window.location.search);
            const isDemoMode = urlParams.get('demo') === 'true';
            const testFeature = urlParams.get('test'); // Specific feature to test (e.g., 'audio', '3d', 'media')

            if (isDemoMode) {
                console.log('Demo mode activated - creating private test room');
                // Auto-create and join a private test room for documentation testing
                setTimeout(() => {
                    this.createDemoRoom(testFeature);
                }, 2500);
            } else {
                // Show main menu
                setTimeout(() => {
                    this.showScreen('main-menu');
                    // Start periodic server status monitoring
                    this.startServerStatusMonitoring();
                }, 2000);
            }

        } catch (error) {
            console.error('Failed to initialize VoiceLink:', error);
            // Show main menu anyway - audio will initialize on first user interaction
            setTimeout(() => {
                this.showScreen('main-menu');
                // Don't show error - this is normal browser behavior
                console.log('VoiceLink loaded. Audio features will activate when needed.');
            }, 2000);
        }
    }

    async initializeAudioSystems() {
        try {
            // Check if Web Audio API is supported
            const AudioContext = window.AudioContext || window.webkitAudioContext;
            if (!AudioContext) {
                throw new Error('Web Audio API not supported');
            }

            // Try to initialize audio systems - this may fail due to browser security
            this.audioEngine = new AudioEngine();
            this.spatialAudio = new SpatialAudioEngine();

            // Initialize built-in effects processor
            if (typeof BuiltinEffectsProcessor !== 'undefined' && this.audioEngine.audioContext) {
                window.builtinEffectsProcessor = new BuiltinEffectsProcessor(this.audioEngine.audioContext);
            }

            // Initialize audio test manager
            if (typeof AudioTestManager !== 'undefined') {
                window.audioTestManager = new AudioTestManager(this.audioEngine, this.spatialAudio);
                console.log('AudioTestManager initialized successfully');
            }

            console.log('Audio systems initialized successfully');
        } catch (error) {
            // This is normal - browsers require user interaction for audio
            console.log('Audio will initialize when user interacts with the app (this is normal browser behavior)');

            // Create deferred audio engine that initializes on first interaction
            this.audioEngine = {
                audioContext: null,
                isDeferred: true,
                getUserMedia: async () => {
                    await this.retryAudioInitialization();
                    return this.audioEngine.getUserMedia();
                },
                testSpeakers: async () => {
                    await this.retryAudioInitialization();
                    return this.audioEngine.testSpeakers();
                },
                updateSettings: (settings) => {
                    if (this.audioEngine.isDeferred) {
                        console.log('Audio settings will apply when audio is enabled');
                        return;
                    }
                    this.audioEngine.updateSettings(settings);
                },
                resumeAudioContext: async () => {
                    await this.retryAudioInitialization();
                }
            };

            this.spatialAudio = {
                isDeferred: true,
                enable: async () => {
                    await this.retryAudioInitialization();
                    return this.spatialAudio.enable();
                },
                disable: () => {},
                setRoomModel: () => {},
                resumeAudioContext: async () => {
                    await this.retryAudioInitialization();
                }
            };
        }
    }

    async retryAudioInitialization() {
        try {
            console.log('Retrying audio initialization after user interaction...');

            // Re-initialize audio systems
            this.audioEngine = new AudioEngine();
            this.spatialAudio = new SpatialAudioEngine();

            // Initialize built-in effects processor
            if (typeof BuiltinEffectsProcessor !== 'undefined' && this.audioEngine.audioContext) {
                window.builtinEffectsProcessor = new BuiltinEffectsProcessor(this.audioEngine.audioContext);
            }

            // Initialize audio test manager now that audio systems are ready
            if (typeof AudioTestManager !== 'undefined') {
                window.audioTestManager = new AudioTestManager(this.audioEngine, this.spatialAudio);
                console.log('AudioTestManager re-initialized successfully');
            }

            console.log('Audio systems re-initialized successfully');
            return true;
        } catch (error) {
            console.error('Audio re-initialization failed:', error);
            return false;
        }
    }

    initializeAdvancedSystems() {
        // Initialize multi-channel engine
        if (typeof MultiChannelAudioEngine !== 'undefined') {
            window.multiChannelEngine = new MultiChannelAudioEngine(this.audioEngine.audioContext);
        }

        // Initialize VST streaming engine
        if (typeof VSTStreamingEngine !== 'undefined') {
            window.vstStreamingEngine = new VSTStreamingEngine(this.audioEngine.audioContext);
        }

        // Initialize server access manager
        if (typeof ServerAccessManager !== 'undefined') {
            window.serverAccessManager = new ServerAccessManager();
        }

        // Initialize security encryption manager
        if (typeof SecurityEncryptionManager !== 'undefined') {
            window.securityEncryptionManager = new SecurityEncryptionManager();
        }

        // Initialize multi-input manager
        if (typeof MultiInputManager !== 'undefined' && this.audioEngine) {
            window.multiInputManager = new MultiInputManager(this.audioEngine);
            console.log('Multi-input manager initialized');
        }

        // Initialize media metadata detector
        if (typeof MediaMetadataDetector !== 'undefined' && this.audioEngine) {
            window.mediaMetadataDetector = new MediaMetadataDetector(this.audioEngine);
            console.log('Media metadata detector initialized');
        }

        // Initialize whisper mode manager
        if (typeof WhisperModeManager !== 'undefined' && this.audioEngine) {
            this.whisperMode = new WhisperModeManager(this.audioEngine);
            this.whisperMode.setupWhisperPTT();

            // Set up UI callbacks
            this.whisperMode.onWhisperStart = (userId, username) => {
                this.showWhisperStatus(true, username);
            };
            this.whisperMode.onWhisperStop = () => {
                this.showWhisperStatus(false);
            };
            this.whisperMode.onTargetChange = (userId, username) => {
                this.updateWhisperTargetUI(userId, username);
            };

            console.log('Whisper mode manager initialized');
        }

        // Initialize user settings manager
        if (typeof UserSettingsManager !== 'undefined') {
            window.userSettingsManager = new UserSettingsManager();
            console.log('User settings manager initialized');
        }

        // Initialize user settings interface
        if (typeof UserSettingsInterface !== 'undefined' && window.userSettingsManager) {
            window.userSettingsInterface = new UserSettingsInterface(window.userSettingsManager);
            console.log('User settings interface initialized');
        }

        // Initialize media streaming interface
        if (typeof MediaStreamingInterface !== 'undefined') {
            window.mediaStreamingInterface = new MediaStreamingInterface();
            console.log('Media streaming interface initialized');
        }

        // Initialize user context menu
        if (typeof UserContextMenu !== 'undefined') {
            window.userContextMenu = new UserContextMenu();
            console.log('User context menu initialized');
        }

        // Initialize accessibility manager
        if (typeof AccessibilityManager !== 'undefined') {
            window.accessibilityManager = new AccessibilityManager();
            console.log('Accessibility manager initialized');
        }

        // Initialize keychain auth manager
        if (typeof KeychainAuthManager !== 'undefined') {
            window.keychainAuthManager = new KeychainAuthManager();
        }

        // AudioTestManager will be initialized after audio systems are ready

        // Initialize synthetic audio generator
        if (typeof SyntheticAudioGenerator !== 'undefined') {
            window.syntheticAudioGenerator = new SyntheticAudioGenerator();
        }

        // Initialize feature permissions manager
        if (typeof FeaturePermissionsManager !== 'undefined') {
            window.featurePermissionsManager = new FeaturePermissionsManager();
        }

        // Initialize WordPress integration
        if (typeof WordPressIntegration !== 'undefined' && window.featurePermissionsManager) {
            window.wordPressIntegration = new WordPressIntegration(window.featurePermissionsManager);
        }

        // Initialize unified admin interface
        if (typeof UnifiedAdminInterface !== 'undefined') {
            window.unifiedAdminInterface = new UnifiedAdminInterface(
                window.serverAccessManager,
                this.audioEngine,
                window.multiChannelEngine,
                window.vstStreamingEngine
            );
        }

        // Initialize Jukebox Manager for Jellyfin integration
        if (typeof JukeboxManager !== 'undefined') {
            window.jukeboxManager = new JukeboxManager(this);
            console.log('Jukebox manager initialized');
        }

        console.log('Advanced systems initialized');
    }

    initializePASystemAndTTS() {
        // Initialize PA System Manager (after WebRTC is ready)
        if (typeof PASystemManager !== 'undefined' && this.webrtcManager) {
            window.paSystemManager = new PASystemManager(
                this.socket,
                this.audioEngine,
                this.spatialAudio,
                this.webrtcManager
            );
        }

        // Initialize TTS Announcement Manager
        if (typeof TTSAnnouncementManager !== 'undefined' && window.paSystemManager && window.builtinEffectsProcessor) {
            window.ttsAnnouncementManager = new TTSAnnouncementManager(
                window.paSystemManager,
                window.builtinEffectsProcessor,
                this.audioEngine
            );
        }

        console.log('PA System and TTS initialized');
    }

    async connectToServer() {
        return new Promise((resolve, reject) => {
            // Determine host - use page host for web access, localhost for native apps
            const pageHost = window.location.hostname || 'localhost';
            const pagePort = window.location.port;
            const pageProtocol = window.location.protocol;
            const isNativeApp = !!window.nativeAPI;
            const isWebProduction = !isNativeApp && (pageProtocol === 'https:' ||
                pageHost.includes('voicelink.devinecreations.net') ||
                pageHost.includes('voicelink.tappedin.fm'));

            // For production web, connect via the same origin (nginx proxy)
            if (isWebProduction) {
                const url = `${pageProtocol}//${pageHost}`;
                console.log(`Connecting via nginx proxy at ${url}`);
                this.socket = io(url, {
                    timeout: 10000,
                    reconnection: true,
                    reconnectionAttempts: 5,
                    transports: ['websocket', 'polling']
                });

                this.socket.on('connect', () => {
                    console.log('Connected to VoiceLink server via nginx proxy');
                    this.updateServerStatus('online');
                    if (window.serverEncryptionManager) {
                        window.dispatchEvent(new CustomEvent('serverConnected', {
                            detail: { serverId: 'production-server', isOwner: false }
                        }));
                        window.dispatchEvent(new CustomEvent('userAuthenticated', {
                            detail: { userId: 'web-user-' + Date.now() }
                        }));
                    }
                    this.setupSocketEventListeners();
                    this.registerSession();
                    resolve();
                });

                this.socket.on('connect_error', (error) => {
                    console.error('Failed to connect to server:', error.message);
                    this.updateServerStatus('offline');
                    reject(new Error('Server not available'));
                });
                return;
            }

            // For native/local dev, use port sequence
            const host = isNativeApp ? 'localhost' : pageHost;
            // If page was loaded from a specific port, try that first
            // Port sequence: page port (if any), 3010, 4004 (Electron), etc.
            const portSequence = pagePort ? [parseInt(pagePort), 3010, 4004, 4005, 4006] : [3010, 4004, 4005, 4006, 3000, 3001];
            let currentPortIndex = 0;

            const tryConnect = (port) => {
                const url = `http://${host}:${port}`;
                console.log(`Attempting to connect to server at ${url}`);
                this.socket = io(url, {
                    timeout: 5000,
                    reconnection: true,
                    reconnectionAttempts: 3
                });

                const timeoutId = setTimeout(() => {
                    currentPortIndex++;
                    if (currentPortIndex < portSequence.length) {
                        console.log(`Port ${port} failed, trying port ${portSequence[currentPortIndex]}...`);
                        this.socket.disconnect();
                        tryConnect(portSequence[currentPortIndex]);
                    } else {
                        console.error('Failed to connect to server on all ports');
                        this.updateServerStatus('offline');
                        reject(new Error('Server not available'));
                    }
                }, 5000);

                this.socket.on('connect', () => {
                    clearTimeout(timeoutId);
                    console.log(`Connected to VoiceLink local server on port ${port}`);

                    // Update server status display
                    this.updateServerStatus('online');

                    // Initialize encryption manager events
                    if (window.serverEncryptionManager) {
                        window.dispatchEvent(new CustomEvent('serverConnected', {
                            detail: {
                                serverId: 'local-server',
                                isOwner: true // For local server, user is considered owner
                            }
                        }));

                        window.dispatchEvent(new CustomEvent('userAuthenticated', {
                            detail: {
                                userId: 'local-user-' + Date.now()
                            }
                        }));
                    }

                    this.setupSocketEventListeners();
                    this.registerSession();
                    resolve();
                });

                this.socket.on('connect_error', (error) => {
                    clearTimeout(timeoutId);
                    if (port === 3000) {
                        console.log('Port 3000 failed, trying port 3001...');
                        this.socket.disconnect();
                        tryConnect(3001);
                    } else {
                        console.error('Failed to connect to server:', error);
                        reject(error);
                    }
                });
            };

            // Start with first port in sequence (4004)
            tryConnect(portSequence[0]);
        });
    }

    setupSocketEventListeners() {
        // Remove existing listeners to prevent duplicates on reconnect
        const events = [
            'joined-room', 'user-joined', 'user-left', 'user-audio-routing-changed',
            'user-position-changed', 'user-audio-settings-changed', 'chat-message',
            'error', 'room-expiring', 'room-expired', 'forced-leave', 'background-stream'
        ];
        events.forEach(event => this.socket.off(event));
        this.socket.off('multi-device-login');
        this.socket.off('multi-device-active');
        this.socket.off('multi-device-command');

        // Room events
        this.socket.on('joined-room', (data) => {
            this.handleJoinedRoom(data.room, data.user);
        });

        this.socket.on('user-joined', (user) => {
            this.handleUserJoined(user);
        });

        this.socket.on('user-left', (data) => {
            this.handleUserLeft(data.userId);
        });

        // Audio events
        this.socket.on('user-audio-routing-changed', (data) => {
            this.handleUserAudioRoutingChanged(data.userId, data.routing);
        });

        this.socket.on('user-position-changed', (data) => {
            this.spatialAudio.setUserPosition(data.userId, data.position);
        });

        this.socket.on('user-audio-settings-changed', (data) => {
            this.handleUserAudioSettingsChanged(data.userId, data.settings);
        });

        // Chat events
        this.socket.on('chat-message', (message) => {
            this.addChatMessage(message);
        });

        // Error handling
        this.socket.on('error', (error) => {
            this.showError(error.message);
        });

        // Room expiration events (for guest/non-logged-in users)
        this.socket.on('room-expiring', (data) => {
            this.handleRoomExpiring(data);
        });

        this.socket.on('room-expired', (data) => {
            this.handleRoomExpired(data);
        });

        this.socket.on('forced-leave', (data) => {
            this.handleForcedLeave(data);
        });

        // Background stream events
        this.socket.on('background-stream', (data) => {
            this.handleBackgroundStream(data);
        });

        // Multi-device session events
        this.socket.on('multi-device-login', (data) => {
            this.handleMultiDeviceLogin(data);
        });

        this.socket.on('multi-device-active', (data) => {
            this.handleMultiDeviceActive(data);
        });

        this.socket.on('multi-device-command', (data) => {
            this.handleMultiDeviceCommand(data);
        });
    }

    // ========================================
    // MULTI-DEVICE SESSIONS
    // ========================================

    getClientId() {
        const key = 'voicelink_client_id';
        let clientId = localStorage.getItem(key);
        if (!clientId) {
            clientId = 'dev_' + Math.random().toString(36).slice(2, 10);
            localStorage.setItem(key, clientId);
        }
        return clientId;
    }

    getMultiDeviceSettings() {
        return {
            behavior: localStorage.getItem('voicelink_multi_device_behavior') || 'prompt',
            autoQuit: localStorage.getItem('voicelink_auto_quit_other') === 'true'
        };
    }

    setMultiDeviceSettings(settings = {}) {
        if (settings.behavior) {
            localStorage.setItem('voicelink_multi_device_behavior', settings.behavior);
        }
        if (typeof settings.autoQuit === 'boolean') {
            localStorage.setItem('voicelink_auto_quit_other', settings.autoQuit ? 'true' : 'false');
        }
    }

    getAuthContext() {
        const whmcsToken = localStorage.getItem('voicelink_whmcs_token') ||
            sessionStorage.getItem('voicelink_whmcs_token');
        const ecriptoToken = localStorage.getItem('voicelink_ecripto_token') ||
            sessionStorage.getItem('voicelink_ecripto_token');
        const mastodonToken = localStorage.getItem('mastodon_access_token') ||
            sessionStorage.getItem('mastodon_access_token');
        const user = this.currentUser || window.mastodonAuth?.getUser() || null;

        if (whmcsToken) {
            return { provider: 'whmcs', token: whmcsToken, user };
        }
        if (ecriptoToken) {
            return { provider: 'ecripto', token: ecriptoToken, user };
        }
        if (mastodonToken && user) {
            return { provider: 'mastodon', token: mastodonToken, user };
        }
        return null;
    }

    registerSession() {
        if (!this.socket || !this.socket.connected) return;
        const authContext = this.getAuthContext();
        if (!authContext) return;

        const payload = {
            token: authContext.token,
            provider: authContext.provider,
            deviceId: this.getClientId(),
            deviceName: navigator.platform || 'Web Client',
            deviceType: 'web',
            clientVersion: '1.0.0',
            appVersion: '1.0.0',
            timeZone: Intl.DateTimeFormat().resolvedOptions().timeZone || '',
            locale: navigator.language || '',
            locationHint: Intl.DateTimeFormat().resolvedOptions().locale || '',
            user: authContext.user
        };

        this.socket.emit('register-session', payload);
    }

    handleMultiDeviceActive(payload) {
        if (!payload || !payload.activeDevices) return;
        this.multiDeviceState.activeDevices = payload.activeDevices || [];
        this.updateMultiDeviceStatusUI();
    }

    handleMultiDeviceLogin(payload) {
        if (!payload) return;
        const data = Array.isArray(payload) ? payload[0] : payload;
        const newDevice = data?.newDevice || {};
        this.multiDeviceState.lastEvent = newDevice;
        this.multiDeviceState.activeDevices = data?.activeDevices || [];

        const settings = this.getMultiDeviceSettings();
        this.updateMultiDeviceStatusUI();

        const deviceName = newDevice.deviceName || 'Another device';
        const locationHint = newDevice.locationHint ? ` • ${newDevice.locationHint}` : '';
        const roomName = newDevice.currentRoomName ? `Room: ${newDevice.currentRoomName}` : 'No room joined';

        if (settings.autoQuit) {
            this.showMultiDeviceStatusModal(deviceName, roomName);
            this.disconnectForMultiDevice();
            return;
        }

        switch (settings.behavior) {
        case 'keep':
            this.showNotification(`Signed in on ${deviceName}${locationHint}`, 'info');
            break;
        case 'join_other_room':
            if (newDevice.currentRoomId) {
                this.joinRoomById(newDevice.currentRoomId, newDevice.currentRoomName);
            }
            break;
        case 'leave_other_room':
            this.sendMultiDeviceCommand(newDevice.deviceId, 'leave_room');
            break;
        case 'disconnect_other':
            this.sendMultiDeviceCommand(newDevice.deviceId, 'disconnect');
            break;
        case 'warn_other':
            this.sendMultiDeviceCommand(newDevice.deviceId, 'warn_feedback');
            break;
        case 'prompt':
        default:
            this.showMultiDeviceStatusModal(deviceName, roomName, newDevice);
            break;
        }
    }

    handleMultiDeviceCommand(payload) {
        const data = Array.isArray(payload) ? payload[0] : payload;
        if (!data) return;
        switch (data.action) {
        case 'leave_room':
            this.leaveRoom();
            break;
        case 'disconnect':
            this.disconnectForMultiDevice();
            break;
        case 'warn_feedback':
            this.showNotification('Another device is signed in. Consider closing one copy to prevent feedback.', 'warning');
            break;
        default:
            break;
        }
    }

    sendMultiDeviceCommand(targetDeviceId, action) {
        if (!this.socket || !targetDeviceId) return;
        this.socket.emit('multi-device-command', {
            targetDeviceId,
            action
        });
    }

    joinRoomById(roomId, roomName = '') {
        const userNameInput = document.getElementById('user-name');
        if (userNameInput && !userNameInput.value) {
            userNameInput.value = this.currentUser?.displayName || 'VoiceLink User';
        }
        const joinRoomInput = document.getElementById('join-room-id');
        if (joinRoomInput) {
            joinRoomInput.value = roomId;
        }
        if (roomName) {
            const nameEl = document.getElementById('join-room-name');
            if (nameEl) nameEl.textContent = roomName;
        }
        this.showScreen('join-room-screen');
        this.joinRoom();
    }

    disconnectForMultiDevice() {
        if (this.socket) {
            this.socket.disconnect();
            this.socket = null;
        }
        this.updateServerStatus('offline');
        this.showScreen('main-menu');
    }

    showMultiDeviceStatusModal(deviceName, roomName, newDevice = {}) {
        this.showScreen('settings-screen');
        this.openSettingsTab('connections');
        this.updateMultiDeviceStatusUI();

        const existing = document.getElementById('multi-device-modal');
        if (existing) existing.remove();

        const overlay = document.createElement('div');
        overlay.id = 'multi-device-modal';
        overlay.className = 'modal-overlay';

        const content = document.createElement('div');
        content.className = 'modal-content';

        content.innerHTML = `
            <h3>Signed in on another device</h3>
            <p style="color: rgba(255,255,255,0.7); margin-bottom: 16px;">
                ${deviceName} • ${roomName}
            </p>
            <div class="button-group">
                <button id="multi-device-join-btn" class="primary-btn">Join That Room</button>
                <button id="multi-device-leave-btn" class="secondary-btn">Ask Other to Leave</button>
                <button id="multi-device-keep-btn" class="secondary-btn">Keep Both</button>
            </div>
        `;

        overlay.appendChild(content);
        document.body.appendChild(overlay);

        document.getElementById('multi-device-join-btn')?.addEventListener('click', () => {
            overlay.remove();
            if (newDevice.currentRoomId) {
                this.joinRoomById(newDevice.currentRoomId, newDevice.currentRoomName);
            }
        });

        document.getElementById('multi-device-leave-btn')?.addEventListener('click', () => {
            overlay.remove();
            this.sendMultiDeviceCommand(newDevice.deviceId, 'leave_room');
        });

        document.getElementById('multi-device-keep-btn')?.addEventListener('click', () => {
            overlay.remove();
        });

        overlay.addEventListener('click', (e) => {
            if (e.target === overlay) overlay.remove();
        });
    }

    updateMultiDeviceStatusUI() {
        const statusEl = document.getElementById('multi-device-status');
        if (!statusEl) return;
        const devices = this.multiDeviceState.activeDevices || [];
        if (devices.length <= 1) {
            statusEl.innerHTML = `
                <div class="status-title">No other active devices detected.</div>
                <div class="status-details">You are the only active session.</div>
            `;
            return;
        }
        const otherDevices = devices.filter(d => d.deviceId !== this.getClientId());
        const deviceLines = otherDevices.map(device => {
            const room = device.currentRoomName ? ` • ${device.currentRoomName}` : '';
            const location = device.locationHint ? ` • ${device.locationHint}` : '';
            return `<div>${device.deviceName || 'Device'}${room}${location}</div>`;
        }).join('');
        statusEl.innerHTML = `
            <div class="status-title">Other active devices detected:</div>
            <div class="status-details">${deviceLines || 'Another device is active.'}</div>
        `;
    }

    openSettingsTab(tabId) {
        const tabBtn = document.querySelector(`.tab-btn[data-tab="${tabId}"]`);
        const tabContent = document.getElementById(`${tabId}-tab`);
        if (!tabBtn || !tabContent) return;
        document.querySelectorAll('.tab-btn').forEach(btn => btn.classList.remove('active'));
        document.querySelectorAll('.settings-tab').forEach(tab => tab.classList.remove('active'));
        tabBtn.classList.add('active');
        tabContent.classList.add('active');
    }

    /**
     * Handle room expiring warning
     */
    handleRoomExpiring(data) {
        const { message, timeRemaining, expiresAt } = data;
        console.log('Room expiring warning:', message, 'Time remaining:', timeRemaining);

        // Show notification
        this.showNotification(message, 'warning', 10000);

        // Start or update countdown timer display
        this.startExpirationCountdown(expiresAt, timeRemaining);
    }

    /**
     * Handle room expired event
     */
    handleRoomExpired(data) {
        const { message } = data;
        console.log('Room expired:', message);

        // Stop countdown timer
        this.stopExpirationCountdown();

        // Show expiration modal
        this.showRoomExpiredModal(message);
    }

    /**
     * Handle forced leave from room
     */
    handleForcedLeave(data) {
        const { reason, roomId } = data;
        console.log('Forced to leave room:', reason);

        // Clean up room state
        this.currentRoomId = null;
        this.stopExpirationCountdown();
        this.stopBackgroundStream();

        // Return to main menu
        this.showScreen('main-menu');
        this.showNotification('You have been disconnected: ' + reason, 'info');
    }

    /**
     * Handle background stream event - plays ambient/radio stream in room
     */
    handleBackgroundStream(data) {
        console.log('[BackgroundStream] Received stream config:', data);

        const { id, name, url, volume, hidden, autoPlay, fadeInDuration } = data;

        if (!url) {
            console.warn('[BackgroundStream] No stream URL provided');
            return;
        }

        // Create or get background audio element
        let bgAudio = document.getElementById('background-stream-audio');
        if (!bgAudio) {
            bgAudio = document.createElement('audio');
            bgAudio.id = 'background-stream-audio';
            bgAudio.className = hidden ? 'hidden-stream' : '';
            bgAudio.crossOrigin = 'anonymous';
            bgAudio.preload = 'none';
            document.body.appendChild(bgAudio);
        }

        // Store stream info for controls
        this.backgroundStream = {
            id,
            name,
            url,
            volume: volume / 100,
            hidden,
            element: bgAudio
        };

        bgAudio.src = url;
        bgAudio.volume = 0;

        if (autoPlay) {
            bgAudio.play().then(() => {
                console.log(`[BackgroundStream] Playing: ${name}`);
                // Fade in
                const targetVolume = volume / 100;
                const fadeSteps = 20;
                const fadeStepTime = fadeInDuration / fadeSteps;
                let currentStep = 0;

                const fadeInterval = setInterval(() => {
                    currentStep++;
                    bgAudio.volume = (currentStep / fadeSteps) * targetVolume;
                    if (currentStep >= fadeSteps) {
                        clearInterval(fadeInterval);
                        bgAudio.volume = targetVolume;
                    }
                }, fadeStepTime);
            }).catch(err => {
                console.warn('[BackgroundStream] Autoplay blocked:', err.message);
                // Try again on user interaction
                document.addEventListener('click', () => bgAudio.play(), { once: true });
            });
        }
    }

    /**
     * Stop background stream
     */
    stopBackgroundStream() {
        const bgAudio = document.getElementById('background-stream-audio');
        if (bgAudio) {
            bgAudio.pause();
            bgAudio.src = '';
        }
        this.backgroundStream = null;
    }

    /**
     * Set background stream volume (0-100)
     */
    setBackgroundStreamVolume(volume) {
        const bgAudio = document.getElementById('background-stream-audio');
        if (bgAudio) {
            bgAudio.volume = volume / 100;
            if (this.backgroundStream) {
                this.backgroundStream.volume = volume / 100;
            }
        }
    }

    /**
     * Start expiration countdown timer display
     */
    startExpirationCountdown(expiresAt, initialTimeRemaining) {
        // Stop any existing countdown
        this.stopExpirationCountdown();

        const expirationTime = new Date(expiresAt).getTime();

        // Create or update countdown display
        let countdownEl = document.getElementById('room-expiration-countdown');
        if (!countdownEl) {
            countdownEl = document.createElement('div');
            countdownEl.id = 'room-expiration-countdown';
            countdownEl.className = 'room-expiration-countdown';

            // Build countdown UI using DOM methods (safer than innerHTML)
            const iconDiv = document.createElement('div');
            iconDiv.className = 'countdown-icon';
            iconDiv.textContent = '⏱️';

            const textDiv = document.createElement('div');
            textDiv.className = 'countdown-text';

            const labelSpan = document.createElement('span');
            labelSpan.className = 'countdown-label';
            labelSpan.textContent = 'Guest Room Expires In:';

            const timeSpan = document.createElement('span');
            timeSpan.className = 'countdown-time';
            timeSpan.textContent = '--:--';

            textDiv.appendChild(labelSpan);
            textDiv.appendChild(document.createElement('br'));
            textDiv.appendChild(timeSpan);

            const loginDiv = document.createElement('div');
            loginDiv.className = 'countdown-login';

            const loginBtn = document.createElement('button');
            loginBtn.className = 'login-to-extend';
            loginBtn.textContent = 'Login for Unlimited Time';
            loginBtn.onclick = () => this.showMastodonLoginModal();
            loginDiv.appendChild(loginBtn);

            countdownEl.appendChild(iconDiv);
            countdownEl.appendChild(textDiv);
            countdownEl.appendChild(loginDiv);

            // Add styles
            countdownEl.style.cssText = `
                position: fixed;
                bottom: 20px;
                right: 20px;
                background: linear-gradient(135deg, #ff6b6b, #ee5a24);
                color: white;
                padding: 15px 20px;
                border-radius: 12px;
                display: flex;
                align-items: center;
                gap: 15px;
                box-shadow: 0 4px 20px rgba(238, 90, 36, 0.4);
                z-index: 10000;
                font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
            `;
            document.body.appendChild(countdownEl);
        }

        const timeDisplay = countdownEl.querySelector('.countdown-time');

        // Update countdown every second
        this.expirationCountdownInterval = setInterval(() => {
            const now = Date.now();
            const remaining = expirationTime - now;

            if (remaining <= 0) {
                this.stopExpirationCountdown();
                return;
            }

            const minutes = Math.floor(remaining / 60000);
            const seconds = Math.floor((remaining % 60000) / 1000);
            timeDisplay.textContent = minutes + ':' + seconds.toString().padStart(2, '0');

            // Pulse effect when under 1 minute
            if (remaining < 60000) {
                countdownEl.style.animation = 'pulse 0.5s ease-in-out infinite';
            }
        }, 1000);
    }

    /**
     * Stop expiration countdown
     */
    stopExpirationCountdown() {
        if (this.expirationCountdownInterval) {
            clearInterval(this.expirationCountdownInterval);
            this.expirationCountdownInterval = null;
        }

        const countdownEl = document.getElementById('room-expiration-countdown');
        if (countdownEl) {
            countdownEl.remove();
        }
    }

    /**
     * Show room expired modal using DOM methods
     */
    showRoomExpiredModal(message) {
        const modal = document.createElement('div');
        modal.className = 'room-expired-modal';

        // Create overlay
        const overlay = document.createElement('div');
        overlay.className = 'modal-overlay';
        overlay.style.cssText = 'position: fixed; inset: 0; background: rgba(0,0,0,0.8); z-index: 10001;';

        // Create content container
        const content = document.createElement('div');
        content.className = 'modal-content';
        content.style.cssText = `
            position: fixed;
            top: 50%;
            left: 50%;
            transform: translate(-50%, -50%);
            background: linear-gradient(135deg, #1a1a2e 0%, #16213e 100%);
            padding: 30px;
            border-radius: 16px;
            text-align: center;
            z-index: 10002;
            max-width: 400px;
            width: 90%;
            box-shadow: 0 10px 40px rgba(0,0,0,0.5);
        `;

        // Icon
        const icon = document.createElement('div');
        icon.style.cssText = 'font-size: 4rem; margin-bottom: 20px;';
        icon.textContent = '⏰';

        // Title
        const title = document.createElement('h2');
        title.style.cssText = 'color: #ff6b6b; margin-bottom: 15px;';
        title.textContent = 'Room Expired';

        // Message
        const msgEl = document.createElement('p');
        msgEl.style.cssText = 'color: #aaa; margin-bottom: 25px;';
        msgEl.textContent = message;

        // Button container
        const btnContainer = document.createElement('div');
        btnContainer.style.cssText = 'display: flex; flex-direction: column; gap: 10px;';

        // Login button
        const loginBtn = document.createElement('button');
        loginBtn.style.cssText = `
            background: linear-gradient(135deg, #7b2cbf, #00d4ff);
            color: white;
            border: none;
            padding: 12px 24px;
            border-radius: 8px;
            cursor: pointer;
            font-size: 1rem;
        `;
        loginBtn.textContent = '🐘 Login with Mastodon';
        loginBtn.onclick = () => {
            modal.remove();
            this.showMastodonLoginModal();
        };

        // Return button
        const returnBtn = document.createElement('button');
        returnBtn.style.cssText = `
            background: transparent;
            color: #888;
            border: 1px solid #444;
            padding: 10px 20px;
            border-radius: 8px;
            cursor: pointer;
        `;
        returnBtn.textContent = 'Return to Menu';
        returnBtn.onclick = () => {
            modal.remove();
            this.showScreen('main-menu');
        };

        btnContainer.appendChild(loginBtn);
        btnContainer.appendChild(returnBtn);

        content.appendChild(icon);
        content.appendChild(title);
        content.appendChild(msgEl);
        content.appendChild(btnContainer);

        modal.appendChild(overlay);
        modal.appendChild(content);
        document.body.appendChild(modal);
    }

    setupUIEventListeners() {
        // Menu navigation
        document.getElementById('create-room-btn')?.addEventListener('click', () => {
            this.showScreen('create-room-screen');
            this.setupRoomPrivacyControls();
        });

        document.getElementById('join-room-btn')?.addEventListener('click', () => {
            this.showScreen('join-room-screen');
        });

        document.getElementById('comprehensive-settings-btn')?.addEventListener('click', () => {
            // Use unified admin interface for comprehensive settings
            if (window.unifiedAdminInterface) {
                window.unifiedAdminInterface.showAdminPanel();
            } else {
                window.settingsInterfaceManager?.showSettings();
            }
        });

        document.getElementById('multi-input-manager-btn')?.addEventListener('click', () => {
            // Use unified admin interface for multi-input management
            if (window.unifiedAdminInterface) {
                window.unifiedAdminInterface.showAdminPanel();
                window.unifiedAdminInterface.switchAdminSection('audio');
            } else {
                window.multiInputManager?.show();
            }
        });

        document.getElementById('open-settings-btn')?.addEventListener('click', () => {
            // Show settings screen
            this.showScreen('settings-screen');
            this.initializeSettingsScreen();
        });


        document.getElementById('user-settings-btn')?.addEventListener('click', () => {
            // Use unified admin interface for user settings
            if (window.unifiedAdminInterface) {
                window.unifiedAdminInterface.showAdminPanel();
                window.unifiedAdminInterface.switchAdminSection('users');
            } else {
                window.userSettingsInterface?.show();
            }
        });

        document.getElementById('media-streaming-btn')?.addEventListener('click', () => {
            window.mediaStreamingInterface?.show();
        });

        // Server control buttons
        document.getElementById('start-server-btn')?.addEventListener('click', async () => {
            this.setServerButtonState('starting');
            try {
                const result = await window.nativeAPI?.startServer();
                if (result) {
                    console.log('Server started successfully');
                    // Status will be updated via connection success
                } else {
                    console.error('Failed to start server');
                    this.setServerButtonState('offline');
                }
            } catch (error) {
                console.error('Error starting server:', error);
                this.setServerButtonState('offline');
            }
        });

        document.getElementById('stop-server-btn')?.addEventListener('click', async () => {
            this.setServerButtonState('stopping');
            try {
                const result = await window.nativeAPI?.stopServer();
                if (result) {
                    console.log('Server stopped successfully');
                    this.updateServerStatus('offline');
                    this.setServerButtonState('offline');
                } else {
                    console.error('Failed to stop server');
                    this.setServerButtonState('online');
                }
            } catch (error) {
                console.error('Error stopping server:', error);
                this.setServerButtonState('online');
            }
        });

        document.getElementById('restart-server-btn')?.addEventListener('click', async () => {
            this.setServerButtonState('restarting');
            try {
                const result = await window.nativeAPI?.restartServer();
                if (result) {
                    console.log('Server restarted successfully');
                    // Status will be updated via connection success
                } else {
                    console.error('Failed to restart server');
                    this.setServerButtonState('offline');
                }
            } catch (error) {
                console.error('Error restarting server:', error);
                this.setServerButtonState('offline');
            }
        });


        // Add test audio button
        document.getElementById('test-audio-btn')?.addEventListener('click', () => {
            this.testAudioPlayback();
        });

        // Quick audio button
        document.getElementById('quick-audio-btn')?.addEventListener('click', () => {
            this.showQuickAudioPanel();
        });

        // Room settings and quick audio (from room screen)
        document.getElementById('room-settings-btn')?.addEventListener('click', () => {
            this.showScreen('settings-screen');
            this.initializeSettingsScreen();
        });

        // Jukebox button - opens Jellyfin music player
        document.getElementById('room-jukebox-btn')?.addEventListener('click', () => {
            if (window.jukeboxManager) {
                window.jukeboxManager.togglePanel();
            } else {
                this.showToast('Jukebox not available. Configure Jellyfin in settings.');
            }
        });

        document.getElementById('quick-audio-room-btn')?.addEventListener('click', () => {
            this.showQuickAudioPanel();
        });

        // Settings screen navigation
        document.getElementById('close-settings')?.addEventListener('click', () => {
            // Go back to previous screen (main menu or room)
            if (this.currentRoom) {
                this.showScreen('voice-chat-screen');
            } else {
                this.showScreen('main-menu');
            }
        });

        document.getElementById('back-from-settings')?.addEventListener('click', () => {
            // Go back to previous screen (main menu or room)
            if (this.currentRoom) {
                this.showScreen('voice-chat-screen');
            } else {
                this.showScreen('main-menu');
            }
        });

        // Desktop app controls (only available in Electron)
        if (window.nativeAPI) {
            // Show desktop controls section
            const desktopControls = document.getElementById('desktop-controls');
            if (desktopControls) {
                desktopControls.style.display = 'block';
            }

            // Minimize to tray button
            document.getElementById('minimize-to-tray-btn')?.addEventListener('click', async () => {
                try {
                    await window.nativeAPI.minimizeToTray();
                } catch (error) {
                    console.error('Failed to minimize to tray:', error);
                }
            });

            // Preferences button
            document.getElementById('preferences-btn')?.addEventListener('click', async () => {
                try {
                    await window.nativeAPI.showPreferences();
                } catch (error) {
                    console.error('Failed to show preferences:', error);
                }
            });
        }

        // Back buttons
        document.getElementById('back-to-menu')?.addEventListener('click', () => {
            this.showScreen('main-menu');
        });

        document.getElementById('back-to-menu-2')?.addEventListener('click', () => {
            this.showScreen('main-menu');
        });

        document.getElementById('back-to-menu-3')?.addEventListener('click', () => {
            this.showScreen('main-menu');
        });

        // Room creation
        document.getElementById('create-room-form')?.addEventListener('submit', (e) => {
            e.preventDefault();
            this.createRoom();
        });

        // Visibility option toggle
        document.querySelectorAll('.visibility-option').forEach(option => {
            option.addEventListener('click', function() {
                document.querySelectorAll('.visibility-option').forEach(o => o.classList.remove('selected'));
                this.classList.add('selected');
            });
        });

        // Access type option toggle
        document.querySelectorAll('.access-option').forEach(option => {
            option.addEventListener('click', function() {
                document.querySelectorAll('.access-option').forEach(o => o.classList.remove('selected'));
                this.classList.add('selected');
            });
        });

        // Join room
        document.getElementById('join-room-form')?.addEventListener('submit', (e) => {
            e.preventDefault();
            this.joinRoom();
        });

        // Voice chat controls
        document.getElementById('mute-btn')?.addEventListener('click', () => {
            const isMuted = this.webrtcManager?.isLocalMuted() || false;
            this.webrtcManager?.setMuted(!isMuted);
            this.playUiSound('button-click.wav');
            this.announce(`Microphone ${!isMuted ? 'muted' : 'unmuted'}`, 'polite');
        });

        document.getElementById('deafen-btn')?.addEventListener('click', () => {
            // Toggle deafen state (implement state tracking)
            const isDeafened = this.isDeafened || false;
            this.isDeafened = !isDeafened;
            this.webrtcManager?.setDeafened(this.isDeafened);
            this.playUiSound('button-click.wav');
            this.announce(`Output ${this.isDeafened ? 'muted' : 'unmuted'}`, 'polite');
        });

        document.getElementById('leave-room-btn')?.addEventListener('click', () => {
            this.leaveRoom();
        });

        // Share room button (in room header)
        document.getElementById('share-room-btn')?.addEventListener('click', () => {
            if (this.currentRoom) {
                this.shareRoom(this.currentRoom.id);
            }
        });

        document.getElementById('settings-btn')?.addEventListener('click', () => {
            this.toggleAudioRoutingPanel();
        });

        // Chat
        document.getElementById('send-message-btn')?.addEventListener('click', () => {
            this.sendChatMessage();
        });

        document.getElementById('chat-input')?.addEventListener('keypress', (e) => {
            if (e.key === 'Enter') {
                this.sendChatMessage();
            }
        });

        // Audio settings
        document.getElementById('test-microphone')?.addEventListener('click', () => {
            this.audioEngine.startMicrophoneTest();
        });

        document.getElementById('test-speakers')?.addEventListener('click', () => {
            const btn = document.getElementById('test-speakers');
            this.audioEngine.testSpeakers().finally(() => {
                if (btn) {
                    btn.textContent = this.audioEngine?.isTestAudioPlaying ? 'Stop Test' : 'Sound Test';
                }
            });
        });

        // Auto-play sound test after output device changes
        const outputDeviceSettings = document.getElementById('output-device-settings');
        outputDeviceSettings?.addEventListener('change', () => {
            const btn = document.getElementById('test-speakers');
            this.audioEngine.testSpeakers().finally(() => {
                if (btn) {
                    btn.textContent = this.audioEngine?.isTestAudioPlaying ? 'Stop Test' : 'Sound Test';
                }
            });
        });

        document.getElementById('save-audio-settings')?.addEventListener('click', () => {
            this.saveAudioSettings();
        });

        // Audio routing
        document.getElementById('close-routing-panel')?.addEventListener('click', () => {
            this.toggleAudioRoutingPanel();
        });

        // Spatial audio settings
        document.getElementById('spatial-audio-enabled')?.addEventListener('change', (e) => {
            if (e.target.checked) {
                this.spatialAudio.enable();
            } else {
                this.spatialAudio.disable();
            }
        });

        document.getElementById('reverb-setting')?.addEventListener('change', (e) => {
            this.spatialAudio.setRoomModel(e.target.value);
        });

        // Enable click anywhere to resume audio context
        document.addEventListener('click', () => {
            this.audioEngine?.resumeAudioContext();
            this.spatialAudio?.resumeAudioContext();
        }, { once: true });

        // Initialize button click audio feedback
        this.initializeButtonAudio();

        // Setup Mastodon authentication
        this.setupMastodonAuth();

        // Check for OAuth callback
        this.checkOAuthCallback();
    }

    showScreen(screenId) {
        // Hide all screens
        this.ui.screens.forEach(screen => {
            document.getElementById(screen)?.classList.remove('active');
        });

        // Show target screen
        document.getElementById(screenId)?.classList.add('active');
        this.ui.currentScreen = screenId;

        console.log('Switched to screen:', screenId);
    }

    updateServerStatus(status) {
        const statusValue = document.getElementById('server-status-value');

        if (statusValue) {
            if (status === 'online') {
                statusValue.textContent = 'Online';
                statusValue.className = 'status-value status-online';
            } else {
                statusValue.textContent = 'Offline';
                statusValue.className = 'status-value status-offline';
            }
        }

        // Also update user and room counts when we have socket events
        if (this.socket && status === 'online') {
            this.socket.on('room-list-updated', (data) => {
                const roomsValue = document.getElementById('server-rooms-value');
                if (roomsValue && data.rooms) {
                    roomsValue.textContent = data.rooms.length;
                }
            });

            this.socket.on('user-count-updated', (count) => {
                const usersValue = document.getElementById('server-users-value');
                if (usersValue) {
                    usersValue.textContent = count;
                }
            });
        }

        // Update server control button states
        this.setServerButtonState(status);

        // Update network info if in Electron
        this.updateNetworkInfo();
    }

    async updateNetworkInfo() {
        if (!window.nativeAPI) return;

        try {
            const info = await window.nativeAPI.getServerInfo();
            if (!info) return;

            // Update internet status
            const internetStatus = document.getElementById('internet-status-value');
            if (internetStatus) {
                if (info.isOnline) {
                    internetStatus.textContent = 'Online';
                    internetStatus.className = 'status-value status-online';
                } else {
                    internetStatus.textContent = 'Offline';
                    internetStatus.className = 'status-value status-offline';
                }
            }

            // Update local IP
            const localIp = document.getElementById('local-ip-value');
            if (localIp) {
                localIp.textContent = info.localIP || 'Not detected';
            }

            // Update public IP
            const publicIp = document.getElementById('public-ip-value');
            if (publicIp) {
                publicIp.textContent = info.externalIP || 'Not available';
            }

            // Update port
            const portValue = document.getElementById('server-port-value');
            if (portValue) {
                portValue.textContent = info.port || '--';
            }

            // Enable/disable public URL button
            const publicUrlBtn = document.getElementById('copy-public-url-btn');
            if (publicUrlBtn) {
                publicUrlBtn.disabled = !info.externalIP;
            }

            // Update network binding display
            this.updateNetworkBindingDisplay(info.networkInterfaces, info.selectedInterface);

        } catch (error) {
            console.error('Failed to update network info:', error);
        }
    }

    // Handle network info update from main process IPC
    handleNetworkInfoUpdate(info) {
        if (!info) return;

        console.log('Updating UI with network info:', info);

        // Update server status (from main process)
        const serverStatus = document.getElementById('server-status-value');
        if (serverStatus) {
            if (info.isServerRunning) {
                serverStatus.textContent = 'Running';
                serverStatus.className = 'status-value status-online';
            } else {
                serverStatus.textContent = 'Stopped';
                serverStatus.className = 'status-value status-offline';
            }
        }

        // Update internet status
        const internetStatus = document.getElementById('internet-status-value');
        if (internetStatus) {
            if (info.isOnline) {
                internetStatus.textContent = 'Online';
                internetStatus.className = 'status-value status-online';
            } else {
                internetStatus.textContent = 'Offline';
                internetStatus.className = 'status-value status-offline';
            }
        }

        // Update local IP
        const localIp = document.getElementById('local-ip-value');
        if (localIp) {
            localIp.textContent = info.localIP || 'Not detected';
        }

        // Update public IP
        const publicIp = document.getElementById('public-ip-value');
        if (publicIp) {
            publicIp.textContent = info.externalIP || 'Not available';
        }

        // Update port
        const portValue = document.getElementById('server-port-value');
        if (portValue && info.port) {
            portValue.textContent = info.port;
        }

        // Enable/disable public URL button
        const publicUrlBtn = document.getElementById('copy-public-url-btn');
        if (publicUrlBtn) {
            publicUrlBtn.disabled = !info.externalIP;
        }

        // Update network binding display
        if (info.networkInterfaces && info.selectedInterface) {
            this.updateNetworkBindingDisplay(info.networkInterfaces, info.selectedInterface);
        }
    }

    updateNetworkBindingDisplay(interfaces, selectedInterface) {
        const bindingValue = document.getElementById('network-binding-value');
        if (!bindingValue) return;

        // Find the selected interface
        const selected = interfaces.find(i => i.name === selectedInterface);

        if (selectedInterface === 'all' || !selected) {
            bindingValue.textContent = 'All Networks';
        } else {
            // Show display name with IP address
            const displayName = selected.displayName || selected.name;
            bindingValue.textContent = `${displayName} (${selected.address})`;
        }
    }

    setupNetworkEventHandlers() {
        // Detect if running in native desktop app
        const isNativeApp = !!window.nativeAPI;

        console.log('Platform detection:', {
            isNativeApp,
            hasNativeAPI: !!window.nativeAPI
        });

        if (!isNativeApp) {
            // WEB BROWSER: Hide desktop-only elements
            document.getElementById('copy-local-url-btn')?.remove();
            document.getElementById('copy-localhost-url-btn')?.remove();
            document.getElementById('refresh-network-btn')?.remove();
            // Hide all desktop-only sections (network binding, menubar references)
            document.querySelectorAll('.desktop-only').forEach(el => el.remove());
            document.querySelector('.network-interface-section')?.remove();
        } else {
            // DESKTOP APP: Hide login benefits and download section (already have the app)
            console.log('Desktop app detected - hiding web-only elements');
            const loginBenefits = document.getElementById('login-benefits');
            const downloadSection = document.getElementById('download-app-section');
            console.log('Elements to remove:', { loginBenefits: !!loginBenefits, downloadSection: !!downloadSection });
            loginBenefits?.remove();
            downloadSection?.remove();
            // Hide all web-only elements (download links, etc.)
            const webOnlyElements = document.querySelectorAll('.web-only');
            console.log('Web-only elements found:', webOnlyElements.length);
            webOnlyElements.forEach(el => el.remove());
        }

        // Copy URL buttons
        document.getElementById('copy-local-url-btn')?.addEventListener('click', async () => {
            if (window.nativeAPI) {
                const result = await window.nativeAPI.copyUrl('local');
                if (result?.success) {
                    this.showToast('Local URL copied to clipboard');
                }
            }
        });

        document.getElementById('copy-public-url-btn')?.addEventListener('click', async () => {
            if (window.nativeAPI) {
                const result = await window.nativeAPI.copyUrl('public');
                if (result?.success) {
                    this.showToast('Public URL copied (requires port forwarding)');
                } else {
                    this.showToast('Public IP not available');
                }
            }
        });

        document.getElementById('copy-localhost-url-btn')?.addEventListener('click', async () => {
            if (window.nativeAPI) {
                const result = await window.nativeAPI.copyUrl('localhost');
                if (result?.success) {
                    this.showToast('Localhost URL copied to clipboard');
                }
            }
        });

        // Refresh network button
        document.getElementById('refresh-network-btn')?.addEventListener('click', async () => {
            if (window.nativeAPI) {
                this.showToast('Refreshing network info...');
                await window.nativeAPI.refreshNetworkInfo();
                await this.updateNetworkInfo();
                this.showToast('Network info refreshed');
            }
        });

        // Network interface selection moved to menubar/tray menu
        // Use tray menu to change which interface the server listens on
    }

    showToast(message, duration = 3000) {
        // Create or reuse toast element
        let toast = document.getElementById('app-toast');
        if (!toast) {
            toast = document.createElement('div');
            toast.id = 'app-toast';
            toast.className = 'app-toast';
            toast.setAttribute('role', 'status');
            toast.setAttribute('aria-live', 'polite');
            document.body.appendChild(toast);
        }

        toast.textContent = message;
        toast.classList.add('show');

        setTimeout(() => {
            toast.classList.remove('show');
        }, duration);
    }

    /**
     * Show whisper mode status indicator
     */
    showWhisperStatus(isWhispering, targetUsername = null) {
        let indicator = document.getElementById('whisper-status-indicator');

        if (isWhispering) {
            if (!indicator) {
                indicator = document.createElement('div');
                indicator.id = 'whisper-status-indicator';
                indicator.className = 'whisper-status-indicator';
                indicator.setAttribute('role', 'status');
                indicator.setAttribute('aria-live', 'assertive');
                document.body.appendChild(indicator);
            }
            indicator.innerHTML = `<span class="whisper-icon">Whispering</span> to ${targetUsername || 'user'}`;
            indicator.classList.add('active');
        } else if (indicator) {
            indicator.classList.remove('active');
        }
    }

    /**
     * Update whisper target UI indicator
     */
    updateWhisperTargetUI(userId, username) {
        // Update any UI elements showing current whisper target
        const targetDisplay = document.getElementById('whisper-target-display');
        if (targetDisplay) {
            if (userId) {
                targetDisplay.textContent = `Whisper target: ${username || userId}`;
                targetDisplay.style.display = 'block';
            } else {
                targetDisplay.style.display = 'none';
            }
        }

        // Show toast notification
        if (userId) {
            this.showToast(`Whisper target set: ${username || userId}. Hold Enter to whisper.`, 4000);
        }
    }

    /**
     * Set whisper target from user context menu
     */
    setWhisperTarget(userId, username) {
        if (this.whisperMode) {
            this.whisperMode.setWhisperTarget(userId, username);
        }
    }

    setServerButtonState(status) {
        const startBtn = document.getElementById('start-server-btn');
        const stopBtn = document.getElementById('stop-server-btn');
        const restartBtn = document.getElementById('restart-server-btn');

        // Only show server control buttons in native app, not in browser
        const isNativeApp = !!this.getNativeAPI();
        if (!isNativeApp) {
            // Hide all server control buttons for web visitors
            if (startBtn) startBtn.style.display = 'none';
            if (stopBtn) stopBtn.style.display = 'none';
            if (restartBtn) restartBtn.style.display = 'none';
            return;
        }

        // Show/hide buttons based on status (native only)
        if (startBtn && stopBtn && restartBtn) {
            switch (status) {
                case 'online':
                    startBtn.style.display = 'none';
                    stopBtn.style.display = 'inline-block';
                    restartBtn.style.display = 'inline-block';
                    stopBtn.disabled = false;
                    restartBtn.disabled = false;
                    break;
                case 'offline':
                    startBtn.style.display = 'inline-block';
                    stopBtn.style.display = 'none';
                    restartBtn.style.display = 'none';
                    startBtn.disabled = false;
                    break;
                case 'starting':
                    startBtn.style.display = 'inline-block';
                    stopBtn.style.display = 'none';
                    restartBtn.style.display = 'none';
                    startBtn.disabled = true;
                    startBtn.textContent = '⏳ Starting...';
                    break;
                case 'stopping':
                    startBtn.style.display = 'none';
                    stopBtn.style.display = 'inline-block';
                    restartBtn.style.display = 'inline-block';
                    stopBtn.disabled = true;
                    restartBtn.disabled = true;
                    stopBtn.textContent = '⏳ Stopping...';
                    break;
                case 'restarting':
                    startBtn.style.display = 'none';
                    stopBtn.style.display = 'none';
                    restartBtn.style.display = 'inline-block';
                    restartBtn.disabled = true;
                    restartBtn.textContent = '⏳ Restarting...';
                    break;
            }

            // Reset button text if not in transitional states
            if (status === 'online' || status === 'offline') {
                startBtn.textContent = '▶️ Start Server';
                stopBtn.textContent = '⏹️ Stop Server';
                restartBtn.textContent = '🔄 Restart Server';
            }
        }
    }

    startServerStatusMonitoring() {
        // Initial status check - update based on current socket state
        if (this.socket && this.socket.connected) {
            this.updateServerStatus('online');
            console.log('Server status: connected');
        } else {
            this.updateServerStatus('offline');
            console.log('Server status: not connected');
        }

        // Periodic status monitoring every 10 seconds
        this.statusMonitorInterval = setInterval(() => {
            if (this.socket && this.socket.connected) {
                // Server is responsive
                this.updateServerStatus('online');
            } else {
                // Server is not responsive, try to reconnect
                this.updateServerStatus('offline');
                // Optionally attempt reconnection
                if (this.socket && !this.socket.connected) {
                    console.log('Attempting to reconnect to server...');
                    this.connectToServer().catch(() => {
                        console.log('Reconnection failed, server remains offline');
                    });
                }
            }
        }, 10000);

        // Also monitor socket events for real-time updates
        if (this.socket) {
            this.socket.on('disconnect', () => {
                console.log('Server disconnected');
                this.updateServerStatus('offline');
            });

            this.socket.on('reconnect', () => {
                console.log('Server reconnected');
                this.updateServerStatus('online');
            });
        }
    }

    getCurrentPort() {
        // Try to get port from socket connection
        if (this.socket && this.socket.io && this.socket.io.opts) {
            const url = this.socket.io.opts.hostname || this.socket.io.opts.host;
            if (this.socket.io.opts.port) {
                return this.socket.io.opts.port;
            }
        }
        return null;
    }

    async loadRooms() {
        try {
            const apiBase = this.getApiBaseUrl();

            // Fetch rooms from local server (which now proxies main server rooms)
            let rooms = [];
            try {
                console.log('Fetching rooms from:', apiBase);
                const response = await fetch(`${apiBase}/api/rooms?source=app`);
                console.log('Room fetch response status:', response.status);
                if (response.ok) {
                    rooms = await response.json();
                    console.log('Got', rooms.length, 'rooms');

                    // Update room count display
                    const roomsValue = document.getElementById('server-rooms-value');
                    if (roomsValue) {
                        roomsValue.textContent = rooms.length;
                    }
                }
            } catch (e) {
                console.error('Room fetch error:', e.message);
            }

            // Check if user is authenticated
            const isAuthenticated = window.mastodonAuth?.isAuthenticated() || false;
            const currentUser = window.mastodonAuth?.getUser();

            // Filter rooms based on authentication state
            if (!isAuthenticated) {
                // Guests can only see rooms that are:
                // 1. Marked as public/visible to visitors (or not explicitly private)
                // 2. Default rooms (always visible)
                // 3. Rooms from main server (null visibility = public by default)
                rooms = rooms.filter(room =>
                    room.visibility === 'public' ||
                    room.visibility === null ||
                    room.visibility === undefined ||
                    room.visibleToGuests === true ||
                    room.isDefault === true ||
                    room.serverSource === 'main'  // Main server rooms always visible
                );
            }

            // Calculate how many rooms are hidden from guests
            const totalServerRooms = rooms.length; // This is already filtered
            let hiddenCount = 0;

            if (!isAuthenticated) {
                // Show up to 50 rooms for guests (increased from 5 for better discovery)
                const guestRoomLimit = 50;
                if (rooms.length > guestRoomLimit) {
                    hiddenCount = rooms.length - guestRoomLimit;
                    rooms = rooms.slice(0, guestRoomLimit);
                }
            }

            const roomList = document.getElementById('room-list');
            if (roomList) {
                if (rooms.length === 0) {
                    const message = isAuthenticated
                        ? `<div class="no-rooms-message">
                               <p class="text-muted">No rooms available</p>
                               <p class="text-small">Create a room to get started</p>
                           </div>`
                        : `<div class="no-rooms-message">
                               <p class="text-muted">No public rooms available</p>
                               <p class="text-small">Login with Mastodon to see all rooms or create your own</p>
                               <button class="auth-btn mastodon-btn" onclick="document.getElementById('mastodon-login-btn')?.click()">
                                   Login with Mastodon
                               </button>
                           </div>`;
                    roomList.innerHTML = message;
                } else {
                    // Group rooms by category for better organization
                    const groupedRooms = this.groupRoomsByCategory(rooms);
                    let html = this.renderGroupedRooms(groupedRooms);

                    // Add login prompt for guests if there are hidden rooms
                    if (!isAuthenticated && hiddenCount > 0) {
                        html += `
                            <div class="login-to-see-more">
                                <p>+${hiddenCount} more room${hiddenCount > 1 ? 's' : ''} available</p>
                                <button class="auth-btn mastodon-btn small" onclick="document.getElementById('mastodon-login-btn')?.click()">
                                    Login to see all rooms
                                </button>
                            </div>
                        `;
                    } else if (!isAuthenticated) {
                        html += `
                            <div class="login-prompt-small">
                                <p>Have a direct room link? Join with ID above.</p>
                                <button class="auth-btn mastodon-btn small" onclick="document.getElementById('mastodon-login-btn')?.click()">
                                    Login for more features
                                </button>
                            </div>
                        `;
                    }

                    roomList.innerHTML = html;
                }

                // Update encryption status indicators for all rooms
                if (window.encryptionStatusDisplay) {
                    window.encryptionStatusDisplay.updateRoomListStatus(
                        rooms.map(room => ({ id: room.id, element: roomList.querySelector(`[data-room-id="${room.id}"]`) }))
                    );
                }
            }
        } catch (error) {
            console.error('Failed to load rooms:', error);
            // Show error message in room list
            const roomList = document.getElementById('room-list');
            if (roomList) {
                roomList.innerHTML = `<div class="no-rooms-message">
                    <p class="text-muted">Could not load rooms</p>
                    <p class="text-small">${error.message}</p>
                    <button class="btn btn-secondary" onclick="window.voiceLinkApp?.loadRooms()">Retry</button>
                </div>`;
            }
        }
    }

    groupRoomsByCategory(rooms) {
        const grouped = {
            default: {},
            user: []
        };

        rooms.forEach(room => {
            if (room.isDefault && room.template) {
                const category = room.template.category || 'Other';
                if (!grouped.default[category]) {
                    grouped.default[category] = {
                        icon: room.template.icon || '🏠',
                        rooms: []
                    };
                }
                grouped.default[category].rooms.push(room);
            } else {
                grouped.user.push(room);
            }
        });

        return grouped;
    }

    renderGroupedRooms(groupedRooms) {
        let html = '';

        // Render default room categories
        if (Object.keys(groupedRooms.default).length > 0) {
            html += '<div class="room-categories">';

            for (const [category, categoryData] of Object.entries(groupedRooms.default)) {
                html += `
                    <div class="room-category">
                        <div class="category-header">
                            <h4 class="category-title">${category} (Federated)</h4>
                            <span class="category-count">${categoryData.rooms.length} room${categoryData.rooms.length !== 1 ? 's' : ''}</span>
                        </div>
                        <div class="category-rooms">
                            ${categoryData.rooms.map(room => this.renderRoomItem(room, true)).join('')}
                        </div>
                    </div>
                `;
            }

            html += '</div>';
        }

        // Render federated rooms (rooms from the server/federation)
        if (groupedRooms.user.length > 0) {
            html += `
                <div class="user-rooms-section">
                    <div class="section-header">
                        <h4>Federated Rooms</h4>
                        <span class="section-count">${groupedRooms.user.length} room${groupedRooms.user.length !== 1 ? 's' : ''}</span>
                    </div>
                    <div class="user-rooms">
                        ${groupedRooms.user.map(room => this.renderRoomItem(room, false)).join('')}
                    </div>
                </div>
            `;
        }

        return html;
    }

    renderRoomItem(room, isDefault = false) {
        const roomData = {
            id: room.id || room.roomId,
            name: room.name,
            description: room.description || '',
            users: room.users || 0,
            maxUsers: room.maxUsers,
            hasPassword: room.hasPassword || !!room.password,
            template: room.template || null,
            privacyLevel: room.privacyLevel || 'public',
            encrypted: room.encrypted || false,
            isDefault: isDefault,
            isFederated: isDefault || room.isFederated || false
        };

        // Cache room data for join screen
        this.roomDataCache.set(roomData.id, roomData);

        const statusLabels = this.getRoomStatusLabels(roomData);
        const tags = isDefault && room.template?.tags ?
            room.template.tags.slice(0, 3).map(tag => `<span class="room-tag">${tag}</span>`).join('') : '';

        // Description text - show placeholder if none provided
        const descriptionText = room.description && room.description.trim()
            ? room.description
            : 'No description for this room';
        const descriptionClass = room.description && room.description.trim()
            ? 'room-description'
            : 'room-description no-description';

        // User count message for accessibility
        const userCountText = roomData.users === 0
            ? 'Empty'
            : roomData.users === 1
                ? '1 user'
                : `${roomData.users} users`;

        // Show peek button only for rooms with active users
        const showPeekButton = roomData.users > 0;
        const peekButton = showPeekButton ? `
            <button class="peek-room-btn"
                    onclick="event.stopPropagation(); app.peekIntoRoom('${roomData.id}', '${roomData.name}')"
                    title="Preview room audio (5-20 seconds)"
                    aria-label="Peek into ${roomData.name} - hear room audio preview">
                👁️ Peek In
            </button>
        ` : '';

        const shareButton = `
            <button class="share-room-btn"
                    onclick="event.stopPropagation(); app.shareRoom('${roomData.id}')"
                    title="Share room"
                    aria-label="Share ${roomData.name}">
                🔗 Share
            </button>
        `;

        return `
            <div class="room-item ${isDefault ? 'default-room' : 'user-room'}"
                 data-room-id="${roomData.id}"
                 onclick="app.quickJoinRoom('${roomData.id}')"
                 role="button"
                 tabindex="0"
                 aria-label="${roomData.name}, ${descriptionText}, ${userCountText} of ${roomData.maxUsers} max">
                <div class="room-header">
                    <div class="room-info">
                        <h5 class="room-name">${roomData.name}</h5>
                        <p class="${descriptionClass}">${descriptionText}</p>
                    </div>
                    <div class="room-status">
                        ${statusLabels}
                    </div>
                </div>
                <div class="room-details">
                    <div class="room-stats">
                        <span class="user-count">${userCountText} / ${roomData.maxUsers} max</span>
                        ${roomData.hasPassword ? '<span class="password-protected">[Password Protected]</span>' : ''}
                        ${this.getRoomDurationDisplay(room)}
                    </div>
                    ${tags ? `<div class="room-tags">${tags}</div>` : ''}
                    ${peekButton}
                    ${shareButton}
                </div>
            </div>
        `;
    }

    getRoomStatusLabels(roomData) {
        let labels = [];

        // Privacy level label
        const privacyLabels = {
            'public': '[Public]',
            'unlisted': '[Unlisted]',
            'private': '[Private]',
            'encrypted': '[Encrypted]',
            'secure': '[Secure]'
        };
        labels.push(privacyLabels[roomData.privacyLevel] || '[Public]');

        // Encryption status
        if (roomData.encrypted) {
            labels.push('[End-to-End Encrypted]');
        }

        return labels.map(label => `<span class="status-label">${label}</span>`).join(' ');
    }

    // Legacy alias for compatibility
    getRoomStatusIcons(roomData) {
        return this.getRoomStatusLabels(roomData);
    }

    getRoomDurationDisplay(room) {
        if (!room.duration) {
            return '<span class="room-duration">[Permanent Room]</span>';
        }

        const hours = Math.floor(room.duration / 3600000);
        const minutes = Math.floor((room.duration % 3600000) / 60000);

        let durationText = '';
        if (hours > 0) {
            durationText = `${hours}h${minutes > 0 ? ` ${minutes}m` : ''} remaining`;
        } else {
            durationText = `${minutes}m remaining`;
        }

        return `<span class="room-duration">[${durationText}]</span>`;
    }

    /**
     * Format room ID for display - strips prefix like 'default_' for cleaner display
     * @param {string} roomId - Full room ID
     * @returns {string} Formatted room ID
     */
    formatRoomIdForDisplay(roomId) {
        if (!roomId) return '';
        // If room ID has a prefix like 'default_', strip it
        const underscoreIndex = roomId.indexOf('_');
        if (underscoreIndex > 0 && underscoreIndex < 10) {
            return roomId.substring(underscoreIndex + 1);
        }
        return roomId;
    }

    async createRoom() {
        const roomName = document.getElementById('room-name').value;
        const password = document.getElementById('room-password').value;
        const maxUsers = parseInt(document.getElementById('max-users').value);
        const duration = document.getElementById('room-duration').value;
        // Get visibility from radio buttons (public, unlisted, private)
        const visibility = document.querySelector('input[name="room-visibility"]:checked')?.value || 'public';
        // Get access type (hybrid, app-only, web-only, hidden)
        const accessType = document.querySelector('input[name="room-access"]:checked')?.value || 'hybrid';
        // Legacy privacy level support
        const privacyLevel = document.querySelector('input[name="privacy-level"]:checked')?.value || visibility;

        // Determine if room should be visible to guests based on visibility and access type
        const visibleToGuests = visibility === 'public' && accessType !== 'hidden';

        try {
            // Set room privacy settings in the encryption manager
            const roomId = `room_${Date.now()}_${Math.random().toString(36).substr(2, 9)}`;

            if (window.serverEncryptionManager) {
                try {
                    await window.serverEncryptionManager.setUserRoomPrivacy(roomId, privacyLevel);
                } catch (error) {
                    console.warn('Failed to set room privacy:', error);
                }
            }

            const apiBase = this.getApiBaseUrl();

            // Check if user is authenticated for room time limits
            const isAuthenticated = window.mastodonAuth?.isAuthenticated() || false;

            const response = await fetch(`${apiBase}/api/rooms`, {
                method: 'POST',
                headers: {
                    'Content-Type': 'application/json'
                },
                body: JSON.stringify({
                    roomId: roomId,
                    name: roomName,
                    password: password || undefined,
                    maxUsers,
                    duration: duration === 'lifetime' ? null : parseInt(duration),
                    visibility,
                    accessType,
                    visibleToGuests,
                    privacyLevel,
                    encrypted: window.serverEncryptionManager?.isRoomEncrypted(roomId) || false,
                    creatorHandle: window.mastodonAuth?.getUser()?.fullHandle || null,
                    isAuthenticated  // Pass auth status for room time limits
                })
            });

            const result = await response.json();

            if (response.ok) {
                // Auto-join the created room
                document.getElementById('join-room-id').value = result.roomId;
                document.getElementById('user-name').value = 'Room Creator';
                document.getElementById('join-room-password').value = password;

                this.showScreen('join-room-screen');
            } else {
                this.showError(result.message || 'Failed to create room');
            }
        } catch (error) {
            console.error('Failed to create room:', error);
            this.showError('Failed to create room. Please try again.');
        }
    }

    /**
     * Create a private demo room for interactive documentation testing
     * These rooms are hidden from the public room list and expire quickly
     * @param {string} testFeature - Optional specific feature to test ('audio', '3d', 'media')
     */
    async createDemoRoom(testFeature = null) {
        const demoRoomId = `demo_${Date.now()}_${Math.random().toString(36).substr(2, 6)}`;
        const demoRoomName = testFeature
            ? `Demo: ${testFeature.charAt(0).toUpperCase() + testFeature.slice(1)} Testing`
            : 'Interactive Demo Room';

        try {
            this.showNotification('Creating private demo room...', 'info');

            const apiBase = this.getApiBaseUrl();
            const response = await fetch(`${apiBase}/api/rooms`, {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({
                    roomId: demoRoomId,
                    name: demoRoomName,
                    maxUsers: 5,
                    duration: 3600000, // 1 hour
                    visibility: 'hidden',      // Not visible in room listings
                    accessType: 'hidden',      // Hidden from all public access
                    visibleToGuests: false,    // Never show to guests
                    privacyLevel: 'hidden',    // Maximum privacy
                    encrypted: false,
                    isDemo: true,              // Mark as demo room for cleanup
                    creatorHandle: null,
                    isAuthenticated: false
                })
            });

            const result = await response.json();

            if (response.ok) {
                // Auto-join the demo room with a demo user name
                const userName = `Demo_${Math.random().toString(36).substr(2, 4)}`;
                document.getElementById('join-room-id').value = result.roomId;
                document.getElementById('user-name').value = userName;
                document.getElementById('join-room-password').value = '';

                // Clear demo URL params after creating room
                const cleanUrl = window.location.pathname;
                window.history.replaceState({}, document.title, cleanUrl);

                // Show the join screen and display help based on test feature
                this.showScreen('join-room-screen');

                // Show feature-specific demo help panel
                if (testFeature) {
                    setTimeout(() => {
                        this.showDemoFeatureHelp(testFeature);
                    }, 500);
                }

                this.showNotification(`Demo room ready! Room ID: ${result.roomId}`, 'success');
            } else {
                // Fall back to main menu on failure
                this.showError('Could not create demo room. Showing main menu.');
                this.showScreen('main-menu');
            }
        } catch (error) {
            console.error('Failed to create demo room:', error);
            this.showScreen('main-menu');
        }
    }

    /**
     * Show feature-specific help for demo mode
     */
    showDemoFeatureHelp(feature) {
        const helpContent = {
            audio: {
                title: 'Audio Testing Demo',
                steps: [
                    'Click "Join Room" to enter the demo room',
                    'Allow microphone access when prompted',
                    'Test your microphone level in the meter',
                    'Try muting/unmuting with the microphone button',
                    'Adjust your volume slider to test output'
                ]
            },
            '3d': {
                title: '3D Spatial Audio Demo',
                steps: [
                    'Join the room and enable 3D audio in settings',
                    'Drag user icons to position them in 3D space',
                    'Notice how audio pans left/right as you move users',
                    'Try the distance attenuation - farther users sound quieter',
                    'Experiment with different reverb environments'
                ]
            },
            media: {
                title: 'Media Streaming Demo',
                steps: [
                    'Open the Media Player panel after joining',
                    'Try playing a YouTube URL or local file',
                    'Connect your Jellyfin server for library access',
                    'Test the playback controls and volume',
                    'See how media syncs for all room members'
                ]
            }
        };

        const help = helpContent[feature];
        if (!help) return;

        this.showNotification(
            `${help.title}: ${help.steps[0]}`,
            'info',
            8000
        );
    }

    async joinRoom() {
        const roomId = document.getElementById('join-room-id').value;
        const userName = document.getElementById('user-name').value;
        const password = document.getElementById('join-room-password').value;

        if (!roomId || !userName) {
            this.showError('Please enter room ID and your name');
            return;
        }

        try {
            // Initialize local stream first
            await this.audioEngine.getUserMedia();

            // Initialize WebRTC manager
            this.webrtcManager = new WebRTCManager(
                this.socket,
                this.audioEngine,
                this.spatialAudio
            );

            await this.webrtcManager.initializeLocalStream();

            // Setup push-to-talk
            this.webrtcManager.setupPushToTalk('Space');

            // Initialize PA System and TTS after WebRTC is ready
            this.initializePASystemAndTTS();

            // Join room via socket
            this.socket.emit('join-room', {
                roomId,
                userName,
                password
            });

        } catch (error) {
            console.error('Failed to join room:', error);
            this.showError('Failed to access microphone or join room');
        }
    }

    quickJoinRoom(roomId) {
        // Get cached room data
        const roomData = this.roomDataCache.get(roomId);

        // Set room ID (hidden field)
        document.getElementById('join-room-id').value = roomId;

        // Populate room preview info
        if (roomData) {
            document.getElementById('join-room-name').textContent = roomData.name;
            document.getElementById('join-room-description').textContent =
                roomData.description || 'No description for this room';

            // User count
            const userText = roomData.users === 0 ? 'Empty' :
                roomData.users === 1 ? '1 user' : `${roomData.users} users`;
            document.getElementById('join-room-users').textContent = `${userText} / ${roomData.maxUsers} max`;

            // Privacy label
            const privacyLabels = {
                'public': '[Public]',
                'unlisted': '[Unlisted]',
                'private': '[Private]',
                'encrypted': '[Encrypted]'
            };
            document.getElementById('join-room-privacy').textContent =
                privacyLabels[roomData.privacyLevel] || '[Public]';

            // Show/hide password field based on room requirements
            const passwordGroup = document.getElementById('join-password-group');
            if (roomData.hasPassword) {
                passwordGroup.style.display = 'block';
                document.getElementById('join-room-password').value = '';
            } else {
                passwordGroup.style.display = 'none';
                document.getElementById('join-room-password').value = '';
            }

            // Show peek button if room has users
            const peekBtn = document.getElementById('join-peek-btn');
            if (roomData.users > 0) {
                peekBtn.style.display = 'inline-block';
                peekBtn.onclick = () => this.peekIntoRoom(roomId, roomData.name);
            } else {
                peekBtn.style.display = 'none';
            }
        } else {
            // Fallback for manual room ID entry
            document.getElementById('join-room-name').textContent = 'Join Room';
            document.getElementById('join-room-description').textContent = 'Enter room details to join';
            document.getElementById('join-room-users').textContent = '';
            document.getElementById('join-room-privacy').textContent = '';
            document.getElementById('join-password-group').style.display = 'block'; // Show password just in case
            document.getElementById('join-peek-btn').style.display = 'none';
        }

        // Set default username if not already set
        const userNameField = document.getElementById('user-name');
        if (!userNameField.value) {
            userNameField.value = `User_${Date.now().toString().slice(-4)}`;
        }

        this.showScreen('join-room-screen');
    }

    // ========================================
    // PEEK INTO ROOM - Audio Preview Feature
    // ========================================

    /**
     * Peek into a room - hear audio preview with "behind the door" effect
     * @param {string} roomId - Room to peek into
     * @param {string} roomName - Room name for display
     */
    async peekIntoRoom(roomId, roomName) {
        // Prevent multiple simultaneous peeks
        if (this.isPeeking) {
            this.showNotification('Already peeking into a room...', 'info');
            return;
        }

        console.log(`Peeking into room: ${roomName} (${roomId})`);
        this.isPeeking = true;
        this.peekRoomId = roomId;

        // Update button state
        const peekBtn = document.querySelector(`[data-room-id="${roomId}"] .peek-room-btn`);
        if (peekBtn) {
            peekBtn.textContent = '👁️ Peeking...';
            peekBtn.disabled = true;
            peekBtn.classList.add('peeking');
        }

        try {
            // Create audio context for preview
            this.peekAudioContext = new (window.AudioContext || window.webkitAudioContext)();

            // Create lowpass filter for "behind the door" effect
            this.peekLowpassFilter = this.peekAudioContext.createBiquadFilter();
            this.peekLowpassFilter.type = 'lowpass';
            this.peekLowpassFilter.frequency.value = 800; // Muffled sound
            this.peekLowpassFilter.Q.value = 0.7;

            // Create gain node for volume control
            this.peekGainNode = this.peekAudioContext.createGain();
            this.peekGainNode.gain.value = 0.7;

            // Connect filter chain
            this.peekLowpassFilter.connect(this.peekGainNode);
            this.peekGainNode.connect(this.peekAudioContext.destination);

            // Play whoosh/door opening sound
            await this.playPeekSound('start');

            // Show peek overlay
            this.showPeekOverlay(roomName);

            // Connect to room as listener (read-only mode)
            await this.connectToPeekStream(roomId);

            // Auto-stop after 15 seconds (adjustable 5-20s)
            this.peekTimeout = setTimeout(() => {
                this.stopPeeking();
            }, 15000);

        } catch (error) {
            console.error('Failed to peek into room:', error);
            this.showNotification('Failed to peek into room', 'error');
            this.stopPeeking();
        }
    }

    /**
     * Connect to room audio stream for preview
     */
    async connectToPeekStream(roomId) {
        const apiBase = this.getApiBaseUrl();

        // Request room audio stream for preview
        // This creates a temporary listen-only connection
        try {
            const response = await fetch(`${apiBase}/api/rooms/${roomId}/peek`, {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ duration: 15 })
            });

            if (response.ok) {
                const data = await response.json();
                if (data.streamUrl) {
                    // Connect to WebRTC stream
                    await this.setupPeekWebRTC(data);
                } else if (data.audioData) {
                    // Play buffered audio preview if provided
                    await this.playBufferedPreview(data.audioData);
                }
            } else {
                // Fallback: Show "no preview available" with ambient sound
                console.log('Room peek not available, playing ambient preview');
                this.showNotification('Preview not available - room may be quiet', 'info');
            }
        } catch (error) {
            console.log('Peek stream unavailable:', error.message);
            // Still show the peek overlay for ambiance
        }
    }

    /**
     * Setup WebRTC connection for peek audio
     */
    async setupPeekWebRTC(streamData) {
        // Simplified WebRTC for audio-only receive
        const pc = new RTCPeerConnection({
            iceServers: [{ urls: 'stun:stun.l.google.com:19302' }]
        });

        pc.ontrack = (event) => {
            const audioElement = new Audio();
            audioElement.srcObject = event.streams[0];

            // Create media stream source and connect through filter
            const source = this.peekAudioContext.createMediaStreamSource(event.streams[0]);
            source.connect(this.peekLowpassFilter);

            this.peekMediaSource = source;
            console.log('Peek audio stream connected with lowpass filter');
        };

        this.peekPeerConnection = pc;

        // Handle signaling if provided
        if (streamData.offer) {
            await pc.setRemoteDescription(new RTCSessionDescription(streamData.offer));
            const answer = await pc.createAnswer();
            await pc.setLocalDescription(answer);
        }
    }

    /**
     * Play buffered audio preview
     */
    async playBufferedPreview(audioData) {
        try {
            const audioBuffer = await this.peekAudioContext.decodeAudioData(audioData);
            const source = this.peekAudioContext.createBufferSource();
            source.buffer = audioBuffer;
            source.connect(this.peekLowpassFilter);
            source.start();
            this.peekBufferSource = source;
        } catch (error) {
            console.error('Failed to play buffered preview:', error);
        }
    }

    /**
     * Play peek transition sounds (blinds up/down + random whoosh layered)
     * @param {string} type - 'start' or 'end'
     */
    async playPeekSound(type) {
        try {
            const ctx = this.peekAudioContext || new AudioContext();

            // Primary peek sounds (blinds going up for peek in, down for peek out)
            const peekSounds = {
                start: 'assets/sounds/peek/Peek-In-To-Room-Raised-Fast.flac',
                end: 'assets/sounds/peek/Peek-Out-Of-Room-Blinds-Lowered-Fast.flac'
            };

            // Random whoosh sounds to layer with the blinds sound
            const whooshSounds = [
                'assets/sounds/peek/whoosh_fast1.wav',
                'assets/sounds/peek/whoosh_fast2.wav',
                'assets/sounds/peek/whoosh_fast3.wav',
                'assets/sounds/peek/whoosh_medium1.wav',
                'assets/sounds/peek/whoosh_medium2.wav',
                'assets/sounds/peek/whoosh_medium3.wav',
                'assets/sounds/peek/whoosh_medium4.wav',
                'assets/sounds/peek/whoosh_slow1.wav',
                'assets/sounds/peek/whoosh_slow2.wav',
                'assets/sounds/peek/whoosh_slower1.wav'
            ];

            // Randomly select a whoosh sound
            const randomWhoosh = whooshSounds[Math.floor(Math.random() * whooshSounds.length)];

            // Helper to play a sound file
            const playSound = async (soundFile, volume = 0.6) => {
                try {
                    const response = await fetch(soundFile);
                    if (!response.ok) return 0;

                    const arrayBuffer = await response.arrayBuffer();
                    const audioBuffer = await ctx.decodeAudioData(arrayBuffer);

                    const source = ctx.createBufferSource();
                    source.buffer = audioBuffer;

                    const gainNode = ctx.createGain();
                    gainNode.gain.value = volume;

                    source.connect(gainNode);
                    gainNode.connect(ctx.destination);
                    source.start();

                    return audioBuffer.duration * 1000;
                } catch (e) {
                    console.log('Sound load failed:', soundFile);
                    return 0;
                }
            };

            // Play blinds sound and random whoosh layered together
            const [peekDuration, whooshDuration] = await Promise.all([
                playSound(peekSounds[type], 0.5),   // Blinds up/down
                playSound(randomWhoosh, 0.35)       // Random whoosh overlay
            ]);

            // Wait for the longer sound to finish
            const maxDuration = Math.max(peekDuration, whooshDuration);
            if (maxDuration > 0) {
                await new Promise(resolve => setTimeout(resolve, Math.min(maxDuration, 1500)));
            } else {
                // Fallback if both sounds failed
                await this.playWhooshFallback(ctx, type);
            }

        } catch (error) {
            console.log('Could not play peek sound, using fallback:', error.message);
            await this.playWhooshFallback(this.peekAudioContext, type);
        }
    }

    /**
     * Fallback whoosh sound if audio files unavailable
     */
    async playWhooshFallback(ctx, type) {
        try {
            const duration = 0.4;
            const oscillator = ctx.createOscillator();
            const masterGain = ctx.createGain();

            oscillator.type = 'sine';
            if (type === 'start') {
                oscillator.frequency.setValueAtTime(100, ctx.currentTime);
                oscillator.frequency.exponentialRampToValueAtTime(600, ctx.currentTime + duration);
                masterGain.gain.setValueAtTime(0, ctx.currentTime);
                masterGain.gain.linearRampToValueAtTime(0.3, ctx.currentTime + duration * 0.3);
                masterGain.gain.linearRampToValueAtTime(0, ctx.currentTime + duration);
            } else {
                oscillator.frequency.setValueAtTime(600, ctx.currentTime);
                oscillator.frequency.exponentialRampToValueAtTime(100, ctx.currentTime + duration);
                masterGain.gain.setValueAtTime(0.3, ctx.currentTime);
                masterGain.gain.linearRampToValueAtTime(0, ctx.currentTime + duration);
            }

            oscillator.connect(masterGain);
            masterGain.connect(ctx.destination);
            oscillator.start(ctx.currentTime);
            oscillator.stop(ctx.currentTime + duration);

            await new Promise(resolve => setTimeout(resolve, duration * 1000));
        } catch (e) {
            console.log('Whoosh fallback failed:', e.message);
        }
    }

    /**
     * Show peek overlay UI
     */
    showPeekOverlay(roomName) {
        // Remove existing overlay
        document.querySelector('.peek-overlay')?.remove();

        const overlay = document.createElement('div');
        overlay.className = 'peek-overlay';
        overlay.innerHTML = `
            <div class="peek-content">
                <div class="peek-icon">👁️</div>
                <div class="peek-info">
                    <h3>Peeking into "${roomName}"</h3>
                    <p>Listening through the door...</p>
                    <div class="peek-progress">
                        <div class="peek-progress-bar"></div>
                    </div>
                    <p class="peek-hint">Audio is filtered for preview</p>
                </div>
                <button class="peek-stop-btn" onclick="app.stopPeeking()">Stop Peeking</button>
                <button class="peek-join-btn" onclick="app.stopPeeking(); app.quickJoinRoom('${this.peekRoomId}')">Join Room</button>
            </div>
        `;

        document.body.appendChild(overlay);

        // Animate progress bar
        const progressBar = overlay.querySelector('.peek-progress-bar');
        if (progressBar) {
            progressBar.style.animation = 'peekProgress 15s linear forwards';
        }
    }

    /**
     * Stop peeking and cleanup
     */
    async stopPeeking() {
        if (!this.isPeeking) return;

        console.log('Stopping peek...');

        // Play end whoosh sound
        await this.playPeekSound('end');

        // Cleanup timeout
        if (this.peekTimeout) {
            clearTimeout(this.peekTimeout);
            this.peekTimeout = null;
        }

        // Cleanup audio
        if (this.peekMediaSource) {
            this.peekMediaSource.disconnect();
            this.peekMediaSource = null;
        }

        if (this.peekBufferSource) {
            try { this.peekBufferSource.stop(); } catch (e) {}
            this.peekBufferSource = null;
        }

        if (this.peekPeerConnection) {
            this.peekPeerConnection.close();
            this.peekPeerConnection = null;
        }

        if (this.peekAudioContext) {
            this.peekAudioContext.close();
            this.peekAudioContext = null;
        }

        // Remove overlay
        document.querySelector('.peek-overlay')?.remove();

        // Reset button state
        const peekBtn = document.querySelector(`[data-room-id="${this.peekRoomId}"] .peek-room-btn`);
        if (peekBtn) {
            peekBtn.textContent = '👁️ Peek In';
            peekBtn.disabled = false;
            peekBtn.classList.remove('peeking');
        }

        this.isPeeking = false;
        this.peekRoomId = null;
    }

    handleJoinedRoom(room, user) {
        // Clear room-specific UI/state before switching
        const chatMessages = document.getElementById('chat-messages');
        if (chatMessages) {
            chatMessages.innerHTML = '';
        }
        const userList = document.getElementById('user-list');
        if (userList) {
            userList.innerHTML = '';
        }
        this.users.clear();

        this.currentRoom = room;
        this.currentRoomId = room?.id || room?.roomId || null;
        this.currentUser = user;

        // Update UI
        document.getElementById('current-room-name').textContent = room.name;
        document.getElementById('room-id-display').textContent = `Room ID: ${this.formatRoomIdForDisplay(room.id)}`;

        // Add existing users
        room.users.forEach(existingUser => {
            if (existingUser.id !== user.id) {
                this.users.set(existingUser.id, existingUser);
                this.addUserToUI(existingUser);
            }
        });

        this.updateUserCount();
        this.showScreen('voice-chat-screen');

        // Enable jukebox for room
        if (window.jukeboxManager) {
            window.jukeboxManager.enable();
        }

        // Update share button visibility based on room settings and auth state
        const isAuthenticated = !!(localStorage.getItem('mastodon_access_token') || sessionStorage.getItem('mastodon_access_token'));
        this.updateShareButtons(isAuthenticated);

        console.log('Successfully joined room:', room.name);
    }

    handleUserJoined(user) {
        this.users.set(user.id, user);
        this.addUserToUI(user);
        this.updateUserCount();

        this.addSystemMessage(`${user.name} joined the room`);
        this.playUiSound('user-join.wav');
    }

    handleUserLeft(userId) {
        const user = this.users.get(userId);
        if (user) {
            this.users.delete(userId);
            this.removeUserFromUI(userId);
            this.updateUserCount();

            this.addSystemMessage(`${user.name} left the room`);
            this.playUiSound('user-leave.wav');
        }
    }

    addUserToUI(user) {
        const userList = document.getElementById('user-list');
        if (!userList) return;

        const userElement = document.createElement('div');
        userElement.className = 'user-item';
        userElement.setAttribute('data-user-id', user.id);
        userElement.setAttribute('data-user-name', user.name || 'Unknown');

        userElement.innerHTML = `
            <div class="user-info">
                <div class="user-status connected" title="Connected"></div>
                <span class="user-name">${user.name}</span>
                <span class="audio-indicator" style="display: none;">[Speaking]</span>
            </div>
            <div class="user-controls">
                <button onclick="app.adjustUserVolume('${user.id}', -0.1)" title="Decrease volume" aria-label="Decrease volume for ${user.name}">Vol -</button>
                <button onclick="app.adjustUserVolume('${user.id}', 0.1)" title="Increase volume" aria-label="Increase volume for ${user.name}">Vol +</button>
                <button onclick="app.toggleUserMute('${user.id}')" title="Mute user" aria-label="Mute ${user.name}">Mute</button>
                <button onclick="window.userContextMenu?.showMenuForUser('${user.id}', this.closest('.user-item'))" title="User actions" aria-label="Actions for ${user.name}">Actions</button>
            </div>
        `;

        userList.appendChild(userElement);

        // Update audio routing panel
        this.updateAudioRoutingPanel();
    }

    removeUserFromUI(userId) {
        const userElement = document.querySelector(`[data-user-id=\"${userId}\"]`);
        if (userElement) {
            userElement.remove();
        }

        this.updateAudioRoutingPanel();
    }

    updateUserCount() {
        const userCountElement = document.getElementById('user-count');
        const totalUsers = this.users.size + 1; // +1 for current user

        if (userCountElement) {
            userCountElement.textContent = totalUsers;
        }

        // Show/hide the "alone in room" message
        this.updateAloneInRoomMessage(totalUsers === 1);
    }

    updateAloneInRoomMessage(isAlone) {
        const existingMessage = document.getElementById('alone-in-room-message');
        const chatMessages = document.getElementById('chat-messages');

        if (isAlone && !existingMessage && chatMessages) {
            const messageElement = document.createElement('div');
            messageElement.id = 'alone-in-room-message';
            messageElement.className = 'alone-room-notice';
            messageElement.innerHTML = `
                <p class="alone-message">You are the only one here!</p>
                <p class="invite-prompt">Why not invite someone to join?</p>
            `;
            // Insert at the top of chat messages
            chatMessages.insertBefore(messageElement, chatMessages.firstChild);
        } else if (!isAlone && existingMessage) {
            existingMessage.remove();
        }
    }

    adjustUserVolume(userId, delta) {
        const currentVolume = this.audioEngine.userVolumes.get(userId) || 1.0;
        const newVolume = Math.max(0, Math.min(2, currentVolume + delta));

        this.audioEngine.setUserVolume(userId, newVolume);
        console.log(`Set volume for user ${userId} to ${newVolume}`);
    }

    toggleUserMute(userId) {
        // This would implement per-user muting
        console.log('Toggle mute for user:', userId);
    }

    sendChatMessage() {
        const input = document.getElementById('chat-input');
        const message = input.value.trim();

        if (message && this.socket) {
            this.socket.emit('chat-message', { message });
            input.value = '';
        }
    }

    addChatMessage(message) {
        const chatMessages = document.getElementById('chat-messages');
        if (!chatMessages) return;

        if (this.currentRoomId && message.roomId && message.roomId !== this.currentRoomId) {
            return;
        }

        if (message.id && chatMessages.querySelector(`[data-message-id=\"${message.id}\"]`)) {
            return;
        }

        const messageElement = document.createElement('div');
        messageElement.className = 'chat-message';
        if (message.id) {
            messageElement.setAttribute('data-message-id', message.id);
        }

        const timestamp = new Date(message.timestamp).toLocaleTimeString();

        messageElement.innerHTML = `
            <div class="message-header">
                <strong>${message.userName}</strong>
                <span class="timestamp">${timestamp}</span>
            </div>
            <div class="message-text">${this.escapeHtml(message.message)}</div>
        `;

        chatMessages.appendChild(messageElement);
        chatMessages.scrollTop = chatMessages.scrollHeight;
    }

    addSystemMessage(text) {
        const chatMessages = document.getElementById('chat-messages');
        if (!chatMessages) return;

        const messageElement = document.createElement('div');
        messageElement.className = 'chat-message system-message';
        messageElement.style.fontStyle = 'italic';
        messageElement.style.opacity = '0.8';

        messageElement.innerHTML = `
            <div class="message-text">${this.escapeHtml(text)}</div>
        `;

        chatMessages.appendChild(messageElement);
        chatMessages.scrollTop = chatMessages.scrollHeight;
    }

    playUiSound(filename, volume = 0.6) {
        try {
            const candidates = [
                `sounds/${filename}`,
                `assets/sounds/${filename}`,
                `client/sounds/${filename}`,
                `source/assets/sounds/${filename}`
            ];

            const audio = new Audio();
            audio.volume = volume;

            const tryNext = (idx) => {
                if (idx >= candidates.length) return;
                audio.src = candidates[idx];
                audio.onerror = () => tryNext(idx + 1);
                audio.play().catch(() => tryNext(idx + 1));
            };

            tryNext(0);
        } catch (error) {
            console.warn('UI sound failed:', error);
        }
    }

    announce(message, priority = 'polite') {
        if (window.accessibilityManager && typeof window.accessibilityManager.announce === 'function') {
            window.accessibilityManager.announce(message, priority, false);
            return;
        }
        const liveRegionId = priority === 'assertive' ? 'app-live-assertive' : 'app-live-polite';
        let region = document.getElementById(liveRegionId);
        if (!region) {
            region = document.createElement('div');
            region.id = liveRegionId;
            region.className = 'sr-only';
            region.setAttribute('role', 'status');
            region.setAttribute('aria-live', priority);
            document.body.appendChild(region);
        }
        region.textContent = message;
    }

    toggleAudioRoutingPanel() {
        const panel = document.getElementById('audio-routing-panel');
        if (panel) {
            panel.classList.toggle('hidden');

            if (!panel.classList.contains('hidden')) {
                this.updateAudioRoutingPanel();
            }
        }
    }

    updateAudioRoutingPanel() {
        const userRoutingList = document.getElementById('user-routing-list');
        if (!userRoutingList) return;

        userRoutingList.innerHTML = '';

        this.users.forEach((user, userId) => {
            const routingItem = document.createElement('div');
            routingItem.className = 'user-routing-item';

            const currentOutput = this.audioEngine.outputRouting.get(userId) || 'default';

            routingItem.innerHTML = `
                <span>${user.name}</span>
                <select onchange="app.changeUserOutput('${userId}', this.value)">
                    ${this.audioEngine.getDevices().outputs.map(device =>
                        `<option value="${device.id}" ${device.id === currentOutput ? 'selected' : ''}>${device.name}</option>`
                    ).join('')}
                </select>
            `;

            userRoutingList.appendChild(routingItem);
        });
    }

    changeUserOutput(userId, outputDeviceId) {
        this.audioEngine.routeUserToOutput(userId, outputDeviceId);
        console.log(`Changed output for user ${userId} to ${outputDeviceId}`);
    }

    saveAudioSettings() {
        const settings = {
            noiseSuppression: document.getElementById('noise-suppression')?.checked || false,
            echoCancellation: document.getElementById('echo-cancellation')?.checked || false
        };

        this.audioEngine.updateSettings(settings);
        this.showScreen('main-menu');

        console.log('Audio settings saved');
    }

    leaveRoom() {
        // Disable jukebox - it's room-scoped, playback stops when leaving
        if (window.jukeboxManager) {
            window.jukeboxManager.disable();
        }

        // Stop background stream when leaving room
        this.stopBackgroundStream();

        // Clean up whisper mode
        if (this.whisperMode) {
            this.whisperMode.cleanup();
        }

        if (this.webrtcManager) {
            this.webrtcManager.destroy();
            this.webrtcManager = null;
        }

        if (this.socket) {
            this.socket.emit('leave-room');
            this.socket.disconnect();
            this.socket = null;
        }

        this.currentRoom = null;
        this.currentUser = null;
        this.users.clear();

        // Hide share button (no longer in room)
        this.updateShareButtons(false);

        // Reconnect to server
        this.connectToServer().then(() => {
            this.loadRooms();
            this.showScreen('main-menu');
        });
    }

    handleUserAudioRoutingChanged(userId, routing) {
        console.log('User audio routing changed:', userId, routing);
        this.updateAudioRoutingPanel();
    }

    handleUserAudioSettingsChanged(userId, settings) {
        console.log('User audio settings changed:', userId, settings);
    }

    showError(message) {
        console.error('Error:', message);
        alert(`Error: ${message}`); // In a real app, use a proper modal
    }

    showSuccess(message) {
        console.log('Success:', message);
        this.showNotification(message, 'success');
    }

    // Simple notification system without dialogs
    showNotification(message, type = 'info') {
        // Create notification element
        const notification = document.createElement('div');
        notification.style.cssText = `
            position: fixed;
            top: 20px;
            right: 20px;
            background: ${type === 'success' ? '#4CAF50' : type === 'error' ? '#f44336' : '#2196F3'};
            color: white;
            padding: 15px 20px;
            border-radius: 5px;
            box-shadow: 0 4px 8px rgba(0,0,0,0.2);
            z-index: 10000;
            font-family: system-ui, -apple-system, sans-serif;
            font-size: 14px;
            max-width: 300px;
            opacity: 0;
            transform: translateY(-20px);
            transition: all 0.3s ease;
        `;
        notification.textContent = message;

        document.body.appendChild(notification);

        // Animate in
        setTimeout(() => {
            notification.style.opacity = '1';
            notification.style.transform = 'translateY(0)';
        }, 10);

        // Auto remove after 3 seconds
        setTimeout(() => {
            notification.style.opacity = '0';
            notification.style.transform = 'translateY(-20px)';
            setTimeout(() => {
                if (notification.parentNode) {
                    notification.parentNode.removeChild(notification);
                }
            }, 300);
        }, 3000);
    }

    // Play audio file with stop capability
    async playAudioFile(filename) {
        try {
            // If audio is currently playing, stop it
            if (this.currentAudio && !this.currentAudio.paused) {
                console.log('Stopping current audio...');
                this.currentAudio.pause();
                this.currentAudio.currentTime = 0;
                this.currentAudio = null;
                this.isAudioPlaying = false;
                this.showNotification('Audio stopped', 'info');
                return;
            }

            // Play new audio
            console.log(`Playing audio file: ${filename}`);
            this.currentAudio = new Audio(`sounds/${filename}`);
            this.isAudioPlaying = true;

            // Set up event handlers
            this.currentAudio.onended = () => {
                console.log('Audio playback completed');
                this.currentAudio = null;
                this.isAudioPlaying = false;
            };

            this.currentAudio.onerror = (error) => {
                console.error(`Audio playback error:`, error);
                this.currentAudio = null;
                this.isAudioPlaying = false;
            };

            await this.currentAudio.play();
            console.log(`Started playing: ${filename}`);
        } catch (error) {
            console.error(`Failed to play audio file ${filename}:`, error);
            this.currentAudio = null;
            this.isAudioPlaying = false;
            throw error;
        }
    }

    escapeHtml(text) {
        const div = document.createElement('div');
        div.textContent = text;
        return div.innerHTML;
    }

    // Test audio playback functionality
    async testAudioPlayback() {
        try {
            console.log('Starting audio test...');

            // Try to play the main audio test file first
            try {
                await this.playAudioFile('Audio-Portrit-Sound-Test.wav');
                this.showNotification('Audio test completed! 🎵', 'success');
                return;
            } catch (audioFileError) {
                console.log('Audio file playback failed, trying generated tone...', audioFileError);
            }

            // Fallback to generated audio if file fails
            // Ensure audio engine is ready
            if (!this.audioEngine) {
                console.log('Audio engine not available, attempting to initialize...');
                await this.retryAudioInitialization();
            }

            // Ensure we have an audio context
            if (!this.audioEngine || !this.audioEngine.audioContext) {
                console.log('Creating emergency audio context for test...');
                await this.createEmergencyAudioContext();
            }

            // Resume audio context if needed
            if (this.audioEngine.audioContext && this.audioEngine.audioContext.state === 'suspended') {
                console.log('Resuming audio context...');
                await this.audioEngine.audioContext.resume();
            }

            // Try audio test manager
            if (window.audioTestManager && this.audioEngine.audioContext) {
                console.log('Using Audio Test Manager');
                await window.audioTestManager.runBasicTest();
                this.showNotification('Audio test completed! 🎵', 'success');
                return;
            }

            // Final fallback to simple audio test
            console.log('Using fallback audio test');
            await this.runSimpleAudioTest();
            this.showNotification('Audio test completed! 🎵', 'success');

        } catch (error) {
            console.error('Audio test failed:', error);
            this.showNotification(`Audio test failed: ${error.message}`, 'error');
        }
    }

    // Create emergency audio context for testing
    async createEmergencyAudioContext() {
        try {
            const AudioContext = window.AudioContext || window.webkitAudioContext;
            if (!AudioContext) {
                throw new Error('Web Audio API not supported');
            }

            if (!this.audioEngine) {
                this.audioEngine = {};
            }

            this.audioEngine.audioContext = new AudioContext();

            if (this.audioEngine.audioContext.state === 'suspended') {
                await this.audioEngine.audioContext.resume();
            }

            console.log('Emergency audio context created successfully');

            // Also try to enumerate devices after creating audio context
            if (this.audioEngine.enumerateDevices) {
                await this.audioEngine.enumerateDevices();
            }
        } catch (error) {
            console.error('Failed to create emergency audio context:', error);
            throw error;
        }
    }

    // Manually trigger device enumeration
    async refreshAudioDevices() {
        try {
            if (this.audioEngine && this.audioEngine.enumerateDevices) {
                await this.audioEngine.enumerateDevices();
                console.log('Audio devices refreshed');
            } else {
                console.warn('Audio engine not available for device enumeration');
            }
        } catch (error) {
            console.error('Failed to refresh audio devices:', error);
        }
    }

    // Simple audio test fallback
    async runSimpleAudioTest() {
        if (!this.audioEngine || !this.audioEngine.audioContext) {
            throw new Error('Audio engine not initialized');
        }

        const audioContext = this.audioEngine.audioContext;

        console.log('Simple audio test - Audio context state:', audioContext.state);

        // Ensure audio context is running (Safari requirement)
        if (audioContext.state === 'suspended') {
            console.log('Resuming suspended audio context...');
            await audioContext.resume();
            console.log('Audio context state after resume:', audioContext.state);
        }

        // Create a simple, loud test tone
        const oscillator = audioContext.createOscillator();
        const gainNode = audioContext.createGain();

        oscillator.connect(gainNode);
        gainNode.connect(audioContext.destination);

        // Configure a simple 440Hz tone
        oscillator.frequency.setValueAtTime(440, audioContext.currentTime);
        oscillator.type = 'sine';

        // Set volume to be clearly audible
        gainNode.gain.setValueAtTime(0.5, audioContext.currentTime);
        gainNode.gain.setValueAtTime(0, audioContext.currentTime + 1);

        console.log('Starting simple test tone at 440Hz for 1 second...');

        oscillator.start(audioContext.currentTime);
        oscillator.stop(audioContext.currentTime + 1);

        // Wait for the tone to finish
        await new Promise(resolve => setTimeout(resolve, 1100));

        // Show feedback to user
        this.showAudioTestFeedback('Audio test tone played successfully!');

        console.log('Simple audio test completed');
    }

    // Show audio test feedback
    showAudioTestFeedback(message) {
        // Create temporary feedback message
        const feedback = document.createElement('div');
        feedback.style.cssText = `
            position: fixed;
            top: 20px;
            right: 20px;
            background: linear-gradient(135deg, #28a745, #20c997);
            color: white;
            padding: 15px 20px;
            border-radius: 8px;
            box-shadow: 0 4px 12px rgba(40, 167, 69, 0.3);
            z-index: 10000;
            font-size: 14px;
            max-width: 300px;
            opacity: 0;
            transition: opacity 0.3s ease;
        `;
        feedback.textContent = message;

        document.body.appendChild(feedback);

        // Animate in
        setTimeout(() => {
            feedback.style.opacity = '1';
        }, 100);

        // Auto-remove after 3 seconds
        setTimeout(() => {
            feedback.style.opacity = '0';
            setTimeout(() => {
                if (feedback.parentElement) {
                    feedback.remove();
                }
            }, 300);
        }, 3000);
    }

    // Setup room privacy controls in the create room form
    setupRoomPrivacyControls() {
        const privacyContainer = document.getElementById('room-privacy-controls');
        if (!privacyContainer) return;

        // Check if encryption status display is available
        if (window.encryptionStatusDisplay) {
            const privacyControls = window.encryptionStatusDisplay.addRoomPrivacyControls();
            privacyContainer.innerHTML = '';
            privacyContainer.appendChild(privacyControls);
        } else {
            // Fallback basic privacy controls
            privacyContainer.innerHTML = `
                <h3>Room Privacy</h3>
                <div class="privacy-level-selector">
                    <label class="privacy-option">
                        <input type="radio" name="privacy-level" value="public" checked>
                        <span class="privacy-icon">🌐</span>
                        <span class="privacy-label">Public</span>
                        <span class="privacy-desc">Visible to all users</span>
                    </label>
                    <label class="privacy-option">
                        <input type="radio" name="privacy-level" value="unlisted">
                        <span class="privacy-icon">🔗</span>
                        <span class="privacy-label">Unlisted</span>
                        <span class="privacy-desc">Joinable with link only</span>
                    </label>
                    <label class="privacy-option">
                        <input type="radio" name="privacy-level" value="private">
                        <span class="privacy-icon">👥</span>
                        <span class="privacy-label">Private</span>
                        <span class="privacy-desc">Invitation only, encrypted</span>
                    </label>
                </div>
            `;
        }
    }

    async testAudioPlayback() {
        try {
            // Try to use AudioTestManager if available
            if (window.audioTestManager) {
                await window.audioTestManager.playTestTone();
                return;
            }

            // Fallback to basic audio test
            if (!this.audioEngine?.audioContext) {
                // Initialize audio if not already done
                await this.initializeAudioSystems();
            }

            if (this.audioEngine?.audioContext) {
                const context = this.audioEngine.audioContext;
                const oscillator = context.createOscillator();
                const gainNode = context.createGain();

                oscillator.connect(gainNode);
                gainNode.connect(context.destination);

                oscillator.frequency.setValueAtTime(440, context.currentTime); // A4 note
                gainNode.gain.setValueAtTime(0.3, context.currentTime);
                gainNode.gain.exponentialRampToValueAtTime(0.01, context.currentTime + 1);

                oscillator.start(context.currentTime);
                oscillator.stop(context.currentTime + 1);

                console.log('Audio test tone played successfully');
            } else {
                throw new Error('Audio context not available');
            }
        } catch (error) {
            console.error('Audio test failed:', error);
            alert('Audio test failed. Please check your audio settings and ensure audio permissions are granted.');
        }
    }

    initializeSettingsScreen() {
        // Setup tab navigation
        this.setupSettingsTabs();

        // Load current settings
        this.loadCurrentSettings();

        // Setup settings event listeners
        this.setupSettingsEventListeners();

        // Setup streaming warnings
        this.setupStreamingWarnings();

        // Load server info for network tab
        this.loadServerInfo();
    }

    setupSettingsTabs() {
        const tabButtons = document.querySelectorAll('.tab-btn');
        const tabContents = document.querySelectorAll('.settings-tab');

        tabButtons.forEach(button => {
            button.addEventListener('click', () => {
                // Remove active class from all tabs
                tabButtons.forEach(btn => btn.classList.remove('active'));
                tabContents.forEach(content => content.classList.remove('active'));

                // Add active class to clicked tab
                button.classList.add('active');
                const tabId = button.getAttribute('data-tab');
                document.getElementById(`${tabId}-tab`).classList.add('active');
            });
        });
    }

    loadCurrentSettings() {
        // This would load settings from localStorage or native API
        // For now, just set default values
        console.log('Loading current settings...');

        const behaviorSelect = document.getElementById('multi-device-behavior');
        const autoQuitToggle = document.getElementById('auto-quit-on-other-login');
        if (behaviorSelect) {
            behaviorSelect.value = localStorage.getItem('voicelink_multi_device_behavior') || 'prompt';
        }
        if (autoQuitToggle) {
            autoQuitToggle.checked = localStorage.getItem('voicelink_auto_quit_other') === 'true';
        }
        this.updateMultiDeviceStatusUI();
    }

    setupSettingsEventListeners() {
        // Save all settings button - saves and returns to previous screen
        document.getElementById('save-all-settings')?.addEventListener('click', () => {
            this.saveAllSettings();
            // Return to previous screen after saving
            if (this.currentRoom) {
                this.showScreen('voice-chat-screen');
            } else {
                this.showScreen('main-menu');
            }
        });

        // Test audio in advanced tab
        document.getElementById('test-audio-advanced')?.addEventListener('click', () => {
            this.testAudioPlayback();
        });

        // Reset settings
        document.getElementById('reset-settings')?.addEventListener('click', () => {
            if (confirm('Are you sure you want to reset all settings to defaults?')) {
                this.resetAllSettings();
            }
        });

        // Network buttons
        document.getElementById('copy-url-btn')?.addEventListener('click', () => {
            this.copyServerUrl();
        });

        document.getElementById('show-qr-btn')?.addEventListener('click', () => {
            if (window.nativeAPI) {
                window.nativeAPI.showQRCode();
            }
        });

        document.getElementById('restart-server-btn')?.addEventListener('click', () => {
            if (window.nativeAPI) {
                window.nativeAPI.restartServer();
            }
        });

        // Multi-device settings
        document.getElementById('multi-device-behavior')?.addEventListener('change', (e) => {
            this.setMultiDeviceSettings({ behavior: e.target.value });
        });

        document.getElementById('auto-quit-on-other-login')?.addEventListener('change', (e) => {
            this.setMultiDeviceSettings({ autoQuit: e.target.checked });
        });

        document.getElementById('multi-device-reconnect')?.addEventListener('click', () => {
            this.connectToServer().then(() => {
                this.registerSession();
                this.showNotification('Reconnected', 'success');
            }).catch(() => {
                this.showNotification('Reconnect failed', 'error');
            });
        });

        document.getElementById('multi-device-disconnect')?.addEventListener('click', () => {
            this.disconnectForMultiDevice();
        });

        document.getElementById('multi-device-keep')?.addEventListener('click', () => {
            this.showNotification('Keeping both devices active', 'info');
        });
    }

    loadServerInfo() {
        if (window.nativeAPI) {
            window.nativeAPI.getServerInfo().then(info => {
                this.updateServerInfoDisplay(info);
            }).catch(console.error);
        }
    }

    updateServerInfoDisplay(info) {
        const serverInfoEl = document.getElementById('settings-server-info');
        if (serverInfoEl && info) {
            serverInfoEl.innerHTML = `
                <div class="info-item">
                    <span class="info-label">Status:</span>
                    <span class="info-value">${info.isRunning ? 'Running' : 'Stopped'}</span>
                </div>
                <div class="info-item">
                    <span class="info-label">URL:</span>
                    <span class="info-value">${info.url || 'N/A'}</span>
                </div>
                <div class="info-item">
                    <span class="info-label">Port:</span>
                    <span class="info-value">${info.port || 3000}</span>
                </div>
                <div class="info-item">
                    <span class="info-label">Users:</span>
                    <span class="info-value">${info.userCount || 0}</span>
                </div>
            `;
        }
    }

    showQuickAudioPanel() {
        // Remove existing panel if it exists
        const existingPanel = document.querySelector('.quick-audio-panel');
        if (existingPanel) {
            existingPanel.remove();
        }

        // Create quick audio panel
        const panel = document.createElement('div');
        panel.className = 'quick-audio-panel';
        panel.innerHTML = `
            <h3>🎵 Quick Audio Settings</h3>
            <div class="quick-audio-controls">
                <div class="setting-item">
                    <label>Input Volume:</label>
                    <input type="range" id="quick-input-volume" min="0" max="200" value="100">
                    <span id="quick-input-value">100%</span>
                </div>
                <div class="setting-item">
                    <label>Output Volume:</label>
                    <input type="range" id="quick-output-volume" min="0" max="200" value="100">
                    <span id="quick-output-value">100%</span>
                </div>
                <div class="setting-item">
                    <label>
                        <input type="checkbox" id="quick-noise-suppression" checked>
                        Noise Suppression
                    </label>
                </div>
                <div class="setting-item">
                    <label>
                        <input type="checkbox" id="quick-spatial-audio" checked>
                        3D Spatial Audio
                    </label>
                </div>
            </div>
            <div class="panel-buttons">
                <button class="test-btn" onclick="app.testAudioPlayback()">🧪 Test</button>
                <button class="secondary-btn" onclick="this.parentElement.parentElement.remove()">Close</button>
            </div>
        `;

        document.body.appendChild(panel);

        // Add event listeners for the volume sliders
        const inputSlider = panel.querySelector('#quick-input-volume');
        const outputSlider = panel.querySelector('#quick-output-volume');
        const inputValue = panel.querySelector('#quick-input-value');
        const outputValue = panel.querySelector('#quick-output-value');

        inputSlider.addEventListener('input', (e) => {
            inputValue.textContent = e.target.value + '%';
        });

        outputSlider.addEventListener('input', (e) => {
            outputValue.textContent = e.target.value + '%';
        });

        // Close panel when clicking outside
        panel.addEventListener('click', (e) => {
            if (e.target === panel) {
                panel.remove();
            }
        });
    }

    saveAllSettings() {
        console.log('Saving all settings...');
        // Implementation would save to localStorage or native API
        alert('Settings saved successfully!');
    }

    resetAllSettings() {
        console.log('Resetting all settings...');
        // Implementation would reset to defaults
        alert('Settings reset to defaults!');
    }

    copyServerUrl() {
        if (window.nativeAPI) {
            window.nativeAPI.copyServerUrl();
        } else {
            // Fallback for web
            const url = `http://${window.location.hostname}:3000`;
            navigator.clipboard.writeText(url).then(() => {
                alert('Server URL copied to clipboard!');
            }).catch(() => {
                prompt('Copy this URL:', url);
            });
        }
    }

    setupStreamingWarnings() {
        // List of streaming feature checkboxes that need warnings
        const streamingFeatures = [
            'enable-streaming',
            'enable-recording',
            'enable-rtmp',
            'enable-icecast',
            'enable-srt',
            'enable-webrtc-streaming',
            'enable-hls',
            'enable-ndi',
            'enable-multi-streaming'
        ];

        streamingFeatures.forEach(featureId => {
            const checkbox = document.getElementById(featureId);
            if (checkbox) {
                checkbox.addEventListener('change', (e) => {
                    if (e.target.checked) {
                        this.showStreamingWarning(featureId, e.target);
                    }
                });
            }
        });

        // Also add warnings to streaming control buttons
        const streamingButtons = [
            'start-stream',
            'start-recording',
            'test-stream'
        ];

        streamingButtons.forEach(buttonId => {
            const button = document.getElementById(buttonId);
            if (button) {
                button.addEventListener('click', (e) => {
                    e.preventDefault();
                    this.showStreamingWarning('streaming-action', null, () => {
                        // Callback if user confirms
                        console.log('User confirmed streaming action:', buttonId);
                        // Implementation would go here
                        alert(`${buttonId} feature not yet implemented`);
                    });
                });
            }
        });
    }

    showStreamingWarning(featureType, checkbox, onConfirm) {
        // Remove any existing warning modal
        const existingModal = document.querySelector('.warning-modal');
        if (existingModal) {
            existingModal.remove();
        }

        // Create warning modal
        const modal = document.createElement('div');
        modal.className = 'warning-modal';

        const featureNames = {
            'enable-streaming': 'Live Streaming',
            'enable-recording': 'Recording',
            'enable-rtmp': 'RTMP Streaming',
            'enable-icecast': 'Icecast Streaming',
            'enable-srt': 'SRT Protocol',
            'enable-webrtc-streaming': 'WebRTC Streaming',
            'enable-hls': 'HLS Streaming',
            'enable-ndi': 'NDI Output',
            'enable-multi-streaming': 'Multi-platform Streaming',
            'streaming-action': 'Streaming Features'
        };

        const featureName = featureNames[featureType] || 'Streaming Feature';

        modal.innerHTML = `
            <div class="warning-content">
                <span class="warning-icon">⚠️</span>
                <h3 class="warning-title">Experimental Feature Warning</h3>
                <div class="warning-message">
                    <p><strong>${featureName}</strong> is not officially supported yet and may not work properly or could crash the application.</p>
                    <p>This feature is included for future development and testing purposes only.</p>
                    <p><strong>Are you sure you want to enable this experimental feature?</strong></p>
                </div>
                <div class="warning-buttons">
                    <button class="warning-btn confirm">Yes, Enable It</button>
                    <button class="warning-btn cancel">No, Go Back</button>
                </div>
            </div>
        `;

        // Add event listeners
        const confirmBtn = modal.querySelector('.confirm');
        const cancelBtn = modal.querySelector('.cancel');

        confirmBtn.addEventListener('click', () => {
            modal.remove();
            if (onConfirm) {
                onConfirm();
            } else if (checkbox) {
                // User confirmed, keep checkbox checked
                console.log(`User enabled experimental feature: ${featureName}`);
            }
        });

        cancelBtn.addEventListener('click', () => {
            modal.remove();
            if (checkbox) {
                // User cancelled, uncheck the checkbox
                checkbox.checked = false;
            }
        });

        // Close modal when clicking outside
        modal.addEventListener('click', (e) => {
            if (e.target === modal) {
                modal.remove();
                if (checkbox) {
                    checkbox.checked = false;
                }
            }
        });

        document.body.appendChild(modal);
    }

    // Button click audio system
    initializeButtonAudio() {
        this.buttonAudio = {
            clickSound: null,
            init: async () => {
                try {
                    // Try different audio file paths
                    const possiblePaths = [
                        'sounds/connected.wav',
                        'client/sounds/connected.wav',
                        'assets/audio/test-audio/connected.wav'
                    ];

                    for (const path of possiblePaths) {
                        try {
                            this.buttonAudio.clickSound = new Audio(path);
                            this.buttonAudio.clickSound.volume = 0.3;
                            await new Promise((resolve, reject) => {
                                this.buttonAudio.clickSound.addEventListener('canplaythrough', resolve);
                                this.buttonAudio.clickSound.addEventListener('error', reject);
                                this.buttonAudio.clickSound.load();
                            });
                            console.log(`Button click audio loaded from: ${path}`);
                            break;
                        } catch (e) {
                            console.log(`Failed to load audio from ${path}`);
                        }
                    }
                } catch (error) {
                    console.log('Button click audio not available, using fallback');
                }
            },
            playClick: () => {
                if (this.buttonAudio.clickSound) {
                    this.buttonAudio.clickSound.currentTime = 0;
                    this.buttonAudio.clickSound.play().catch(e => console.log('Click sound failed'));
                }
            }
        };

        // Initialize button audio
        this.buttonAudio.init();

        // Add click sound to all buttons
        document.addEventListener('click', (e) => {
            if (e.target.tagName === 'BUTTON' || e.target.classList.contains('btn')) {
                this.buttonAudio.playClick();
            }
        });
    }

    // ========================================
    // MASTODON AUTHENTICATION SYSTEM
    // ========================================

    setupMastodonAuth() {
        // Login button
        document.getElementById('mastodon-login-btn')?.addEventListener('click', () => {
            this.showMastodonLoginModal();
        });

        // Close modal button
        document.getElementById('close-login-modal')?.addEventListener('click', () => {
            this.hideMastodonLoginModal();
        });

        // Auth Tab Switching
        document.querySelectorAll('.auth-tab').forEach(tab => {
            tab.addEventListener('click', () => {
                const tabId = tab.dataset.tab;
                // Update tab active state
                document.querySelectorAll('.auth-tab').forEach(t => t.classList.remove('active'));
                tab.classList.add('active');
                // Update content visibility
                document.querySelectorAll('.auth-tab-content').forEach(content => {
                    content.classList.remove('active');
                });
                document.getElementById(`${tabId}-tab`)?.classList.add('active');
            });
        });

        // WHMCS Login Form Submit
        document.getElementById('whmcs-login-form')?.addEventListener('submit', async (e) => {
            e.preventDefault();
            const email = document.getElementById('whmcs-login-email')?.value;
            const password = document.getElementById('whmcs-login-password')?.value;
            const twoFactorCode = document.getElementById('whmcs-login-2fa')?.value;
            const mastodonHandle = document.getElementById('whmcs-mastodon-handle')?.value;
            const remember = document.getElementById('whmcs-remember-me')?.checked;

            if (email && password) {
                await this.handleWhmcsLogin(email, password, {
                    twoFactorCode,
                    mastodonHandle,
                    remember
                });
            }
        });

        document.getElementById('whmcs-sso-btn')?.addEventListener('click', async () => {
            const email = document.getElementById('whmcs-login-email')?.value;
            const password = document.getElementById('whmcs-login-password')?.value;
            const twoFactorCode = document.getElementById('whmcs-login-2fa')?.value;
            const remember = document.getElementById('whmcs-remember-me')?.checked;
            await this.handleWhmcsSsoLogin({ email, password, twoFactorCode, remember });
        });

        // Connect button (Mastodon)
        document.getElementById('mastodon-connect-btn')?.addEventListener('click', () => {
            const instanceInput = document.getElementById('mastodon-instance-input');
            if (instanceInput?.value) {
                this.startMastodonAuth(instanceInput.value);
            }
        });

        // Instance input - allow Enter key
        document.getElementById('mastodon-instance-input')?.addEventListener('keypress', (e) => {
            if (e.key === 'Enter') {
                e.preventDefault();
                document.getElementById('mastodon-connect-btn')?.click();
            }
        });

        // Suggested instance buttons
        document.querySelectorAll('.instance-btn').forEach(btn => {
            btn.addEventListener('click', () => {
                const instance = btn.dataset.instance;
                if (instance) {
                    this.startMastodonAuth(instance);
                }
            });
        });

        // Manual OAuth code submit (for native apps that can't auto-callback)
        document.getElementById('oauth-code-submit')?.addEventListener('click', () => {
            const codeInput = document.getElementById('oauth-code-input');
            if (codeInput?.value) {
                this.handleManualOAuthCode(codeInput.value);
            }
        });

        // Logout button
        document.getElementById('mastodon-logout-btn')?.addEventListener('click', () => {
            this.handleMastodonLogout();
        });

        // Listen for Mastodon auth events
        window.addEventListener('mastodon-login', (e) => {
            this.updateUIForAuthState(e.detail.user);
        });

        window.addEventListener('mastodon-logout', () => {
            this.updateUIForAuthState(null);
        });

        // Check existing session
        if (window.mastodonAuth?.isAuthenticated()) {
            this.updateUIForAuthState(window.mastodonAuth.getUser());
        } else {
            this.restoreWhmcsSession();
        }
    }

    showMastodonLoginModal() {
        const modal = document.getElementById('mastodon-login-modal');
        if (modal) {
            modal.style.display = 'flex';
            this.setActiveAuthTab('mastodon-login');
        }
    }

    setActiveAuthTab(tabId) {
        document.querySelectorAll('.auth-tab').forEach(tab => {
            if (tab.dataset.tab === tabId) {
                tab.classList.add('active');
            } else {
                tab.classList.remove('active');
            }
        });
        document.querySelectorAll('.auth-tab-content').forEach(content => {
            content.classList.remove('active');
        });
        document.getElementById(`${tabId}-tab`)?.classList.add('active');
    }

    hideMastodonLoginModal() {
        const modal = document.getElementById('mastodon-login-modal');
        if (modal) {
            modal.style.display = 'none';
        }
        // Hide code entry section
        const codeEntry = document.getElementById('oauth-code-entry');
        if (codeEntry) {
            codeEntry.style.display = 'none';
        }
    }

    async startMastodonAuth(instanceUrl) {
        try {
            if (!window.mastodonAuth) {
                throw new Error('Mastodon OAuth manager not initialized');
            }

            this.showNotification('Connecting to ' + instanceUrl + '...', 'info');

            const authUrl = await window.mastodonAuth.startAuth(instanceUrl);

            const isNativeApp = !!window.nativeAPI;

            if (isNativeApp) {
                await this.openExternal(authUrl);
                const codeEntry = document.getElementById('oauth-code-entry');
                if (codeEntry) {
                    codeEntry.style.display = 'block';
                }
            } else {
                window.location.href = authUrl;
            }
        } catch (error) {
            console.error('Failed to start Mastodon auth:', error);
            this.showNotification('Failed to connect: ' + error.message, 'error');
        }
    }

    async handleManualOAuthCode(code) {
        try {
            this.showNotification('Verifying authorization code...', 'info');

            const user = await window.mastodonAuth.handleManualCode(code);

            this.hideMastodonLoginModal();
            this.showNotification('Welcome, ' + user.displayName + '!', 'success');
        } catch (error) {
            console.error('Failed to verify OAuth code:', error);
            this.showNotification('Failed to verify code: ' + error.message, 'error');
        }
    }

    /**
     * Handle WHMCS (Client Portal) login
     */
    async handleWhmcsLogin(email, password, options = {}) {
        try {
            this.showNotification('Logging in to client portal...', 'info');
            const apiBase = this.getApiBaseUrl();

            const response = await fetch(`${apiBase}/api/auth/whmcs/login`, {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({
                    email,
                    password,
                    twoFactorCode: options.twoFactorCode || null,
                    remember: options.remember === true,
                    mastodonHandle: options.mastodonHandle || null
                })
            });

            const data = await response.json();
            if (!response.ok) {
                if (data?.requires2FA) {
                    this.showNotification('2FA required. Enter your code and try again.', 'warning');
                    return;
                }
                throw new Error(data.error || 'Login failed');
            }

            const tokenKey = 'voicelink_whmcs_token';
            if (options.remember) {
                localStorage.setItem(tokenKey, data.token);
            } else {
                sessionStorage.setItem(tokenKey, data.token);
            }

            this.hideMastodonLoginModal();
            this.updateUIForAuthState(data.user);
            this.showNotification('Welcome back, ' + data.user.displayName + '!', 'success');
            window.dispatchEvent(new CustomEvent('mastodon-login', { detail: { user: data.user } }));
        } catch (error) {
            console.error('WHMCS login failed:', error);
            this.showNotification(error.message || 'Login failed', 'error');
        }
    }

    async handleWhmcsSsoLogin(options = {}) {
        try {
            this.showNotification('Opening client portal...', 'info');
            const apiBase = this.getApiBaseUrl();

            const response = await fetch(`${apiBase}/api/auth/whmcs/sso/start`, {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({
                    email: options.email,
                    password: options.password,
                    twoFactorCode: options.twoFactorCode || null,
                    remember: options.remember === true
                })
            });

            const data = await response.json();
            if (!response.ok) {
                if (data?.requires2FA) {
                    this.showNotification('2FA required. Enter your code and try again.', 'warning');
                    return;
                }
                throw new Error(data.error || 'SSO failed');
            }

            const redirectUrl = data.redirectUrl || data.portalUrl;
            if (redirectUrl) {
                await this.openExternal(redirectUrl);
            }
        } catch (error) {
            console.error('WHMCS SSO failed:', error);
            this.showNotification(error.message || 'SSO failed', 'error');
        }
    }

    restoreWhmcsSession() {
        const tokenKey = 'voicelink_whmcs_token';
        const token = localStorage.getItem(tokenKey) || sessionStorage.getItem(tokenKey);
        if (!token) return;

        const apiBase = this.getApiBaseUrl();
        fetch(`${apiBase}/api/auth/whmcs/session/${token}`)
            .then(res => res.json())
            .then(data => {
                if (data?.valid && data.user) {
                    this.updateUIForAuthState(data.user);
                }
            })
            .catch(() => {});
    }

    checkOAuthCallback() {
        // Check URL for OAuth callback params
        const urlParams = new URLSearchParams(window.location.search);
        const code = urlParams.get('oauth_code') || urlParams.get('code');
        const state = urlParams.get('oauth_state') || urlParams.get('state');

        if (code) {
            // Remove params from URL
            const cleanUrl = window.location.pathname;
            window.history.replaceState({}, document.title, cleanUrl);

            // Handle the callback
            this.handleOAuthCallback(code, state);
        }
    }

    async handleOAuthCallback(code, state) {
        try {
            this.showNotification('Completing login...', 'info');

            const user = await window.mastodonAuth.handleCallback(code, state);

            this.showNotification('Welcome, ' + user.displayName + '!', 'success');
        } catch (error) {
            console.error('OAuth callback failed:', error);
            this.showNotification('Login failed: ' + error.message, 'error');
        }
    }

    async handleMastodonLogout() {
        try {
            await window.mastodonAuth?.logout();
            this.showNotification('Logged out successfully', 'info');
        } catch (error) {
            console.error('Logout failed:', error);
        }
    }

    updateUIForAuthState(user) {
        const loginPrompt = document.getElementById('mastodon-login-prompt');
        const userInfo = document.getElementById('mastodon-user-info');
        const avatar = document.getElementById('mastodon-user-avatar');
        const userName = document.getElementById('mastodon-user-name');
        const userHandle = document.getElementById('mastodon-user-handle');
        const userRole = document.getElementById('mastodon-user-role');
        const joinNameInput = document.getElementById('user-name');

        this.currentUser = user || null;

        if (user) {
            // Show logged-in state
            if (loginPrompt) loginPrompt.style.display = 'none';
            if (userInfo) userInfo.style.display = 'flex';

            if (avatar) avatar.src = user.avatar || user.avatarStatic || '';
            if (userName) userName.textContent = user.displayName || user.username || 'VoiceLink User';
            if (userHandle) userHandle.textContent = user.fullHandle || user.email || user.username || '';

            const roleValue = user.role || (user.isAdmin ? 'admin' : user.isModerator ? 'staff' : 'user');
            if (userRole) {
                if (roleValue === 'admin') {
                    userRole.textContent = 'Admin';
                    userRole.className = 'user-role admin';
                } else if (roleValue === 'staff' || roleValue === 'moderator') {
                    userRole.textContent = 'Staff';
                    userRole.className = 'user-role moderator';
                } else {
                    userRole.textContent = 'User';
                    userRole.className = 'user-role user';
                }
            }

            // Update role-based UI
            this.updateRoleBasedUI(user);
            this.registerSession();
            this.applyEntitlementVisibility(user);

            // Default the join name to Mastodon display name if empty or placeholder
            if (joinNameInput) {
                const currentValue = joinNameInput.value?.trim();
                if (!currentValue || currentValue === 'Room Creator' || currentValue.startsWith('User')) {
                    joinNameInput.value = user.displayName || user.username || currentValue;
                }
            }
        } else {
            // Show logged-out state
            if (loginPrompt) loginPrompt.style.display = 'block';
            if (userInfo) userInfo.style.display = 'none';

            // Hide admin controls
            this.hideAdminControls();
            this.applyEntitlementVisibility(null);
        }
    }

    applyEntitlementVisibility(user) {
        const connectionsTabBtn = document.querySelector('.tab-btn[data-tab="connections"]');
        const connectionsTab = document.getElementById('connections-tab');
        const allowByRole = user?.permissions?.includes('admin') || user?.permissions?.includes('staff') || user?.permissions?.includes('client');
        const allowByEntitlement = user?.entitlements?.allowMultiDeviceSettings !== false;
        const allowConnections = !!user && allowByRole && allowByEntitlement;

        if (connectionsTabBtn) connectionsTabBtn.style.display = allowConnections ? '' : 'none';
        if (connectionsTab) connectionsTab.style.display = allowConnections ? '' : 'none';
    }

    updateRoleBasedUI(user) {
        const role = user?.role;
        const isAdmin = user?.isAdmin === true || role === 'admin' || user?.permissions?.includes('admin');
        const isModerator = user?.isModerator === true || role === 'staff' || user?.permissions?.includes('staff') || isAdmin;

        // Server control buttons - only for admins
        const serverControls = document.querySelector('.server-control-buttons');
        if (serverControls) {
            if (isAdmin) {
                serverControls.style.display = 'flex';
            } else {
                serverControls.style.display = 'none';
            }
        }

        // Show admin panel button
        let adminPanelBtn = document.getElementById('admin-panel-btn');
        if (isAdmin && !adminPanelBtn) {
            this.createAdminPanelButton();
        } else if (!isAdmin && adminPanelBtn) {
            adminPanelBtn.remove();
        }

        // Show share room button for all authenticated users
        this.updateShareButtons(!!user);

        console.log('UI updated for ' + user?.displayName + ' - Admin: ' + isAdmin + ', Moderator: ' + isModerator);
    }

    hideAdminControls() {
        const serverControls = document.querySelector('.server-control-buttons');
        if (serverControls) {
            serverControls.style.display = 'none';
        }

        const adminPanelBtn = document.getElementById('admin-panel-btn');
        if (adminPanelBtn) {
            adminPanelBtn.remove();
        }
    }

    updateShareButtons(isAuthenticated) {
        // Share button in room header - only show when inside a room and sharing is allowed
        const shareRoomBtn = document.getElementById('share-room-btn');
        if (shareRoomBtn) {
            // Show share button only when: authenticated AND inside a room AND room allows sharing
            const roomAllowsShare = this.currentRoom?.allowShare !== false; // Default to true if not set
            if (isAuthenticated && this.currentRoom && roomAllowsShare) {
                shareRoomBtn.style.display = '';
            } else {
                shareRoomBtn.style.display = 'none';
            }
        }
    }

    async shareRoom(roomId) {
        try {
            const apiBase = this.getApiBaseUrl();
            const response = await fetch(`${apiBase}/api/share/${roomId}`);
            const data = await response.json();

            if (data.shareUrls?.mastodon) {
                window.open(data.shareUrls.mastodon, '_blank');
            } else {
                // Fallback - copy link
                const joinUrl = data.joinUrl || (window.location.origin + '/?room=' + roomId);
                await navigator.clipboard.writeText(joinUrl);
                this.showNotification('Room link copied to clipboard!', 'success');
            }
        } catch (error) {
            console.error('Failed to share room:', error);
            this.showNotification('Failed to share room', 'error');
        }
    }

    // ========================================
    // EMBED CODE GENERATOR
    // ========================================

    async showEmbedCodeModal(roomId, roomName) {
        // Remove existing modal
        document.querySelector('.embed-code-modal')?.remove();

        const modal = document.createElement('div');
        modal.className = 'embed-code-modal modal';
        modal.style.display = 'flex';

        const content = document.createElement('div');
        content.className = 'modal-content embed-modal';

        // Title
        const title = document.createElement('h2');
        title.textContent = 'Embed Room';
        content.appendChild(title);

        // Room name
        const roomLabel = document.createElement('p');
        roomLabel.textContent = `Room: ${roomName}`;
        roomLabel.style.color = '#888';
        content.appendChild(roomLabel);

        // Generate token button
        const generateBtn = document.createElement('button');
        generateBtn.className = 'primary-btn';
        generateBtn.textContent = 'Generate Embed Code';
        generateBtn.style.marginTop = '15px';
        content.appendChild(generateBtn);

        // Embed code container (hidden initially)
        const embedContainer = document.createElement('div');
        embedContainer.className = 'embed-code-container';
        embedContainer.style.display = 'none';

        const embedCode = document.createElement('pre');
        embedCode.className = 'embed-code';
        embedContainer.appendChild(embedCode);

        const copyBtn = document.createElement('button');
        copyBtn.className = 'copy-embed-btn';
        copyBtn.textContent = 'Copy';
        embedContainer.appendChild(copyBtn);

        content.appendChild(embedContainer);

        // Size options
        const sizeOptions = document.createElement('div');
        sizeOptions.className = 'embed-options';
        sizeOptions.style.display = 'none';

        const widthOption = document.createElement('div');
        widthOption.className = 'embed-option';
        const widthLabel = document.createElement('label');
        widthLabel.textContent = 'Size';
        const sizeInputs = document.createElement('div');
        sizeInputs.className = 'embed-size-inputs';

        const widthInput = document.createElement('input');
        widthInput.type = 'number';
        widthInput.value = '400';
        widthInput.id = 'embed-width';

        const sizeX = document.createElement('span');
        sizeX.textContent = 'x';

        const heightInput = document.createElement('input');
        heightInput.type = 'number';
        heightInput.value = '300';
        heightInput.id = 'embed-height';

        sizeInputs.appendChild(widthInput);
        sizeInputs.appendChild(sizeX);
        sizeInputs.appendChild(heightInput);
        widthOption.appendChild(widthLabel);
        widthOption.appendChild(sizeInputs);
        sizeOptions.appendChild(widthOption);

        content.appendChild(sizeOptions);

        // Close button
        const closeBtn = document.createElement('button');
        closeBtn.className = 'close-modal-btn';
        closeBtn.textContent = '\u2715';
        closeBtn.addEventListener('click', () => modal.remove());
        content.appendChild(closeBtn);

        modal.appendChild(content);
        document.body.appendChild(modal);

        // Generate token handler
        generateBtn.addEventListener('click', async () => {
            generateBtn.disabled = true;
            generateBtn.textContent = 'Generating...';

            try {
                const apiBase = this.getApiBaseUrl();

                const response = await fetch(`${apiBase}/api/embed/token`, {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/json' },
                    body: JSON.stringify({
                        roomId,
                        creatorHandle: window.mastodonAuth?.getUser()?.fullHandle || null,
                        expiresIn: 86400000 * 30 // 30 days
                    })
                });

                const data = await response.json();

                if (data.success) {
                    embedCode.textContent = data.embedCode;
                    embedContainer.style.display = 'block';
                    sizeOptions.style.display = 'flex';
                    generateBtn.style.display = 'none';

                    // Update embed code when size changes
                    const updateEmbed = () => {
                        const w = widthInput.value || 400;
                        const h = heightInput.value || 300;
                        embedCode.textContent = data.embedCode.replace('width="400"', `width="${w}"`).replace('height="300"', `height="${h}"`);
                    };

                    widthInput.addEventListener('input', updateEmbed);
                    heightInput.addEventListener('input', updateEmbed);

                    // Copy handler
                    copyBtn.addEventListener('click', () => {
                        navigator.clipboard.writeText(embedCode.textContent);
                        copyBtn.textContent = 'Copied!';
                        setTimeout(() => copyBtn.textContent = 'Copy', 2000);
                    });
                } else {
                    alert('Failed to generate embed code: ' + (data.error || 'Unknown error'));
                    generateBtn.disabled = false;
                    generateBtn.textContent = 'Generate Embed Code';
                }
            } catch (error) {
                console.error('Embed generation error:', error);
                alert('Error generating embed code');
                generateBtn.disabled = false;
                generateBtn.textContent = 'Generate Embed Code';
            }
        });
    }

    // ========================================
    // ADMIN PANEL & CONTROLS
    // ========================================

    createAdminPanelButton() {
        const menuSection = document.querySelector('.menu-section');
        if (!menuSection) return;

        const adminSection = document.createElement('div');
        adminSection.className = 'menu-section admin-section';

        const header = document.createElement('h3');
        header.textContent = 'Admin Controls';

        const adminBtn = document.createElement('button');
        adminBtn.id = 'admin-panel-btn';
        adminBtn.className = 'primary-btn admin-btn';
        adminBtn.textContent = 'Open Admin Panel';

        adminSection.appendChild(header);
        adminSection.appendChild(adminBtn);

        menuSection.parentNode.insertBefore(adminSection, menuSection);

        adminBtn.addEventListener('click', () => {
            this.showAdminPanel();
        });
    }

    showAdminPanel() {
        // Remove existing panel
        document.querySelector('.admin-panel-modal')?.remove();

        const modal = document.createElement('div');
        modal.className = 'admin-panel-modal modal';
        modal.style.display = 'flex';

        // Build admin panel content using DOM methods
        const content = document.createElement('div');
        content.className = 'modal-content admin-panel';

        // Header
        const header = document.createElement('div');
        header.className = 'admin-header';
        const title = document.createElement('h2');
        title.textContent = 'VoiceLink Admin Panel';
        const closeBtn = document.createElement('button');
        closeBtn.className = 'close-admin-panel';
        closeBtn.textContent = 'X';
        header.appendChild(title);
        header.appendChild(closeBtn);
        content.appendChild(header);

        // Tabs
        const tabs = document.createElement('div');
        tabs.className = 'admin-tabs';
        const tabData = [
            { id: 'server', label: 'Server' },
            { id: 'rooms', label: 'Rooms' },
            { id: 'users', label: 'Users' },
            { id: 'mastodon', label: 'Mastodon' },
            { id: 'federation', label: 'Federation' }
        ];
        tabData.forEach((tab, index) => {
            const tabBtn = document.createElement('button');
            tabBtn.className = 'admin-tab' + (index === 0 ? ' active' : '');
            tabBtn.dataset.tab = tab.id;
            tabBtn.textContent = tab.label;
            tabs.appendChild(tabBtn);
        });
        content.appendChild(tabs);

        // Content area
        const contentArea = document.createElement('div');
        contentArea.className = 'admin-content';

        // Server Tab
        const serverTab = this.createServerTab();
        contentArea.appendChild(serverTab);

        // Rooms Tab
        const roomsTab = this.createRoomsTab();
        contentArea.appendChild(roomsTab);

        // Users Tab
        const usersTab = this.createUsersTab();
        contentArea.appendChild(usersTab);

        // Mastodon Tab
        const mastodonTab = this.createMastodonTab();
        contentArea.appendChild(mastodonTab);

        // Federation Tab
        const federationTab = this.createFederationTab();
        contentArea.appendChild(federationTab);

        content.appendChild(contentArea);
        modal.appendChild(content);
        document.body.appendChild(modal);

        // Setup tab switching
        modal.querySelectorAll('.admin-tab').forEach(tab => {
            tab.addEventListener('click', () => {
                modal.querySelectorAll('.admin-tab').forEach(t => t.classList.remove('active'));
                modal.querySelectorAll('.admin-tab-content').forEach(c => c.classList.remove('active'));

                tab.classList.add('active');
                const tabId = 'admin-' + tab.dataset.tab + '-tab';
                document.getElementById(tabId)?.classList.add('active');
            });
        });

        // Close button
        closeBtn.addEventListener('click', () => modal.remove());

        // Click outside to close
        modal.addEventListener('click', (e) => {
            if (e.target === modal) modal.remove();
        });

        // Load initial data
        this.loadAdminData();
    }

    createServerTab() {
        const tab = document.createElement('div');
        tab.className = 'admin-tab-content active';
        tab.id = 'admin-server-tab';

        const title = document.createElement('h3');
        title.textContent = 'Server Management';
        tab.appendChild(title);

        const grid = document.createElement('div');
        grid.className = 'admin-grid';

        // Status card
        const statusCard = document.createElement('div');
        statusCard.className = 'admin-card';

        const statusTitle = document.createElement('h4');
        statusTitle.textContent = 'Server Status';
        statusCard.appendChild(statusTitle);

        const stats = document.createElement('div');
        stats.className = 'server-stats';

        const statusItem = this.createStatItem('Status:', 'admin-server-status', 'Online');
        const uptimeItem = this.createStatItem('Uptime:', 'admin-server-uptime', 'Loading...');
        const connItem = this.createStatItem('Connections:', 'admin-connections', '0');

        stats.appendChild(statusItem);
        stats.appendChild(uptimeItem);
        stats.appendChild(connItem);
        statusCard.appendChild(stats);

        const actions = document.createElement('div');
        actions.className = 'admin-actions';

        const restartBtn = document.createElement('button');
        restartBtn.className = 'admin-action-btn';
        restartBtn.textContent = 'Restart';
        restartBtn.onclick = () => this.adminRestartServer();

        const stopBtn = document.createElement('button');
        stopBtn.className = 'admin-action-btn danger';
        stopBtn.textContent = 'Stop';
        stopBtn.onclick = () => this.adminStopServer();

        actions.appendChild(restartBtn);
        actions.appendChild(stopBtn);
        statusCard.appendChild(actions);

        grid.appendChild(statusCard);

        // Settings card
        const settingsCard = document.createElement('div');
        settingsCard.className = 'admin-card';

        const settingsTitle = document.createElement('h4');
        settingsTitle.textContent = 'Server Settings';
        settingsCard.appendChild(settingsTitle);

        const maxRoomsRow = this.createSettingRow('Max Concurrent Rooms:', 'admin-max-rooms', 'number', '100');
        settingsCard.appendChild(maxRoomsRow);

        const requireAuthRow = this.createCheckboxRow('Require Authentication', 'admin-require-auth');
        settingsCard.appendChild(requireAuthRow);

        const saveBtn = document.createElement('button');
        saveBtn.className = 'primary-btn';
        saveBtn.textContent = 'Save Settings';
        saveBtn.onclick = () => this.saveServerSettings();
        settingsCard.appendChild(saveBtn);

        grid.appendChild(settingsCard);
        tab.appendChild(grid);

        return tab;
    }

    createRoomsTab() {
        const tab = document.createElement('div');
        tab.className = 'admin-tab-content';
        tab.id = 'admin-rooms-tab';

        const title = document.createElement('h3');
        title.textContent = 'Room Management';
        tab.appendChild(title);

        const toolbar = document.createElement('div');
        toolbar.className = 'admin-toolbar';

        const defaultRoomsBtn = document.createElement('button');
        defaultRoomsBtn.className = 'admin-action-btn';
        defaultRoomsBtn.textContent = 'Generate Default Rooms';
        defaultRoomsBtn.onclick = () => this.createDefaultRooms();

        const cleanupBtn = document.createElement('button');
        cleanupBtn.className = 'admin-action-btn';
        cleanupBtn.textContent = 'Cleanup Expired';
        cleanupBtn.onclick = () => this.cleanupExpiredRooms();

        toolbar.appendChild(defaultRoomsBtn);
        toolbar.appendChild(cleanupBtn);
        tab.appendChild(toolbar);

        const roomsList = document.createElement('div');
        roomsList.id = 'admin-rooms-list';
        roomsList.className = 'admin-list';
        roomsList.textContent = 'Loading rooms...';
        tab.appendChild(roomsList);

        return tab;
    }

    createUsersTab() {
        const tab = document.createElement('div');
        tab.className = 'admin-tab-content';
        tab.id = 'admin-users-tab';

        const title = document.createElement('h3');
        title.textContent = 'Connected Users';
        tab.appendChild(title);

        const toolbar = document.createElement('div');
        toolbar.className = 'admin-toolbar';

        const refreshBtn = document.createElement('button');
        refreshBtn.className = 'admin-action-btn';
        refreshBtn.textContent = 'Refresh';
        refreshBtn.onclick = () => this.refreshUserList();

        const broadcastBtn = document.createElement('button');
        broadcastBtn.className = 'admin-action-btn';
        broadcastBtn.textContent = 'Broadcast Message';
        broadcastBtn.onclick = () => this.broadcastMessage();

        toolbar.appendChild(refreshBtn);
        toolbar.appendChild(broadcastBtn);
        tab.appendChild(toolbar);

        const usersList = document.createElement('div');
        usersList.id = 'admin-users-list';
        usersList.className = 'admin-list';
        usersList.textContent = 'Loading users...';
        tab.appendChild(usersList);

        return tab;
    }

    createMastodonTab() {
        const tab = document.createElement('div');
        tab.className = 'admin-tab-content';
        tab.id = 'admin-mastodon-tab';

        const title = document.createElement('h3');
        title.textContent = 'Mastodon Integration';
        tab.appendChild(title);

        const grid = document.createElement('div');
        grid.className = 'admin-grid';

        // Bot Accounts card
        const botCard = document.createElement('div');
        botCard.className = 'admin-card';

        const botTitle = document.createElement('h4');
        botTitle.textContent = 'Bot Accounts';
        botCard.appendChild(botTitle);

        const botList = document.createElement('div');
        botList.id = 'admin-bot-list';
        botList.textContent = 'Loading bots...';
        botCard.appendChild(botList);

        // Add bot form
        const addBotForm = document.createElement('div');
        addBotForm.className = 'add-bot-form';

        const instanceInput = document.createElement('input');
        instanceInput.type = 'text';
        instanceInput.id = 'new-bot-instance';
        instanceInput.placeholder = 'Instance URL';

        const tokenInput = document.createElement('input');
        tokenInput.type = 'text';
        tokenInput.id = 'new-bot-token';
        tokenInput.placeholder = 'Access Token';

        const addBotBtn = document.createElement('button');
        addBotBtn.className = 'primary-btn';
        addBotBtn.textContent = 'Add Bot';
        addBotBtn.onclick = () => this.registerBot();

        addBotForm.appendChild(instanceInput);
        addBotForm.appendChild(tokenInput);
        addBotForm.appendChild(addBotBtn);
        botCard.appendChild(addBotForm);

        grid.appendChild(botCard);

        // Quick Actions card
        const actionsCard = document.createElement('div');
        actionsCard.className = 'admin-card';

        const actionsTitle = document.createElement('h4');
        actionsTitle.textContent = 'Quick Actions';
        actionsCard.appendChild(actionsTitle);

        const announceBtn = document.createElement('button');
        announceBtn.className = 'admin-action-btn';
        announceBtn.textContent = 'Announce Online';
        announceBtn.onclick = () => this.announceServerOnline();

        const customBtn = document.createElement('button');
        customBtn.className = 'admin-action-btn';
        customBtn.textContent = 'Custom Announcement';
        customBtn.onclick = () => this.showAnnouncementForm();

        actionsCard.appendChild(announceBtn);
        actionsCard.appendChild(customBtn);

        // Announcement form
        const announcementForm = document.createElement('div');
        announcementForm.id = 'announcement-form';
        announcementForm.style.display = 'none';
        announcementForm.style.marginTop = '10px';

        const textarea = document.createElement('textarea');
        textarea.id = 'announcement-text';
        textarea.placeholder = 'Enter announcement...';
        textarea.rows = 3;
        textarea.style.width = '100%';

        const postBtn = document.createElement('button');
        postBtn.className = 'primary-btn';
        postBtn.textContent = 'Post';
        postBtn.onclick = () => this.postAnnouncement();

        announcementForm.appendChild(textarea);
        announcementForm.appendChild(postBtn);
        actionsCard.appendChild(announcementForm);

        grid.appendChild(actionsCard);
        tab.appendChild(grid);

        return tab;
    }

    createFederationTab() {
        const tab = document.createElement('div');
        tab.className = 'admin-tab-content';
        tab.id = 'admin-federation-tab';

        const title = document.createElement('h3');
        title.textContent = 'Server Federation';
        tab.appendChild(title);

        const card = document.createElement('div');
        card.className = 'admin-card';

        const cardTitle = document.createElement('h4');
        cardTitle.textContent = 'Connected Servers';
        card.appendChild(cardTitle);

        const serverList = document.createElement('div');
        serverList.id = 'admin-federation-list';
        serverList.textContent = 'Loading federated servers...';
        card.appendChild(serverList);

        // Add server form
        const addServerForm = document.createElement('div');
        addServerForm.className = 'add-server-form';

        const serverInput = document.createElement('input');
        serverInput.type = 'text';
        serverInput.id = 'new-federated-server';
        serverInput.placeholder = 'Server URL';

        const addServerBtn = document.createElement('button');
        addServerBtn.className = 'primary-btn';
        addServerBtn.textContent = 'Connect Server';
        addServerBtn.onclick = () => this.addFederatedServer();

        addServerForm.appendChild(serverInput);
        addServerForm.appendChild(addServerBtn);
        card.appendChild(addServerForm);

        tab.appendChild(card);

        return tab;
    }

    createStatItem(label, id, defaultValue) {
        const item = document.createElement('div');
        item.className = 'stat-item';

        const labelSpan = document.createElement('span');
        labelSpan.className = 'stat-label';
        labelSpan.textContent = label;

        const valueSpan = document.createElement('span');
        valueSpan.className = 'stat-value';
        valueSpan.id = id;
        valueSpan.textContent = defaultValue;

        item.appendChild(labelSpan);
        item.appendChild(valueSpan);
        return item;
    }

    createSettingRow(label, id, type, defaultValue) {
        const row = document.createElement('div');
        row.className = 'setting-row';

        const labelEl = document.createElement('label');
        labelEl.textContent = label;

        const input = document.createElement('input');
        input.type = type;
        input.id = id;
        input.value = defaultValue;

        row.appendChild(labelEl);
        row.appendChild(input);
        return row;
    }

    createCheckboxRow(label, id) {
        const row = document.createElement('div');
        row.className = 'setting-row';

        const labelEl = document.createElement('label');

        const checkbox = document.createElement('input');
        checkbox.type = 'checkbox';
        checkbox.id = id;

        labelEl.appendChild(checkbox);
        labelEl.appendChild(document.createTextNode(' ' + label));

        row.appendChild(labelEl);
        return row;
    }

    async loadAdminData() {
        await Promise.all([
            this.loadAdminServerStats(),
            this.loadAdminRooms(),
            this.loadAdminUsers(),
            this.loadAdminBots(),
            this.loadFederatedServers()
        ]);
    }

    async loadAdminServerStats() {
        try {
            const apiBase = this.getApiBaseUrl();
            const response = await fetch(`${apiBase}/api/stats`);
            const stats = await response.json();

            const statusEl = document.getElementById('admin-server-status');
            const uptimeEl = document.getElementById('admin-server-uptime');
            const connEl = document.getElementById('admin-connections');

            if (statusEl) statusEl.textContent = 'Online';
            if (uptimeEl) uptimeEl.textContent = this.formatUptime(stats.uptime);
            if (connEl) connEl.textContent = stats.connections || 0;
        } catch (error) {
            console.error('Failed to load server stats:', error);
        }
    }

    formatUptime(ms) {
        if (!ms) return 'Unknown';
        const hours = Math.floor(ms / 3600000);
        const minutes = Math.floor((ms % 3600000) / 60000);
        return hours + 'h ' + minutes + 'm';
    }

    async loadAdminRooms() {
        try {
            const apiBase = this.getApiBaseUrl();
            const response = await fetch(`${apiBase}/api/rooms`);
            const rooms = await response.json();

            const roomsList = document.getElementById('admin-rooms-list');
            if (roomsList) {
                roomsList.textContent = '';

                if (rooms.length === 0) {
                    roomsList.textContent = 'No active rooms';
                } else {
                    rooms.forEach(room => {
                        const item = this.createAdminListItem(
                            room.name,
                            'Users: ' + (room.users || 0) + '/' + room.maxUsers + ' - ' + (room.hasPassword ? 'Locked' : 'Public'),
                            [
                                { label: 'Edit', action: () => this.editRoom(room.id || room.roomId) },
                                { label: 'Delete', action: () => this.deleteRoom(room.id || room.roomId), danger: true }
                            ]
                        );
                        item.dataset.roomId = room.id || room.roomId;
                        roomsList.appendChild(item);
                    });
                }
            }
        } catch (error) {
            console.error('Failed to load admin rooms:', error);
        }
    }

    async loadAdminUsers() {
        try {
            const apiBase = this.getApiBaseUrl();
            const response = await fetch(`${apiBase}/api/users`);
            const users = await response.json();

            const usersList = document.getElementById('admin-users-list');
            if (usersList) {
                usersList.textContent = '';

                if (!users || users.length === 0) {
                    usersList.textContent = 'No connected users';
                } else {
                    users.forEach(user => {
                        const item = this.createAdminListItem(
                            user.name || user.username || 'Anonymous',
                            'Room: ' + (user.room || 'Lobby') + ' - ' + (user.mastodonHandle || 'No Mastodon'),
                            [
                                { label: 'Kick', action: () => this.kickUser(user.id) },
                                { label: 'Ban', action: () => this.banUser(user.id), danger: true }
                            ]
                        );
                        item.dataset.userId = user.id;
                        usersList.appendChild(item);
                    });
                }
            }
        } catch (error) {
            console.error('Failed to load admin users:', error);
        }
    }

    async loadAdminBots() {
        try {
            const apiBase = this.getApiBaseUrl();
            const response = await fetch(`${apiBase}/api/mastodon/bots`);
            const bots = await response.json();

            const botList = document.getElementById('admin-bot-list');
            if (botList) {
                botList.textContent = '';

                if (!bots || bots.length === 0) {
                    botList.textContent = 'No bots configured';
                } else {
                    bots.forEach(bot => {
                        const item = this.createAdminListItem(
                            '@' + bot.username,
                            bot.instance + ' - ' + (bot.enabled ? 'Active' : 'Disabled'),
                            [
                                { label: bot.enabled ? 'Disable' : 'Enable', action: () => this.toggleBot(encodeURIComponent(bot.instance)) },
                                { label: 'Remove', action: () => this.removeBot(encodeURIComponent(bot.instance)), danger: true }
                            ]
                        );
                        item.dataset.botInstance = bot.instance;
                        botList.appendChild(item);
                    });
                }
            }
        } catch (error) {
            console.error('Failed to load admin bots:', error);
        }
    }

    async loadFederatedServers() {
        try {
            const apiBase = this.getApiBaseUrl();
            const response = await fetch(`${apiBase}/api/federation/servers`);
            const servers = await response.json();

            const serverList = document.getElementById('admin-federation-list');
            if (serverList) {
                serverList.textContent = '';

                if (!servers || servers.length === 0) {
                    serverList.textContent = 'No federated servers';
                } else {
                    servers.forEach(server => {
                        const item = this.createAdminListItem(
                            server.name || server.url,
                            (server.status === 'connected' ? 'Connected' : 'Disconnected') + ' - ' + (server.rooms || 0) + ' rooms',
                            [
                                { label: 'Ping', action: () => this.pingServer(encodeURIComponent(server.url)) },
                                { label: 'Disconnect', action: () => this.disconnectServer(encodeURIComponent(server.url)), danger: true }
                            ]
                        );
                        item.dataset.serverUrl = server.url;
                        serverList.appendChild(item);
                    });
                }
            }
        } catch (error) {
            console.error('Failed to load federated servers:', error);
        }
    }

    createAdminListItem(name, meta, actions) {
        const item = document.createElement('div');
        item.className = 'admin-list-item';

        const info = document.createElement('div');
        info.className = 'item-info';

        const nameSpan = document.createElement('span');
        nameSpan.className = 'item-name';
        nameSpan.textContent = name;

        const metaSpan = document.createElement('span');
        metaSpan.className = 'item-meta';
        metaSpan.textContent = meta;

        info.appendChild(nameSpan);
        info.appendChild(metaSpan);
        item.appendChild(info);

        const actionsDiv = document.createElement('div');
        actionsDiv.className = 'item-actions';

        actions.forEach(action => {
            const btn = document.createElement('button');
            btn.className = 'small-btn' + (action.danger ? ' danger' : '');
            btn.textContent = action.label;
            btn.onclick = action.action;
            actionsDiv.appendChild(btn);
        });

        item.appendChild(actionsDiv);
        return item;
    }

    // Admin actions
    async adminRestartServer() {
        if (confirm('Are you sure you want to restart the server?')) {
            try {
                const apiBase = this.getApiBaseUrl();
                await fetch(`${apiBase}/api/admin/restart`, { method: 'POST' });
                this.showNotification('Server restarting...', 'info');
            } catch (error) {
                this.showNotification('Failed to restart server', 'error');
            }
        }
    }

    async adminStopServer() {
        if (confirm('Are you sure you want to stop the server? All users will be disconnected.')) {
            try {
                const apiBase = this.getApiBaseUrl();
                await fetch(`${apiBase}/api/admin/stop`, { method: 'POST' });
                this.showNotification('Server stopping...', 'info');
            } catch (error) {
                this.showNotification('Failed to stop server', 'error');
            }
        }
    }

    async createDefaultRooms() {
        try {
            const apiBase = this.getApiBaseUrl();
            const response = await fetch(`${apiBase}/api/rooms/generate-defaults`, { method: 'POST' });
            const result = await response.json();

            this.showNotification('Created ' + (result.count || 0) + ' default rooms', 'success');
            this.loadAdminRooms();
            this.loadRooms();
        } catch (error) {
            this.showNotification('Failed to create default rooms', 'error');
        }
    }

    async cleanupExpiredRooms() {
        try {
            const apiBase = this.getApiBaseUrl();
            const response = await fetch(`${apiBase}/api/rooms/cleanup`, { method: 'POST' });
            const result = await response.json();

            this.showNotification('Cleaned up ' + (result.removed || 0) + ' expired rooms', 'success');
            this.loadAdminRooms();
            this.loadRooms();
        } catch (error) {
            this.showNotification('Failed to cleanup rooms', 'error');
        }
    }

    async deleteRoom(roomId) {
        if (confirm('Delete this room? All users will be disconnected.')) {
            try {
                const apiBase = this.getApiBaseUrl();
                await fetch(`${apiBase}/api/rooms/${roomId}`, { method: 'DELETE' });
                this.showNotification('Room deleted', 'success');
                this.loadAdminRooms();
                this.loadRooms();
            } catch (error) {
                this.showNotification('Failed to delete room', 'error');
            }
        }
    }

    async registerBot() {
        const instanceInput = document.getElementById('new-bot-instance');
        const tokenInput = document.getElementById('new-bot-token');

        if (!instanceInput?.value || !tokenInput?.value) {
            this.showNotification('Please enter instance URL and access token', 'error');
            return;
        }

        try {
            const apiBase = this.getApiBaseUrl();

            const response = await fetch(`${apiBase}/api/mastodon/bots`, {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({
                    instanceUrl: instanceInput.value,
                    accessToken: tokenInput.value
                })
            });

            const result = await response.json();

            if (result.success) {
                this.showNotification('Bot @' + result.bot.username + ' registered!', 'success');
                instanceInput.value = '';
                tokenInput.value = '';
                this.loadAdminBots();
            } else {
                this.showNotification(result.error || 'Failed to register bot', 'error');
            }
        } catch (error) {
            this.showNotification('Failed to register bot', 'error');
        }
    }

    async removeBot(instance) {
        if (confirm('Remove this bot?')) {
            try {
                const apiBase = this.getApiBaseUrl();
                await fetch(`${apiBase}/api/mastodon/bots/${instance}`, { method: 'DELETE' });
                this.showNotification('Bot removed', 'success');
                this.loadAdminBots();
            } catch (error) {
                this.showNotification('Failed to remove bot', 'error');
            }
        }
    }

    showAnnouncementForm() {
        const form = document.getElementById('announcement-form');
        if (form) {
            form.style.display = form.style.display === 'none' ? 'block' : 'none';
        }
    }

    async postAnnouncement() {
        const textArea = document.getElementById('announcement-text');

        if (!textArea?.value.trim()) {
            this.showNotification('Please enter an announcement', 'error');
            return;
        }

        try {
            const apiBase = this.getApiBaseUrl();

            const response = await fetch(`${apiBase}/api/mastodon/announce`, {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({
                    message: textArea.value,
                    visibility: 'public'
                })
            });

            const result = await response.json();

            if (result.success) {
                this.showNotification('Announcement posted!', 'success');
                textArea.value = '';
                document.getElementById('announcement-form').style.display = 'none';
            } else {
                this.showNotification('Failed to post announcement', 'error');
            }
        } catch (error) {
            this.showNotification('Failed to post announcement', 'error');
        }
    }

    async announceServerOnline() {
        try {
            const apiBase = this.getApiBaseUrl();

            const response = await fetch(`${apiBase}/api/mastodon/announce`, {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({
                    message: `VoiceLink Server is now online!\n\n${apiBase}\n\n#VoiceLink #VoiceChat #P2P`,
                    visibility: 'public'
                })
            });

            const result = await response.json();

            if (result.success) {
                this.showNotification('Server online announcement posted!', 'success');
            } else {
                this.showNotification('Failed to post announcement', 'error');
            }
        } catch (error) {
            this.showNotification('Failed to post announcement', 'error');
        }
    }

    async broadcastMessage() {
        const message = prompt('Enter message to broadcast to all users:');
        if (!message) return;

        try {
            const apiBase = this.getApiBaseUrl();

            await fetch(`${apiBase}/api/admin/broadcast`, {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ message })
            });

            this.showNotification('Broadcast sent', 'success');
        } catch (error) {
            this.showNotification('Failed to send broadcast', 'error');
        }
    }

    async kickUser(userId) {
        if (confirm('Kick this user?')) {
            try {
                const apiBase = this.getApiBaseUrl();
                await fetch(`${apiBase}/api/admin/users/${userId}/kick`, { method: 'POST' });
                this.showNotification('User kicked', 'success');
                this.loadAdminUsers();
            } catch (error) {
                this.showNotification('Failed to kick user', 'error');
            }
        }
    }

    async banUser(userId) {
        if (confirm('Ban this user? They will not be able to reconnect.')) {
            try {
                const apiBase = this.getApiBaseUrl();
                await fetch(`${apiBase}/api/admin/users/${userId}/ban`, { method: 'POST' });
                this.showNotification('User banned', 'success');
                this.loadAdminUsers();
            } catch (error) {
                this.showNotification('Failed to ban user', 'error');
            }
        }
    }

    async addFederatedServer() {
        const serverInput = document.getElementById('new-federated-server');
        if (!serverInput?.value) {
            this.showNotification('Please enter a server URL', 'error');
            return;
        }

        try {
            const apiBase = this.getApiBaseUrl();

            const response = await fetch(`${apiBase}/api/federation/connect`, {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ serverUrl: serverInput.value })
            });

            const result = await response.json();

            if (result.success) {
                this.showNotification('Server connected!', 'success');
                serverInput.value = '';
                this.loadFederatedServers();
            } else {
                this.showNotification(result.error || 'Failed to connect', 'error');
            }
        } catch (error) {
            this.showNotification('Failed to connect to server', 'error');
        }
    }

    async saveServerSettings() {
        try {
            const apiBase = this.getApiBaseUrl();

            const settings = {
                maxRooms: document.getElementById('admin-max-rooms')?.value,
                requireAuth: document.getElementById('admin-require-auth')?.checked
            };

            await fetch(`${apiBase}/api/admin/settings`, {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify(settings)
            });

            this.showNotification('Settings saved!', 'success');
        } catch (error) {
            this.showNotification('Failed to save settings', 'error');
        }
    }

    refreshUserList() {
        this.loadAdminUsers();
        this.showNotification('User list refreshed', 'info');
    }

    editRoom(roomId) {
        this.showNotification('Room editor coming soon', 'info');
    }

    toggleBot(instance) {
        this.showNotification('Bot toggle coming soon', 'info');
    }

    pingServer(serverUrl) {
        this.showNotification('Pinging server...', 'info');
    }

    disconnectServer(serverUrl) {
        this.showNotification('Server disconnect coming soon', 'info');
    }

}

/**
 * JukeboxManager - Manages Jellyfin media streaming integration
 * Provides UI controls for browsing, queuing, and playing media in rooms
 */
class JukeboxManager {
    constructor(app) {
        this.app = app;
        this.isEnabled = false;
        this.isMinimized = false;
        this.servers = [];
        this.currentServer = null;
        this.queue = [];
        this.currentTrack = null;
        this.currentIndex = -1;
        this.isPlaying = false;
        this.isLooping = false;
        this.volume = 50;
        this.audioElement = null;
        this.progressInterval = null;

        this.elements = {
            panel: document.getElementById('jukebox-panel'),
            toggleBtn: document.getElementById('jukebox-toggle-btn'),
            configBtn: document.getElementById('jukebox-config-btn'),
            minimizeBtn: document.getElementById('jukebox-minimize-btn'),
            closeBtn: document.getElementById('jukebox-close-btn'),
            nowPlaying: document.getElementById('jukebox-now-playing'),
            progress: document.getElementById('jukebox-progress'),
            currentTime: document.getElementById('jukebox-current-time'),
            duration: document.getElementById('jukebox-duration'),
            prevBtn: document.getElementById('jukebox-prev-btn'),
            playBtn: document.getElementById('jukebox-play-btn'),
            nextBtn: document.getElementById('jukebox-next-btn'),
            loopBtn: document.getElementById('jukebox-loop-btn'),
            volumeSlider: document.getElementById('jukebox-volume'),
            queueList: document.getElementById('jukebox-queue-list'),
            libraryList: document.getElementById('jukebox-library-list'),
            searchInput: document.getElementById('jukebox-search'),
            searchBtn: document.getElementById('jukebox-search-btn')
        };

        this.init();
    }

    init() {
        this.setupEventListeners();
        this.createAudioElement();
        this.loadServers();
        console.log('JukeboxManager initialized');
    }

    setupEventListeners() {
        // Toggle button
        this.elements.toggleBtn?.addEventListener('click', () => this.togglePanel());

        // Header controls
        this.elements.configBtn?.addEventListener('click', () => this.openServerConfig());
        this.elements.minimizeBtn?.addEventListener('click', () => this.minimize());
        this.elements.closeBtn?.addEventListener('click', () => this.closePanel());

        // Playback controls
        this.elements.prevBtn?.addEventListener('click', () => this.previous());
        this.elements.playBtn?.addEventListener('click', () => this.togglePlayPause());
        this.elements.nextBtn?.addEventListener('click', () => this.next());
        this.elements.loopBtn?.addEventListener('click', () => this.toggleLoop());

        // Progress and volume
        this.elements.progress?.addEventListener('input', (e) => this.seek(e.target.value));
        this.elements.volumeSlider?.addEventListener('input', (e) => this.setVolume(e.target.value));

        // Search
        this.elements.searchBtn?.addEventListener('click', () => this.searchLibrary());
        this.elements.searchInput?.addEventListener('keypress', (e) => {
            if (e.key === 'Enter') this.searchLibrary();
        });

        // Socket events for synced playback
        if (this.app.socket) {
            this.app.socket.on('jukebox-play', (data) => this.handleRemotePlay(data));
            this.app.socket.on('jukebox-pause', () => this.handleRemotePause());
            this.app.socket.on('jukebox-skip', (data) => this.handleRemoteSkip(data));
            this.app.socket.on('jukebox-queue-update', (data) => this.handleRemoteQueueUpdate(data));
        }
    }

    createAudioElement() {
        this.audioElement = new Audio();
        this.audioElement.crossOrigin = 'anonymous';
        this.audioElement.volume = this.volume / 100;

        this.audioElement.addEventListener('timeupdate', () => this.updateProgress());
        this.audioElement.addEventListener('ended', () => this.handleTrackEnded());
        this.audioElement.addEventListener('loadedmetadata', () => this.updateDuration());
        this.audioElement.addEventListener('error', (e) => this.handlePlaybackError(e));
    }

    async loadServers() {
        try {
            const apiBase = this.app.getApiBaseUrl();
            const response = await fetch(`${apiBase}/api/jellyfin/servers`);
            const data = await response.json();

            if (data.success && data.servers) {
                this.servers = data.servers;
                if (this.servers.length > 0) {
                    this.currentServer = this.servers[0];
                    this.loadLibrary();
                }
            }
        } catch (error) {
            console.error('Failed to load Jellyfin servers:', error);
        }
    }

    async loadLibrary(parentId = null) {
        if (!this.currentServer) return;

        try {
            const apiBase = this.app.getApiBaseUrl();

            const params = new URLSearchParams({
                serverId: this.currentServer.id
            });
            if (parentId) params.append('parentId', parentId);

            const response = await fetch(`${apiBase}/api/jellyfin/library?${params}`);
            const data = await response.json();

            if (data.success && data.items) {
                this.renderLibrary(data.items, parentId);
            }
        } catch (error) {
            console.error('Failed to load library:', error);
        }
    }

    renderLibrary(items, parentId = null) {
        if (!this.elements.libraryList) return;

        this.elements.libraryList.innerHTML = '';

        // Add back button if in subfolder
        if (parentId) {
            const backItem = document.createElement('div');
            backItem.className = 'library-item back-item';
            backItem.innerHTML = '⬅️ Back';
            backItem.addEventListener('click', () => this.loadLibrary());
            this.elements.libraryList.appendChild(backItem);
        }

        items.forEach(item => {
            const itemEl = document.createElement('div');
            itemEl.className = 'library-item';
            itemEl.dataset.id = item.Id;
            itemEl.dataset.type = item.Type;

            const icon = this.getItemIcon(item.Type);
            const name = item.Name || 'Unknown';
            const artist = item.AlbumArtist || item.Artists?.[0] || '';

            itemEl.innerHTML = `
                <span class="item-icon">${icon}</span>
                <div class="item-info">
                    <span class="item-name">${name}</span>
                    ${artist ? `<span class="item-artist">${artist}</span>` : ''}
                </div>
                ${item.Type === 'Audio' ? '<button class="add-queue-btn" title="Add to queue">+</button>' : ''}
            `;

            // Click handler
            if (item.Type === 'Audio') {
                itemEl.addEventListener('click', (e) => {
                    if (e.target.classList.contains('add-queue-btn')) {
                        this.addToQueue(item);
                    } else {
                        this.playItem(item);
                    }
                });
            } else if (['Folder', 'MusicAlbum', 'MusicArtist', 'CollectionFolder'].includes(item.Type)) {
                itemEl.addEventListener('click', () => this.loadLibrary(item.Id));
            }

            this.elements.libraryList.appendChild(itemEl);
        });
    }

    getItemIcon(type) {
        const icons = {
            'Audio': '🎵',
            'MusicAlbum': '💿',
            'MusicArtist': '👤',
            'Folder': '📁',
            'CollectionFolder': '📚',
            'Video': '🎬',
            'Movie': '🎥',
            'Episode': '📺'
        };
        return icons[type] || '📄';
    }

    async searchLibrary() {
        const query = this.elements.searchInput?.value?.trim();
        if (!query || !this.currentServer) return;

        try {
            const apiBase = this.app.getApiBaseUrl();

            const params = new URLSearchParams({
                serverId: this.currentServer.id,
                query: query
            });

            const response = await fetch(`${apiBase}/api/jellyfin/search?${params}`);
            const data = await response.json();

            if (data.success && data.items) {
                this.renderLibrary(data.items);
            }
        } catch (error) {
            console.error('Failed to search library:', error);
        }
    }

    async playItem(item) {
        if (!this.currentServer || !item) return;

        try {
            const apiBase = this.app.getApiBaseUrl();

            const response = await fetch(`${apiBase}/api/jellyfin/stream-url`, {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({
                    serverId: this.currentServer.id,
                    itemId: item.Id,
                    type: item.Type === 'Audio' ? 'audio' : 'video'
                })
            });

            const data = await response.json();

            if (data.success && data.streamUrl) {
                this.currentTrack = {
                    ...item,
                    streamUrl: data.streamUrl
                };

                this.audioElement.src = data.streamUrl;
                this.audioElement.play();
                this.isPlaying = true;
                this.updateNowPlaying();
                this.updatePlayButton();

                // Broadcast to room
                this.broadcastPlay();
            }
        } catch (error) {
            console.error('Failed to play item:', error);
            this.app.showNotification('Failed to play media', 'error');
        }
    }

    addToQueue(item) {
        this.queue.push(item);
        this.renderQueue();
        this.app.showNotification(`Added "${item.Name}" to queue`, 'success');

        // If nothing playing, start playback
        if (!this.currentTrack) {
            this.currentIndex = 0;
            this.playItem(this.queue[0]);
        }

        this.broadcastQueueUpdate();
    }

    renderQueue() {
        if (!this.elements.queueList) return;

        this.elements.queueList.innerHTML = '';

        if (this.queue.length === 0) {
            const empty = document.createElement('div');
            empty.className = 'queue-empty';
            empty.textContent = 'Queue is empty';
            this.elements.queueList.appendChild(empty);
            return;
        }

        this.queue.forEach((item, index) => {
            const queueItem = document.createElement('div');
            queueItem.className = 'queue-item' + (index === this.currentIndex ? ' active' : '');
            queueItem.innerHTML = `
                <span class="queue-number">${index + 1}</span>
                <div class="queue-info">
                    <span class="queue-name">${item.Name}</span>
                    <span class="queue-artist">${item.AlbumArtist || item.Artists?.[0] || ''}</span>
                </div>
                <button class="remove-queue-btn" data-index="${index}" title="Remove">✕</button>
            `;

            queueItem.querySelector('.remove-queue-btn')?.addEventListener('click', (e) => {
                e.stopPropagation();
                this.removeFromQueue(index);
            });

            queueItem.addEventListener('click', () => {
                this.currentIndex = index;
                this.playItem(this.queue[index]);
            });

            this.elements.queueList.appendChild(queueItem);
        });
    }

    removeFromQueue(index) {
        this.queue.splice(index, 1);
        if (index < this.currentIndex) {
            this.currentIndex--;
        } else if (index === this.currentIndex) {
            if (this.queue.length > 0) {
                this.currentIndex = Math.min(this.currentIndex, this.queue.length - 1);
                this.playItem(this.queue[this.currentIndex]);
            } else {
                this.stop();
            }
        }
        this.renderQueue();
        this.broadcastQueueUpdate();
    }

    togglePlayPause() {
        if (this.isPlaying) {
            this.pause();
        } else {
            this.play();
        }
    }

    play() {
        if (this.audioElement.src) {
            this.audioElement.play();
            this.isPlaying = true;
            this.updatePlayButton();
            this.broadcastPlay();
        } else if (this.queue.length > 0) {
            this.currentIndex = 0;
            this.playItem(this.queue[0]);
        }
    }

    pause() {
        this.audioElement.pause();
        this.isPlaying = false;
        this.updatePlayButton();
        this.broadcastPause();
    }

    stop() {
        this.audioElement.pause();
        this.audioElement.currentTime = 0;
        this.audioElement.src = '';
        this.isPlaying = false;
        this.currentTrack = null;
        this.currentIndex = -1;
        this.updatePlayButton();
        this.updateNowPlaying();
    }

    previous() {
        if (this.queue.length === 0) return;

        // If more than 3 seconds in, restart; otherwise go to previous
        if (this.audioElement.currentTime > 3) {
            this.audioElement.currentTime = 0;
        } else {
            this.currentIndex = (this.currentIndex - 1 + this.queue.length) % this.queue.length;
            this.playItem(this.queue[this.currentIndex]);
        }
        this.renderQueue();
    }

    next() {
        if (this.queue.length === 0) return;

        this.currentIndex = (this.currentIndex + 1) % this.queue.length;
        this.playItem(this.queue[this.currentIndex]);
        this.renderQueue();
        this.broadcastSkip(this.currentIndex);
    }

    toggleLoop() {
        this.isLooping = !this.isLooping;
        this.audioElement.loop = this.isLooping && this.queue.length <= 1;

        if (this.elements.loopBtn) {
            this.elements.loopBtn.classList.toggle('active', this.isLooping);
        }
    }

    seek(value) {
        if (this.audioElement.duration) {
            this.audioElement.currentTime = (value / 100) * this.audioElement.duration;
        }
    }

    setVolume(value) {
        this.volume = parseInt(value);
        this.audioElement.volume = this.volume / 100;
    }

    updateProgress() {
        if (!this.audioElement.duration) return;

        const progress = (this.audioElement.currentTime / this.audioElement.duration) * 100;
        if (this.elements.progress) {
            this.elements.progress.value = progress;
        }
        if (this.elements.currentTime) {
            this.elements.currentTime.textContent = this.formatTime(this.audioElement.currentTime);
        }
    }

    updateDuration() {
        if (this.elements.duration) {
            this.elements.duration.textContent = this.formatTime(this.audioElement.duration);
        }
    }

    formatTime(seconds) {
        const mins = Math.floor(seconds / 60);
        const secs = Math.floor(seconds % 60);
        return `${mins}:${secs.toString().padStart(2, '0')}`;
    }

    updateNowPlaying() {
        if (!this.elements.nowPlaying) return;

        if (this.currentTrack) {
            const titleEl = this.elements.nowPlaying.querySelector('.now-playing-title');
            const artistEl = this.elements.nowPlaying.querySelector('.now-playing-artist');

            if (titleEl) titleEl.textContent = this.currentTrack.Name || 'Unknown';
            if (artistEl) artistEl.textContent = this.currentTrack.AlbumArtist || this.currentTrack.Artists?.[0] || '';
        }
    }

    updatePlayButton() {
        if (this.elements.playBtn) {
            this.elements.playBtn.textContent = this.isPlaying ? '⏸️' : '▶️';
        }
    }

    handleTrackEnded() {
        if (this.queue.length > 0) {
            if (this.isLooping && this.queue.length === 1) {
                this.audioElement.currentTime = 0;
                this.audioElement.play();
            } else {
                this.next();
            }
        } else {
            this.stop();
        }
    }

    handlePlaybackError(e) {
        console.error('Playback error:', e);
        this.app.showNotification('Playback error. Trying next track...', 'error');
        if (this.queue.length > 1) {
            this.next();
        } else {
            this.stop();
        }
    }

    // Socket broadcast methods
    broadcastPlay() {
        if (this.app.socket && this.app.currentRoom) {
            this.app.socket.emit('jukebox-play', {
                roomId: this.app.currentRoom.id,
                track: this.currentTrack,
                position: this.audioElement.currentTime
            });
        }
    }

    broadcastPause() {
        if (this.app.socket && this.app.currentRoom) {
            this.app.socket.emit('jukebox-pause', {
                roomId: this.app.currentRoom.id
            });
        }
    }

    broadcastSkip(index) {
        if (this.app.socket && this.app.currentRoom) {
            this.app.socket.emit('jukebox-skip', {
                roomId: this.app.currentRoom.id,
                index: index
            });
        }
    }

    broadcastQueueUpdate() {
        if (this.app.socket && this.app.currentRoom) {
            this.app.socket.emit('jukebox-queue-update', {
                roomId: this.app.currentRoom.id,
                queue: this.queue
            });
        }
    }

    // Remote event handlers
    handleRemotePlay(data) {
        if (data.track && data.track.streamUrl) {
            this.currentTrack = data.track;
            this.audioElement.src = data.track.streamUrl;
            if (data.position) {
                this.audioElement.currentTime = data.position;
            }
            this.audioElement.play();
            this.isPlaying = true;
            this.updateNowPlaying();
            this.updatePlayButton();
        }
    }

    handleRemotePause() {
        this.audioElement.pause();
        this.isPlaying = false;
        this.updatePlayButton();
    }

    handleRemoteSkip(data) {
        if (this.queue[data.index]) {
            this.currentIndex = data.index;
            this.playItem(this.queue[data.index]);
        }
    }

    handleRemoteQueueUpdate(data) {
        if (data.queue) {
            this.queue = data.queue;
            this.renderQueue();
        }
    }

    // Panel visibility
    togglePanel() {
        if (this.elements.panel?.classList.contains('hidden')) {
            this.openPanel();
        } else {
            this.closePanel();
        }
    }

    openPanel() {
        this.elements.panel?.classList.remove('hidden', 'minimized');
        this.elements.toggleBtn?.classList.add('hidden');
        this.isMinimized = false;
    }

    closePanel() {
        this.elements.panel?.classList.add('hidden');
        this.elements.toggleBtn?.classList.remove('hidden');
    }

    minimize() {
        this.elements.panel?.classList.toggle('minimized');
        this.isMinimized = !this.isMinimized;
    }

    // Open server configuration (MediaStreamingInterface)
    openServerConfig() {
        if (window.mediaStreamingInterface) {
            window.mediaStreamingInterface.show();
        } else {
            this.app?.showToast('Media Streaming interface not available');
        }
    }

    // Enable/disable for room
    enable() {
        this.isEnabled = true;
        this.elements.toggleBtn?.classList.remove('hidden');
    }

    disable() {
        this.isEnabled = false;
        this.closePanel();
        this.elements.toggleBtn?.classList.add('hidden');
        this.stop();
    }

    // Stop room sync but keep playing (for when leaving room but wanting to continue listening)
    stopRoomSync() {
        // Just stop broadcasting to room, keep local playback going
        console.log('Jukebox: Stopped room sync, playback continues locally');
    }

    // Get current state for admin controls
    getState() {
        return {
            isEnabled: this.isEnabled,
            isPlaying: this.isPlaying,
            currentTrack: this.currentTrack,
            queue: this.queue,
            volume: this.volume
        };
    }

    // ============================================
    // ROOM-LOCALIZED JUKEBOX WITH SPATIAL AUDIO
    // ============================================

    /**
     * Initialize room-specific audio with binaural 3D spatial processing
     */
    initRoomAudio() {
        if (this.audioContext) return; // Already initialized

        this.audioContext = new (window.AudioContext || window.webkitAudioContext)();
        this.roomVolume = 50; // Default room volume (50%)
        this.isAdminOnlyVolume = false;
        this.currentRoom = null;
        this.fadeInDuration = 1.5; // seconds

        // Create audio nodes for spatial processing
        this.setupSpatialAudioNodes();

        console.log('Room audio initialized with binaural 3D processing');
    }

    /**
     * Setup binaural 3D spatial audio processing chain
     */
    setupSpatialAudioNodes() {
        // Master gain for room volume control
        this.masterGain = this.audioContext.createGain();
        this.masterGain.gain.value = this.roomVolume / 100;

        // HRTF Panner for binaural 3D audio (cafe-like ambience)
        this.binauralPanner = this.audioContext.createPanner();
        this.binauralPanner.panningModel = 'HRTF'; // Head-related transfer function
        this.binauralPanner.distanceModel = 'inverse';
        this.binauralPanner.refDistance = 1;
        this.binauralPanner.maxDistance = 50;
        this.binauralPanner.rolloffFactor = 1;
        this.binauralPanner.coneInnerAngle = 360;
        this.binauralPanner.coneOuterAngle = 360;
        this.binauralPanner.coneOuterGain = 0;

        // Position audio source slightly in front and to the side (like cafe speakers)
        this.binauralPanner.positionX.value = 2;
        this.binauralPanner.positionY.value = 1;
        this.binauralPanner.positionZ.value = -3;

        // Stereo widener using delay
        this.stereoDelay = this.audioContext.createDelay(0.05);
        this.stereoDelay.delayTime.value = 0.02; // 20ms delay for spatial feel

        // Subtle reverb/ambience using convolver (optional)
        this.createAmbienceReverb();

        // Connect the chain: source -> panner -> gain -> destination
        this.binauralPanner.connect(this.masterGain);
        this.masterGain.connect(this.audioContext.destination);
    }

    /**
     * Create subtle room ambience reverb for cafe-like sound
     */
    createAmbienceReverb() {
        // Create a simple impulse response for room ambience
        const sampleRate = this.audioContext.sampleRate;
        const duration = 0.8; // Short reverb for ambient sound
        const channels = 2;
        const frameCount = sampleRate * duration;

        const impulseBuffer = this.audioContext.createBuffer(channels, frameCount, sampleRate);

        for (let channel = 0; channel < channels; channel++) {
            const channelData = impulseBuffer.getChannelData(channel);
            for (let i = 0; i < frameCount; i++) {
                // Exponential decay with some randomness for natural feel
                channelData[i] = (Math.random() * 2 - 1) * Math.pow(1 - i / frameCount, 2) * 0.3;
            }
        }

        this.convolver = this.audioContext.createConvolver();
        this.convolver.buffer = impulseBuffer;

        // Wet/dry mix
        this.reverbGain = this.audioContext.createGain();
        this.reverbGain.gain.value = 0.15; // Subtle reverb

        this.convolver.connect(this.reverbGain);
        this.reverbGain.connect(this.audioContext.destination);
    }

    /**
     * Connect audio element to spatial processing
     */
    connectToSpatialAudio() {
        if (!this.audioContext || !this.audioElement) return;

        // Resume audio context if suspended
        if (this.audioContext.state === 'suspended') {
            this.audioContext.resume();
        }

        // Disconnect existing source if any
        if (this.mediaSource) {
            try {
                this.mediaSource.disconnect();
            } catch (e) {
                // Ignore disconnect errors
            }
        }

        // Create new media source from audio element
        try {
            this.mediaSource = this.audioContext.createMediaElementSource(this.audioElement);
            this.mediaSource.connect(this.binauralPanner);

            // Also send to reverb for ambience
            if (this.convolver) {
                this.mediaSource.connect(this.convolver);
            }
        } catch (e) {
            // Already connected - use existing source
            console.log('Audio source already connected');
        }
    }

    /**
     * Play media for room with fade-in and spatial audio
     */
    playForRoom(streamUrl, trackName, options = {}) {
        if (!this.audioContext) {
            this.initRoomAudio();
        }

        this.currentTrack = {
            Name: trackName,
            streamUrl: streamUrl
        };

        this.audioElement.src = streamUrl;

        // Start at 0 volume for fade-in
        if (this.masterGain) {
            this.masterGain.gain.value = 0;
        }

        this.audioElement.play().then(() => {
            this.isPlaying = true;
            this.updateNowPlaying();
            this.updatePlayButton();

            // Connect to spatial processing
            this.connectToSpatialAudio();

            // Fade in over 1.5 seconds
            this.fadeIn(this.fadeInDuration);

            // Broadcast to room
            this.broadcastPlay();
        }).catch(e => {
            console.error('Failed to play for room:', e);
        });
    }

    /**
     * Smooth fade-in for room audio
     */
    fadeIn(duration = 1.5) {
        if (!this.masterGain) return;

        const targetVolume = this.roomVolume / 100;
        const currentTime = this.audioContext.currentTime;

        this.masterGain.gain.cancelScheduledValues(currentTime);
        this.masterGain.gain.setValueAtTime(0, currentTime);
        this.masterGain.gain.linearRampToValueAtTime(targetVolume, currentTime + duration);
    }

    /**
     * Smooth fade-out when leaving room
     */
    fadeOut(duration = 0.5) {
        if (!this.masterGain) return;

        const currentTime = this.audioContext.currentTime;
        const currentVolume = this.masterGain.gain.value;

        this.masterGain.gain.cancelScheduledValues(currentTime);
        this.masterGain.gain.setValueAtTime(currentVolume, currentTime);
        this.masterGain.gain.linearRampToValueAtTime(0, currentTime + duration);
    }

    /**
     * Set room volume (respects admin-only restrictions)
     */
    setRoomVolume(value, isAdmin = false) {
        if (this.isAdminOnlyVolume && !isAdmin) {
            console.log('Volume control is admin-only for this room');
            return false;
        }

        this.roomVolume = Math.max(0, Math.min(100, parseInt(value)));

        if (this.masterGain) {
            this.masterGain.gain.value = this.roomVolume / 100;
        }

        // Also update the regular audio element volume as backup
        this.audioElement.volume = this.roomVolume / 100;

        return true;
    }

    /**
     * Set room volume restrictions (admin control)
     */
    setAdminOnlyVolume(enabled) {
        this.isAdminOnlyVolume = enabled;
        console.log(`Room volume control: ${enabled ? 'Admin only' : 'Anyone'}`);
    }

    /**
     * Set 3D position for spatial audio (for different room types)
     */
    setSpatialPosition(preset = 'cafe') {
        if (!this.binauralPanner) return;

        const presets = {
            cafe: { x: 2, y: 1, z: -3 },      // Speakers to the front-right
            lounge: { x: 0, y: 0.5, z: -2 },  // Centered, slightly above
            studio: { x: 0, y: 0, z: -1 },    // Direct front
            surround: { x: 3, y: 2, z: -4 }   // Wider, more immersive
        };

        const pos = presets[preset] || presets.cafe;

        this.binauralPanner.positionX.value = pos.x;
        this.binauralPanner.positionY.value = pos.y;
        this.binauralPanner.positionZ.value = pos.z;

        console.log(`Spatial audio preset: ${preset}`);
    }

    /**
     * Handle room join - fade in any playing audio
     */
    onRoomJoin(roomId, roomSettings = {}) {
        this.currentRoom = roomId;

        // Apply room-specific settings
        if (roomSettings.adminOnlyVolume !== undefined) {
            this.setAdminOnlyVolume(roomSettings.adminOnlyVolume);
        }
        if (roomSettings.defaultVolume !== undefined) {
            this.roomVolume = roomSettings.defaultVolume;
        } else {
            this.roomVolume = 50; // Default 50%
        }
        if (roomSettings.spatialPreset) {
            this.setSpatialPosition(roomSettings.spatialPreset);
        }

        // If audio was playing, fade it in
        if (this.isPlaying && this.masterGain) {
            this.fadeIn(this.fadeInDuration);
        }
    }

    /**
     * Handle room leave - fade out but keep audio playing for next person
     */
    onRoomLeave() {
        // Fade out audio when leaving
        this.fadeOut(0.5);

        // Keep the stream playing - it persists for the room
        // Just stop syncing locally
        this.currentRoom = null;
    }
}

// Initialize the application when DOM is loaded
document.addEventListener('DOMContentLoaded', () => {
    window.app = new VoiceLinkApp();
    window.voiceLinkApp = window.app; // For compatibility

    // Initialize accessible dropdowns for VoiceOver support
    if (typeof initAccessibleDropdowns === 'function') {
        initAccessibleDropdowns('select');
        console.log('Accessible dropdowns initialized for VoiceOver compatibility');
    }
});

// Export for testing
if (typeof module !== 'undefined' && module.exports) {
    module.exports = VoiceLinkApp;
}
