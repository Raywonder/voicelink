/**
 * Enhanced Port Detection for VoiceLink Client
 * Improved auto-port detection and server connection logic
 */

class VoiceLinkPortDetector {
    constructor() {
        this.portSequence = [3010, 3001, 3002, 3003, 3004, 3005, 4000, 4001, 4002, 4003, 4004, 4005, 8080, 8081];
        this.currentPortIndex = 0;
        this.connectionTimeout = 3000;
        this.maxRetries = 2;
        this.onPortFound = null;
        this.onConnectionFailed = null;
    }

    async detectServerPort(host = 'localhost') {
        console.log('🔍 Starting auto-port detection...');
        
        // First, try to get current port from server status
        try {
            const status = await this.getServerStatus(host);
            if (status && status.port) {
                console.log(`✅ Server running on detected port: ${status.port}`);
                return status.port;
            }
        } catch (error) {
            console.log('⚠️ Server status check failed, trying port sequence...');
        }

        // Fall back to port sequence detection
        for (let i = 0; i < this.portSequence.length; i++) {
            const port = this.portSequence[i];
            console.log(`🔍 Trying port ${port}...`);
            
            if (await this.testPort(host, port)) {
                console.log(`✅ Found server on port ${port}`);
                return port;
            }
        }
        
        throw new Error('❌ No VoiceLink server found on any port!');
    }

    async getServerStatus(host) {
        const ports = [3010, 3001, 4004, 4005];
        
        for (const port of ports) {
            try {
                const response = await fetch(`http://${host}:${port}/api/status`, {
                    method: 'GET',
                    timeout: 2000
                });
                
                if (response.ok) {
                    return await response.json();
                }
            } catch (error) {
                // Port not available, try next
            }
        }
        
        return null;
    }

    async testPort(host, port) {
        return new Promise((resolve) => {
            const timeout = setTimeout(() => {
                resolve(false);
            }, this.connectionTimeout);

            fetch(`http://${host}:${port}/api/server-info`, {
                method: 'GET',
                timeout: this.connectionTimeout
            })
            .then(response => {
                clearTimeout(timeout);
                resolve(response.ok);
            })
            .catch(() => {
                clearTimeout(timeout);
                resolve(false);
            });
        });
    }

    async createConnection(host, port) {
        const url = `http://${host}:${port}`;
        console.log(`🔌 Connecting to: ${url}`);
        
        return new Promise((resolve, reject) => {
            const timeout = setTimeout(() => {
                reject(new Error('Connection timeout'));
            }, this.connectionTimeout);

            const socket = io(url, {
                timeout: this.connectionTimeout,
                transports: ['websocket', 'polling'],
                forceNew: true
            });

            socket.on('connect', () => {
                clearTimeout(timeout);
                console.log(`✅ Connected to VoiceLink server on port ${port}`);
                resolve(socket);
            });

            socket.on('connect_error', (error) => {
                clearTimeout(timeout);
                reject(error);
            });

            // Enhanced server info handling
            socket.on('server-info', (info) => {
                console.log('📊 Server info:', info);
                this.currentPort = info.port;
                this.serverUrl = info.url;
                
                if (this.onPortFound) {
                    this.onPortFound(info);
                }
            });
        });
    }
}

/**
 * Enhanced getApiBaseUrl method
 */
const enhancedGetApiBaseUrl = (socket, window) => {
    const protocol = window.location.protocol;
    const host = socket?.io?.opts?.hostname || window.location.hostname || 'localhost';
    const socketPort = socket?.io?.opts?.port;
    const locationPort = window.location.port;
    const detector = new VoiceLinkPortDetector();
    
    // Use detected port if available
    if (detector.currentPort) {
        return `${protocol}//${host}:${detector.currentPort}`;
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
};

/**
 * Enhanced connection method
 */
const enhancedConnectToServer = async (host = 'localhost') => {
    const detector = new VoiceLinkPortDetector();
    
    try {
        const port = await detector.detectServerPort(host);
        const socket = await detector.createConnection(host, port);
        
        return {
            socket,
            port,
            url: `http://${host}:${port}`,
            detector
        };
    } catch (error) {
        console.error('❌ Failed to connect to VoiceLink server:', error.message);
        throw error;
    }
};

// Export for use in main app
if (typeof module !== 'undefined' && module.exports) {
    module.exports = {
        VoiceLinkPortDetector,
        enhancedGetApiBaseUrl,
        enhancedConnectToServer
    };
}

// Also expose globally for browser use
if (typeof window !== 'undefined') {
    window.VoiceLinkPortDetector = VoiceLinkPortDetector;
    window.enhancedGetApiBaseUrl = enhancedGetApiBaseUrl;
    window.enhancedConnectToServer = enhancedConnectToServer;
}