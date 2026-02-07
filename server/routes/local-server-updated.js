#!/usr/bin/env node

const express = require('express');
const http = require('http');
const socketIo = require('socket.io');
const cors = require('cors');
const fs = require('fs').promises;
const path = require('path');
const { v4: uuidv4 } = require('uuid');

// Import modules
const { ModuleRegistry } = require('../modules/module-registry');
const { FederationManager } = require('../utils/federation-manager');
const { MastodonBot } = require('../utils/mastodon-bot');
const { SupportSystemModule } = require('../modules/support-system');

class VoiceLinkLocalServer {
    constructor() {
        this.app = express();
        this.server = null;
        this.io = null;
        this.port = null;
        this.clients = new Map();
        this.rooms = new Map();
        
        // Module system
        this.modules = {
            moduleRegistry: null,
            federationManager: null,
            mastodonBot: null,
            supportSystem: null,
            emailTransport: null // Set up email transport if configured
        };

        // Initialize
        this.setupMiddleware();
        this.initializeModules();
        this.setupRoutes();
        this.startServerWithAutoDetection();
    }

    setupMiddleware() {
        this.app.use(cors({
            origin: ['http://localhost:4000', 'http://localhost:4001', 'http://localhost:4002', 
                    'http://localhost:4003', 'http://localhost:4004', 'http://localhost:4005',
                    'http://localhost:4006', 'http://localhost:4007', 'http://localhost:4008',
                    'http://localhost:4009', 'http://localhost:3000', 'http://localhost:3001',
                    'http://127.0.0.1:*', 'file://*'],
            credentials: true
        }));

        this.app.use(express.json({ limit: '10mb' }));
        this.app.use(express.urlencoded({ extended: true, limit: '10mb' }));
        this.app.use(express.static(path.join(__dirname, '../../client')));
    }

    initializeModules() {
        this.modules.moduleRegistry = new ModuleRegistry();
        
        // Initialize Support System module if installed
        if (this.modules.moduleRegistry.isModuleEnabled('support-system')) {
            const config = this.modules.moduleRegistry.getModule('support-system')?.config;
            this.modules.supportSystem = new SupportSystemModule({
                dataDir: path.join(__dirname, '../../data/support'),
                webUrl: 'http://localhost:3010', // This will be updated with actual port
                emailTransport: null
            });
            console.log('[Modules] Support System module initialized');
        }
    }

    async startServerWithAutoDetection() {
        const portSequence = [
            parseInt(process.env.PORT) || 3010,
            3010, 3001, 3002, 3003, 3004, 3005,
            4000, 4001, 4002, 4003, 4004, 4005,
            5000, 5001, 5002, 8080, 8081
        ];

        for (let i = 0; i < portSequence.length; i++) {
            const port = portSequence[i];
            
            try {
                const isAvailable = await this.checkPortAvailable(port);
                if (isAvailable) {
                    await this.startServer(port);
                    console.log(`✅ VoiceLink server started successfully on port ${port}`);
                    
                    // Update module configurations with actual port
                    if (this.modules.supportSystem) {
                        this.modules.supportSystem.config.webUrl = `http://localhost:${port}`;
                    }
                    
                    return;
                }
            } catch (error) {
                console.log(`❌ Port ${port} not available: ${error.message}`);
            }
        }
        
        throw new Error('❌ No available ports found! Please check system permissions.');
    }

    async checkPortAvailable(port) {
        return new Promise((resolve, reject) => {
            const testServer = http.createServer();
            
            testServer.listen(port, 'localhost', () => {
                testServer.close(() => {
                    resolve(true);
                });
            });
            
            testServer.on('error', (error) => {
                if (error.code === 'EADDRINUSE') {
                    resolve(false);
                } else {
                    reject(error);
                }
            });
            
            // Timeout after 2 seconds
            setTimeout(() => {
                testServer.close();
                resolve(false);
            }, 2000);
        });
    }

    async startServer(port) {
        return new Promise((resolve, reject) => {
            this.server = http.createServer(this.app);
            this.io = socketIo(this.server, {
                cors: {
                    origin: "*",
                    methods: ["GET", "POST"],
                    credentials: true
                }
            });

            this.port = port;
            
            this.server.listen(port, 'localhost', () => {
                console.log(`🚀 VoiceLink Local Server running on http://localhost:${port}`);
                this.setupSocketIO();
                resolve(port);
            });

            this.server.on('error', (error) => {
                console.error(`❌ Failed to start server on port ${port}:`, error.message);
                reject(error);
            });
        });
    }

    setupSocketIO() {
        this.io.on('connection', (socket) => {
            console.log('🔌 Client connected:', socket.id);
            this.clients.set(socket.id, {
                socket,
                user: null,
                room: null,
                joinedAt: new Date()
            });

            // Send current server info immediately
            socket.emit('server-info', {
                port: this.port,
                url: `http://localhost:${this.port}`,
                timestamp: new Date().toISOString()
            });

            // Basic socket events
            socket.on('join-room', (data) => {
                this.handleJoinRoom(socket, data);
            });

            socket.on('leave-room', (data) => {
                this.handleLeaveRoom(socket, data);
            });

            socket.on('voice-data', (data) => {
                this.handleVoiceData(socket, data);
            });

            socket.on('disconnect', () => {
                this.handleDisconnect(socket);
            });

            // Port detection API
            socket.on('get-server-info', () => {
                socket.emit('server-info', {
                    port: this.port,
                    url: `http://localhost:${this.port}`,
                    timestamp: new Date().toISOString()
                });
            });
        });
    }

    handleJoinRoom(socket, data) {
        const { roomId, userName } = data;
        
        if (!this.rooms.has(roomId)) {
            this.rooms.set(roomId, {
                id: roomId,
                name: `Room ${roomId}`,
                users: new Map(),
                createdAt: new Date()
            });
        }

        const room = this.rooms.get(roomId);
        const client = this.clients.get(socket.id);
        
        client.user = { id: socket.id, name: userName || `User${socket.id.slice(0, 4)}` };
        client.room = roomId;
        
        room.users.set(socket.id, client.user);
        
        socket.join(roomId);
        socket.emit('room-joined', { 
            roomId, 
            user: client.user, 
            port: this.port 
        });
        
        this.broadcastToRoom(roomId, 'user-joined', { user: client.user }, socket.id);
    }

    handleLeaveRoom(socket, data) {
        const client = this.clients.get(socket.id);
        if (!client || !client.room) return;

        const room = this.rooms.get(client.room);
        if (room) {
            room.users.delete(socket.id);
            this.broadcastToRoom(client.room, 'user-left', { user: client.user }, socket.id);
            
            if (room.users.size === 0) {
                this.rooms.delete(client.room);
            }
        }

        socket.leave(client.room);
        client.room = null;
        socket.emit('room-left', { roomId: client.room });
    }

    handleVoiceData(socket, data) {
        const client = this.clients.get(socket.id);
        if (!client || !client.room) return;

        this.broadcastToRoom(client.room, 'voice-data', {
            userId: socket.id,
            userName: client.user.name,
            data: data.data,
            timestamp: new Date().toISOString()
        }, socket.id);
    }

    handleDisconnect(socket) {
        const client = this.clients.get(socket.id);
        if (!client) return;

        if (client.room) {
            const room = this.rooms.get(client.room);
            if (room) {
                room.users.delete(socket.id);
                this.broadcastToRoom(client.room, 'user-left', { user: client.user }, socket.id);
                
                if (room.users.size === 0) {
                    this.rooms.delete(client.room);
                }
            }
        }

        this.clients.delete(socket.id);
        console.log('🔌 Client disconnected:', socket.id);
    }

    broadcastToRoom(roomId, event, data, excludeSocketId = null) {
        const room = this.rooms.get(roomId);
        if (!room) return;

        room.users.forEach((user, socketId) => {
            if (socketId !== excludeSocketId) {
                const client = this.clients.get(socketId);
                if (client && client.socket) {
                    client.socket.emit(event, data);
                }
            }
        });
    }

    setupRoutes() {
        // Enhanced API routes for port detection
        this.app.get('/api/status', (req, res) => {
            res.json({
                status: 'running',
                port: this.port,
                url: `http://localhost:${this.port}`,
                rooms: Array.from(this.rooms.values()).map(room => ({
                    id: room.id,
                    name: room.name,
                    userCount: room.users.size,
                    createdAt: room.createdAt
                })),
                clients: this.clients.size,
                timestamp: new Date().toISOString(),
                uptime: process.uptime()
            });
        });

        this.app.get('/api/server-info', (req, res) => {
            res.json({
                port: this.port,
                url: `http://localhost:${this.port}`,
                autoDetection: true,
                timestamp: new Date().toISOString()
            });
        });

        this.app.get('/api/rooms', (req, res) => {
            res.json({
                rooms: Array.from(this.rooms.values()).map(room => ({
                    id: room.id,
                    name: room.name,
                    userCount: room.users.size,
                    users: Array.from(room.users.values()),
                    createdAt: room.createdAt
                }))
            });
        });

        this.app.get('/api/port-scan', async (req, res) => {
            const scanPorts = [3000, 3001, 3002, 3010, 4000, 4001, 4002, 4003, 4004, 4005];
            const availablePorts = [];

            for (const port of scanPorts) {
                try {
                    const isAvailable = await this.checkPortAvailable(port);
                    availablePorts.push({ port, available: isAvailable });
                } catch (error) {
                    availablePorts.push({ port, available: false, error: error.message });
                }
            }

            res.json({
                currentPort: this.port,
                availablePorts,
                timestamp: new Date().toISOString()
            });
        });

        // Health check
        this.app.get('/health', (req, res) => {
            res.json({
                status: 'healthy',
                port: this.port,
                uptime: process.uptime(),
                memory: process.memoryUsage(),
                timestamp: new Date().toISOString()
            });
        });

        // Legacy routes (keep compatibility)
        this.app.get('/', (req, res) => {
            res.sendFile(path.join(__dirname, '../../client/index.html'));
        });
    }
}

// Graceful shutdown
process.on('SIGINT', () => {
    console.log('🛑 Received SIGINT, shutting down gracefully...');
    process.exit(0);
});

process.on('SIGTERM', () => {
    console.log('🛑 Received SIGTERM, shutting down gracefully...');
    process.exit(0);
});

module.exports = VoiceLinkLocalServer;