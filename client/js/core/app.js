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

        // Audio playback management
        this.currentAudio = null;
        this.isAudioPlaying = false;

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

    async init() {
        console.log('Initializing VoiceLink Local...');

        try {
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

            // Load rooms
            await this.loadRooms();

            // Show main menu
            setTimeout(() => {
                this.showScreen('main-menu');
                // Start periodic server status monitoring
                this.startServerStatusMonitoring();
            }, 2000);

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
            // Determine host - use page host for web access, localhost for Electron
            const pageHost = window.location.hostname || 'localhost';
            const pagePort = window.location.port;
            const isElectron = typeof process !== 'undefined' && process.versions?.electron;
            const host = isElectron ? 'localhost' : pageHost;

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
                const result = await window.electronAPI?.startServer();
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
                const result = await window.electronAPI?.stopServer();
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
                const result = await window.electronAPI?.restartServer();
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

        document.getElementById('quick-audio-room-btn')?.addEventListener('click', () => {
            this.showQuickAudioPanel();
        });

        // Settings screen navigation
        document.getElementById('close-settings')?.addEventListener('click', () => {
            this.showScreen('main-menu');
        });

        document.getElementById('cancel-settings')?.addEventListener('click', () => {
            this.showScreen('main-menu');
        });

        // Desktop app controls (only available in Electron)
        if (window.electronAPI) {
            // Show desktop controls section
            const desktopControls = document.getElementById('desktop-controls');
            if (desktopControls) {
                desktopControls.style.display = 'block';
            }

            // Minimize to tray button
            document.getElementById('minimize-to-tray-btn')?.addEventListener('click', async () => {
                try {
                    await window.electronAPI.minimizeToTray();
                } catch (error) {
                    console.error('Failed to minimize to tray:', error);
                }
            });

            // Preferences button
            document.getElementById('preferences-btn')?.addEventListener('click', async () => {
                try {
                    await window.electronAPI.showPreferences();
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
        });

        document.getElementById('deafen-btn')?.addEventListener('click', () => {
            // Toggle deafen state (implement state tracking)
            const isDeafened = this.isDeafened || false;
            this.isDeafened = !isDeafened;
            this.webrtcManager?.setDeafened(this.isDeafened);
        });

        document.getElementById('leave-room-btn')?.addEventListener('click', () => {
            this.leaveRoom();
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
            this.audioEngine.testSpeakers();
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
                statusValue.textContent = '🟢 Online';
                statusValue.style.color = '#4CAF50';
            } else {
                statusValue.textContent = '🔴 Offline';
                statusValue.style.color = '#f44336';
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
    }

    setServerButtonState(status) {
        const startBtn = document.getElementById('start-server-btn');
        const stopBtn = document.getElementById('stop-server-btn');
        const restartBtn = document.getElementById('restart-server-btn');

        // Only show server control buttons in Electron app, not in browser
        const isElectron = typeof process !== 'undefined' && process.versions?.electron;
        if (!isElectron) {
            // Hide all server control buttons for web visitors
            if (startBtn) startBtn.style.display = 'none';
            if (stopBtn) stopBtn.style.display = 'none';
            if (restartBtn) restartBtn.style.display = 'none';
            return;
        }

        // Show/hide buttons based on status (Electron only)
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
        // Initial status check - if no socket connection, server is offline
        if (!this.socket || !this.socket.connected) {
            this.updateServerStatus('offline');
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
            // Get host and port from socket connection or page location
            const host = this.socket?.io?.opts?.hostname || window.location.hostname || 'localhost';
            const port = this.socket?.io?.opts?.port || window.location.port || 3010;
            const response = await fetch(`http://${host}:${port}/api/rooms`);
            if (!response.ok) {
                throw new Error('Failed to fetch rooms');
            }
            let rooms = await response.json();

            // Check if user is authenticated
            const isAuthenticated = window.mastodonAuth?.isAuthenticated() || false;
            const currentUser = window.mastodonAuth?.getUser();

            // Filter rooms based on authentication state
            if (!isAuthenticated) {
                // Guests can only see rooms that are:
                // 1. Marked as public/visible to visitors
                // 2. Default rooms (always visible)
                rooms = rooms.filter(room =>
                    room.visibility === 'public' ||
                    room.visibleToGuests === true ||
                    room.isDefault === true
                );
            }

            // Calculate how many rooms are hidden from guests
            const totalServerRooms = rooms.length; // This is already filtered
            let hiddenCount = 0;

            if (!isAuthenticated) {
                // Show up to 5 rooms for guests, prompt to login for more
                const guestRoomLimit = 5;
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
                            <span class="category-icon">${categoryData.icon}</span>
                            <h4 class="category-title">${category}</h4>
                            <span class="category-count">${categoryData.rooms.length}</span>
                        </div>
                        <div class="category-rooms">
                            ${categoryData.rooms.map(room => this.renderRoomItem(room, true)).join('')}
                        </div>
                    </div>
                `;
            }

            html += '</div>';
        }

        // Render user-created rooms
        if (groupedRooms.user.length > 0) {
            html += `
                <div class="user-rooms-section">
                    <div class="section-header">
                        <h4>👥 User Created Rooms</h4>
                        <span class="section-count">${groupedRooms.user.length}</span>
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
            users: room.users || 0,
            maxUsers: room.maxUsers,
            hasPassword: room.hasPassword || !!room.password,
            template: room.template || null,
            privacyLevel: room.privacyLevel || 'public',
            encrypted: room.encrypted || false
        };

        const statusIcons = this.getRoomStatusIcons(roomData);
        const tags = isDefault && room.template?.tags ?
            room.template.tags.slice(0, 3).map(tag => `<span class="room-tag">${tag}</span>`).join('') : '';

        return `
            <div class="room-item ${isDefault ? 'default-room' : 'user-room'}"
                 data-room-id="${roomData.id}"
                 onclick="app.quickJoinRoom('${roomData.id}')">
                <div class="room-header">
                    <div class="room-info">
                        <h5 class="room-name">${roomData.name}</h5>
                        ${room.description ? `<p class="room-description">${room.description}</p>` : ''}
                    </div>
                    <div class="room-status">
                        ${statusIcons}
                    </div>
                </div>
                <div class="room-details">
                    <div class="room-stats">
                        <span class="user-count">👥 ${roomData.users}/${roomData.maxUsers}</span>
                        ${roomData.hasPassword ? '<span class="password-protected">🔒 Protected</span>' : ''}
                        ${this.getRoomDurationDisplay(room)}
                    </div>
                    ${tags ? `<div class="room-tags">${tags}</div>` : ''}
                </div>
            </div>
        `;
    }

    getRoomStatusIcons(roomData) {
        let icons = [];

        // Privacy level icon
        const privacyIcons = {
            'public': '🌐',
            'unlisted': '🔗',
            'private': '👥',
            'encrypted': '🔐',
            'secure': '🛡️'
        };
        icons.push(privacyIcons[roomData.privacyLevel] || '🌐');

        // Encryption status
        if (roomData.encrypted) {
            icons.push('🔒');
        }

        return icons.join(' ');
    }

    getRoomDurationDisplay(room) {
        if (!room.duration) {
            return '<span class="room-duration">♾️ Permanent</span>';
        }

        const hours = Math.floor(room.duration / 3600000);
        const minutes = Math.floor((room.duration % 3600000) / 60000);

        let durationText = '';
        if (hours > 0) {
            durationText = `${hours}h${minutes > 0 ? ` ${minutes}m` : ''}`;
        } else {
            durationText = `${minutes}m`;
        }

        return `<span class="room-duration">⏱️ ${durationText}</span>`;
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

            const host = this.socket?.io?.opts?.hostname || window.location.hostname || 'localhost';
            const port = this.socket?.io?.opts?.port || window.location.port || 3010;

            const response = await fetch('http://' + host + ':' + port + '/api/rooms', {
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
                    creatorHandle: window.mastodonAuth?.getUser()?.fullHandle || null
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
        document.getElementById('join-room-id').value = roomId;
        document.getElementById('user-name').value = `User_${Date.now().toString().slice(-4)}`;
        this.showScreen('join-room-screen');
    }

    handleJoinedRoom(room, user) {
        this.currentRoom = room;
        this.currentUser = user;

        // Update UI
        document.getElementById('current-room-name').textContent = room.name;
        document.getElementById('room-id-display').textContent = `Room ID: ${room.id}`;

        // Add existing users
        room.users.forEach(existingUser => {
            if (existingUser.id !== user.id) {
                this.users.set(existingUser.id, existingUser);
                this.addUserToUI(existingUser);
            }
        });

        this.updateUserCount();
        this.showScreen('voice-chat-screen');

        console.log('Successfully joined room:', room.name);
    }

    handleUserJoined(user) {
        this.users.set(user.id, user);
        this.addUserToUI(user);
        this.updateUserCount();

        this.addSystemMessage(`${user.name} joined the room`);
    }

    handleUserLeft(userId) {
        const user = this.users.get(userId);
        if (user) {
            this.users.delete(userId);
            this.removeUserFromUI(userId);
            this.updateUserCount();

            this.addSystemMessage(`${user.name} left the room`);
        }
    }

    addUserToUI(user) {
        const userList = document.getElementById('user-list');
        if (!userList) return;

        const userElement = document.createElement('div');
        userElement.className = 'user-item';
        userElement.setAttribute('data-user-id', user.id);

        userElement.innerHTML = `
            <div class="user-info">
                <div class="user-status connected" title="Connected"></div>
                <span class="user-name">${user.name}</span>
                <span class="audio-indicator" style="display: none;">🔊</span>
            </div>
            <div class="user-controls">
                <button onclick="app.adjustUserVolume('${user.id}', -0.1)" title="Volume Down">🔉</button>
                <button onclick="app.adjustUserVolume('${user.id}', 0.1)" title="Volume Up">🔊</button>
                <button onclick="app.toggleUserMute('${user.id}')" title="Mute User">🔇</button>
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
        if (userCountElement) {
            userCountElement.textContent = this.users.size + 1; // +1 for current user
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

        const messageElement = document.createElement('div');
        messageElement.className = 'chat-message';

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
        if (this.webrtcManager) {
            this.webrtcManager.destroy();
            this.webrtcManager = null;
        }

        if (this.socket) {
            this.socket.disconnect();
            this.socket = null;
        }

        this.currentRoom = null;
        this.currentUser = null;
        this.users.clear();

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
        // This would load settings from localStorage or electron API
        // For now, just set default values
        console.log('Loading current settings...');
    }

    setupSettingsEventListeners() {
        // Save all settings button
        document.getElementById('save-all-settings')?.addEventListener('click', () => {
            this.saveAllSettings();
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
            if (window.electronAPI) {
                window.electronAPI.showQRCode();
            }
        });

        document.getElementById('restart-server-btn')?.addEventListener('click', () => {
            if (window.electronAPI) {
                window.electronAPI.restartServer();
            }
        });
    }

    loadServerInfo() {
        if (window.electronAPI) {
            window.electronAPI.getServerInfo().then(info => {
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
        // Implementation would save to localStorage or electron API
        alert('Settings saved successfully!');
    }

    resetAllSettings() {
        console.log('Resetting all settings...');
        // Implementation would reset to defaults
        alert('Settings reset to defaults!');
    }

    copyServerUrl() {
        if (window.electronAPI) {
            window.electronAPI.copyServerUrl();
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

        // Connect button
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

        // Manual OAuth code submit (for Electron)
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
        }
    }

    showMastodonLoginModal() {
        const modal = document.getElementById('mastodon-login-modal');
        if (modal) {
            modal.style.display = 'flex';
        }
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

            // Check if we're in Electron (need manual code entry)
            const isElectron = typeof process !== 'undefined' && process.versions?.electron;

            if (isElectron) {
                // Open external browser and show code entry field
                if (window.electronAPI?.openExternal) {
                    window.electronAPI.openExternal(authUrl);
                } else {
                    window.open(authUrl, '_blank');
                }

                // Show code entry section
                const codeEntry = document.getElementById('oauth-code-entry');
                if (codeEntry) {
                    codeEntry.style.display = 'block';
                }
            } else {
                // Web flow - redirect to auth page
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

        if (user) {
            // Show logged-in state
            if (loginPrompt) loginPrompt.style.display = 'none';
            if (userInfo) userInfo.style.display = 'flex';

            if (avatar) avatar.src = user.avatar || user.avatarStatic || '';
            if (userName) userName.textContent = user.displayName;
            if (userHandle) userHandle.textContent = user.fullHandle;

            // Show role badge
            if (userRole) {
                if (user.isAdmin) {
                    userRole.textContent = 'Admin';
                    userRole.className = 'user-role admin';
                } else if (user.isModerator) {
                    userRole.textContent = 'Moderator';
                    userRole.className = 'user-role moderator';
                } else {
                    userRole.textContent = 'User';
                    userRole.className = 'user-role user';
                }
            }

            // Update role-based UI
            this.updateRoleBasedUI(user);
        } else {
            // Show logged-out state
            if (loginPrompt) loginPrompt.style.display = 'block';
            if (userInfo) userInfo.style.display = 'none';

            // Hide admin controls
            this.hideAdminControls();
        }
    }

    updateRoleBasedUI(user) {
        const isAdmin = user?.isAdmin === true;
        const isModerator = user?.isModerator === true || isAdmin;

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
        // Add share buttons to rooms if user is authenticated
        if (isAuthenticated) {
            document.querySelectorAll('.room-item').forEach(roomItem => {
                if (!roomItem.querySelector('.share-room-btn')) {
                    const shareBtn = document.createElement('button');
                    shareBtn.className = 'share-room-btn';
                    shareBtn.textContent = 'Share';
                    shareBtn.onclick = (e) => {
                        e.stopPropagation();
                        const roomId = roomItem.dataset.roomId;
                        this.shareRoom(roomId);
                    };
                    roomItem.querySelector('.room-details')?.appendChild(shareBtn);
                }
            });
        }
    }

    async shareRoom(roomId) {
        try {
            const host = this.socket?.io?.opts?.hostname || window.location.hostname || 'localhost';
            const port = this.socket?.io?.opts?.port || window.location.port || 3010;

            const response = await fetch('http://' + host + ':' + port + '/api/share/' + roomId);
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
                const host = this.socket?.io?.opts?.hostname || window.location.hostname || 'localhost';
                const port = this.socket?.io?.opts?.port || window.location.port || 3010;

                const response = await fetch(`http://${host}:${port}/api/embed/token`, {
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
            const host = this.socket?.io?.opts?.hostname || window.location.hostname || 'localhost';
            const port = this.socket?.io?.opts?.port || window.location.port || 3010;

            const response = await fetch('http://' + host + ':' + port + '/api/stats');
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
            const host = this.socket?.io?.opts?.hostname || window.location.hostname || 'localhost';
            const port = this.socket?.io?.opts?.port || window.location.port || 3010;

            const response = await fetch('http://' + host + ':' + port + '/api/rooms');
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
            const host = this.socket?.io?.opts?.hostname || window.location.hostname || 'localhost';
            const port = this.socket?.io?.opts?.port || window.location.port || 3010;

            const response = await fetch('http://' + host + ':' + port + '/api/users');
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
            const host = this.socket?.io?.opts?.hostname || window.location.hostname || 'localhost';
            const port = this.socket?.io?.opts?.port || window.location.port || 3010;

            const response = await fetch('http://' + host + ':' + port + '/api/mastodon/bots');
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
            const host = this.socket?.io?.opts?.hostname || window.location.hostname || 'localhost';
            const port = this.socket?.io?.opts?.port || window.location.port || 3010;

            const response = await fetch('http://' + host + ':' + port + '/api/federation/servers');
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
                const host = this.socket?.io?.opts?.hostname || window.location.hostname || 'localhost';
                const port = this.socket?.io?.opts?.port || window.location.port || 3010;

                await fetch('http://' + host + ':' + port + '/api/admin/restart', { method: 'POST' });
                this.showNotification('Server restarting...', 'info');
            } catch (error) {
                this.showNotification('Failed to restart server', 'error');
            }
        }
    }

    async adminStopServer() {
        if (confirm('Are you sure you want to stop the server? All users will be disconnected.')) {
            try {
                const host = this.socket?.io?.opts?.hostname || window.location.hostname || 'localhost';
                const port = this.socket?.io?.opts?.port || window.location.port || 3010;

                await fetch('http://' + host + ':' + port + '/api/admin/stop', { method: 'POST' });
                this.showNotification('Server stopping...', 'info');
            } catch (error) {
                this.showNotification('Failed to stop server', 'error');
            }
        }
    }

    async createDefaultRooms() {
        try {
            const host = this.socket?.io?.opts?.hostname || window.location.hostname || 'localhost';
            const port = this.socket?.io?.opts?.port || window.location.port || 3010;

            const response = await fetch('http://' + host + ':' + port + '/api/rooms/generate-defaults', { method: 'POST' });
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
            const host = this.socket?.io?.opts?.hostname || window.location.hostname || 'localhost';
            const port = this.socket?.io?.opts?.port || window.location.port || 3010;

            const response = await fetch('http://' + host + ':' + port + '/api/rooms/cleanup', { method: 'POST' });
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
                const host = this.socket?.io?.opts?.hostname || window.location.hostname || 'localhost';
                const port = this.socket?.io?.opts?.port || window.location.port || 3010;

                await fetch('http://' + host + ':' + port + '/api/rooms/' + roomId, { method: 'DELETE' });
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
            const host = this.socket?.io?.opts?.hostname || window.location.hostname || 'localhost';
            const port = this.socket?.io?.opts?.port || window.location.port || 3010;

            const response = await fetch('http://' + host + ':' + port + '/api/mastodon/bots', {
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
                const host = this.socket?.io?.opts?.hostname || window.location.hostname || 'localhost';
                const port = this.socket?.io?.opts?.port || window.location.port || 3010;

                await fetch('http://' + host + ':' + port + '/api/mastodon/bots/' + instance, { method: 'DELETE' });
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
            const host = this.socket?.io?.opts?.hostname || window.location.hostname || 'localhost';
            const port = this.socket?.io?.opts?.port || window.location.port || 3010;

            const response = await fetch('http://' + host + ':' + port + '/api/mastodon/announce', {
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
            const host = this.socket?.io?.opts?.hostname || window.location.hostname || 'localhost';
            const port = this.socket?.io?.opts?.port || window.location.port || 3010;
            const serverUrl = 'http://' + host + ':' + port;

            const response = await fetch('http://' + host + ':' + port + '/api/mastodon/announce', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({
                    message: 'VoiceLink Server is now online!\n\n' + serverUrl + '\n\n#VoiceLink #VoiceChat #P2P',
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
            const host = this.socket?.io?.opts?.hostname || window.location.hostname || 'localhost';
            const port = this.socket?.io?.opts?.port || window.location.port || 3010;

            await fetch('http://' + host + ':' + port + '/api/admin/broadcast', {
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
                const host = this.socket?.io?.opts?.hostname || window.location.hostname || 'localhost';
                const port = this.socket?.io?.opts?.port || window.location.port || 3010;

                await fetch('http://' + host + ':' + port + '/api/admin/users/' + userId + '/kick', { method: 'POST' });
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
                const host = this.socket?.io?.opts?.hostname || window.location.hostname || 'localhost';
                const port = this.socket?.io?.opts?.port || window.location.port || 3010;

                await fetch('http://' + host + ':' + port + '/api/admin/users/' + userId + '/ban', { method: 'POST' });
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
            const host = this.socket?.io?.opts?.hostname || window.location.hostname || 'localhost';
            const port = this.socket?.io?.opts?.port || window.location.port || 3010;

            const response = await fetch('http://' + host + ':' + port + '/api/federation/connect', {
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
            const host = this.socket?.io?.opts?.hostname || window.location.hostname || 'localhost';
            const port = this.socket?.io?.opts?.port || window.location.port || 3010;

            const settings = {
                maxRooms: document.getElementById('admin-max-rooms')?.value,
                requireAuth: document.getElementById('admin-require-auth')?.checked
            };

            await fetch('http://' + host + ':' + port + '/api/admin/settings', {
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
            const host = this.app.socket?.io?.opts?.hostname || window.location.hostname || 'localhost';
            const port = this.app.socket?.io?.opts?.port || window.location.port || 3010;

            const response = await fetch(`http://${host}:${port}/api/jellyfin/servers`);
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
            const host = this.app.socket?.io?.opts?.hostname || window.location.hostname || 'localhost';
            const port = this.app.socket?.io?.opts?.port || window.location.port || 3010;

            const params = new URLSearchParams({
                serverId: this.currentServer.id
            });
            if (parentId) params.append('parentId', parentId);

            const response = await fetch(`http://${host}:${port}/api/jellyfin/library?${params}`);
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
            const host = this.app.socket?.io?.opts?.hostname || window.location.hostname || 'localhost';
            const port = this.app.socket?.io?.opts?.port || window.location.port || 3010;

            const params = new URLSearchParams({
                serverId: this.currentServer.id,
                query: query
            });

            const response = await fetch(`http://${host}:${port}/api/jellyfin/search?${params}`);
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
            const host = this.app.socket?.io?.opts?.hostname || window.location.hostname || 'localhost';
            const port = this.app.socket?.io?.opts?.port || window.location.port || 3010;

            const response = await fetch(`http://${host}:${port}/api/jellyfin/stream-url`, {
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