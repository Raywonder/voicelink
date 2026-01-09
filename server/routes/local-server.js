const express = require('express');
const http = require('http');
const socketIo = require('socket.io');
const path = require('path');
const cors = require('cors');
const { v4: uuidv4 } = require('uuid');
const FederationManager = require('../utils/federation-manager');
const MastodonBotManager = require('../utils/mastodon-bot');

class VoiceLinkLocalServer {
    constructor() {
        this.app = express();
        this.server = http.createServer(this.app);
        this.io = socketIo(this.server, {
            cors: {
                origin: "*",
                methods: ["GET", "POST"]
            },
            maxHttpBufferSize: 1e7 // 10MB for audio data
        });

        this.rooms = new Map();
        this.users = new Map();
        this.audioRouting = new Map();

        // Audio relay state
        this.audioRelayEnabled = new Map(); // socketId -> boolean
        this.audioBuffers = new Map(); // socketId -> audio buffer for mixing
        this.relayStats = {
            bytesRelayed: 0,
            packetsRelayed: 0,
            activeRelays: 0
        };

        // Initialize federation manager for room sync
        this.federation = new FederationManager(this);

        // Initialize Mastodon bot manager
        this.mastodonBot = new MastodonBotManager(this);

        // Authenticated users (Mastodon OAuth)
        this.authenticatedUsers = new Map(); // socketId -> mastodon user info

        this.setupMiddleware();
        this.setupRoutes();
        this.setupSocketHandlers();
        this.start();
    }

    setupMiddleware() {
        this.app.use(cors());
        this.app.use(express.json());
        this.app.use(express.static(path.join(__dirname, '..', '..', 'client')));
    }

    setupRoutes() {
        // API Routes
        this.app.get('/api/rooms', (req, res) => {
            const source = req.query.source || 'app'; // 'app', 'web', 'all'
            const includeHidden = req.query.includeHidden === 'true';

            let rooms = Array.from(this.rooms.values());

            // Filter by access type based on request source
            if (!includeHidden) {
                rooms = rooms.filter(room => {
                    if (room.accessType === 'hidden') return false;
                    if (source === 'app' && !room.showInApp) return false;
                    if (source === 'web' && !room.allowEmbed) return false;
                    return true;
                });
            }

            const roomList = rooms.map(room => ({
                id: room.id,
                name: room.name,
                users: room.users.length,
                maxUsers: room.maxUsers,
                hasPassword: !!room.password,
                visibility: room.visibility,
                accessType: room.accessType,
                allowEmbed: room.allowEmbed,
                visibleToGuests: room.visibleToGuests,
                isGuestRoom: room.isGuestRoom || false,
                expiresAt: room.expiresAt ? room.expiresAt.toISOString ? room.expiresAt.toISOString() : room.expiresAt : null,
                creatorHandle: room.creatorHandle || null
            }));
            res.json(roomList);
        });

        this.app.post('/api/rooms', (req, res) => {
            const {
                name,
                password,
                maxUsers = 10,
                visibility = 'public',
                visibleToGuests = true,
                accessType = 'hybrid',  // 'web-only', 'app-only', 'hybrid', 'hidden'
                duration,
                privacyLevel,
                encrypted,
                creatorHandle,
                isAuthenticated = false  // Whether creator is logged in
            } = req.body;
            const roomId = req.body.roomId || uuidv4();

            // Guest room time limit: 10 minutes (600000ms)
            const GUEST_ROOM_DURATION = 10 * 60 * 1000;

            // Calculate expiration based on authentication status
            let expiresAt = null;
            let isGuestRoom = false;

            if (!isAuthenticated && !creatorHandle) {
                // Guest user - enforce 10-minute limit
                expiresAt = new Date(Date.now() + GUEST_ROOM_DURATION);
                isGuestRoom = true;
                console.log(`Guest room created: ${roomId} - expires at ${expiresAt.toISOString()}`);
            } else if (duration && typeof duration === 'number') {
                // Authenticated user with explicit duration
                expiresAt = new Date(Date.now() + duration);
            }
            // Authenticated users without explicit duration get permanent rooms

            // Access type determines where the room is accessible:
            // - web-only: Only via direct URL/embed (not listed in app)
            // - app-only: Only within VoiceLink app (no embed access)
            // - hybrid: Both app and web embed access
            // - hidden: Not listed anywhere, only direct link works

            const room = {
                id: roomId,
                name: name || `Room ${roomId.slice(0, 8)}`,
                password,
                hasPassword: !!password,
                maxUsers,
                users: [],
                visibility,  // 'public', 'unlisted', 'private'
                visibleToGuests: accessType === 'hidden' ? false : visibleToGuests,
                accessType,
                allowEmbed: accessType === 'web-only' || accessType === 'hybrid',
                showInApp: accessType === 'app-only' || accessType === 'hybrid',
                privacyLevel: privacyLevel || visibility,
                encrypted: encrypted || false,
                creatorHandle,
                createdAt: new Date(),
                expiresAt,
                isGuestRoom,  // Track if this is a guest (time-limited) room
                audioSettings: {
                    spatialAudio: true,
                    quality: 'high',
                    effects: []
                }
            };

            this.rooms.set(roomId, room);

            // Broadcast to federated servers (only public hybrid/app rooms)
            if (visibility === 'public' && room.showInApp) {
                this.federation.broadcastRoomChange('created', room);
            }

            // Return room info including expiration for guest rooms
            res.json({
                roomId,
                message: 'Room created successfully',
                accessType,
                isGuestRoom,
                expiresAt: expiresAt ? expiresAt.toISOString() : null,
                timeLimit: isGuestRoom ? GUEST_ROOM_DURATION : null
            });
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

        // API status endpoint with relay stats
        this.app.get('/api/status', (req, res) => {
            res.json({
                server: 'VoiceLink Local Server',
                version: '1.0.1',
                capabilities: [
                    'audioSettings',
                    'userSettings',
                    'roomConfigurations',
                    'customScripts',
                    'menuSounds',
                    'backgroundAudio',
                    'spatialAudio',
                    'landscapeSharing',
                    'p2pAudio',
                    'serverRelay'
                ],
                lastUpdated: new Date().toISOString(),
                activeRooms: this.rooms.size,
                connectedUsers: this.users.size,
                audioRelay: {
                    enabled: true,
                    activeRelays: this.relayStats.activeRelays,
                    bytesRelayed: this.relayStats.bytesRelayed,
                    packetsRelayed: this.relayStats.packetsRelayed
                },
                connectionModes: ['p2p', 'relay', 'auto']
            });
        });

        // Get relay statistics
        this.app.get('/api/relay/stats', (req, res) => {
            res.json({
                ...this.relayStats,
                activeUsers: Array.from(this.audioRelayEnabled.entries())
                    .filter(([_, enabled]) => enabled).length
            });
        });

        // Serve the main client
        this.app.get('/', (req, res) => {
            res.sendFile(path.join(__dirname, '..', '..', 'client', 'index.html'));
        });

        // Setup federation API routes
        this.federation.setupRoutes(this.app);

        // Protocol handler redirect (voicelink:// URLs)
        this.app.get('/join/:roomId', (req, res) => {
            const { roomId } = req.params;
            const room = this.rooms.get(roomId);
            if (room) {
                res.redirect(`/?room=${roomId}`);
            } else {
                res.status(404).send('Room not found');
            }
        });

        // Deep link handler
        this.app.get('/link/:roomId', (req, res) => {
            const { roomId } = req.params;
            const serverUrl = `${req.protocol}://${req.get('host')}`;
            res.json({
                roomId,
                webUrl: `${serverUrl}/?room=${roomId}`,
                protocolUrl: `voicelink://join/${roomId}?server=${encodeURIComponent(serverUrl)}`,
                serverUrl
            });
        });

        // OAuth callback handler for browser-based auth
        this.app.get('/oauth/callback', (req, res) => {
            const { code, state } = req.query;
            // Redirect to main app with code for client-side processing
            res.redirect(`/?oauth_code=${code}&oauth_state=${state}`);
        });

        // Generate Mastodon share URL for a room
        this.app.get('/api/share/:roomId', (req, res) => {
            const { roomId } = req.params;
            const { instance } = req.query;
            const room = this.rooms.get(roomId);
            const serverUrl = `${req.protocol}://${req.get('host')}`;

            if (!room) {
                return res.status(404).json({ error: 'Room not found' });
            }

            const joinUrl = `${serverUrl}/?room=${roomId}`;
            const statusText = `Join me in "${room.name}" on VoiceLink!\n\n` +
                `${room.hasPassword ? '🔒 Private room' : '🌐 Public room'}\n` +
                `👥 Up to ${room.maxUsers} users\n\n` +
                `Join: ${joinUrl}\n\n` +
                `#VoiceLink #VoiceChat`;

            // If instance provided, generate share URL for that instance
            if (instance) {
                const instanceUrl = instance.startsWith('http') ? instance : `https://${instance}`;
                const shareUrl = `${instanceUrl}/share?text=${encodeURIComponent(statusText)}`;
                res.json({ shareUrl, statusText, joinUrl });
            } else {
                // Return URLs for suggested instances
                const shareUrls = [
                    {
                        instance: 'md.tappedin.fm',
                        name: 'TappedIn',
                        shareUrl: `https://md.tappedin.fm/share?text=${encodeURIComponent(statusText)}`
                    },
                    {
                        instance: 'mastodon.devinecreations.net',
                        name: 'DevineCreations',
                        shareUrl: `https://mastodon.devinecreations.net/share?text=${encodeURIComponent(statusText)}`
                    }
                ];
                res.json({ shareUrls, statusText, joinUrl });
            }
        });

        // Room visibility sync with Mastodon
        this.app.post('/api/rooms/:roomId/visibility', (req, res) => {
            const { roomId } = req.params;
            const { visibility, allowedInstances } = req.body;
            const room = this.rooms.get(roomId);

            if (!room) {
                return res.status(404).json({ error: 'Room not found' });
            }

            // Update room visibility settings
            room.visibility = visibility; // 'public', 'unlisted', 'followers', 'direct'
            room.allowedInstances = allowedInstances || []; // Empty = all instances
            room.lastUpdated = new Date();

            this.rooms.set(roomId, room);
            this.federation.broadcastRoomChange('updated', room);

            res.json({ success: true, room });
        });

        // ========================================
        // ADMIN ROOM MANAGEMENT
        // ========================================

        // Generate default rooms
        this.app.post('/api/rooms/generate-defaults', (req, res) => {
            const defaultRooms = [
                { name: 'General Chat', maxUsers: 50, visibility: 'public' },
                { name: 'Music Lounge', maxUsers: 20, visibility: 'public' },
                { name: 'Gaming Voice', maxUsers: 10, visibility: 'public' },
                { name: 'Podcast Studio', maxUsers: 5, visibility: 'public' },
                { name: 'Chill Zone', maxUsers: 30, visibility: 'public' },
                { name: 'Tech Talk', maxUsers: 25, visibility: 'public' },
                { name: 'Creative Corner', maxUsers: 15, visibility: 'public' },
                { name: 'Late Night', maxUsers: 20, visibility: 'public' }
            ];

            const created = [];

            for (const roomConfig of defaultRooms) {
                // Check if room with same name exists
                const exists = Array.from(this.rooms.values()).some(
                    r => r.name.toLowerCase() === roomConfig.name.toLowerCase()
                );

                if (!exists) {
                    const roomId = uuidv4();
                    const room = {
                        id: roomId,
                        name: roomConfig.name,
                        password: null,
                        maxUsers: roomConfig.maxUsers,
                        users: [],
                        visibility: roomConfig.visibility,
                        isDefault: true,
                        createdAt: new Date(),
                        audioSettings: {
                            spatialAudio: true,
                            quality: 'high',
                            effects: []
                        }
                    };

                    this.rooms.set(roomId, room);
                    this.federation.broadcastRoomChange('created', room);
                    created.push(room);
                }
            }

            res.json({ success: true, count: created.length, rooms: created });
        });

        // Cleanup expired/empty rooms
        this.app.post('/api/rooms/cleanup', (req, res) => {
            const { keepDefaults = true, maxAge = 86400000 } = req.body; // 24h default
            const now = Date.now();
            let removed = 0;

            for (const [roomId, room] of this.rooms) {
                // Skip default rooms if keepDefaults is true
                if (keepDefaults && room.isDefault) continue;

                // Check if room is empty and old
                const isEmpty = !room.users || room.users.length === 0;
                const isOld = room.createdAt && (now - new Date(room.createdAt).getTime()) > maxAge;
                const isExpired = room.expiresAt && new Date(room.expiresAt).getTime() < now;

                if ((isEmpty && isOld) || isExpired) {
                    this.rooms.delete(roomId);
                    this.federation.broadcastRoomChange('deleted', { id: roomId });
                    removed++;
                }
            }

            res.json({ success: true, removed });
        });

        // Delete a specific room
        this.app.delete('/api/rooms/:roomId', (req, res) => {
            const { roomId } = req.params;
            const room = this.rooms.get(roomId);

            if (!room) {
                return res.status(404).json({ error: 'Room not found' });
            }

            // Kick all users from room
            if (room.users && room.users.length > 0) {
                this.io.to(roomId).emit('room-deleted', { reason: 'Room closed by admin' });
            }

            this.rooms.delete(roomId);
            this.federation.broadcastRoomChange('deleted', { id: roomId });

            res.json({ success: true, message: 'Room deleted' });
        });

        // Update room settings
        this.app.put('/api/rooms/:roomId', (req, res) => {
            const { roomId } = req.params;
            const updates = req.body;
            const room = this.rooms.get(roomId);

            if (!room) {
                return res.status(404).json({ error: 'Room not found' });
            }

            // Apply updates
            if (updates.name) room.name = updates.name;
            if (updates.maxUsers) room.maxUsers = updates.maxUsers;
            if (updates.visibility) room.visibility = updates.visibility;
            if (updates.password !== undefined) room.password = updates.password || null;
            if (updates.isDefault !== undefined) room.isDefault = updates.isDefault;

            room.lastUpdated = new Date();
            this.rooms.set(roomId, room);
            this.federation.broadcastRoomChange('updated', room);

            res.json({ success: true, room });
        });

        // Get federation servers
        this.app.get('/api/federation/servers', (req, res) => {
            const servers = this.federation.getConnectedServers();
            res.json(servers);
        });

        // Connect to federation server
        this.app.post('/api/federation/connect', async (req, res) => {
            const { serverUrl } = req.body;
            try {
                const result = await this.federation.connectToServer(serverUrl);
                res.json({ success: true, ...result });
            } catch (err) {
                res.status(400).json({ error: err.message });
            }
        });

        // ============================================
        // EMBED API ROUTES
        // ============================================

        // Store for embed tokens
        this.embedTokens = new Map(); // token -> { roomId, creatorHandle, permissions, expiresAt }

        // Generate embed token for a room
        this.app.post('/api/embed/token', (req, res) => {
            const { roomId, permissions = {}, expiresIn = 86400000, creatorHandle } = req.body;

            const room = this.rooms.get(roomId);
            if (!room) {
                return res.status(404).json({ error: 'Room not found' });
            }

            // Verify creator owns the room or is admin
            if (room.creatorHandle && creatorHandle !== room.creatorHandle) {
                return res.status(403).json({ error: 'Only room creator can generate embed tokens' });
            }

            // Generate secure token
            const token = uuidv4() + '-' + Date.now().toString(36);
            const tokenData = {
                roomId,
                creatorHandle,
                permissions: {
                    allowGuests: permissions.allowGuests !== false,
                    requirePassword: permissions.requirePassword || false,
                    maxUsers: permissions.maxUsers || room.maxUsers,
                    allowMic: permissions.allowMic !== false
                },
                createdAt: new Date(),
                expiresAt: new Date(Date.now() + expiresIn)
            };

            this.embedTokens.set(token, tokenData);

            // Generate embed code
            const serverUrl = req.protocol + '://' + req.get('host');
            const embedUrl = `${serverUrl}/embed.html?room=${roomId}&token=${token}`;
            const embedCode = `<iframe src="${embedUrl}" width="400" height="300" frameborder="0" allow="microphone" style="border-radius: 12px;"></iframe>`;

            res.json({
                success: true,
                token,
                embedUrl,
                embedCode,
                expiresAt: tokenData.expiresAt
            });
        });

        // Validate embed token
        this.app.post('/api/embed/validate', (req, res) => {
            const { roomId, token } = req.body;

            const tokenData = this.embedTokens.get(token);
            if (!tokenData) {
                return res.json({ valid: false, reason: 'Token not found' });
            }

            if (tokenData.roomId !== roomId) {
                return res.json({ valid: false, reason: 'Token room mismatch' });
            }

            if (new Date() > tokenData.expiresAt) {
                this.embedTokens.delete(token);
                return res.json({ valid: false, reason: 'Token expired' });
            }

            res.json({
                valid: true,
                permissions: tokenData.permissions
            });
        });

        // Get embed info for a room
        this.app.get('/api/embed/:roomId', (req, res) => {
            const room = this.rooms.get(req.params.roomId);
            if (!room) {
                return res.status(404).json({ error: 'Room not found' });
            }

            // Return limited info for embed
            res.json({
                id: room.id,
                name: room.name,
                users: room.users.length,
                maxUsers: room.maxUsers,
                hasPassword: !!room.password,
                visibility: room.visibility
            });
        });

        // Revoke embed token
        this.app.delete('/api/embed/token/:token', (req, res) => {
            const token = req.params.token;
            const creatorHandle = req.body.creatorHandle;

            const tokenData = this.embedTokens.get(token);
            if (!tokenData) {
                return res.status(404).json({ error: 'Token not found' });
            }

            // Verify ownership
            if (tokenData.creatorHandle && tokenData.creatorHandle !== creatorHandle) {
                return res.status(403).json({ error: 'Only token creator can revoke' });
            }

            this.embedTokens.delete(token);
            res.json({ success: true, message: 'Token revoked' });
        });

        // List active embed tokens for a room
        this.app.get('/api/embed/tokens/:roomId', (req, res) => {
            const roomId = req.params.roomId;
            const tokens = [];

            this.embedTokens.forEach((data, token) => {
                if (data.roomId === roomId) {
                    tokens.push({
                        token: token.substring(0, 8) + '...',
                        createdAt: data.createdAt,
                        expiresAt: data.expiresAt,
                        permissions: data.permissions
                    });
                }
            });

            res.json({ tokens });
        });

        // ============================================
        // API AUTHENTICATION ENDPOINTS
        // For external integrations (Composr, WordPress, etc.)
        // ============================================

        // Store for API keys and sessions
        this.apiKeys = new Map(); // apiKey -> { name, permissions, createdAt, createdBy }
        this.apiSessions = new Map(); // sessionToken -> { userId, apiKey, expiresAt, metadata }

        // Generate API key for external application
        this.app.post('/api/auth/keys', (req, res) => {
            const { name, permissions = [], createdBy } = req.body;

            if (!name) {
                return res.status(400).json({ error: 'Application name required' });
            }

            // Generate secure API key
            const apiKey = 'vl_' + uuidv4().replace(/-/g, '') + '_' + Date.now().toString(36);

            this.apiKeys.set(apiKey, {
                name,
                permissions: permissions.length ? permissions : ['read', 'join', 'embed'],
                createdAt: new Date(),
                createdBy,
                lastUsed: null,
                requestCount: 0
            });

            res.json({
                success: true,
                apiKey,
                name,
                permissions: this.apiKeys.get(apiKey).permissions,
                message: 'Store this API key securely - it cannot be retrieved again'
            });
        });

        // Validate API key
        this.app.post('/api/auth/validate', (req, res) => {
            const { apiKey } = req.body;

            const keyData = this.apiKeys.get(apiKey);
            if (!keyData) {
                return res.json({ valid: false, reason: 'Invalid API key' });
            }

            // Update usage stats
            keyData.lastUsed = new Date();
            keyData.requestCount++;

            res.json({
                valid: true,
                name: keyData.name,
                permissions: keyData.permissions
            });
        });

        // Create session for external user (for use with external auth systems)
        this.app.post('/api/auth/session', (req, res) => {
            const { apiKey, userId, userName, externalId, metadata = {} } = req.body;

            // Validate API key
            const keyData = this.apiKeys.get(apiKey);
            if (!keyData) {
                return res.status(401).json({ error: 'Invalid API key' });
            }

            if (!keyData.permissions.includes('auth')) {
                return res.status(403).json({ error: 'API key does not have auth permission' });
            }

            // Generate session token
            const sessionToken = 'vls_' + uuidv4() + '_' + Date.now().toString(36);

            this.apiSessions.set(sessionToken, {
                userId: userId || externalId,
                userName,
                externalId,
                apiKey,
                appName: keyData.name,
                metadata,
                createdAt: new Date(),
                expiresAt: new Date(Date.now() + 86400000) // 24 hours
            });

            res.json({
                success: true,
                sessionToken,
                expiresAt: this.apiSessions.get(sessionToken).expiresAt
            });
        });

        // Validate session and get user info
        this.app.get('/api/auth/session/:token', (req, res) => {
            const session = this.apiSessions.get(req.params.token);

            if (!session) {
                return res.json({ valid: false, reason: 'Session not found' });
            }

            if (new Date() > session.expiresAt) {
                this.apiSessions.delete(req.params.token);
                return res.json({ valid: false, reason: 'Session expired' });
            }

            res.json({
                valid: true,
                userId: session.userId,
                userName: session.userName,
                externalId: session.externalId,
                appName: session.appName,
                expiresAt: session.expiresAt
            });
        });

        // Join room with API session
        this.app.post('/api/auth/join', (req, res) => {
            const { sessionToken, roomId, password } = req.body;

            // Validate session
            const session = this.apiSessions.get(sessionToken);
            if (!session || new Date() > session.expiresAt) {
                return res.status(401).json({ error: 'Invalid or expired session' });
            }

            // Find room
            const room = this.rooms.get(roomId);
            if (!room) {
                return res.status(404).json({ error: 'Room not found' });
            }

            // Check password if required
            if (room.password && room.password !== password) {
                return res.status(403).json({ error: 'Invalid password' });
            }

            // Check room capacity
            if (room.users.length >= room.maxUsers) {
                return res.status(403).json({ error: 'Room is full' });
            }

            // Generate join token for WebSocket connection
            const joinToken = 'vlj_' + uuidv4();

            res.json({
                success: true,
                joinToken,
                roomId,
                roomName: room.name,
                currentUsers: room.users.length,
                maxUsers: room.maxUsers,
                socketUrl: '/socket.io',
                message: 'Use joinToken when connecting via WebSocket'
            });
        });

        // List API keys (admin only - requires master key or admin session)
        this.app.get('/api/auth/keys', (req, res) => {
            const keys = [];
            this.apiKeys.forEach((data, key) => {
                keys.push({
                    keyPrefix: key.substring(0, 12) + '...',
                    name: data.name,
                    permissions: data.permissions,
                    createdAt: data.createdAt,
                    lastUsed: data.lastUsed,
                    requestCount: data.requestCount
                });
            });
            res.json({ keys });
        });

        // Revoke API key
        this.app.delete('/api/auth/keys/:keyPrefix', (req, res) => {
            const prefix = req.params.keyPrefix;
            let deleted = false;

            this.apiKeys.forEach((data, key) => {
                if (key.startsWith(prefix)) {
                    this.apiKeys.delete(key);
                    // Also delete all sessions using this key
                    this.apiSessions.forEach((session, token) => {
                        if (session.apiKey === key) {
                            this.apiSessions.delete(token);
                        }
                    });
                    deleted = true;
                }
            });

            if (deleted) {
                res.json({ success: true, message: 'API key revoked' });
            } else {
                res.status(404).json({ error: 'API key not found' });
            }
        });

        // ============================================
        // JELLYFIN MEDIA STREAMING INTEGRATION
        // Stream audio/video from Jellyfin into rooms
        // ============================================

        // Jellyfin server configurations
        this.jellyfinServers = new Map(); // serverId -> { url, apiKey, name }
        this.roomMediaStreams = new Map(); // roomId -> { serverId, itemId, type, startedAt, startedBy }
        this.mediaQueues = new Map(); // roomId -> [{ itemId, title, type, addedBy }]

        // Add/configure Jellyfin server
        this.app.post('/api/jellyfin/servers', (req, res) => {
            const { name, url, apiKey } = req.body;

            if (!name || !url || !apiKey) {
                return res.status(400).json({ error: 'Name, URL, and API key required' });
            }

            const serverId = 'jf_' + Date.now().toString(36);
            this.jellyfinServers.set(serverId, {
                name,
                url: url.replace(/\/$/, ''), // Remove trailing slash
                apiKey,
                addedAt: new Date()
            });

            res.json({ success: true, serverId, name });
        });

        // List configured Jellyfin servers
        this.app.get('/api/jellyfin/servers', (req, res) => {
            const servers = [];
            this.jellyfinServers.forEach((data, id) => {
                servers.push({
                    id,
                    name: data.name,
                    url: data.url,
                    addedAt: data.addedAt
                });
            });
            res.json({ servers });
        });

        // Browse Jellyfin library
        this.app.get('/api/jellyfin/:serverId/library', async (req, res) => {
            const server = this.jellyfinServers.get(req.params.serverId);
            if (!server) {
                return res.status(404).json({ error: 'Jellyfin server not found' });
            }

            try {
                const parentId = req.query.parentId || '';
                const type = req.query.type || ''; // Audio, Video, MusicAlbum, etc.

                let endpoint = `${server.url}/Items`;
                const params = new URLSearchParams({
                    api_key: server.apiKey,
                    Recursive: 'true',
                    Fields: 'Overview,MediaStreams',
                    Limit: req.query.limit || '50'
                });

                if (parentId) params.append('ParentId', parentId);
                if (type) params.append('IncludeItemTypes', type);

                const response = await fetch(`${endpoint}?${params}`);
                const data = await response.json();

                res.json({
                    items: data.Items?.map(item => ({
                        id: item.Id,
                        name: item.Name,
                        type: item.Type,
                        mediaType: item.MediaType,
                        duration: item.RunTimeTicks ? Math.floor(item.RunTimeTicks / 10000000) : null,
                        artist: item.AlbumArtist || item.Artists?.[0],
                        album: item.Album,
                        year: item.ProductionYear,
                        imageUrl: item.ImageTags?.Primary ?
                            `${server.url}/Items/${item.Id}/Images/Primary?api_key=${server.apiKey}` : null
                    })) || [],
                    totalCount: data.TotalRecordCount
                });
            } catch (error) {
                res.status(500).json({ error: 'Failed to fetch library: ' + error.message });
            }
        });

        // Search Jellyfin library
        this.app.get('/api/jellyfin/:serverId/search', async (req, res) => {
            const server = this.jellyfinServers.get(req.params.serverId);
            if (!server) {
                return res.status(404).json({ error: 'Jellyfin server not found' });
            }

            try {
                const query = req.query.q || '';
                const type = req.query.type || 'Audio,MusicAlbum,Video';

                const params = new URLSearchParams({
                    api_key: server.apiKey,
                    SearchTerm: query,
                    IncludeItemTypes: type,
                    Limit: '25',
                    Fields: 'Overview,MediaStreams'
                });

                const response = await fetch(`${server.url}/Items?${params}`);
                const data = await response.json();

                res.json({
                    results: data.Items?.map(item => ({
                        id: item.Id,
                        name: item.Name,
                        type: item.Type,
                        mediaType: item.MediaType,
                        duration: item.RunTimeTicks ? Math.floor(item.RunTimeTicks / 10000000) : null,
                        artist: item.AlbumArtist || item.Artists?.[0],
                        imageUrl: item.ImageTags?.Primary ?
                            `${server.url}/Items/${item.Id}/Images/Primary?api_key=${server.apiKey}` : null
                    })) || []
                });
            } catch (error) {
                res.status(500).json({ error: 'Search failed: ' + error.message });
            }
        });

        // Get stream URL for an item
        this.app.get('/api/jellyfin/:serverId/stream/:itemId', async (req, res) => {
            const server = this.jellyfinServers.get(req.params.serverId);
            if (!server) {
                return res.status(404).json({ error: 'Jellyfin server not found' });
            }

            const itemId = req.params.itemId;
            const audioCodec = req.query.audioCodec || 'mp3';
            const container = req.query.container || 'mp3';

            // Generate streaming URLs
            const audioStreamUrl = `${server.url}/Audio/${itemId}/universal?api_key=${server.apiKey}&AudioCodec=${audioCodec}&Container=${container}&TranscodingContainer=${container}&TranscodingProtocol=http`;
            const videoStreamUrl = `${server.url}/Videos/${itemId}/stream?api_key=${server.apiKey}&Static=true`;
            const hlsStreamUrl = `${server.url}/Videos/${itemId}/master.m3u8?api_key=${server.apiKey}`;

            res.json({
                audioStream: audioStreamUrl,
                videoStream: videoStreamUrl,
                hlsStream: hlsStreamUrl,
                directPlay: `${server.url}/Items/${itemId}/Download?api_key=${server.apiKey}`
            });
        });

        // Start streaming media to a room
        this.app.post('/api/jellyfin/stream-to-room', (req, res) => {
            const { serverId, itemId, roomId, type = 'audio', startedBy = 'Jukebox' } = req.body;

            const server = this.jellyfinServers.get(serverId);
            if (!server) {
                return res.status(404).json({ error: 'Jellyfin server not found' });
            }

            const room = this.rooms.get(roomId);
            if (!room) {
                return res.status(404).json({ error: 'Room not found' });
            }

            // Store active stream info
            this.roomMediaStreams.set(roomId, {
                serverId,
                itemId,
                type,
                startedAt: new Date(),
                startedBy,
                serverUrl: server.url,
                apiKey: server.apiKey
            });

            // Build stream URL
            let streamUrl;
            if (type === 'audio') {
                streamUrl = `${server.url}/Audio/${itemId}/universal?api_key=${server.apiKey}&AudioCodec=mp3&Container=mp3`;
            } else {
                streamUrl = `${server.url}/Videos/${itemId}/master.m3u8?api_key=${server.apiKey}`;
            }

            // Notify room users
            this.io.to(roomId).emit('media-stream-started', {
                type,
                streamUrl,
                itemId,
                startedBy
            });

            res.json({
                success: true,
                streamUrl,
                message: `${type} stream started in room`
            });
        });

        // Stop streaming media in a room
        this.app.post('/api/jellyfin/stop-stream', (req, res) => {
            const { roomId } = req.body;

            if (!this.roomMediaStreams.has(roomId)) {
                return res.status(404).json({ error: 'No active stream in room' });
            }

            this.roomMediaStreams.delete(roomId);

            // Notify room users
            this.io.to(roomId).emit('media-stream-stopped', { roomId });

            res.json({ success: true, message: 'Stream stopped' });
        });

        // Get active stream for a room
        this.app.get('/api/jellyfin/room-stream/:roomId', (req, res) => {
            const stream = this.roomMediaStreams.get(req.params.roomId);
            if (!stream) {
                return res.json({ active: false });
            }

            let streamUrl;
            if (stream.type === 'audio') {
                streamUrl = `${stream.serverUrl}/Audio/${stream.itemId}/universal?api_key=${stream.apiKey}&AudioCodec=mp3&Container=mp3`;
            } else {
                streamUrl = `${stream.serverUrl}/Videos/${stream.itemId}/master.m3u8?api_key=${stream.apiKey}`;
            }

            res.json({
                active: true,
                type: stream.type,
                streamUrl,
                startedAt: stream.startedAt,
                startedBy: stream.startedBy
            });
        });

        // Add to room queue
        this.app.post('/api/jellyfin/queue', (req, res) => {
            const { roomId, serverId, itemId, title, type, addedBy = 'Jukebox' } = req.body;

            if (!this.mediaQueues.has(roomId)) {
                this.mediaQueues.set(roomId, []);
            }

            const queue = this.mediaQueues.get(roomId);
            queue.push({
                serverId,
                itemId,
                title,
                type,
                addedBy,
                addedAt: new Date()
            });

            // Notify room
            this.io.to(roomId).emit('queue-updated', { queue });

            res.json({ success: true, queueLength: queue.length });
        });

        // Get room queue
        this.app.get('/api/jellyfin/queue/:roomId', (req, res) => {
            const queue = this.mediaQueues.get(req.params.roomId) || [];
            res.json({ queue });
        });

        // Clear room queue
        this.app.delete('/api/jellyfin/queue/:roomId', (req, res) => {
            this.mediaQueues.delete(req.params.roomId);
            this.io.to(req.params.roomId).emit('queue-updated', { queue: [] });
            res.json({ success: true });
        });

        // Wrapper: Browse library with serverId as query param (for JukeboxManager)
        this.app.get('/api/jellyfin/library', async (req, res) => {
            const serverId = req.query.serverId;
            const server = this.jellyfinServers.get(serverId);
            if (!server) {
                return res.json({ success: false, error: 'Jellyfin server not found', items: [] });
            }

            try {
                const parentId = req.query.parentId || '';
                const type = req.query.type || '';

                let endpoint = `${server.url}/Items`;
                const params = new URLSearchParams({
                    api_key: server.apiKey,
                    Recursive: parentId ? 'false' : 'true',
                    Fields: 'Overview,MediaStreams',
                    SortBy: 'SortName',
                    SortOrder: 'Ascending',
                    Limit: req.query.limit || '100'
                });

                if (parentId) params.append('ParentId', parentId);
                if (type) params.append('IncludeItemTypes', type);

                const response = await fetch(`${endpoint}?${params}`);
                const data = await response.json();

                res.json({
                    success: true,
                    items: data.Items || []
                });
            } catch (error) {
                res.json({ success: false, error: error.message, items: [] });
            }
        });

        // Wrapper: Search library with serverId as query param (for JukeboxManager)
        this.app.get('/api/jellyfin/search', async (req, res) => {
            const serverId = req.query.serverId;
            const server = this.jellyfinServers.get(serverId);
            if (!server) {
                return res.json({ success: false, error: 'Jellyfin server not found', items: [] });
            }

            try {
                const query = req.query.query || req.query.q || '';
                const type = req.query.type || 'Audio,MusicAlbum,Video,Movie,Episode';

                const params = new URLSearchParams({
                    api_key: server.apiKey,
                    SearchTerm: query,
                    IncludeItemTypes: type,
                    Limit: '50',
                    Fields: 'Overview,MediaStreams'
                });

                const response = await fetch(`${server.url}/Items?${params}`);
                const data = await response.json();

                res.json({
                    success: true,
                    items: data.Items || []
                });
            } catch (error) {
                res.json({ success: false, error: error.message, items: [] });
            }
        });

        // Wrapper: Get stream URL (POST for JukeboxManager)
        this.app.post('/api/jellyfin/stream-url', async (req, res) => {
            const { serverId, itemId, type = 'audio' } = req.body;
            const server = this.jellyfinServers.get(serverId);

            if (!server) {
                return res.json({ success: false, error: 'Jellyfin server not found' });
            }

            try {
                let streamUrl;
                if (type === 'audio') {
                    streamUrl = `${server.url}/Audio/${itemId}/universal?api_key=${server.apiKey}&AudioCodec=mp3&Container=mp3&TranscodingContainer=mp3&TranscodingProtocol=http`;
                } else {
                    streamUrl = `${server.url}/Videos/${itemId}/stream?api_key=${server.apiKey}&Static=true`;
                }

                res.json({
                    success: true,
                    streamUrl,
                    directPlay: `${server.url}/Items/${itemId}/Download?api_key=${server.apiKey}`
                });
            } catch (error) {
                res.json({ success: false, error: error.message });
            }
        });

        // Setup Mastodon bot routes
        this.mastodonBot.setupRoutes(this.app);
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

            // ==================== Jukebox (Jellyfin) Handlers ====================

            // Jukebox play - broadcast to room
            socket.on('jukebox-play', (data) => {
                const user = this.users.get(socket.id);
                if (user && data.roomId) {
                    socket.to(data.roomId).emit('jukebox-play', {
                        track: data.track,
                        position: data.position,
                        startedBy: user.name || 'Jukebox'
                    });
                }
            });

            // Jukebox pause - broadcast to room
            socket.on('jukebox-pause', (data) => {
                const user = this.users.get(socket.id);
                if (user && data.roomId) {
                    socket.to(data.roomId).emit('jukebox-pause', {
                        pausedBy: user.name || 'Jukebox'
                    });
                }
            });

            // Jukebox skip - broadcast to room
            socket.on('jukebox-skip', (data) => {
                const user = this.users.get(socket.id);
                if (user && data.roomId) {
                    socket.to(data.roomId).emit('jukebox-skip', {
                        index: data.index,
                        skippedBy: user.name || 'Jukebox'
                    });
                }
            });

            // Jukebox queue update - broadcast to room
            socket.on('jukebox-queue-update', (data) => {
                const user = this.users.get(socket.id);
                if (user && data.roomId) {
                    socket.to(data.roomId).emit('jukebox-queue-update', {
                        queue: data.queue,
                        updatedBy: user.name || 'Jukebox'
                    });
                }
            });

            // ==================== Audio Relay Handlers ====================

            // Enable/disable audio relay for this user
            socket.on('enable-audio-relay', (data) => {
                const { enabled, sampleRate, channels } = data;
                this.audioRelayEnabled.set(socket.id, enabled);

                if (enabled) {
                    this.relayStats.activeRelays++;
                    console.log(`Audio relay enabled for ${socket.id}`);

                    // Initialize audio buffer for this user
                    this.audioBuffers.set(socket.id, {
                        sampleRate: sampleRate || 48000,
                        channels: channels || 2,
                        buffer: []
                    });
                } else {
                    this.relayStats.activeRelays = Math.max(0, this.relayStats.activeRelays - 1);
                    this.audioBuffers.delete(socket.id);
                    console.log(`Audio relay disabled for ${socket.id}`);
                }

                socket.emit('relay-status', {
                    active: enabled,
                    stats: this.relayStats
                });
            });

            // Receive audio data from client and relay to room
            socket.on('audio-data', (data) => {
                const user = this.users.get(socket.id);
                if (!user || !this.audioRelayEnabled.get(socket.id)) {
                    return;
                }

                const { audioData, timestamp, sampleRate } = data;

                // Update stats
                this.relayStats.packetsRelayed++;
                if (audioData && audioData.length) {
                    this.relayStats.bytesRelayed += audioData.length;
                }

                // Relay audio to all other users in the room who have relay enabled
                const room = this.rooms.get(user.roomId);
                if (room) {
                    room.users.forEach(roomUser => {
                        if (roomUser.id !== socket.id && this.audioRelayEnabled.get(roomUser.id)) {
                            this.io.to(roomUser.id).emit('relayed-audio', {
                                userId: socket.id,
                                userName: user.name,
                                audioData: audioData,
                                timestamp: timestamp,
                                sampleRate: sampleRate
                            });
                        }
                    });
                }
            });

            // Get relay statistics
            socket.on('get-relay-stats', () => {
                socket.emit('relay-stats', this.relayStats);
            });

            // Request P2P fallback notification (when P2P connection fails)
            socket.on('p2p-connection-failed', (data) => {
                const { targetUserId, reason } = data;
                console.log(`P2P connection failed between ${socket.id} and ${targetUserId}: ${reason}`);

                // Notify both users to use relay mode
                socket.emit('p2p-fallback-needed', { userId: targetUserId });
                this.io.to(targetUserId).emit('p2p-fallback-needed', { userId: socket.id });
            });

            // Connection mode query
            socket.on('get-connection-info', () => {
                const user = this.users.get(socket.id);
                socket.emit('connection-info', {
                    userId: socket.id,
                    relayEnabled: this.audioRelayEnabled.get(socket.id) || false,
                    roomId: user?.roomId,
                    serverRelay: {
                        available: true,
                        stats: this.relayStats
                    }
                });
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

                // Clean up audio relay state
                if (this.audioRelayEnabled.get(socket.id)) {
                    this.relayStats.activeRelays = Math.max(0, this.relayStats.activeRelays - 1);
                }
                this.audioRelayEnabled.delete(socket.id);
                this.audioBuffers.delete(socket.id);

                console.log(`User disconnected: ${socket.id}`);
            });
        });
    }

    start() {
        const PORT = process.env.PORT || 3010;
        // Start room expiration check interval (every 10 seconds)
        this.startRoomExpirationChecker();

        this.server.listen(PORT, () => {
            console.log(`VoiceLink Local Server running on http://localhost:${PORT}`);
            console.log('Ready for P2P and server relay voice chat!');
            console.log('Connection modes: p2p (direct), relay (server), auto (fallback)');
        });
    }

    /**
     * Start the room expiration checker
     * Checks every 10 seconds for:
     * - Rooms that need warning (2 min, 30 sec before expiration)
     * - Rooms that have expired
     */
    startRoomExpirationChecker() {
        const CHECK_INTERVAL = 10 * 1000; // 10 seconds
        const WARNING_2MIN = 2 * 60 * 1000; // 2 minutes
        const WARNING_30SEC = 30 * 1000; // 30 seconds

        setInterval(() => {
            const now = Date.now();

            for (const [roomId, room] of this.rooms) {
                if (!room.expiresAt || !room.isGuestRoom) continue;

                const expiresAt = new Date(room.expiresAt).getTime();
                const timeRemaining = expiresAt - now;

                // Room has expired
                if (timeRemaining <= 0) {
                    console.log(`Guest room expired: ${roomId}`);
                    this.expireRoom(roomId);
                    continue;
                }

                // 2-minute warning (only send once)
                if (timeRemaining <= WARNING_2MIN && !room.warned2Min) {
                    room.warned2Min = true;
                    this.sendRoomWarning(roomId, 'Room will expire in 2 minutes. Login to keep rooms permanently!', timeRemaining);
                }

                // 30-second warning (only send once)
                if (timeRemaining <= WARNING_30SEC && !room.warned30Sec) {
                    room.warned30Sec = true;
                    this.sendRoomWarning(roomId, 'Room will expire in 30 seconds!', timeRemaining);
                }
            }
        }, CHECK_INTERVAL);

        console.log('Room expiration checker started');
    }

    /**
     * Send a warning to all users in a room
     */
    sendRoomWarning(roomId, message, timeRemaining) {
        const room = this.rooms.get(roomId);
        if (!room) return;

        // Emit warning to all sockets in the room
        this.io.to(roomId).emit('room-expiring', {
            roomId,
            message,
            timeRemaining,
            expiresAt: room.expiresAt
        });

        console.log(`Room warning sent to ${roomId}: ${message}`);
    }

    /**
     * Expire a room - disconnect all users and remove the room
     */
    expireRoom(roomId) {
        const room = this.rooms.get(roomId);
        if (!room) return;

        // Notify all users in the room
        this.io.to(roomId).emit('room-expired', {
            roomId,
            message: 'This guest room has expired. Login with Mastodon for unlimited room time!'
        });

        // Disconnect all sockets from the room
        const socketsInRoom = this.io.sockets.adapter.rooms.get(roomId);
        if (socketsInRoom) {
            for (const socketId of socketsInRoom) {
                const socket = this.io.sockets.sockets.get(socketId);
                if (socket) {
                    socket.leave(roomId);
                    socket.emit('forced-leave', {
                        reason: 'Room expired',
                        roomId
                    });
                }
            }
        }

        // Remove the room
        this.rooms.delete(roomId);
        this.federation.broadcastRoomChange('deleted', { id: roomId });

        console.log(`Guest room ${roomId} has been expired and removed`);
    }
}

// Start the server
new VoiceLinkLocalServer();

module.exports = VoiceLinkLocalServer;