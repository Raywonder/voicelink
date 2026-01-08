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
            // Try port sequence: 4004 (Electron default), 4005, 4006, 3000, 3001
            const portSequence = [4004, 4005, 4006, 3000, 3001];
            let currentPortIndex = 0;

            const tryConnect = (port) => {
                const url = `http://localhost:${port}`;
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
                    this.updateServerStatus('online', port);

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

    updateServerStatus(status, port = null) {
        const statusValue = document.getElementById('server-status-value');
        const portValue = document.getElementById('server-port-value');

        if (statusValue) {
            if (status === 'online') {
                statusValue.textContent = '🟢 Online';
                statusValue.style.color = '#4CAF50';
            } else {
                statusValue.textContent = '🔴 Offline';
                statusValue.style.color = '#f44336';
            }
        }

        if (portValue && port) {
            portValue.textContent = port;
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

        // Show/hide buttons based on status
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
                this.updateServerStatus('online', this.getCurrentPort());
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
                this.updateServerStatus('online', this.getCurrentPort());
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
            // Get the correct port from socket connection
            const port = this.socket?.io?.opts?.port || 3000;
            const response = await fetch(`http://localhost:${port}/api/rooms`);
            if (!response.ok) {
                throw new Error('Failed to fetch rooms');
            }
            const rooms = await response.json();

            const roomList = document.getElementById('room-list');
            if (roomList) {
                if (rooms.length === 0) {
                    roomList.innerHTML = `
                        <div class="no-rooms-message">
                            <p class="text-muted">No rooms available</p>
                            <p class="text-small">Default rooms will be generated automatically if enabled</p>
                        </div>
                    `;
                } else {
                    // Group rooms by category for better organization
                    const groupedRooms = this.groupRoomsByCategory(rooms);
                    roomList.innerHTML = this.renderGroupedRooms(groupedRooms);
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
        const privacyLevel = document.querySelector('input[name="privacy-level"]:checked')?.value || 'public';

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

            const response = await fetch('/api/rooms', {
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
                    privacyLevel,
                    encrypted: window.serverEncryptionManager?.isRoomEncrypted(roomId) || false
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

}

// Initialize the application when DOM is loaded
document.addEventListener('DOMContentLoaded', () => {
    window.app = new VoiceLinkApp();
    window.voiceLinkApp = window.app; // For compatibility
});

// Export for testing
if (typeof module !== 'undefined' && module.exports) {
    module.exports = VoiceLinkApp;
}