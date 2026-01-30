/**
 * VoiceLink Server Access Manager
 * Public/Private server connections with multiple access methods
 */

class ServerAccessManager {
    constructor() {
        this.connectedServers = new Map(); // serverId -> ServerConnection
        this.serverList = new Map(); // serverId -> ServerInfo
        this.currentConnection = null;
        this.accessMethods = new Map(); // methodId -> AccessMethod

        // Access control
        this.userCredentials = new Map(); // serverId -> credentials
        this.serverPermissions = new Map(); // serverId -> permissions
        this.inviteTokens = new Map(); // token -> serverInfo

        // Connection types
        this.connectionTypes = {
            LOCAL: 'local',
            DIRECT_IP: 'direct_ip',
            DOMAIN: 'domain',
            INVITE_LINK: 'invite_link',
            QR_CODE: 'qr_code',
            SERVER_BROWSER: 'server_browser',
            VPN_TUNNEL: 'vpn_tunnel',
            PROXY: 'proxy'
        };

        this.init();
    }

    async init() {
        console.log('Initializing Server Access Manager...');

        // Initialize access methods
        this.initializeAccessMethods();

        // Load saved servers
        await this.loadSavedServers();

        // Setup server discovery
        this.setupServerDiscovery();

        console.log('Server Access Manager initialized');
    }

    initializeAccessMethods() {
        // Direct IP/Port Connection
        this.accessMethods.set('direct_ip', {
            name: 'Direct IP Connection',
            description: 'Connect directly using IP address and port',
            requiresAuth: false,
            fields: [
                { name: 'ip', label: 'IP Address', type: 'text', required: true },
                { name: 'port', label: 'Port', type: 'number', required: true, default: 3001 },
                { name: 'password', label: 'Password', type: 'password', required: false }
            ],
            connect: this.connectDirectIP.bind(this)
        });

        // Domain Name Connection
        this.accessMethods.set('domain', {
            name: 'Domain Connection',
            description: 'Connect using domain name',
            requiresAuth: false,
            fields: [
                { name: 'domain', label: 'Domain/Hostname', type: 'text', required: true },
                { name: 'port', label: 'Port', type: 'number', required: false, default: 443 },
                { name: 'ssl', label: 'Use SSL/TLS', type: 'checkbox', default: true },
                { name: 'password', label: 'Password', type: 'password', required: false }
            ],
            connect: this.connectDomain.bind(this)
        });

        // Invite Link Connection
        this.accessMethods.set('invite_link', {
            name: 'Invite Link',
            description: 'Connect using an invite link',
            requiresAuth: false,
            fields: [
                { name: 'inviteUrl', label: 'Invite Link', type: 'url', required: true }
            ],
            connect: this.connectInviteLink.bind(this)
        });

        // QR Code Connection
        this.accessMethods.set('qr_code', {
            name: 'QR Code',
            description: 'Scan QR code to connect',
            requiresAuth: false,
            fields: [],
            connect: this.connectQRCode.bind(this),
            requiresCamera: true
        });

        // Server Browser
        this.accessMethods.set('server_browser', {
            name: 'Server Browser',
            description: 'Browse public servers',
            requiresAuth: false,
            fields: [
                { name: 'region', label: 'Region', type: 'select', options: ['Global', 'North America', 'Europe', 'Asia', 'Oceania'] },
                { name: 'gameMode', label: 'Category', type: 'select', options: ['All', 'Gaming', 'Music', 'Business', 'Education', 'Social'] }
            ],
            connect: this.browseServers.bind(this)
        });

        // VPN Tunnel Connection
        this.accessMethods.set('vpn_tunnel', {
            name: 'VPN Tunnel',
            description: 'Connect through VPN tunnel (Headscale/Tailscale)',
            requiresAuth: true,
            fields: [
                { name: 'vpnType', label: 'VPN Type', type: 'select', options: ['Tailscale', 'Headscale', 'WireGuard', 'OpenVPN'] },
                { name: 'networkId', label: 'Network ID', type: 'text', required: true },
                { name: 'nodeId', label: 'Node ID', type: 'text', required: true },
                { name: 'authKey', label: 'Auth Key', type: 'password', required: true }
            ],
            connect: this.connectVPNTunnel.bind(this)
        });

        // Proxy Connection
        this.accessMethods.set('proxy', {
            name: 'Proxy Connection',
            description: 'Connect through SOCKS/HTTP proxy',
            requiresAuth: false,
            fields: [
                { name: 'proxyType', label: 'Proxy Type', type: 'select', options: ['SOCKS5', 'SOCKS4', 'HTTP', 'HTTPS'] },
                { name: 'proxyHost', label: 'Proxy Host', type: 'text', required: true },
                { name: 'proxyPort', label: 'Proxy Port', type: 'number', required: true },
                { name: 'proxyAuth', label: 'Proxy Authentication', type: 'checkbox' },
                { name: 'proxyUser', label: 'Proxy Username', type: 'text', conditional: 'proxyAuth' },
                { name: 'proxyPass', label: 'Proxy Password', type: 'password', conditional: 'proxyAuth' },
                { name: 'targetHost', label: 'Target Server', type: 'text', required: true },
                { name: 'targetPort', label: 'Target Port', type: 'number', required: true }
            ],
            connect: this.connectProxy.bind(this)
        });

        // Local Network Discovery
        this.accessMethods.set('local_discovery', {
            name: 'Local Network',
            description: 'Discover servers on local network',
            requiresAuth: false,
            fields: [],
            connect: this.discoverLocalServers.bind(this),
            autoDiscover: true
        });
    }

    // Connection Methods Implementation

    async connectDirectIP(connectionData) {
        const { ip, port, password } = connectionData;

        try {
            const serverInfo = {
                id: `${ip}:${port}`,
                name: `Direct Connection (${ip}:${port})`,
                host: ip,
                port: parseInt(port),
                type: 'direct',
                isPublic: false,
                requiresPassword: !!password,
                lastConnected: Date.now()
            };

            const connection = await this.establishConnection(serverInfo, { password });
            return this.handleSuccessfulConnection(serverInfo, connection);

        } catch (error) {
            throw new Error(`Failed to connect to ${ip}:${port} - ${error.message}`);
        }
    }

    async connectDomain(connectionData) {
        const { domain, port = 443, ssl = true, password } = connectionData;

        try {
            // Resolve domain first
            const resolvedIP = await this.resolveDomain(domain);

            const serverInfo = {
                id: `${domain}:${port}`,
                name: `Domain Connection (${domain})`,
                host: domain,
                resolvedIP,
                port: parseInt(port),
                ssl,
                type: 'domain',
                isPublic: true,
                requiresPassword: !!password,
                lastConnected: Date.now()
            };

            const connection = await this.establishConnection(serverInfo, { password, ssl });
            return this.handleSuccessfulConnection(serverInfo, connection);

        } catch (error) {
            throw new Error(`Failed to connect to ${domain} - ${error.message}`);
        }
    }

    async connectInviteLink(connectionData) {
        const { inviteUrl } = connectionData;

        try {
            // Parse invite link
            const inviteData = await this.parseInviteLink(inviteUrl);

            const serverInfo = {
                id: inviteData.serverId,
                name: inviteData.serverName,
                host: inviteData.host,
                port: inviteData.port,
                type: 'invite',
                isPublic: inviteData.isPublic,
                inviteToken: inviteData.token,
                inviteExpires: inviteData.expires,
                lastConnected: Date.now()
            };

            const connection = await this.establishConnection(serverInfo, {
                inviteToken: inviteData.token
            });

            return this.handleSuccessfulConnection(serverInfo, connection);

        } catch (error) {
            throw new Error(`Invalid invite link - ${error.message}`);
        }
    }

    async connectQRCode() {
        try {
            // Start QR code scanner
            const qrData = await this.scanQRCode();

            // Parse QR code data
            const connectionData = JSON.parse(qrData);

            // Use appropriate connection method based on QR data
            switch (connectionData.type) {
                case 'invite':
                    return this.connectInviteLink({ inviteUrl: connectionData.url });
                case 'direct':
                    return this.connectDirectIP(connectionData);
                case 'domain':
                    return this.connectDomain(connectionData);
                default:
                    throw new Error('Unknown QR code connection type');
            }

        } catch (error) {
            throw new Error(`QR code connection failed - ${error.message}`);
        }
    }

    async browseServers(filterData) {
        const { region = 'Global', gameMode = 'All' } = filterData;

        try {
            // Fetch public server list
            const servers = await this.fetchPublicServers(region, gameMode);

            // Show server browser UI
            this.showServerBrowser(servers);

            return {
                type: 'browser',
                servers,
                region,
                category: gameMode
            };

        } catch (error) {
            throw new Error(`Failed to browse servers - ${error.message}`);
        }
    }

    async connectVPNTunnel(connectionData) {
        const { vpnType, networkId, nodeId, authKey } = connectionData;

        try {
            // Authenticate with VPN network
            const vpnAuth = await this.authenticateVPN(vpnType, networkId, authKey);

            // Get node information
            const nodeInfo = await this.getVPNNodeInfo(vpnType, networkId, nodeId);

            const serverInfo = {
                id: `${vpnType}_${networkId}_${nodeId}`,
                name: `${vpnType} Node (${nodeId})`,
                host: nodeInfo.ip,
                port: nodeInfo.port || 3001,
                type: 'vpn',
                vpnType,
                networkId,
                nodeId,
                isPublic: false,
                isSecure: true,
                lastConnected: Date.now()
            };

            const connection = await this.establishConnection(serverInfo, {
                vpnAuth,
                encrypted: true
            });

            return this.handleSuccessfulConnection(serverInfo, connection);

        } catch (error) {
            throw new Error(`VPN connection failed - ${error.message}`);
        }
    }

    async connectProxy(connectionData) {
        const {
            proxyType, proxyHost, proxyPort, proxyAuth,
            proxyUser, proxyPass, targetHost, targetPort
        } = connectionData;

        try {
            // Setup proxy configuration
            const proxyConfig = {
                type: proxyType.toLowerCase(),
                host: proxyHost,
                port: parseInt(proxyPort),
                auth: proxyAuth ? { username: proxyUser, password: proxyPass } : null
            };

            const serverInfo = {
                id: `proxy_${targetHost}:${targetPort}`,
                name: `Proxy Connection (${targetHost}:${targetPort})`,
                host: targetHost,
                port: parseInt(targetPort),
                type: 'proxy',
                proxy: proxyConfig,
                isPublic: false,
                lastConnected: Date.now()
            };

            const connection = await this.establishConnection(serverInfo, {
                proxy: proxyConfig
            });

            return this.handleSuccessfulConnection(serverInfo, connection);

        } catch (error) {
            throw new Error(`Proxy connection failed - ${error.message}`);
        }
    }

    async discoverLocalServers() {
        try {
            console.log('Discovering local VoiceLink servers...');

            const localServers = [];
            const localNetworks = await this.getLocalNetworkRanges();

            // Scan common ports on local networks
            const commonPorts = [3001, 3002, 3003, 8080, 8443];

            for (const network of localNetworks) {
                for (const port of commonPorts) {
                    const servers = await this.scanNetworkForServers(network, port);
                    localServers.push(...servers);
                }
            }

            // Also check mDNS/Bonjour for advertised services
            const mdnsServers = await this.discoverMDNSServices();
            localServers.push(...mdnsServers);

            return {
                type: 'local_discovery',
                servers: localServers,
                discovered: localServers.length
            };

        } catch (error) {
            throw new Error(`Local discovery failed - ${error.message}`);
        }
    }

    // Server Connection Management

    async establishConnection(serverInfo, connectionOptions = {}) {
        console.log(`Establishing connection to ${serverInfo.name}...`);

        let socket;

        try {
            // Build connection URL
            const connectionUrl = this.buildConnectionUrl(serverInfo, connectionOptions);

            // Setup socket connection
            const socketOptions = {
                timeout: 10000,
                forceNew: true,
                ...this.getSocketOptions(serverInfo, connectionOptions)
            };

            socket = io(connectionUrl, socketOptions);

            // Setup connection handlers
            const connection = await this.setupConnectionHandlers(socket, serverInfo);

            // Authenticate if required
            if (serverInfo.requiresPassword || connectionOptions.inviteToken) {
                await this.authenticateConnection(connection, connectionOptions);
            }

            // Store connection
            this.connectedServers.set(serverInfo.id, connection);

            return connection;

        } catch (error) {
            if (socket) {
                socket.disconnect();
            }
            throw error;
        }
    }

    buildConnectionUrl(serverInfo, options) {
        let protocol = 'http://';

        if (options.ssl || serverInfo.ssl || serverInfo.port === 443) {
            protocol = 'https://';
        }

        if (options.proxy) {
            // For proxy connections, we'd need to handle this differently
            // This is a simplified example
            return `${protocol}${options.proxy.host}:${options.proxy.port}`;
        }

        return `${protocol}${serverInfo.host}:${serverInfo.port}`;
    }

    getSocketOptions(serverInfo, options) {
        const socketOptions = {};

        // Proxy configuration
        if (options.proxy) {
            socketOptions.agent = this.createProxyAgent(options.proxy);
        }

        // VPN configuration
        if (options.vpnAuth) {
            socketOptions.extraHeaders = {
                'X-VPN-Auth': options.vpnAuth.token,
                'X-VPN-Network': serverInfo.networkId
            };
        }

        // SSL configuration
        if (options.ssl && options.ssl.rejectUnauthorized === false) {
            socketOptions.rejectUnauthorized = false;
        }

        return socketOptions;
    }

    async setupConnectionHandlers(socket, serverInfo) {
        return new Promise((resolve, reject) => {
            const connection = {
                socket,
                serverInfo,
                status: 'connecting',
                connectedAt: null,
                lastActivity: Date.now()
            };

            socket.on('connect', () => {
                connection.status = 'connected';
                connection.connectedAt = Date.now();
                console.log(`Connected to ${serverInfo.name}`);
                resolve(connection);
            });

            socket.on('connect_error', (error) => {
                connection.status = 'error';
                console.error(`Connection error to ${serverInfo.name}:`, error);
                reject(new Error(`Connection failed: ${error.message}`));
            });

            socket.on('disconnect', (reason) => {
                connection.status = 'disconnected';
                console.log(`Disconnected from ${serverInfo.name}:`, reason);
                this.handleDisconnection(serverInfo.id, reason);
            });

            // Server-specific event handlers
            this.setupServerEventHandlers(socket, serverInfo);

            // Connection timeout
            setTimeout(() => {
                if (connection.status === 'connecting') {
                    socket.disconnect();
                    reject(new Error('Connection timeout'));
                }
            }, 10000);
        });
    }

    setupServerEventHandlers(socket, serverInfo) {
        // Server information
        socket.on('server_info', (info) => {
            console.log('Received server info:', info);
            serverInfo.name = info.name || serverInfo.name;
            serverInfo.description = info.description;
            serverInfo.version = info.version;
            serverInfo.maxUsers = info.maxUsers;
            serverInfo.currentUsers = info.currentUsers;
            serverInfo.features = info.features;
        });

        // Authentication responses
        socket.on('auth_success', (data) => {
            console.log('Authentication successful');
            serverInfo.authenticated = true;
            serverInfo.userRole = data.role;
            serverInfo.permissions = data.permissions;
        });

        socket.on('auth_failed', (error) => {
            console.error('Authentication failed:', error);
            this.handleAuthenticationError(serverInfo.id, error);
        });

        // Server events
        socket.on('server_message', (message) => {
            this.handleServerMessage(serverInfo.id, message);
        });

        socket.on('user_list', (users) => {
            this.handleUserListUpdate(serverInfo.id, users);
        });

        socket.on('room_list', (rooms) => {
            this.handleRoomListUpdate(serverInfo.id, rooms);
        });
    }

    async authenticateConnection(connection, options) {
        const { socket, serverInfo } = connection;

        return new Promise((resolve, reject) => {
            const authData = {};

            // Password authentication
            if (options.password) {
                authData.password = options.password;
            }

            // Invite token authentication
            if (options.inviteToken) {
                authData.inviteToken = options.inviteToken;
            }

            // VPN authentication
            if (options.vpnAuth) {
                authData.vpnAuth = options.vpnAuth;
            }

            // Send authentication
            socket.emit('authenticate', authData);

            // Handle authentication response
            const authTimeout = setTimeout(() => {
                reject(new Error('Authentication timeout'));
            }, 5000);

            const onAuthSuccess = () => {
                clearTimeout(authTimeout);
                socket.off('auth_failed', onAuthFailed);
                resolve();
            };

            const onAuthFailed = (error) => {
                clearTimeout(authTimeout);
                socket.off('auth_success', onAuthSuccess);
                reject(new Error(`Authentication failed: ${error.message}`));
            };

            socket.once('auth_success', onAuthSuccess);
            socket.once('auth_failed', onAuthFailed);
        });
    }

    handleSuccessfulConnection(serverInfo, connection) {
        // Save server info
        this.serverList.set(serverInfo.id, serverInfo);
        this.saveServerToLocal(serverInfo);

        // Set as current connection
        this.currentConnection = connection;

        // Update UI
        this.updateConnectionStatus(serverInfo, 'connected');

        console.log(`Successfully connected to ${serverInfo.name}`);

        return {
            serverId: serverInfo.id,
            serverName: serverInfo.name,
            connection: connection,
            success: true
        };
    }

    // Server Management Methods

    async getServerList() {
        return Array.from(this.serverList.values());
    }

    async getConnectedServers() {
        return Array.from(this.connectedServers.values());
    }

    async disconnectFromServer(serverId) {
        const connection = this.connectedServers.get(serverId);
        if (connection) {
            connection.socket.disconnect();
            this.connectedServers.delete(serverId);

            if (this.currentConnection && this.currentConnection.serverInfo.id === serverId) {
                this.currentConnection = null;
            }

            console.log(`Disconnected from server: ${serverId}`);
        }
    }

    async switchToServer(serverId) {
        const connection = this.connectedServers.get(serverId);
        if (connection) {
            this.currentConnection = connection;
            console.log(`Switched to server: ${connection.serverInfo.name}`);
            return connection;
        } else {
            throw new Error('Server not connected');
        }
    }

    // Utility Methods

    async resolveDomain(domain) {
        // In a real implementation, this would use DNS resolution
        // For now, return the domain itself
        return domain;
    }

    async parseInviteLink(inviteUrl) {
        try {
            const url = new URL(inviteUrl);
            const token = url.searchParams.get('token');
            const serverId = url.searchParams.get('server');

            if (!token || !serverId) {
                throw new Error('Invalid invite link format');
            }

            // In a real implementation, this would validate the token with a server
            return {
                token,
                serverId,
                serverName: 'Invited Server',
                host: url.hostname,
                port: parseInt(url.port) || 443,
                isPublic: false,
                expires: Date.now() + (24 * 60 * 60 * 1000) // 24 hours
            };

        } catch (error) {
            throw new Error('Invalid invite URL');
        }
    }

    async scanQRCode() {
        // In a real implementation, this would use the camera to scan QR codes
        // For now, return mock data
        return JSON.stringify({
            type: 'direct',
            ip: '192.168.1.100',
            port: 3001
        });
    }

    async fetchPublicServers(region, category) {
        // In a real implementation, this would fetch from a master server list
        // For now, return mock public servers
        return [
            {
                id: 'public_server_1',
                name: 'Global Gaming Hub',
                description: 'Public gaming voice chat server',
                host: 'gaming.voicelink.net',
                port: 443,
                region: 'Global',
                category: 'Gaming',
                users: 45,
                maxUsers: 100,
                ping: 32,
                uptime: '99.5%',
                isPublic: true,
                features: ['3D Audio', 'VST Streaming', 'Screen Share']
            },
            {
                id: 'public_server_2',
                name: 'Music Producers',
                description: 'Professional music collaboration',
                host: 'music.voicelink.net',
                port: 443,
                region: 'North America',
                category: 'Music',
                users: 23,
                maxUsers: 50,
                ping: 18,
                uptime: '99.8%',
                isPublic: true,
                features: ['VST Streaming', '64-Channel Audio', 'Recording']
            }
        ];
    }

    async getLocalNetworkRanges() {
        // Get local network IP ranges for scanning
        return [
            '192.168.1.0/24',
            '192.168.0.0/24',
            '10.0.0.0/24',
            '172.16.0.0/24'
        ];
    }

    async scanNetworkForServers(networkRange, port) {
        // In a real implementation, this would scan the network range
        // For now, return mock local servers
        console.log(`Scanning ${networkRange}:${port} for VoiceLink servers...`);
        return [];
    }

    async discoverMDNSServices() {
        // In a real implementation, this would use mDNS/Bonjour discovery
        return [];
    }

    saveServerToLocal(serverInfo) {
        // Save server to local storage
        const savedServers = JSON.parse(localStorage.getItem('voicelink_servers') || '[]');
        const existingIndex = savedServers.findIndex(s => s.id === serverInfo.id);

        if (existingIndex >= 0) {
            savedServers[existingIndex] = serverInfo;
        } else {
            savedServers.push(serverInfo);
        }

        localStorage.setItem('voicelink_servers', JSON.stringify(savedServers));
    }

    async loadSavedServers() {
        const savedServers = JSON.parse(localStorage.getItem('voicelink_servers') || '[]');
        savedServers.forEach(serverInfo => {
            this.serverList.set(serverInfo.id, serverInfo);
        });

        console.log(`Loaded ${savedServers.length} saved servers`);
    }

    setupServerDiscovery() {
        // Setup background server discovery
        setInterval(() => {
            this.discoverLocalServers();
        }, 30000); // Every 30 seconds
    }

    updateConnectionStatus(serverInfo, status) {
        // Update UI connection status
        const event = new CustomEvent('voicelink-connection-status', {
            detail: { serverId: serverInfo.id, status }
        });
        document.dispatchEvent(event);
    }

    handleDisconnection(serverId, reason) {
        console.log(`Server ${serverId} disconnected: ${reason}`);
        this.connectedServers.delete(serverId);

        if (this.currentConnection && this.currentConnection.serverInfo.id === serverId) {
            this.currentConnection = null;
        }

        // Update UI
        const serverInfo = this.serverList.get(serverId);
        if (serverInfo) {
            this.updateConnectionStatus(serverInfo, 'disconnected');
        }
    }

    handleServerMessage(serverId, message) {
        console.log(`Server message from ${serverId}:`, message);

        // Dispatch server message event
        const event = new CustomEvent('voicelink-server-message', {
            detail: { serverId, message }
        });
        document.dispatchEvent(event);
    }

    handleUserListUpdate(serverId, users) {
        const serverInfo = this.serverList.get(serverId);
        if (serverInfo) {
            serverInfo.currentUsers = users.length;
            serverInfo.userList = users;
        }
    }

    handleRoomListUpdate(serverId, rooms) {
        const serverInfo = this.serverList.get(serverId);
        if (serverInfo) {
            serverInfo.rooms = rooms;
        }
    }

    handleAuthenticationError(serverId, error) {
        console.error(`Authentication error for ${serverId}:`, error);

        // Update UI to show auth error
        const event = new CustomEvent('voicelink-auth-error', {
            detail: { serverId, error }
        });
        document.dispatchEvent(event);
    }

    // Get available access methods
    getAccessMethods() {
        return Array.from(this.accessMethods.values());
    }

    getAccessMethod(methodId) {
        return this.accessMethods.get(methodId);
    }
}

// Export for use in other modules
window.ServerAccessManager = ServerAccessManager;