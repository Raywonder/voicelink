/**
 * VoiceLink Federation Manager
 * Handles room sync between multiple VoiceLink servers
 *
 * Sync modes (set via FEDERATION_MODE env var):
 * - 'redis': Shared Redis for room state (requires REDIS_URL)
 * - 'api': API-based federation (requires PEER_SERVERS)
 * - 'master': Single master server mode (requires MASTER_SERVER_URL)
 * - 'standalone': No federation (default)
 */

const fs = require('fs');
const path = require('path');

class FederationManager {
    constructor(server) {
        this.server = server;
        this.mode = process.env.FEDERATION_MODE || 'standalone';
        this.serverId = process.env.SERVER_ID || `voicelink-${Date.now().toString(36)}`;
        this.peerServers = (process.env.PEER_SERVERS || '').split(',').filter(u => u.trim());
        this.masterServerUrl = process.env.MASTER_SERVER_URL || null;
        this.redisUrl = process.env.REDIS_URL || null;

        // File-based backup for room persistence
        this.dataDir = process.env.DATA_DIR || path.join(__dirname, '..', 'data');
        this.roomsFile = path.join(this.dataDir, 'rooms.json');

        // Sync interval (ms)
        this.syncInterval = parseInt(process.env.SYNC_INTERVAL) || 30000;

        this.init();
    }

    async init() {
        // Ensure data directory exists
        if (!fs.existsSync(this.dataDir)) {
            fs.mkdirSync(this.dataDir, { recursive: true });
        }

        // Load persisted rooms
        this.loadRooms();

        console.log(`Federation mode: ${this.mode}`);
        console.log(`Server ID: ${this.serverId}`);

        switch (this.mode) {
            case 'redis':
                await this.initRedis();
                break;
            case 'api':
                this.initApiFederation();
                break;
            case 'master':
                this.initMasterMode();
                break;
            default:
                console.log('Running in standalone mode (no federation)');
        }
    }

    // Load rooms from file backup
    loadRooms() {
        try {
            if (fs.existsSync(this.roomsFile)) {
                const data = JSON.parse(fs.readFileSync(this.roomsFile, 'utf8'));
                data.forEach(room => {
                    // Restore room without users (they need to reconnect)
                    room.users = [];
                    // Set default values for missing properties to ensure rooms are visible
                    if (room.showInApp === undefined) room.showInApp = true;
                    if (room.allowEmbed === undefined) room.allowEmbed = true;
                    if (room.accessType === undefined) room.accessType = 'hybrid';
                    if (room.visibility === undefined) room.visibility = 'public';
                    if (room.visibleToGuests === undefined) room.visibleToGuests = true;
                    if (room.isDefault === undefined) room.isDefault = false;
                    this.server.rooms.set(room.id, room);
                });
                console.log(`Loaded ${data.length} rooms from backup`);
            }
        } catch (err) {
            console.error('Error loading rooms:', err.message);
        }
    }

    // Save rooms to file backup
    saveRooms() {
        try {
            const rooms = Array.from(this.server.rooms.values()).map(room => ({
                id: room.id,
                name: room.name,
                description: room.description,
                password: room.password,
                maxUsers: room.maxUsers,
                createdAt: room.createdAt,
                audioSettings: room.audioSettings,
                originServer: room.originServer || this.serverId,
                visibility: room.visibility,
                visibleToGuests: room.visibleToGuests,
                accessType: room.accessType,
                showInApp: room.showInApp,
                allowEmbed: room.allowEmbed,
                isDefault: room.isDefault,
                template: room.template,
                privacyLevel: room.privacyLevel,
                encrypted: room.encrypted,
                creatorHandle: room.creatorHandle
            }));
            fs.writeFileSync(this.roomsFile, JSON.stringify(rooms, null, 2));
        } catch (err) {
            console.error('Error saving rooms:', err.message);
        }
    }

    // Redis-based federation
    async initRedis() {
        if (!this.redisUrl) {
            console.error('REDIS_URL not set. Falling back to standalone mode.');
            return;
        }

        try {
            const Redis = require('ioredis');
            this.redis = new Redis(this.redisUrl);
            this.redisSub = new Redis(this.redisUrl);

            // Subscribe to room updates
            this.redisSub.subscribe('voicelink:rooms', (err) => {
                if (err) console.error('Redis subscribe error:', err);
            });

            this.redisSub.on('message', (channel, message) => {
                if (channel === 'voicelink:rooms') {
                    const data = JSON.parse(message);
                    if (data.serverId !== this.serverId) {
                        this.handleRemoteRoomUpdate(data);
                    }
                }
            });

            // Sync rooms from Redis on startup
            const roomsJson = await this.redis.get('voicelink:all-rooms');
            if (roomsJson) {
                const rooms = JSON.parse(roomsJson);
                rooms.forEach(room => {
                    if (!this.server.rooms.has(room.id)) {
                        room.users = [];
                        this.server.rooms.set(room.id, room);
                    }
                });
            }

            console.log('Redis federation initialized');
        } catch (err) {
            console.error('Redis init error:', err.message);
        }
    }

    // API-based federation
    initApiFederation() {
        if (this.peerServers.length === 0) {
            console.log('No peer servers configured for API federation');
            return;
        }

        console.log(`API federation with ${this.peerServers.length} peers`);

        // Periodic sync with peers
        setInterval(() => this.syncWithPeers(), this.syncInterval);

        // Initial sync
        setTimeout(() => this.syncWithPeers(), 5000);
    }

    async syncWithPeers() {
        for (const peerUrl of this.peerServers) {
            try {
                const response = await fetch(`${peerUrl}/api/federation/rooms`);
                if (response.ok) {
                    const data = await response.json();
                    this.mergeRemoteRooms(data.rooms, peerUrl);
                }
            } catch (err) {
                console.log(`Peer sync failed for ${peerUrl}: ${err.message}`);
            }
        }

        // Save after sync
        this.saveRooms();
    }

    mergeRemoteRooms(remoteRooms, sourceServer) {
        remoteRooms.forEach(room => {
            if (!this.server.rooms.has(room.id)) {
                room.users = [];
                room.originServer = sourceServer;
                this.server.rooms.set(room.id, room);
                console.log(`Synced room "${room.name}" from ${sourceServer}`);
            }
        });
    }

    // Master server mode - this server proxies to master
    initMasterMode() {
        if (!this.masterServerUrl) {
            console.error('MASTER_SERVER_URL not set. Falling back to standalone.');
            return;
        }

        console.log(`Master mode: proxying to ${this.masterServerUrl}`);

        // Periodic sync from master
        setInterval(() => this.syncFromMaster(), this.syncInterval);
        setTimeout(() => this.syncFromMaster(), 2000);
    }

    async syncFromMaster() {
        try {
            const response = await fetch(`${this.masterServerUrl}/api/rooms`);
            if (response.ok) {
                const rooms = await response.json();
                // Replace local rooms with master's rooms
                this.server.rooms.clear();
                rooms.forEach(room => {
                    room.users = [];
                    room.originServer = this.masterServerUrl;
                    this.server.rooms.set(room.id, room);
                });
            }
        } catch (err) {
            console.log(`Master sync failed: ${err.message}`);
        }
    }

    handleRemoteRoomUpdate(data) {
        switch (data.action) {
            case 'created':
                if (!this.server.rooms.has(data.room.id)) {
                    data.room.users = [];
                    this.server.rooms.set(data.room.id, data.room);
                }
                break;
            case 'deleted':
                this.server.rooms.delete(data.roomId);
                break;
            case 'updated':
                if (this.server.rooms.has(data.room.id)) {
                    const existing = this.server.rooms.get(data.room.id);
                    Object.assign(existing, data.room, { users: existing.users });
                }
                break;
        }
    }

    // Broadcast room changes
    broadcastRoomChange(action, roomData) {
        this.saveRooms();

        if (this.mode === 'redis' && this.redis) {
            this.redis.publish('voicelink:rooms', JSON.stringify({
                serverId: this.serverId,
                action,
                room: roomData,
                roomId: roomData?.id
            }));

            // Update all-rooms list
            const allRooms = Array.from(this.server.rooms.values()).map(r => ({
                id: r.id, name: r.name, maxUsers: r.maxUsers, originServer: this.serverId
            }));
            this.redis.set('voicelink:all-rooms', JSON.stringify(allRooms));
        }
    }

    // Get all rooms including federated
    getAllRooms() {
        return Array.from(this.server.rooms.values());
    }

    // Setup federation API routes
    setupRoutes(app) {
        // Federation endpoint for peer sync
        app.get('/api/federation/rooms', (req, res) => {
            const rooms = Array.from(this.server.rooms.values()).map(room => ({
                id: room.id,
                name: room.name,
                maxUsers: room.maxUsers,
                hasPassword: !!room.password,
                userCount: room.users.length,
                originServer: room.originServer || this.serverId
            }));
            res.json({ serverId: this.serverId, rooms });
        });

        // Federation status
        app.get('/api/federation/status', (req, res) => {
            res.json({
                serverId: this.serverId,
                mode: this.mode,
                peerServers: this.peerServers,
                masterServer: this.masterServerUrl,
                roomCount: this.server.rooms.size
            });
        });
    }

    // Get list of connected federation servers
    getConnectedServers() {
        const servers = [];

        // Add configured peer servers
        this.peerServers.forEach(url => {
            if (url.trim()) {
                servers.push({
                    url: url.trim(),
                    name: url.replace(/^https?:\/\//, '').split('/')[0],
                    status: 'configured',
                    rooms: 0
                });
            }
        });

        // Add master server if in spoke mode
        if (this.masterServerUrl) {
            servers.push({
                url: this.masterServerUrl,
                name: 'Master Server',
                status: 'configured',
                rooms: 0
            });
        }

        return servers;
    }

    // Connect to a new federation server
    async connectToServer(serverUrl) {
        if (!serverUrl) {
            throw new Error('Server URL is required');
        }

        // Validate URL format
        try {
            new URL(serverUrl);
        } catch (e) {
            throw new Error('Invalid server URL format');
        }

        // Check if already connected
        if (this.peerServers.includes(serverUrl)) {
            throw new Error('Already connected to this server');
        }

        // Try to fetch server status
        try {
            const response = await fetch(`${serverUrl}/api/federation/status`, {
                timeout: 5000
            });
            if (!response.ok) {
                throw new Error('Server did not respond correctly');
            }
            const status = await response.json();

            // Add to peer servers
            this.peerServers.push(serverUrl);

            return {
                serverId: status.serverId,
                roomCount: status.roomCount,
                mode: status.mode
            };
        } catch (err) {
            throw new Error(`Failed to connect: ${err.message}`);
        }
    }
}

module.exports = FederationManager;
