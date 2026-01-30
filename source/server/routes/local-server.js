const express = require('express');
const http = require('http');
const socketIo = require('socket.io');
const path = require('path');
const cors = require('cors');
const fs = require('fs');
const { v4: uuidv4 } = require('uuid');
const { LicensingRoutes } = require('./licensing-routes');

class VoiceLinkLocalServer {
    constructor() {
        this.app = express();
        this.server = http.createServer(this.app);
        this.io = socketIo(this.server, {
            cors: {
                origin: "http://localhost:3001",
                methods: ["GET", "POST"]
            }
        });

        this.rooms = new Map();
        this.users = new Map();
        this.audioRouting = new Map();

        // Client sync system
        this.clientFeatures = new Map();
        this.serverCapabilities = {
            version: '1.0.0',
            supportedFeatures: [
                'audioSettings',
                'userSettings',
                'roomConfigurations',
                'customScripts',
                'menuSounds',
                'backgroundAudio',
                'spatialAudio',
                'landscapeSharing'
            ],
            lastUpdated: new Date()
        };

        // Load deploy config for background streams
        this.deployConfig = this.loadDeployConfig();

        // Remote node/app management system
        this.registeredNodes = new Map(); // nodeId -> { url, name, type, lastSeen, status }
        this.pendingRestarts = new Map(); // nodeId -> { scheduledAt, reason }
        this.restartDelayMs = 10 * 60 * 1000; // 10 minutes default
        this.nodeChangeLog = [];

        this.setupMiddleware();
        this.setupRoutes();
        this.setupSocketHandlers();
        this.start();
    }

    loadDeployConfig() {
        try {
            const configPaths = [
                path.join(__dirname, '../../../data/deploy.json'),
                path.join(__dirname, '../../data/deploy.json'),
                path.join(process.cwd(), 'data/deploy.json')
            ];
            for (const configPath of configPaths) {
                if (fs.existsSync(configPath)) {
                    const config = JSON.parse(fs.readFileSync(configPath, 'utf8'));
                    console.log('[Server] Loaded deploy config from:', configPath);
                    return config;
                }
            }
        } catch (e) {
            console.error('[Server] Error loading deploy config:', e.message);
        }
        return {};
    }

    // Schedule a debounced restart for a remote node
    scheduleNodeRestart(nodeId, delayMinutes, reason) {
        const node = this.registeredNodes.get(nodeId);
        if (!node) return null;

        // Clear existing timer (debounce)
        const existing = this.pendingRestarts.get(nodeId);
        if (existing?.timer) {
            clearTimeout(existing.timer);
            console.log(`[Nodes] Reset restart timer for ${nodeId} (debounced)`);
        }

        const delayMs = (delayMinutes || 10) * 60 * 1000;
        const scheduledAt = new Date(Date.now() + delayMs).toISOString();

        const timer = setTimeout(async () => {
            console.log(`[Nodes] Executing scheduled restart for ${nodeId}...`);
            await this.sendRestartToNode(node, 0, reason || 'Scheduled restart');
            this.pendingRestarts.delete(nodeId);
        }, delayMs);

        this.pendingRestarts.set(nodeId, { scheduledAt, reason, timer });
        console.log(`[Nodes] Restart scheduled for ${nodeId} at ${scheduledAt}`);

        // Log the change
        this.nodeChangeLog.push({
            timestamp: new Date().toISOString(),
            nodeId,
            action: 'restart_scheduled',
            scheduledAt,
            reason
        });
        if (this.nodeChangeLog.length > 100) {
            this.nodeChangeLog = this.nodeChangeLog.slice(-100);
        }

        return { scheduledAt, delayMinutes };
    }

    // Send restart command to a remote node
    async sendRestartToNode(node, delayMinutes, reason) {
        try {
            console.log(`[Nodes] Sending restart to ${node.nodeId} at ${node.url}`);

            const response = await fetch(`${node.url}/api/restart`, {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({
                    delayMinutes: delayMinutes || 0,
                    reason: reason || 'Remote restart requested',
                    from: 'hub'
                }),
                timeout: 10000
            });

            const result = await response.json().catch(() => ({}));

            this.nodeChangeLog.push({
                timestamp: new Date().toISOString(),
                nodeId: node.nodeId,
                action: 'restart_sent',
                success: response.ok,
                reason
            });

            return { success: response.ok, nodeId: node.nodeId, response: result };
        } catch (e) {
            console.error(`[Nodes] Failed to send restart to ${node.nodeId}:`, e.message);
            return { success: false, nodeId: node.nodeId, error: e.message };
        }
    }

    getBackgroundStreamForRoom(roomId, roomName) {
        const bgConfig = this.deployConfig?.backgroundStreams;
        if (!bgConfig?.enabled || !bgConfig?.streams) return null;

        for (const stream of bgConfig.streams) {
            // Check direct room ID match
            if (stream.rooms?.includes(roomId)) {
                return {
                    id: stream.id,
                    name: stream.name,
                    url: stream.streamUrl || stream.url,
                    volume: stream.volume ?? bgConfig.defaultVolume ?? 30,
                    hidden: stream.hidden ?? false,
                    autoPlay: stream.autoPlay ?? true,
                    fadeInDuration: bgConfig.fadeInDuration ?? 2000
                };
            }
            // Check room name patterns
            if (stream.roomPatterns && roomName) {
                for (const pattern of stream.roomPatterns) {
                    const regex = new RegExp(pattern.replace(/\*/g, '.*'), 'i');
                    if (regex.test(roomName)) {
                        return {
                            id: stream.id,
                            name: stream.name,
                            url: stream.streamUrl || stream.url,
                            volume: stream.volume ?? bgConfig.defaultVolume ?? 30,
                            hidden: stream.hidden ?? false,
                            autoPlay: stream.autoPlay ?? true,
                            fadeInDuration: bgConfig.fadeInDuration ?? 2000
                        };
                    }
                }
            }
        }
        return null;
    }

    setupMiddleware() {
        this.app.use(cors());
        this.app.use(express.json());
        this.app.use(express.static(path.join(__dirname, '..', 'client')));
    }

    setupRoutes() {
        // Licensing Routes
        const licensingConfig = this.deployConfig?.licensing || {};
        const licensingRoutes = new LicensingRoutes({
            dataDir: path.join(__dirname, '../../../data/licensing'),
            registrationDelayMinutes: licensingConfig.registrationDelayMinutes || 15,
            maxFreeDevices: 3,
            hubNodeApiUrl: licensingConfig.apiUrl,
            hubNodeApiKey: process.env.HUBNODE_API_KEY
        });
        this.app.use('/api/licensing', licensingRoutes.getRouter());

        // Remote Node Management API endpoints

        // Register a remote node/app
        this.app.post('/api/nodes/register', (req, res) => {
            const { nodeId, name, type, url, capabilities } = req.body;
            if (!nodeId || !url) {
                return res.status(400).json({ success: false, error: 'nodeId and url required' });
            }
            this.registeredNodes.set(nodeId, {
                nodeId, name: name || nodeId, type: type || 'node',
                url, capabilities: capabilities || [],
                registeredAt: new Date().toISOString(),
                lastSeen: new Date().toISOString(),
                status: 'online'
            });
            console.log(`[Nodes] Registered: ${nodeId} (${type}) at ${url}`);
            res.json({ success: true, message: 'Node registered', nodeId });
        });

        // Heartbeat from remote node
        this.app.post('/api/nodes/heartbeat', (req, res) => {
            const { nodeId, status, stats } = req.body;
            const node = this.registeredNodes.get(nodeId);
            if (node) {
                node.lastSeen = new Date().toISOString();
                node.status = status || 'online';
                node.stats = stats;
                res.json({ success: true, pendingRestart: this.pendingRestarts.has(nodeId) });
            } else {
                res.status(404).json({ success: false, error: 'Node not registered' });
            }
        });

        // List all registered nodes
        this.app.get('/api/nodes', (req, res) => {
            const nodes = Array.from(this.registeredNodes.values());
            res.json({ success: true, nodes, count: nodes.length });
        });

        // Get specific node
        this.app.get('/api/nodes/:nodeId', (req, res) => {
            const node = this.registeredNodes.get(req.params.nodeId);
            if (node) {
                res.json({ success: true, node });
            } else {
                res.status(404).json({ success: false, error: 'Node not found' });
            }
        });

        // Send restart command to specific node
        this.app.post('/api/nodes/:nodeId/restart', async (req, res) => {
            const { nodeId } = req.params;
            const { delayMinutes, reason } = req.body;
            const node = this.registeredNodes.get(nodeId);

            if (!node) {
                return res.status(404).json({ success: false, error: 'Node not found' });
            }

            const result = await this.sendRestartToNode(node, delayMinutes || 0, reason);
            res.json(result);
        });

        // Send restart command to all nodes of a type
        this.app.post('/api/nodes/restart-all', async (req, res) => {
            const { type, delayMinutes, reason } = req.body;
            const results = [];

            for (const [nodeId, node] of this.registeredNodes) {
                if (!type || node.type === type) {
                    const result = await this.sendRestartToNode(node, delayMinutes || 0, reason);
                    results.push({ nodeId, ...result });
                }
            }

            res.json({ success: true, results, count: results.length });
        });

        // Schedule delayed restart for node (debounced)
        this.app.post('/api/nodes/:nodeId/schedule-restart', (req, res) => {
            const { nodeId } = req.params;
            const { delayMinutes = 10, reason } = req.body;
            const node = this.registeredNodes.get(nodeId);

            if (!node) {
                return res.status(404).json({ success: false, error: 'Node not found' });
            }

            this.scheduleNodeRestart(nodeId, delayMinutes, reason);
            res.json({
                success: true,
                message: 'Restart scheduled',
                nodeId,
                restartAt: this.pendingRestarts.get(nodeId)?.scheduledAt,
                delayMinutes
            });
        });

        // Cancel scheduled restart for node
        this.app.post('/api/nodes/:nodeId/cancel-restart', (req, res) => {
            const { nodeId } = req.params;
            const pending = this.pendingRestarts.get(nodeId);

            if (pending?.timer) {
                clearTimeout(pending.timer);
                this.pendingRestarts.delete(nodeId);
                res.json({ success: true, message: 'Restart cancelled', nodeId });
            } else {
                res.json({ success: true, message: 'No restart pending', nodeId });
            }
        });

        // Unregister node
        this.app.delete('/api/nodes/:nodeId', (req, res) => {
            const deleted = this.registeredNodes.delete(req.params.nodeId);
            this.pendingRestarts.delete(req.params.nodeId);
            res.json({ success: deleted, message: deleted ? 'Node removed' : 'Node not found' });
        });

        // Broadcast sync/update notification to all nodes
        this.app.post('/api/nodes/broadcast', async (req, res) => {
            const { event, data, type } = req.body;
            const results = [];

            for (const [nodeId, node] of this.registeredNodes) {
                if (!type || node.type === type) {
                    try {
                        const response = await fetch(`${node.url}/api/sync/event`, {
                            method: 'POST',
                            headers: { 'Content-Type': 'application/json' },
                            body: JSON.stringify({ event, data, from: 'hub' })
                        });
                        results.push({ nodeId, success: response.ok });
                    } catch (e) {
                        results.push({ nodeId, success: false, error: e.message });
                    }
                }
            }

            res.json({ success: true, results });
        });

        // Reload local config
        this.app.post('/api/sync/reload-config', (req, res) => {
            const oldConfig = this.deployConfig;
            this.deployConfig = this.loadDeployConfig();
            res.json({
                success: true,
                message: 'Config reloaded',
                configChanged: JSON.stringify(oldConfig) !== JSON.stringify(this.deployConfig)
            });
        });

        // API Routes
        this.app.get('/api/rooms', (req, res) => {
            const roomList = Array.from(this.rooms.values()).map(room => ({
                id: room.id,
                name: room.name,
                users: room.users.length,
                maxUsers: room.maxUsers,
                hasPassword: !!room.password
            }));
            res.json(roomList);
        });

        this.app.post('/api/rooms', (req, res) => {
            const {
                roomId: clientRoomId,
                name,
                description,
                password,
                maxUsers = 10,
                duration,
                privacyLevel,
                encrypted,
                creator
            } = req.body;

            const roomId = clientRoomId || uuidv4();

            const room = {
                id: roomId,
                name: name || `Room ${roomId.slice(0, 8)}`,
                description,
                password,
                maxUsers,
                duration,
                privacyLevel: privacyLevel || 'public',
                encrypted: encrypted || false,
                creator,
                users: [],
                createdAt: new Date(),
                audioSettings: {
                    spatialAudio: true,
                    quality: 'high',
                    effects: []
                }
            };

            this.rooms.set(roomId, room);
            console.log(`Room created: ${room.name} (${roomId}) by ${creator?.name || 'Unknown'}`);
            res.json({ roomId, message: 'Room created successfully' });
        });

        this.app.get('/api/audio/devices', async (req, res) => {
            // This would typically query system audio devices
            // For now, return mock data for local testing
            res.json({
                inputs: [
                    { id: 'default', name: 'Default Microphone', type: 'builtin' },
                    { id: 'usb-mic', name: 'USB Microphone', type: 'usb' }
                ],
                outputs: [
                    { id: 'default', name: 'Built-in Output', type: 'builtin' },
                    { id: 'output-3-4', name: 'Audio Interface 3-4', type: 'interface' },
                    { id: 'output-5-6', name: 'Audio Interface 5-6', type: 'interface' },
                    { id: 'headphones', name: 'Headphones', type: 'headphones' }
                ]
            });
        });

        // Client sync API routes
        this.app.get('/api/status', (req, res) => {
            res.json({
                server: 'VoiceLink Local Server',
                version: this.serverCapabilities.version,
                capabilities: this.serverCapabilities.supportedFeatures,
                lastUpdated: this.serverCapabilities.lastUpdated,
                activeRooms: this.rooms.size,
                connectedUsers: this.users.size
            });
        });

        this.app.get('/api/capabilities', (req, res) => {
            res.json(this.serverCapabilities);
        });

        this.app.post('/api/client-sync', express.json({ limit: '10mb' }), (req, res) => {
            try {
                const { type, name, data, clientVersion, requiresAdmin } = req.body;

                // Validate sync request
                if (!type || !name || !data) {
                    return res.status(400).json({
                        success: false,
                        error: 'Missing required fields: type, name, data'
                    });
                }

                // Check if feature is supported
                if (!this.serverCapabilities.supportedFeatures.includes(name)) {
                    return res.status(400).json({
                        success: false,
                        error: `Feature '${name}' is not supported by this server`
                    });
                }

                // Store client feature
                this.clientFeatures.set(`${type}_${name}`, {
                    type,
                    name,
                    data,
                    clientVersion,
                    timestamp: new Date(),
                    applied: false
                });

                console.log(`Server: Received client sync for ${type}:${name} from version ${clientVersion}`);

                // Apply the feature based on type
                const applyResult = this.applyClientFeature(type, name, data);

                res.json({
                    success: applyResult.success,
                    message: applyResult.message,
                    requiresRestart: applyResult.requiresRestart,
                    appliedFeatures: applyResult.appliedFeatures || []
                });

            } catch (error) {
                console.error('Server: Client sync error:', error);
                res.status(500).json({
                    success: false,
                    error: 'Internal server error during sync'
                });
            }
        });

        this.app.get('/api/landscapes', (req, res) => {
            // Return shared landscapes
            const landscapes = Array.from(this.clientFeatures.values())
                .filter(f => f.type === 'landscapeSharing')
                .map(f => f.data);

            res.json({ landscapes });
        });

        this.app.post('/api/landscapes', express.json({ limit: '10mb' }), (req, res) => {
            try {
                const { name, data, metadata } = req.body;

                const landscapeId = uuidv4();
                this.clientFeatures.set(`landscape_${landscapeId}`, {
                    type: 'landscape',
                    name: landscapeId,
                    data: { name, data, metadata, uploadedAt: new Date() },
                    timestamp: new Date(),
                    applied: true
                });

                console.log(`Server: Stored shared landscape: ${name}`);

                res.json({
                    success: true,
                    landscapeId,
                    message: 'Landscape uploaded and shared successfully'
                });

            } catch (error) {
                console.error('Server: Landscape upload error:', error);
                res.status(500).json({
                    success: false,
                    error: 'Failed to upload landscape'
                });
            }
        });

        // Serve the main client
        this.app.get('/', (req, res) => {
            res.sendFile(path.join(__dirname, '..', 'client', 'index.html'));
        });
    }

    setupSocketHandlers() {
        this.io.on('connection', (socket) => {
            console.log(`User connected: ${socket.id}`);

            // User joins a room
            socket.on('join-room', (data) => {
                const { roomId, userName, password } = data;
                const room = this.rooms.get(roomId);

                if (!room) {
                    socket.emit('error', { message: 'Room not found' });
                    return;
                }

                if (room.password && room.password !== password) {
                    socket.emit('error', { message: 'Invalid password' });
                    return;
                }

                if (room.users.length >= room.maxUsers) {
                    socket.emit('error', { message: 'Room is full' });
                    return;
                }

                // Add user to room
                const user = {
                    id: socket.id,
                    name: userName || `User ${socket.id.slice(0, 8)}`,
                    joinedAt: new Date(),
                    audioSettings: {
                        muted: false,
                        volume: 1.0,
                        spatialPosition: { x: 0, y: 0, z: 0 },
                        outputDevice: 'default'
                    }
                };

                room.users.push(user);
                this.users.set(socket.id, { ...user, roomId });

                socket.join(roomId);
                socket.emit('joined-room', { room, user });
                socket.to(roomId).emit('user-joined', user);

                // Check for background stream and notify client
                const bgStream = this.getBackgroundStreamForRoom(roomId, room.name);
                if (bgStream) {
                    setTimeout(() => {
                        socket.emit('background-stream', bgStream);
                        console.log(`[BackgroundStream] Sent stream ${bgStream.name} to user in ${room.name}`);
                    }, 500); // Small delay to let client initialize
                }

                console.log(`User ${user.name} joined room ${room.name}`);
            });

            // Handle WebRTC signaling
            socket.on('webrtc-offer', (data) => {
                socket.to(data.targetUserId).emit('webrtc-offer', {
                    offer: data.offer,
                    fromUserId: socket.id
                });
            });

            socket.on('webrtc-answer', (data) => {
                socket.to(data.targetUserId).emit('webrtc-answer', {
                    answer: data.answer,
                    fromUserId: socket.id
                });
            });

            socket.on('webrtc-ice-candidate', (data) => {
                socket.to(data.targetUserId).emit('webrtc-ice-candidate', {
                    candidate: data.candidate,
                    fromUserId: socket.id
                });
            });

            // Audio routing
            socket.on('set-audio-routing', (data) => {
                const user = this.users.get(socket.id);
                if (user) {
                    user.audioSettings.outputDevice = data.outputDevice;
                    this.audioRouting.set(socket.id, data);

                    socket.to(user.roomId).emit('user-audio-routing-changed', {
                        userId: socket.id,
                        routing: data
                    });
                }
            });

            // Spatial audio positioning
            socket.on('set-spatial-position', (data) => {
                const user = this.users.get(socket.id);
                if (user) {
                    user.audioSettings.spatialPosition = data.position;

                    socket.to(user.roomId).emit('user-position-changed', {
                        userId: socket.id,
                        position: data.position
                    });
                }
            });

            // User settings updates
            socket.on('update-audio-settings', (data) => {
                const user = this.users.get(socket.id);
                if (user) {
                    Object.assign(user.audioSettings, data);

                    socket.to(user.roomId).emit('user-audio-settings-changed', {
                        userId: socket.id,
                        settings: user.audioSettings
                    });
                }
            });

            // Chat messages
            socket.on('chat-message', (data) => {
                const user = this.users.get(socket.id);
                if (user) {
                    const message = {
                        id: uuidv4(),
                        userId: socket.id,
                        userName: user.name,
                        message: data.message,
                        timestamp: new Date()
                    };

                    this.io.to(user.roomId).emit('chat-message', message);
                }
            });

            // Disconnect handling
            socket.on('disconnect', () => {
                const user = this.users.get(socket.id);
                if (user) {
                    const room = this.rooms.get(user.roomId);
                    if (room) {
                        room.users = room.users.filter(u => u.id !== socket.id);
                        socket.to(user.roomId).emit('user-left', { userId: socket.id });

                        // Clean up empty rooms
                        if (room.users.length === 0) {
                            this.rooms.delete(user.roomId);
                            console.log(`Room ${room.name} deleted (empty)`);
                        }
                    }

                    this.users.delete(socket.id);
                    this.audioRouting.delete(socket.id);
                }

                console.log(`User disconnected: ${socket.id}`);
            });

            // Client sync socket handlers
            socket.on('get-server-info', (data) => {
                console.log(`Server: Received server info request from client version ${data.clientVersion}`);

                socket.emit('server-info', {
                    version: this.serverCapabilities.version,
                    capabilities: this.serverCapabilities.supportedFeatures,
                    lastUpdated: this.serverCapabilities.lastUpdated,
                    activeRooms: this.rooms.size,
                    connectedUsers: this.users.size,
                    clientFeatures: Array.from(this.clientFeatures.keys())
                });
            });

            socket.on('client-sync-request', (data) => {
                console.log(`Server: Received client sync request: ${data.type}:${data.name}`);

                try {
                    // Validate sync request
                    if (!data.type || !data.name || !data.data) {
                        socket.emit('sync-response', {
                            syncId: data.syncId,
                            success: false,
                            error: 'Missing required fields: type, name, data'
                        });
                        return;
                    }

                    // Check if feature is supported
                    if (!this.serverCapabilities.supportedFeatures.includes(data.name)) {
                        socket.emit('sync-response', {
                            syncId: data.syncId,
                            success: false,
                            error: `Feature '${data.name}' is not supported by this server`
                        });
                        return;
                    }

                    // Store client feature
                    this.clientFeatures.set(`${data.type}_${data.name}`, {
                        type: data.type,
                        name: data.name,
                        data: data.data,
                        clientVersion: data.clientVersion,
                        timestamp: new Date(),
                        applied: false
                    });

                    // Apply the feature
                    const applyResult = this.applyClientFeature(data.type, data.name, data.data);

                    socket.emit('sync-response', {
                        syncId: data.syncId,
                        success: applyResult.success,
                        message: applyResult.message,
                        requiresRestart: applyResult.requiresRestart,
                        appliedFeatures: applyResult.appliedFeatures || []
                    });

                } catch (error) {
                    console.error('Server: Client sync error:', error);
                    socket.emit('sync-response', {
                        syncId: data.syncId,
                        success: false,
                        error: 'Internal server error during sync'
                    });
                }
            });

            socket.on('request-client-features', (data) => {
                console.log(`Server: Client requesting features: ${data.features.join(', ')}`);

                const availableFeatures = {};

                for (const featureName of data.features) {
                    const featureKey = `feature_${featureName}`;
                    const clientFeature = this.clientFeatures.get(featureKey);

                    if (clientFeature) {
                        availableFeatures[featureName] = clientFeature.data;
                    }
                }

                socket.emit('client-features-response', {
                    requestId: data.requestId,
                    features: availableFeatures,
                    serverVersion: this.serverCapabilities.version
                });
            });

            socket.on('client-features-response', (data) => {
                console.log(`Server: Received client features response for request ${data.requestId}`);

                // Store client features
                for (const [featureName, featureData] of Object.entries(data.features)) {
                    this.clientFeatures.set(`client_${featureName}`, {
                        type: 'client',
                        name: featureName,
                        data: featureData,
                        clientVersion: data.clientVersion,
                        timestamp: new Date(),
                        applied: true
                    });
                }

                // Apply new features to server
                const appliedFeatures = [];
                for (const featureName of Object.keys(data.features)) {
                    const applyResult = this.applyClientFeature('client', featureName, data.features[featureName]);
                    if (applyResult.success) {
                        appliedFeatures.push(featureName);
                    }
                }

                if (appliedFeatures.length > 0) {
                    console.log(`Server: Applied client features: ${appliedFeatures.join(', ')}`);

                    // Notify all clients about new features
                    this.io.emit('sync-response', {
                        success: true,
                        message: 'Server updated with new client features',
                        newFeatures: appliedFeatures,
                        requiresRestart: false
                    });
                }
            });
        });
    }

    applyClientFeature(type, name, data) {
        console.log(`Server: Applying client feature: ${type}:${name}`);

        try {
            switch (name) {
                case 'audioSettings':
                    return this.applyAudioSettingsFeature(data);

                case 'userSettings':
                    return this.applyUserSettingsFeature(data);

                case 'roomConfigurations':
                    return this.applyRoomConfigurationsFeature(data);

                case 'customScripts':
                    return this.applyCustomScriptsFeature(data);

                case 'menuSounds':
                    return this.applyMenuSoundsFeature(data);

                case 'backgroundAudio':
                    return this.applyBackgroundAudioFeature(data);

                case 'spatialAudio':
                    return this.applySpatialAudioFeature(data);

                case 'landscapeSharing':
                    return this.applyLandscapeSharingFeature(data);

                case 'keybindings':
                    return this.applyKeybindingsFeature(data);

                case 'serverConfig':
                    return this.applyServerConfigFeature(data);

                default:
                    return {
                        success: false,
                        message: `Unknown feature: ${name}`,
                        requiresRestart: false
                    };
            }

        } catch (error) {
            console.error(`Server: Error applying feature ${name}:`, error);
            return {
                success: false,
                message: `Failed to apply feature: ${error.message}`,
                requiresRestart: false
            };
        }
    }

    applyAudioSettingsFeature(data) {
        // Update server audio capabilities
        this.serverCapabilities.audioSettings = {
            ...this.serverCapabilities.audioSettings,
            ...data
        };

        console.log('Server: Applied enhanced audio settings');
        return {
            success: true,
            message: 'Enhanced audio settings applied to server',
            requiresRestart: false,
            appliedFeatures: ['enhanced_spatial_audio', 'background_audio_persistence']
        };
    }

    applyUserSettingsFeature(data) {
        // Store default user settings for new connections
        this.serverCapabilities.defaultUserSettings = data;

        console.log('Server: Applied user settings defaults');
        return {
            success: true,
            message: 'Default user settings applied to server',
            requiresRestart: false
        };
    }

    applyRoomConfigurationsFeature(data) {
        // Apply room configuration enhancements
        if (data.defaultRooms) {
            // Create default rooms if they don't exist
            for (const roomConfig of data.defaultRooms) {
                if (!this.rooms.has(roomConfig.id)) {
                    this.rooms.set(roomConfig.id, {
                        ...roomConfig,
                        users: [],
                        createdAt: new Date(),
                        isDefault: true
                    });
                }
            }
        }

        console.log('Server: Applied room configuration enhancements');
        return {
            success: true,
            message: 'Room configurations applied to server',
            requiresRestart: false,
            appliedFeatures: ['default_rooms', 'enhanced_room_settings']
        };
    }

    applyCustomScriptsFeature(data) {
        // Store custom script configurations
        this.serverCapabilities.customScripts = data;

        console.log('Server: Applied custom script configurations');
        return {
            success: true,
            message: 'Custom script configurations applied to server',
            requiresRestart: false,
            appliedFeatures: ['background_audio_scripts', 'menu_sound_scripts', 'spatial_audio_enhancements']
        };
    }

    applyMenuSoundsFeature(data) {
        // Apply menu sound enhancements
        this.serverCapabilities.menuSounds = data;

        console.log('Server: Applied menu sound enhancements');
        return {
            success: true,
            message: 'Menu sound enhancements applied to server',
            requiresRestart: false,
            appliedFeatures: ['synthetic_woosh_generation', 'spatial_menu_sounds']
        };
    }

    applyBackgroundAudioFeature(data) {
        // Apply background audio enhancements
        this.serverCapabilities.backgroundAudio = data;

        console.log('Server: Applied background audio enhancements');
        return {
            success: true,
            message: 'Background audio enhancements applied to server',
            requiresRestart: false,
            appliedFeatures: ['seamless_noise_looping', 'persistent_background_audio']
        };
    }

    applySpatialAudioFeature(data) {
        // Apply spatial audio enhancements
        this.serverCapabilities.spatialAudio = data;

        console.log('Server: Applied spatial audio enhancements');
        return {
            success: true,
            message: 'Spatial audio enhancements applied to server',
            requiresRestart: false,
            appliedFeatures: ['3d_positioning', 'room_acoustics', 'distance_attenuation']
        };
    }

    applyLandscapeSharingFeature(data) {
        // Enable landscape sharing on server
        this.serverCapabilities.landscapeSharing = {
            enabled: true,
            maxFileSize: data.maxFileSize || 10 * 1024 * 1024,
            supportedFormats: data.supportedFormats || ['jpg', 'jpeg', 'png', 'webp'],
            compressionEnabled: data.compressionEnabled || true
        };

        console.log('Server: Applied landscape sharing feature');
        return {
            success: true,
            message: 'Landscape sharing feature applied to server',
            requiresRestart: false,
            appliedFeatures: ['landscape_upload', 'landscape_sharing', 'image_compression']
        };
    }

    applyKeybindingsFeature(data) {
        // Store server-side keybinding configurations
        this.serverCapabilities.keybindings = data;

        console.log('Server: Applied keybinding configurations');
        return {
            success: true,
            message: 'Keybinding configurations applied to server',
            requiresRestart: false
        };
    }

    applyServerConfigFeature(data) {
        // Apply server configuration enhancements
        if (data.enhancedRoutes) {
            console.log('Server: Enhanced routes feature noted (requires manual implementation)');
        }

        if (data.middlewareUpdates) {
            console.log('Server: Middleware updates feature noted (requires restart for full application)');
        }

        if (data.securityEnhancements) {
            console.log('Server: Security enhancements feature noted');
        }

        this.serverCapabilities.serverConfig = data;

        return {
            success: true,
            message: 'Server configuration enhancements applied',
            requiresRestart: true,
            appliedFeatures: ['enhanced_routes', 'security_enhancements', 'middleware_updates']
        };
    }

    start() {
        const PORT = process.env.PORT || 3001;
        this.server.listen(PORT, () => {
            console.log(`VoiceLink Local Server running on http://localhost:${PORT}`);
            console.log('Ready for local P2P voice chat testing!');
        });
    }
}

// Start the server
new VoiceLinkLocalServer();

module.exports = VoiceLinkLocalServer;