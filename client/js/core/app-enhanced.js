/**
 * Enhanced VoiceLink Local Application
 * Main application controller with improved port detection
 */

class VoiceLinkApp {
    constructor() {
        this.socket = null;
        this.audioEngine = null;
        this.spatialAudio = null;
        this.webrtcManager = null;
        this.portDetector = null;

        this.currentRoom = null;
        this.currentUser = null;
        this.users = new Map();

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
     * Get API base URL for making HTTP requests
     * Enhanced with auto-port detection
     */
    getApiBaseUrl() {
        const protocol = window.location.protocol;
        const host = this.socket?.io?.opts?.hostname || window.location.hostname || 'localhost';
        const socketPort = this.socket?.io?.opts?.port;
        const locationPort = window.location.port;
        
        // Use detected port if available from port detector
        if (this.portDetector && this.portDetector.currentPort) {
            return `${protocol}//${host}:${this.portDetector.currentPort}`;
        }
        
        // If we have a socket port (direct connection), use it
        if (socketPort && socketPort !== 80 && socketPort !== 443) {
            return `${protocol}//${host}:${socketPort}`;
        } 
        
        // If we have a location port (non-standard port), use it
        if (locationPort && locationPort !== 80 && locationPort !== 443) {
            return `${protocol}//${host}:${locationPort}`;
        }
        
        // Standard port (80/443), no port needed in URL
        return `${protocol}//${host}`;
    }

    async init() {
        console.log('🚀 Initializing VoiceLink Local with Enhanced Port Detection...');

        // Load port detector if available
        if (typeof VoiceLinkPortDetector !== 'undefined') {
            this.portDetector = new VoiceLinkPortDetector();
        }

        // IMMEDIATE: Hide platform-specific elements based on environment
        const isElectronApp = !!(window.electronAPI || window.nodeAPI?.versions?.electron || navigator.userAgent.toLowerCase().includes('electron'));
        console.log('Platform check:', { isElectronApp, hasElectronAPI: !!window.electronAPI });

        if (isElectronApp) {
            document.getElementById('login-benefits')?.remove();
            document.getElementById('download-app-section')?.remove();
            document.querySelectorAll('.web-only').forEach(el => el.remove());
            document.querySelectorAll('.web-label').forEach(el => el.style.display = 'none');
            document.querySelectorAll('.desktop-label').forEach(el => el.style.display = 'inline');
            console.log('Desktop mode: removed web-only elements');
        } else {
            document.getElementById('copy-local-url-btn')?.remove();
            document.getElementById('copy-localhost-url-btn')?.remove();
            document.getElementById('refresh-network-btn')?.remove();
            document.querySelectorAll('.desktop-only').forEach(el => el.remove());
            document.querySelector('.network-interface-section')?.remove();
            console.log('Web mode: removed desktop-only elements');

            const isAuthenticated = localStorage.getItem('mastodon_access_token') || sessionStorage.getItem('mastodon_access_token');
            if (!isAuthenticated) {
                document.querySelectorAll('.auth-required').forEach(el => {
                    el.style.display = 'none';
                    el.dataset.hiddenForAuth = 'true';
                });
                console.log('Web guest mode: hidden auth-required elements');

                window.addEventListener('mastodon-login', () => {
                    document.querySelectorAll('[data-hidden-for-auth="true"]').forEach(el => {
                        el.style.display = '';
                        delete el.dataset.hiddenForAuth;
                    });
                });
            }
        }

        // Initialize connection with enhanced port detection
        await this.initializeConnection();
        this.setupEventListeners();
        this.showScreen('main-menu');
        console.log('✅ VoiceLink initialization complete');
    }

    async initializeConnection() {
        try {
            this.showLoadingScreen('🔍 Detecting VoiceLink Server...');
            
            let socket;
            if (this.portDetector && typeof enhancedConnectToServer !== 'undefined') {
                // Use enhanced port detection
                const connection = await enhancedConnectToServer();
                socket = connection.socket;
                this.portDetector = connection.detector;
                console.log('✅ Enhanced connection established');
            } else {
                // Fallback to original connection method
                socket = await this.fallbackConnection();
            }

            this.socket = socket;
            this.setupSocketEventHandlers();
            
            // Hide loading screen once connected
            setTimeout(() => {
                this.hideLoadingScreen();
            }, 1000);
            
        } catch (error) {
            console.error('❌ Connection failed:', error);
            this.showConnectionError(error);
        }
    }

    async fallbackConnection() {
        const pagePort = window.location.port;
        const host = window.location.hostname || 'localhost';
        
        const portSequence = pagePort ? [parseInt(pagePort), 3010, 4004, 4005, 4006] : [3010, 4004, 4005, 4006, 3000, 3001];
        
        return new Promise((resolve, reject) => {
            let currentPortIndex = 0;
            
            const tryConnect = (port) => {
                console.log(`🔍 Trying to connect to port ${port}...`);
                const url = `http://${host}:${port}`;
                
                const socket = io(url, {
                    transports: ['websocket', 'polling']
                });

                const timeout = setTimeout(() => {
                    socket.disconnect();
                    currentPortIndex++;
                    
                    if (currentPortIndex < portSequence.length) {
                        console.log(`Port ${port} failed, trying port ${portSequence[currentPortIndex]}...`);
                        tryConnect(portSequence[currentPortIndex]);
                    } else {
                        reject(new Error('Failed to connect to VoiceLink server on all ports'));
                    }
                }, 3000);

                socket.on('connect', () => {
                    clearTimeout(timeout);
                    console.log(`✅ Connected to VoiceLink server on port ${port}`);
                    resolve(socket);
                });

                socket.on('connect_error', () => {
                    // Connection will timeout and try next port
                });
            };

            // Start with first port in sequence
            tryConnect(portSequence[0]);
        });
    }

    setupSocketEventHandlers() {
        if (!this.socket) return;

        this.socket.on('server-info', (info) => {
            console.log('📊 Server info received:', info);
            this.updateServerInfoDisplay(info);
        });

        this.socket.on('connect_error', (error) => {
            console.error('❌ Socket connection error:', error);
            this.showConnectionError(error);
        });

        this.socket.on('disconnect', () => {
            console.log('🔌 Disconnected from server');
            this.handleDisconnect();
        });

        // Original event handlers (keep existing functionality)
        this.socket.on('room-joined', (data) => {
            this.handleRoomJoined(data);
        });

        this.socket.on('user-joined', (data) => {
            this.handleUserJoined(data);
        });

        this.socket.on('user-left', (data) => {
            this.handleUserLeft(data);
        });

        this.socket.on('voice-data', (data) => {
            this.handleVoiceData(data);
        });
    }

    updateServerInfoDisplay(info) {
        const portElement = document.getElementById('server-port-value');
        const urlElement = document.getElementById('server-url-value');
        
        if (portElement) {
            portElement.textContent = info.port || '--';
        }
        
        if (urlElement) {
            urlElement.textContent = info.url || 'Unknown';
        }
    }

    showLoadingScreen(message = 'Loading...') {
        const loadingScreen = document.getElementById('loading-screen');
        const loadingText = document.getElementById('loading-text');
        
        if (loadingText) {
            loadingText.textContent = message;
        }
        
        if (loadingScreen) {
            loadingScreen.style.display = 'flex';
        }
    }

    hideLoadingScreen() {
        const loadingScreen = document.getElementById('loading-screen');
        if (loadingScreen) {
            loadingScreen.style.display = 'none';
        }
    }

    showConnectionError(error) {
        this.hideLoadingScreen();
        this.showScreen('connection-error-screen');
        
        const errorElement = document.getElementById('connection-error-message');
        if (errorElement) {
            errorElement.textContent = `Failed to connect to VoiceLink server: ${error.message}`;
        }
        
        const retryButton = document.getElementById('retry-connection-btn');
        if (retryButton) {
            retryButton.onclick = () => {
                this.initializeConnection();
            };
        }
    }

    handleDisconnect() {
        // Show reconnection UI
        const disconnectedUI = document.getElementById('disconnected-ui');
        if (disconnectedUI) {
            disconnectedUI.style.display = 'block';
        }
        
        // Attempt to reconnect after 3 seconds
        setTimeout(() => {
            this.initializeConnection();
        }, 3000);
    }

    showScreen(screenId) {
        // Hide all screens
        this.ui.screens.forEach(screenId => {
            const screen = document.getElementById(screenId);
            if (screen) {
                screen.style.display = 'none';
            }
        });
        
        // Show target screen
        const targetScreen = document.getElementById(screenId);
        if (targetScreen) {
            targetScreen.style.display = 'block';
            this.ui.currentScreen = screenId;
        }
    }

    setupEventListeners() {
        // Connection refresh button
        const refreshBtn = document.getElementById('refresh-network-btn');
        if (refreshBtn) {
            refreshBtn.addEventListener('click', () => {
                console.log('🔄 Refreshing connection...');
                this.initializeConnection();
            });
        }

        // Server info display
        this.updateServerStatus();
        setInterval(() => {
            this.updateServerStatus();
        }, 30000); // Update every 30 seconds
    }

    async updateServerStatus() {
        if (!this.portDetector) return;

        try {
            const response = await fetch(`${this.getApiBaseUrl()}/api/status`);
            if (response.ok) {
                const status = await response.json();
                this.updateServerInfoDisplay({
                    port: status.port,
                    url: status.url
                });
            }
        } catch (error) {
            console.log('Status update failed:', error);
        }
    }

    // Original methods (keep existing functionality)
    handleRoomJoined(data) {
        this.currentRoom = data.roomId;
        this.currentUser = data.user;
        this.showScreen('voice-chat-screen');
        console.log('🏠 Joined room:', data);
    }

    handleUserJoined(data) {
        console.log('👋 User joined:', data);
        // Update UI with new user
    }

    handleUserLeft(data) {
        console.log('👋 User left:', data);
        // Update UI to remove user
    }

    handleVoiceData(data) {
        // Handle voice data for playback
        console.log('🎤 Voice data received:', data);
    }
}

// Initialize app when DOM is ready
document.addEventListener('DOMContentLoaded', () => {
    window.voiceLinkApp = new VoiceLinkApp();
});

// Export for testing
if (typeof module !== 'undefined' && module.exports) {
    module.exports = VoiceLinkApp;
}