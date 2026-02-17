const express = require('express');
const http = require('http');
const https = require('https');
const socketIo = require('socket.io');
const path = require('path');
const cors = require('cors');
const fs = require('fs');
const os = require('os');
const { spawn } = require('child_process');
const { v4: uuidv4 } = require('uuid');
const FederationManager = require('../utils/federation-manager');
const MastodonBotManager = require('../utils/mastodon-bot');
const { deployConfig, PRESETS } = require('../config/deploy-config');
const { ModuleRegistry } = require('../modules/module-registry');
const { TwoFactorAuthModule } = require('../modules/two-factor-auth');
const { SupportSystemModule } = require('../modules/support-system');
const { VMManagerModule } = require('../modules/vm-manager');
const { WHMCSIntegrationModule } = require('../modules/whmcs-integration');
const { MediaRoomsModule } = require('../modules/media-rooms');
const { UpdaterModule } = require('../modules/updater');
const InternalScheduler = require('../services/internal-scheduler');
const RoleMapper = require('../services/role-mapper');
const JellyfinServiceManager = require('../utils/jellyfin-service-manager');
const fileTransferRoutes = require('./file-transfer');

// Stripe integration - lazy loaded if configured
let stripe = null;
const initStripe = () => {
    if (!stripe) {
        const stripeConfig = deployConfig.get('stripe');
        if (stripeConfig && stripeConfig.secretKey) {
            try {
                stripe = require('stripe')(stripeConfig.secretKey);
                console.log('[Stripe] Initialized successfully');
            } catch (e) {
                console.warn('[Stripe] Failed to initialize:', e.message);
            }
        }
    }
    return stripe;
};

// Main signal server URL
const MAIN_SERVER_URL = 'https://voicelink.devinecreations.net';

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

        // Initialize Jellyfin service manager
        this.jellyfinManager = new JellyfinServiceManager();
        this.setupJellyfinManagement();
        this.jellyfinManager.startMonitoring();

        // Authenticated users (Mastodon OAuth)
        this.authenticatedUsers = new Map(); // socketId -> mastodon user info

        // Message persistence storage
        // Key: roomId, Value: array of messages
        this.roomMessages = new Map();
        // Key: `${senderId}_${receiverId}` (sorted), Value: array of DMs
        this.directMessages = new Map();
        this.joinTokens = new Map(); // joinToken -> session-bound identity
        this.roomAgents = new Map(); // roomId -> { enabled, statusText, agentId, agentName, roomScoped }
        this.agentPolicy = this.loadAgentPolicy();
        this.soundFileLookup = new Map();
        this.pushoverConfig = this.loadPushoverConfig();
        this.pendingPushoverActivation = null;
        this.notificationInbox = [];
        // Guest message expiry (24 hours in milliseconds)
        this.GUEST_MESSAGE_EXPIRY = 24 * 60 * 60 * 1000;
        // Start guest message cleanup interval (run every hour)
        this.startGuestMessageCleanup();

        // Initialize module registry and modules
        this.moduleRegistry = new ModuleRegistry(path.join(__dirname, '../../data'));
        this.modules = {
            twoFactorAuth: null,
            supportSystem: null,
            vmManager: null,
            whmcsIntegration: null,
            mediaRooms: null,
            updater: null,
            internalScheduler: null
        };
        this.initializeModules();

        this.setupMiddleware();
        this.setupRoutes();
        this.setupSocketHandlers();
        this.start();
    }

    /**
     * Initialize installed modules
     */
    initializeModules() {
        console.log('[Modules] Initializing installed modules...');

        // Initialize 2FA module if installed
        if (this.moduleRegistry.isModuleEnabled('two-factor-auth')) {
            const config = this.moduleRegistry.getModule('two-factor-auth')?.config;
            this.modules.twoFactorAuth = new TwoFactorAuthModule({
                config,
                dataDir: path.join(__dirname, '../../data/2fa'),
                emailTransport: null // Set up email transport if configured
            });
            console.log('[Modules] 2FA module initialized');
        }

        // Initialize Support System module if installed
        if (this.moduleRegistry.isModuleEnabled('support-system')) {
            const config = this.moduleRegistry.getModule('support-system')?.config;
            this.modules.supportSystem = new SupportSystemModule({
                config,
                dataDir: path.join(__dirname, '../../data/support'),
                io: this.io,
                emailTransport: null
            });
            console.log('[Modules] Support System module initialized');
        }

        // Initialize VM Manager module if installed
        if (this.moduleRegistry.isModuleEnabled('vm-manager')) {
            const config = this.moduleRegistry.getModule('vm-manager')?.config;
            this.modules.vmManager = new VMManagerModule({
                config,
                dataDir: path.join(__dirname, '../../data/vm-manager')
            });
            console.log('[Modules] VM Manager module initialized');
        }

        // Initialize WHMCS Integration module if installed
        if (this.moduleRegistry.isModuleEnabled('whmcs-integration')) {
            const config = this.moduleRegistry.getModule('whmcs-integration')?.config;
            this.modules.whmcsIntegration = new WHMCSIntegrationModule({
                config,
                dataDir: path.join(__dirname, '../../data/whmcs'),
                vmManager: this.modules.vmManager
            });
            // Link VM Manager to WHMCS
            if (this.modules.vmManager) {
                this.modules.vmManager.setWHMCSModule(this.modules.whmcsIntegration);
            }
            console.log('[Modules] WHMCS Integration module initialized');
        }

        // Initialize Media Rooms module (always enabled - core feature)
        try {
            this.modules.mediaRooms = new MediaRoomsModule({
                config: this.moduleRegistry.getModule('media-rooms')?.config || {},
                dataDir: path.join(__dirname, '../../data/media-rooms'),
                server: this
            });
            console.log('[Modules] Media Rooms module initialized');
        } catch (e) {
            console.error('[Modules] Failed to initialize Media Rooms:', e.message);
        }

        // Initialize Updater module (always enabled - core feature)
        try {
            this.modules.updater = new UpdaterModule({
                config: this.moduleRegistry.getModule('updater')?.config || {},
                dataDir: path.join(__dirname, '../../data/updater'),
                server: this
            });
            console.log('[Modules] Updater module initialized');
        } catch (e) {
            console.error('[Modules] Failed to initialize Updater:', e.message);
        }

        // Initialize Internal Scheduler module (always enabled - core feature)
        try {
            this.modules.internalScheduler = new InternalScheduler({
                io: this.io,
                dataDir: path.join(__dirname, '../../data/scheduler'),
                logger: console
            });
            console.log('[Modules] Internal Scheduler module initialized');
        } catch (e) {
            console.error('[Modules] Failed to initialize Internal Scheduler:', e.message);
        }
    }

    getSchedulerRole(req) {
        const groupsHeader = (req.headers['remote-groups'] || req.headers['x-user-groups'] || '').toString();
        const groups = groupsHeader.split(',').map((g) => g.trim().toLowerCase()).filter(Boolean);
        const isAdminGroup = groups.some((g) => ['admins', 'admin', 'wheel', 'sudo'].includes(g));
        const adminKey = req.headers['x-admin-key'] || req.query.adminKey;
        const validAdminKey = process.env.VOICELINK_ADMIN_KEY && adminKey && adminKey === process.env.VOICELINK_ADMIN_KEY;
        return (isAdminGroup || validAdminKey) ? 'admin' : 'user';
    }

    isAdminRequest(req) {
        return this.getSchedulerRole(req) === 'admin';
    }

    parseBool(value, defaultValue = false) {
        if (value === undefined || value === null || value === '') {
            return defaultValue;
        }
        if (typeof value === 'boolean') {
            return value;
        }
        return ['1', 'true', 'yes', 'on'].includes(String(value).trim().toLowerCase());
    }

    sanitizeExportSegment(input, fallback = 'export') {
        const cleaned = String(input || '')
            .trim()
            .toLowerCase()
            .replace(/[^a-z0-9._-]+/g, '-')
            .replace(/^-+/, '')
            .replace(/-+$/, '');
        return cleaned || fallback;
    }

    ensureEscortSessionsStore() {
        if (!this.escortSessions) {
            this.escortSessions = new Map();
        }
        return this.escortSessions;
    }

    runCommand(executable, args, options = {}) {
        return new Promise((resolve, reject) => {
            const proc = spawn(executable, args, options);
            let stdout = '';
            let stderr = '';
            proc.stdout.on('data', (chunk) => { stdout += chunk.toString(); });
            proc.stderr.on('data', (chunk) => { stderr += chunk.toString(); });
            proc.on('error', reject);
            proc.on('close', (code) => {
                if (code === 0) {
                    resolve({ code, stdout, stderr });
                    return;
                }
                reject(new Error(`${executable} exited ${code}: ${stderr || stdout}`));
            });
        });
    }

    getCopyPartyExportConfig() {
        const baseUrl = String(process.env.VOICELINK_COPYPARTY_URL || 'https://files.raywonderis.me')
            .trim()
            .replace(/\/+$/, '');
        let exportPath = String(process.env.VOICELINK_COPYPARTY_EXPORT_PATH || '/uploads/voicelink-exports').trim();
        if (!exportPath.startsWith('/')) {
            exportPath = `/${exportPath}`;
        }
        exportPath = exportPath.replace(/\/+$/, '');
        return {
            enabled: Boolean(baseUrl),
            baseUrl,
            exportPath,
            username: process.env.VOICELINK_COPYPARTY_USERNAME || '',
            password: process.env.VOICELINK_COPYPARTY_PASSWORD || ''
        };
    }

    async createJsonZipArchive(payload, { prefix = 'voicelink-export' } = {}) {
        const exportDir = path.join(__dirname, '../../data/exports');
        fs.mkdirSync(exportDir, { recursive: true });

        const timestamp = new Date().toISOString().replace(/[:.]/g, '-');
        const safePrefix = this.sanitizeExportSegment(prefix, 'voicelink-export');
        const baseName = `${safePrefix}-${timestamp}-${uuidv4().slice(0, 8)}`;
        const jsonPath = path.join(exportDir, `${baseName}.json`);
        const zipPath = path.join(exportDir, `${baseName}.zip`);

        fs.writeFileSync(jsonPath, JSON.stringify(payload, null, 2), 'utf8');
        await this.runCommand('zip', ['-j', '-q', zipPath, jsonPath]);
        fs.unlinkSync(jsonPath);

        const stats = fs.statSync(zipPath);
        return {
            fileName: `${baseName}.zip`,
            zipPath,
            size: stats.size,
            createdAt: new Date().toISOString(),
            downloadUrl: `/exports/${baseName}.zip`
        };
    }

    async uploadArchiveToCopyParty(zipPath, fileName) {
        const config = this.getCopyPartyExportConfig();
        if (!config.enabled) {
            return { uploaded: false, reason: 'CopyParty not configured' };
        }

        const uploadUrl = `${config.baseUrl}${config.exportPath}/${encodeURIComponent(fileName)}`;
        const headers = { 'Content-Type': 'application/zip' };
        if (config.username) {
            const auth = Buffer.from(`${config.username}:${config.password || ''}`).toString('base64');
            headers.Authorization = `Basic ${auth}`;
        }

        const response = await fetch(uploadUrl, {
            method: 'PUT',
            headers,
            body: fs.readFileSync(zipPath)
        });
        if (!response.ok) {
            const errorText = await response.text().catch(() => '');
            throw new Error(`CopyParty upload failed (${response.status}): ${errorText.slice(0, 240)}`);
        }

        return {
            uploaded: true,
            url: uploadUrl,
            baseUrl: config.baseUrl,
            exportPath: config.exportPath
        };
    }

    buildUserDataExport({ userId = '', username = '', includeMessages = true, includeRooms = true } = {}) {
        const cleanUserId = String(userId || '').trim();
        const cleanUsername = String(username || '').trim();
        const roomIds = new Set();
        const memberships = [];

        if (includeRooms) {
            for (const room of this.rooms.values()) {
                const users = Array.isArray(room.users) ? room.users : [];
                const member = users.find((u) => {
                    const uid = String(u?.id || u?.userId || '').trim();
                    const uname = String(u?.name || u?.username || '').trim();
                    return (cleanUserId && uid === cleanUserId) || (cleanUsername && uname === cleanUsername);
                });
                if (member) {
                    roomIds.add(room.id);
                    memberships.push({
                        id: room.id,
                        roomId: room.roomId || room.id,
                        name: room.name,
                        visibility: room.visibility || 'public'
                    });
                }
            }
        }

        const directMessages = [];
        if (includeMessages) {
            for (const messages of this.directMessages.values()) {
                const filtered = (messages || []).filter((msg) => {
                    const senderId = String(msg.senderId || msg.userId || '').trim();
                    const receiverId = String(msg.receiverId || msg.targetUserId || '').trim();
                    return (cleanUserId && (senderId === cleanUserId || receiverId === cleanUserId));
                });
                directMessages.push(...filtered);
            }
        }

        const roomMessages = {};
        if (includeMessages && includeRooms) {
            for (const roomId of roomIds) {
                roomMessages[roomId] = this.roomMessages.get(roomId) || [];
            }
        }

        return {
            schemaVersion: 1,
            generatedAt: new Date().toISOString(),
            user: { userId: cleanUserId || null, username: cleanUsername || null },
            rooms: memberships,
            directMessages,
            roomMessages
        };
    }

    buildAdminMigrationSnapshot(options = {}) {
        const includeMessages = this.parseBool(options.includeMessages, true);
        const includeRooms = this.parseBool(options.includeRooms, true);
        const includeApiKeys = this.parseBool(options.includeApiKeys, false);
        const includeAuthSessions = this.parseBool(options.includeAuthSessions, true);
        const includeAccessPasses = this.parseBool(options.includeAccessPasses, true);

        return {
            schemaVersion: 1,
            generatedAt: new Date().toISOString(),
            host: os.hostname(),
            rooms: includeRooms ? Array.from(this.rooms.values()).map((room) => ({ ...room, users: [] })) : [],
            users: Array.from(this.users.values()).map((user) => ({
                id: user.id || user.userId || null,
                name: user.name || user.username || null,
                roomId: user.roomId || null,
                roleContext: user.roleContext || null
            })),
            apiSessions: includeAuthSessions ? Array.from(this.apiSessions.entries()).map(([token, session]) => ({
                token,
                userId: session.userId || null,
                userName: session.userName || null,
                roleContext: session.roleContext || null,
                metadata: session.metadata || {},
                expiresAt: session.expiresAt || null
            })) : [],
            apiKeys: includeApiKeys ? Array.from(this.apiKeys.entries()).map(([key, data]) => ({ key, ...data })) : [],
            accessPasses: includeAccessPasses ? Array.from((this.accessPasses || new Map()).values()) : [],
            roomMessages: includeMessages ? Object.fromEntries(this.roomMessages.entries()) : {},
            directMessages: includeMessages ? Object.fromEntries(this.directMessages.entries()) : {}
        };
    }

    applyAdminMigrationSnapshot(snapshot = {}) {
        const result = {
            importedRooms: 0,
            importedSessions: 0,
            importedApiKeys: 0,
            importedAccessPasses: 0,
            importedRoomMessageBuckets: 0,
            importedDirectMessageBuckets: 0
        };

        if (Array.isArray(snapshot.rooms)) {
            for (const room of snapshot.rooms) {
                if (!room || !room.id) continue;
                const existing = this.rooms.get(room.id) || {};
                this.rooms.set(room.id, { ...existing, ...room, users: existing.users || [] });
                result.importedRooms += 1;
            }
        }

        if (Array.isArray(snapshot.apiSessions)) {
            for (const item of snapshot.apiSessions) {
                if (!item?.token) continue;
                this.apiSessions.set(item.token, {
                    userId: item.userId || '',
                    userName: item.userName || '',
                    roleContext: item.roleContext || null,
                    metadata: item.metadata || {},
                    createdAt: new Date(),
                    expiresAt: item.expiresAt ? new Date(item.expiresAt) : new Date(Date.now() + 3600000)
                });
                result.importedSessions += 1;
            }
        }

        if (Array.isArray(snapshot.apiKeys)) {
            for (const keyData of snapshot.apiKeys) {
                if (!keyData?.key) continue;
                const { key, ...rest } = keyData;
                this.apiKeys.set(key, rest);
                result.importedApiKeys += 1;
            }
        }

        if (Array.isArray(snapshot.accessPasses)) {
            for (const pass of snapshot.accessPasses) {
                const passId = pass.id || `pass_${uuidv4()}`;
                this.accessPasses.set(passId, pass);
                result.importedAccessPasses += 1;
            }
        }

        if (snapshot.roomMessages && typeof snapshot.roomMessages === 'object') {
            for (const [roomId, messages] of Object.entries(snapshot.roomMessages)) {
                this.roomMessages.set(roomId, Array.isArray(messages) ? messages : []);
                result.importedRoomMessageBuckets += 1;
            }
        }

        if (snapshot.directMessages && typeof snapshot.directMessages === 'object') {
            for (const [dmKey, messages] of Object.entries(snapshot.directMessages)) {
                this.directMessages.set(dmKey, Array.isArray(messages) ? messages : []);
                result.importedDirectMessageBuckets += 1;
            }
        }

        return result;
    }

    startMigrationRoomTransfer({ sourceRoomId, targetRoomId, targetServerUrl = '' } = {}) {
        this.ensureEscortSessionsStore();
        const sourceRoom = this.rooms.get(sourceRoomId);
        if (!sourceRoom) {
            throw new Error('Source room not found');
        }

        const escortId = `escort_migration_${uuidv4().slice(0, 8)}`;
        const session = {
            id: escortId,
            leaderId: 'system_migration',
            leaderName: 'Server Migration',
            sourceRoomId,
            targetRoomId,
            targetServerUrl: targetServerUrl || null,
            followers: [],
            status: 'active',
            migrationMode: true,
            createdAt: new Date(),
            expiresAt: new Date(Date.now() + 10 * 60 * 1000)
        };
        this.escortSessions.set(escortId, session);

        this.io.to(sourceRoomId).emit('escort-started', {
            escortId,
            leaderName: session.leaderName,
            targetRoomId,
            targetServerUrl: session.targetServerUrl,
            migrationMode: true,
            message: targetServerUrl
                ? `Server migration in progress. Follow to move to ${targetRoomId} on ${targetServerUrl}`
                : `Server migration in progress. Follow to move to ${targetRoomId}.`
        });
        return session;
    }

    getRoleContextFromRequest(req) {
        const groupsHeader = (req.headers['remote-groups'] || req.headers['x-user-groups'] || '').toString();
        const groups = groupsHeader.split(',').map((g) => g.trim()).filter(Boolean);
        const remoteUser = (req.headers['remote-user'] || req.headers['x-user-id'] || '').toString().trim();
        const remoteEmail = (req.headers['remote-email'] || req.headers['x-user-email'] || '').toString().trim();
        const roleInput = {
            provider: req.headers['x-auth-provider'] || req.query.provider || 'unknown',
            groups,
            roles: req.headers['x-user-roles'] || req.query.roles || '',
            userName: remoteUser,
            userId: remoteUser,
            email: remoteEmail,
            isAdmin: this.getSchedulerRole(req) === 'admin',
            isAuthenticated: Boolean(remoteUser || remoteEmail)
        };
        return RoleMapper.normalizeIdentity(roleInput);
    }

    getMastodonScopePolicy({ instance = '', username = '', email = '', requestElevated = false } = {}) {
        const cleanInstance = String(instance || '')
            .toLowerCase()
            .trim()
            .replace(/^https?:\/\//, '')
            .replace(/\/+$/, '');
        const cleanUsername = String(username || '').toLowerCase().trim();
        const cleanEmail = String(email || '').toLowerCase().trim();
        const wantsElevated = String(requestElevated).toLowerCase() === 'true' || requestElevated === true || requestElevated === 1 || requestElevated === '1';

        const identity = RoleMapper.normalizeIdentity({
            provider: 'mastodon',
            userName: cleanUsername,
            userId: cleanUsername,
            email: cleanEmail,
            isAuthenticated: Boolean(cleanUsername || cleanEmail)
        });

        const defaultScope = process.env.VOICELINK_MASTODON_DEFAULT_SCOPE || 'read:accounts';
        const elevatedScope = process.env.VOICELINK_MASTODON_ADMIN_SCOPE || 'read write';
        const elevatedInstances = new Set(
            RoleMapper.envList(
                'VOICELINK_MASTODON_ELEVATED_INSTANCES',
                'md.tappedin.fm,mastodon.devinecreations.net'
            )
        );
        const allowAllInstances = elevatedInstances.size === 0 || elevatedInstances.has('*');
        const instanceAllowed = allowAllInstances || elevatedInstances.has(cleanInstance);
        const allowUserElevated = String(process.env.VOICELINK_MASTODON_ALLOW_USER_ELEVATED || 'true').toLowerCase() !== 'false';
        const hasIdentity = Boolean(cleanUsername || cleanEmail);
        const canRequestElevated = Boolean(
            instanceAllowed && (
                identity.isAdmin || (allowUserElevated && hasIdentity)
            )
        );
        const effectiveScope = canRequestElevated && wantsElevated ? elevatedScope : defaultScope;

        return {
            provider: 'mastodon',
            instance: cleanInstance,
            username: cleanUsername || null,
            primaryRole: identity.primaryRole,
            isAdmin: identity.isAdmin,
            isModerator: identity.isModerator,
            canRequestElevated,
            requestElevated: wantsElevated,
            effectiveScope,
            policy: {
                allowUserElevated,
                instanceAllowed
            },
            allowed: {
                defaultScope,
                elevatedScope
            }
        };
    }

    loadAgentPolicy() {
        const fallback = {
            version: 1,
            defaultStatusTemplates: {
                offline: 'No room agent active.',
                available: "I'm here to help you manage your room.",
                busy: 'I am handling a request. Please wait.',
                restricted: 'I can help with chat and allowed actions for this room.'
            },
            defaults: {
                maxMessageLength: 2000,
                allowedIntents: ['chat', 'help', 'account'],
                allowedActions: []
            },
            roles: {
                guest: { allowedIntents: ['chat', 'help'], allowedActions: [] },
                member: { allowedIntents: ['chat', 'help', 'account'], allowedActions: [] },
                moderator: { allowedIntents: ['chat', 'help', 'account', 'moderate'], allowedActions: ['announce'] },
                admin: {
                    allowedIntents: ['chat', 'help', 'account', 'moderate', 'manage_room', 'run_admin_action'],
                    allowedActions: ['announce', 'lock_room', 'unlock_room']
                }
            },
            safetyRules: [
                'Room scope first: agent can only operate in explicitly targeted room.',
                'Least privilege: tokens must include only required permissions.',
                'No cross-user account changes unless caller has admin policy.',
                'No destructive actions without explicit admin action request.',
                'Never expose secrets, keys, session tokens, or private room passwords.'
            ]
        };
        try {
            const policyPath = path.join(__dirname, '../config/agent-policy.json');
            if (fs.existsSync(policyPath)) {
                const parsed = JSON.parse(fs.readFileSync(policyPath, 'utf8'));
                return { ...fallback, ...parsed };
            }
        } catch (error) {
            console.warn('[AgentPolicy] Failed to load policy file, using defaults:', error.message);
        }
        return fallback;
    }

    getAgentRoleForPrincipal(principal = {}) {
        if (principal?.isAdmin) return 'admin';
        const roles = Array.isArray(principal?.roleContext?.voicelinkRoles)
            ? principal.roleContext.voicelinkRoles
            : [];
        if (roles.includes('room_admin') || roles.includes('room_moderator')) return 'moderator';
        if (principal?.userId || principal?.userName) return 'member';
        return 'guest';
    }

    getAgentRuntimePolicy(principal = {}) {
        const role = this.getAgentRoleForPrincipal(principal);
        const defaults = this.agentPolicy?.defaults || {};
        const roleRules = this.agentPolicy?.roles?.[role] || {};
        return {
            role,
            maxMessageLength: Number(roleRules.maxMessageLength || defaults.maxMessageLength || 2000),
            allowedIntents: this.normalizeTokenPermissions(roleRules.allowedIntents || defaults.allowedIntents || []),
            allowedActions: this.normalizeTokenPermissions(roleRules.allowedActions || defaults.allowedActions || [])
        };
    }

    loadPushoverConfig() {
        const fallback = {
            enabled: false,
            active: false,
            appToken: '',
            userKey: '',
            device: '',
            sound: '',
            priority: 0,
            titlePrefix: 'VoiceLink',
            minDeferredSeconds: 15,
            maxDeferredSeconds: 120,
            pendingActivationUntil: null,
            updatedAt: null
        };
        try {
            const cfgPath = path.join(__dirname, '../../data/pushover.json');
            if (!fs.existsSync(cfgPath)) return fallback;
            const parsed = JSON.parse(fs.readFileSync(cfgPath, 'utf8'));
            return { ...fallback, ...parsed };
        } catch (error) {
            console.warn('[Pushover] Failed to load config:', error.message);
            return fallback;
        }
    }

    savePushoverConfig() {
        try {
            const cfgPath = path.join(__dirname, '../../data/pushover.json');
            fs.mkdirSync(path.dirname(cfgPath), { recursive: true });
            fs.writeFileSync(cfgPath, JSON.stringify(this.pushoverConfig, null, 2), 'utf8');
            return true;
        } catch (error) {
            console.error('[Pushover] Failed to save config:', error.message);
            return false;
        }
    }

    maskedPushoverConfig() {
        const config = this.pushoverConfig || {};
        const mask = (value = '') => {
            const str = String(value || '');
            if (!str) return '';
            if (str.length <= 8) return '********';
            return `${str.slice(0, 4)}…${str.slice(-4)}`;
        };
        return {
            enabled: Boolean(config.enabled),
            active: Boolean(config.active),
            hasAppToken: Boolean(config.appToken),
            hasUserKey: Boolean(config.userKey),
            appTokenMasked: mask(config.appToken),
            userKeyMasked: mask(config.userKey),
            device: config.device || '',
            sound: config.sound || '',
            priority: Number(config.priority || 0),
            titlePrefix: config.titlePrefix || 'VoiceLink',
            minDeferredSeconds: Number(config.minDeferredSeconds || 15),
            maxDeferredSeconds: Number(config.maxDeferredSeconds || 120),
            pendingActivationUntil: config.pendingActivationUntil || null,
            updatedAt: config.updatedAt || null
        };
    }

    schedulePushoverActivation() {
        if (this.pendingPushoverActivation) {
            clearTimeout(this.pendingPushoverActivation);
            this.pendingPushoverActivation = null;
        }
        const minDelay = Math.max(1, Number(this.pushoverConfig.minDeferredSeconds || 15));
        const maxDelay = Math.max(minDelay, Number(this.pushoverConfig.maxDeferredSeconds || 120));
        const delaySeconds = Math.floor(Math.random() * (maxDelay - minDelay + 1)) + minDelay;
        const activateAt = new Date(Date.now() + (delaySeconds * 1000));
        this.pushoverConfig.pendingActivationUntil = activateAt.toISOString();
        this.pushoverConfig.active = false;
        this.savePushoverConfig();

        this.pendingPushoverActivation = setTimeout(() => {
            this.pushoverConfig.pendingActivationUntil = null;
            this.pushoverConfig.active = Boolean(this.pushoverConfig.enabled && this.pushoverConfig.appToken && this.pushoverConfig.userKey);
            this.savePushoverConfig();
            this.pendingPushoverActivation = null;
        }, delaySeconds * 1000);
    }

    async sendPushoverNotification({ title = '', message = '', url = '', urlTitle = '' } = {}) {
        const cfg = this.pushoverConfig || {};
        if (!cfg.enabled || !cfg.active || !cfg.appToken || !cfg.userKey) {
            return { success: false, skipped: true, reason: 'Pushover not active/configured' };
        }

        const payload = new URLSearchParams();
        payload.set('token', String(cfg.appToken));
        payload.set('user', String(cfg.userKey));
        payload.set('message', String(message || '').slice(0, 1024));
        payload.set('title', String(title || `${cfg.titlePrefix || 'VoiceLink'} Notification`).slice(0, 250));
        payload.set('priority', String(Number(cfg.priority || 0)));
        if (cfg.device) payload.set('device', String(cfg.device));
        if (cfg.sound) payload.set('sound', String(cfg.sound));
        if (url) payload.set('url', String(url));
        if (urlTitle) payload.set('url_title', String(urlTitle));

        try {
            const response = await fetch('https://api.pushover.net/1/messages.json', {
                method: 'POST',
                headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
                body: payload.toString()
            });
            const body = await response.json().catch(() => ({}));
            if (!response.ok || body.status !== 1) {
                return {
                    success: false,
                    skipped: false,
                    error: body.errors?.[0] || `Pushover API failed (${response.status})`
                };
            }
            return { success: true, request: body.request || null };
        } catch (error) {
            return { success: false, skipped: false, error: error.message };
        }
    }

    normalizeTokenPermissions(input = []) {
        if (!input) return [];
        const values = Array.isArray(input)
            ? input
            : String(input).split(',');
        const cleaned = values
            .map((value) => String(value || '').trim())
            .filter(Boolean);
        return Array.from(new Set(cleaned));
    }

    extractTokenFromRequest(req) {
        const authHeader = String(req.headers.authorization || '').trim();
        if (authHeader.toLowerCase().startsWith('bearer ')) {
            return authHeader.slice(7).trim();
        }
        const tokenHeader = req.headers['x-voicelink-token'] || req.headers['x-session-token'] || req.headers['x-api-key'];
        if (tokenHeader) return String(tokenHeader).trim();
        if (req.query?.token) return String(req.query.token).trim();
        if (req.body?.token) return String(req.body.token).trim();
        return '';
    }

    hasTokenPermission(grantedPermissions = [], requestedPermission = '') {
        const requested = String(requestedPermission || '').trim();
        if (!requested) return true;

        const granted = new Set(this.normalizeTokenPermissions(grantedPermissions));
        if (granted.has('*') || granted.has('admin')) return true;
        if (granted.has(requested)) return true;

        const sections = requested.split('.');
        if (sections.length > 1) {
            const wildcardPrefix = `${sections[0]}.*`;
            if (granted.has(wildcardPrefix)) return true;
        }

        if (requested.startsWith('agent.') && granted.has('agent.admin')) return true;
        if (requested.startsWith('admin.') && granted.has('admin.panel')) return true;
        return false;
    }

    resolvePrincipalFromToken(token = '', req = null) {
        const now = Date.now();
        const cleanToken = String(token || '').trim();
        if (!cleanToken) {
            return { valid: false, status: 401, error: 'Missing token' };
        }

        if (this.integrationTokens?.has(cleanToken)) {
            const integrationToken = this.integrationTokens.get(cleanToken);
            if (integrationToken.expiresAt && now > new Date(integrationToken.expiresAt).getTime()) {
                this.integrationTokens.delete(cleanToken);
                return { valid: false, status: 401, error: 'Token expired' };
            }
            const permissions = this.normalizeTokenPermissions(integrationToken.permissions);
            const roleContext = integrationToken.roleContext || RoleMapper.normalizeIdentity({ isAuthenticated: false });
            return {
                valid: true,
                principal: {
                    tokenType: 'integration',
                    token: cleanToken,
                    name: integrationToken.name || 'integration',
                    permissions,
                    roleContext,
                    userId: integrationToken.userId || '',
                    userName: integrationToken.userName || '',
                    roomScope: integrationToken.roomScope || null,
                    metadata: integrationToken.metadata || {},
                    isAdmin: Boolean(roleContext?.isAdmin) || this.hasTokenPermission(permissions, 'agent.admin'),
                    expiresAt: integrationToken.expiresAt || null
                }
            };
        }

        if (this.apiSessions?.has(cleanToken)) {
            const session = this.apiSessions.get(cleanToken);
            if (!session || new Date() > new Date(session.expiresAt)) {
                this.apiSessions.delete(cleanToken);
                return { valid: false, status: 401, error: 'Session expired' };
            }
            const roleContext = session.roleContext || RoleMapper.normalizeIdentity({ isAuthenticated: true });
            const permissions = new Set(this.normalizeTokenPermissions(roleContext.permissions || []));
            permissions.add('agent.chat');
            if (roleContext.isAdmin) {
                permissions.add('agent.admin');
                permissions.add('admin.panel');
            }
            return {
                valid: true,
                principal: {
                    tokenType: 'session',
                    token: cleanToken,
                    name: session.appName || 'session',
                    permissions: Array.from(permissions),
                    roleContext,
                    userId: session.userId || '',
                    userName: session.userName || '',
                    roomScope: null,
                    metadata: session.metadata || {},
                    isAdmin: Boolean(roleContext?.isAdmin),
                    expiresAt: session.expiresAt || null
                }
            };
        }

        if (this.apiKeys?.has(cleanToken)) {
            const apiKey = this.apiKeys.get(cleanToken);
            apiKey.lastUsed = new Date();
            apiKey.requestCount = (apiKey.requestCount || 0) + 1;
            const permissions = this.normalizeTokenPermissions(apiKey.permissions || []);
            const roleContext = req ? this.getRoleContextFromRequest(req) : RoleMapper.normalizeIdentity({ isAuthenticated: false });
            const isAdmin = this.hasTokenPermission(permissions, 'agent.admin') ||
                this.hasTokenPermission(permissions, 'admin.panel') ||
                Boolean(roleContext?.isAdmin);
            return {
                valid: true,
                principal: {
                    tokenType: 'apiKey',
                    token: cleanToken,
                    name: apiKey.name || 'api-key',
                    permissions,
                    roleContext,
                    userId: '',
                    userName: '',
                    roomScope: null,
                    metadata: { createdBy: apiKey.createdBy || null },
                    isAdmin,
                    expiresAt: null
                }
            };
        }

        return { valid: false, status: 401, error: 'Invalid token' };
    }

    canManageRoomAgent(principal = {}, room = null) {
        if (!room || !principal) return false;
        if (principal.isAdmin) return true;
        const roleContext = principal.roleContext || {};
        const roles = Array.isArray(roleContext.voicelinkRoles) ? roleContext.voicelinkRoles : [];
        if (roles.includes('room_admin') || roles.includes('server_admin') || roles.includes('server_owner')) {
            return true;
        }
        const creator = String(room.creatorHandle || '').trim().toLowerCase();
        const principalUserName = String(principal.userName || '').trim().toLowerCase();
        const principalUserId = String(principal.userId || '').trim().toLowerCase();
        return Boolean(creator && (creator === principalUserName || creator === principalUserId));
    }

    getRoomAgentState(roomId) {
        const existing = this.roomAgents.get(roomId);
        if (existing) return existing;
        return {
            enabled: false,
            roomScoped: true,
            present: false,
            agentId: 'openclaw',
            agentName: 'VoiceLink Agent',
            statusType: 'offline',
            statusText: 'No room agent active.',
            allowedActions: ['chat'],
            updatedAt: new Date().toISOString(),
            updatedBy: 'system'
        };
    }

    setupMiddleware() {
        this.app.use(cors());
        this.app.use(express.json({ limit: '15mb' }));
        this.refreshSoundFileLookup();
        this.app.get(['/assets/sounds/:filename', '/sounds/:filename'], (req, res, next) => {
            const requested = String(req.params.filename || '').trim();
            if (!requested) return next();
            const resolved = this.resolveSoundPath(requested);
            if (!resolved) return next();
            return res.sendFile(resolved);
        });
        this.app.use(express.static(path.join(__dirname, '..', '..', 'client')));
        this.app.use('/uploads', express.static(path.join(__dirname, '../../data/uploads')));
    }

    refreshSoundFileLookup() {
        const soundsRoot = path.join(__dirname, '..', '..', 'client', 'assets', 'sounds');
        const lookup = new Map();
        const walk = (dirPath) => {
            let entries = [];
            try {
                entries = fs.readdirSync(dirPath, { withFileTypes: true });
            } catch {
                return;
            }
            for (const entry of entries) {
                const fullPath = path.join(dirPath, entry.name);
                if (entry.isDirectory()) {
                    walk(fullPath);
                    continue;
                }
                if (!entry.isFile()) continue;
                const lowerName = entry.name.toLowerCase();
                const existing = lookup.get(lowerName);
                if (!existing) {
                    lookup.set(lowerName, fullPath);
                    continue;
                }
                // Prefer shallower paths when duplicates exist.
                const existingDepth = existing.split(path.sep).length;
                const nextDepth = fullPath.split(path.sep).length;
                if (nextDepth < existingDepth) {
                    lookup.set(lowerName, fullPath);
                }
            }
        };

        walk(soundsRoot);
        this.soundFileLookup = lookup;
    }

    resolveSoundPath(requestedFileName) {
        if (!requestedFileName) return null;
        const cleaned = path.basename(requestedFileName).toLowerCase();
        if (!cleaned || cleaned === '.' || cleaned === '..') return null;
        const direct = this.soundFileLookup.get(cleaned);
        if (direct) return direct;

        const parsed = path.parse(cleaned);
        if (!parsed.name) return null;
        const extensions = ['.wav', '.flac', '.mp3', '.m4a', '.aiff', '.ogg'];
        for (const ext of extensions) {
            const byExt = this.soundFileLookup.get(`${parsed.name}${ext}`);
            if (byExt) return byExt;
        }
        return null;
    }

    /**
     * Fetch rooms from main signal server
     */
    async fetchMainServerRooms() {
        // If this IS the main server, don't fetch from ourselves (circular dependency)
        // Check if we're running on the main server domain
        const isMainServer = process.env.IS_MAIN_SERVER === 'true' ||
                           process.env.MAIN_SERVER_URL === undefined ||
                           MAIN_SERVER_URL.includes(process.env.DOMAIN || 'voicelink.devinecreations.net');

        if (isMainServer) {
            console.log('[LocalServer] Running as main server, skipping external room fetch');
            return [];
        }

        return new Promise((resolve) => {
            const url = `${MAIN_SERVER_URL}/api/rooms?source=app`;
            console.log('[LocalServer] Fetching rooms from main server:', url);

            https.get(url, { timeout: 5000 }, (response) => {
                let data = '';
                response.on('data', chunk => data += chunk);
                response.on('end', () => {
                    try {
                        const rooms = JSON.parse(data);
                        console.log(`[LocalServer] Got ${rooms.length} rooms from main server`);
                        resolve(rooms.map(r => ({ ...r, serverSource: 'main' })));
                    } catch (e) {
                        console.error('[LocalServer] Failed to parse main server response:', e.message);
                        resolve([]);
                    }
                });
            }).on('error', (err) => {
                console.error('[LocalServer] Main server fetch error:', err.message);
                resolve([]);
            }).on('timeout', () => {
                console.error('[LocalServer] Main server fetch timeout');
                resolve([]);
            });
        });
    }

    normalizeRoomString(value) {
        return String(value || '')
            .trim()
            .toLowerCase()
            .replace(/\s+/g, ' ');
    }

    getRoomDedupKey(room) {
        const name = this.normalizeRoomString(room.name);
        if (name) return name;
        return this.normalizeRoomString(room.roomId || room.id);
    }

    dedupeRooms(rooms) {
        const deduped = new Map();
        for (const room of rooms || []) {
            const key = this.getRoomDedupKey(room);
            if (!key) continue;

            if (!deduped.has(key)) {
                deduped.set(key, room);
                continue;
            }

            // Keep the richer duplicate candidate.
            const existing = deduped.get(key) || {};
            const existingUsers = Number(existing.users || existing.userCount || 0);
            const incomingUsers = Number(room.users || room.userCount || 0);
            const existingDesc = this.normalizeRoomString(existing.description);
            const incomingDesc = this.normalizeRoomString(room.description);
            if (incomingUsers > existingUsers || (incomingDesc && !existingDesc)) {
                deduped.set(key, room);
            }
        }
        return Array.from(deduped.values());
    }

    /**
     * Lock a room - prevents new users from joining
     */
    lockRoom(roomId, lockedBy, reason) {
        const room = this.rooms.get(roomId);
        if (!room) {
            return { success: false, error: 'Room not found' };
        }

        if (room.locked) {
            return { success: false, error: 'Room is already locked' };
        }

        room.locked = true;
        room.lockedAt = new Date();
        room.lockedBy = lockedBy || 'system';
        room.lockReason = reason || null;

        // Notify room users
        this.io.to(roomId).emit('room-locked', {
            roomId,
            lockedBy: room.lockedBy,
            lockedAt: room.lockedAt,
            reason: room.lockReason,
            message: 'This room is locked.'
        });

        // Broadcast to federated servers
        this.federation.broadcastRoomChange('locked', room);

        console.log(`[Room] ${roomId} locked by ${lockedBy}`);
        return { success: true, message: 'Room locked', locked: true };
    }

    /**
     * Unlock a room - allows new users to join
     */
    unlockRoom(roomId, unlockedBy) {
        const room = this.rooms.get(roomId);
        if (!room) {
            return { success: false, error: 'Room not found' };
        }

        if (!room.locked) {
            return { success: false, error: 'Room is not locked' };
        }

        room.locked = false;
        room.lockedAt = null;
        room.lockedBy = null;
        room.lockReason = null;

        // Notify room users
        this.io.to(roomId).emit('room-unlocked', {
            roomId,
            unlockedBy: unlockedBy || 'system',
            message: 'This room is not locked, and can be joined.'
        });

        // Broadcast to federated servers
        this.federation.broadcastRoomChange('unlocked', room);

        console.log(`[Room] ${roomId} unlocked by ${unlockedBy}`);
        return { success: true, message: 'Room unlocked', locked: false };
    }

    /**
     * Check and apply auto-lock rules when user count changes
     */
    checkAutoLock(roomId) {
        const room = this.rooms.get(roomId);
        if (!room || !room.autoLock || room.locked) return;

        // Auto-lock when user count reaches threshold
        if (room.autoLock.afterUsers && room.users.length >= room.autoLock.afterUsers) {
            this.lockRoom(roomId, 'auto-users', `Auto-locked at ${room.autoLock.afterUsers} users`);
        }
    }

    /**
     * Handle host leave auto-lock
     */
    handleHostLeave(roomId, userId) {
        const room = this.rooms.get(roomId);
        if (!room || !room.autoLock?.onHostLeave) return;

        // Check if leaving user is the host/creator
        if (room.creatorHandle === userId) {
            this.lockRoom(roomId, 'auto-host-leave', 'Host left the room');
        }
    }

    setupRoutes() {
        // User-to-user file transfer APIs
        this.app.use('/api/file-transfer', fileTransferRoutes);

        // API Routes - now fetches from main server and merges with local
        this.app.get('/api/rooms', async (req, res) => {
            const source = req.query.source || 'app'; // 'app', 'web', 'all'
            const includeHidden = req.query.includeHidden === 'true';

            // Fetch rooms from main server first
            let mainServerRooms = [];
            try {
                mainServerRooms = await this.fetchMainServerRooms();
            } catch (e) {
                console.error('[LocalServer] Error fetching main server rooms:', e.message);
            }

            // Get local rooms
            let localRooms = Array.from(this.rooms.values());

            // Filter local rooms by access type based on request source
            if (!includeHidden) {
                localRooms = localRooms.filter(room => {
                    if (room.accessType === 'hidden') return false;
                    if (source === 'app' && !room.showInApp) return false;
                    if (source === 'web' && !room.allowEmbed) return false;
                    return true;
                });
            }

            const localRoomList = localRooms.map(room => ({
                id: room.id,
                name: room.name,
                description: room.description || '',
                users: room.users.length,
                maxUsers: room.maxUsers,
                hasPassword: !!room.password,
                visibility: room.visibility,
                accessType: room.accessType,
                allowEmbed: room.allowEmbed,
                visibleToGuests: room.visibleToGuests,
                isDefault: room.isDefault || false,
                template: room.template || null,
                serverSource: 'local',
                // Lock status
                locked: room.locked || false,
                lockedAt: room.lockedAt || null,
                canJoin: !room.locked
            }));

            // Merge and dedupe logical duplicates (not just exact IDs).
            const mergedRooms = this.dedupeRooms([...mainServerRooms, ...localRoomList]);

            console.log(`[LocalServer] Returning ${mergedRooms.length} rooms (${mainServerRooms.length} main + ${localRoomList.length} local)`);
            res.json(mergedRooms);
        });

        this.app.post('/api/rooms', (req, res) => {
            const {
                name,
                description,
                password,
                maxUsers = 10,
                visibility = 'public',
                visibleToGuests = true,
                accessType = 'hybrid',  // 'web-only', 'app-only', 'hybrid', 'hidden'
                duration,
                privacyLevel,
                encrypted,
                creatorHandle,
                isDefault,
                template,
                locked = false,
                autoLock = null,  // { afterUsers: N, afterMinutes: N, onHostLeave: bool }
                isAuthenticated = false
            } = req.body;
            const roomId = req.body.roomId || uuidv4();
            const requestedRoomName = (name || `Room ${roomId.slice(0, 8)}`).trim();
            const requestedRoomNameKey = this.normalizeRoomString(requestedRoomName);

            // Global room-name uniqueness guard.
            const nameTaken = Array.from(this.rooms.values()).some((room) => {
                return this.normalizeRoomString(room.name) === requestedRoomNameKey;
            });
            if (nameTaken) {
                return res.status(409).json({
                    error: 'This room has already been taken, sorry, try again!',
                    code: 'ROOM_NAME_TAKEN'
                });
            }

            // Enforce guest restrictions
            if (!isAuthenticated) {
                // Guests can only create public rooms
                if (visibility !== 'public') {
                    return res.status(403).json({
                        error: 'Guests can only create public rooms. Please login to create private rooms.',
                        requiresAuth: true
                    });
                }

                // Guests cannot use passwords
                if (password) {
                    return res.status(403).json({
                        error: 'Guests cannot create password-protected rooms. Please login for this feature.',
                        requiresAuth: true
                    });
                }

                // Guests limited to 10-30 minute durations
                if (duration === null || duration > 1800000) { // 30 minutes max
                    return res.status(403).json({
                        error: 'Guests can only create rooms lasting 10-30 minutes. Please login for longer durations.',
                        requiresAuth: true,
                        maxGuestDuration: 1800000
                    });
                }

                if (duration < 600000) { // 10 minutes minimum
                    return res.status(400).json({
                        error: 'Room duration must be at least 10 minutes.',
                        minGuestDuration: 600000
                    });
                }
            }

            // Calculate expiration if duration is set
            let expiresAt = null;
            if (duration && typeof duration === 'number') {
                expiresAt = new Date(Date.now() + duration);
            }

            // Access type determines where the room is accessible:
            // - web-only: Only via direct URL/embed (not listed in app)
            // - app-only: Only within VoiceLink app (no embed access)
            // - hybrid: Both app and web embed access
            // - hidden: Not listed anywhere, only direct link works

            const room = {
                id: roomId,
                name: requestedRoomName,
                description: description || '',
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
                isDefault: isDefault || false,
                template: template || null,
                createdAt: new Date(),
                expiresAt,
                audioSettings: {
                    spatialAudio: true,
                    quality: 'high',
                    effects: []
                },
                // Room lock settings
                locked: locked || false,
                lockedAt: locked ? new Date() : null,
                lockedBy: locked ? creatorHandle : null,
                autoLock: autoLock || null,  // { afterUsers: N, afterMinutes: N, onHostLeave: bool }
                autoLockScheduled: null  // Timeout ID for scheduled auto-lock
            };

            this.rooms.set(roomId, room);

            // Schedule auto-lock if configured
            if (autoLock?.afterMinutes) {
                room.autoLockScheduled = setTimeout(() => {
                    this.lockRoom(roomId, 'auto-timer', `Auto-locked after ${autoLock.afterMinutes} minutes`);
                }, autoLock.afterMinutes * 60 * 1000);
            }

            // Broadcast to federated servers (only public hybrid/app rooms)
            if (visibility === 'public' && room.showInApp) {
                this.federation.broadcastRoomChange('created', room);
            }

            res.json({ roomId, message: 'Room created successfully', accessType });
        });

        // Lock a room
        this.app.post('/api/rooms/:roomId/lock', (req, res) => {
            const { roomId } = req.params;
            const { lockedBy, reason } = req.body;
            const result = this.lockRoom(roomId, lockedBy, reason);
            res.json(result);
        });

        // Unlock a room
        this.app.post('/api/rooms/:roomId/unlock', (req, res) => {
            const { roomId } = req.params;
            const { unlockedBy } = req.body;
            const result = this.unlockRoom(roomId, unlockedBy);
            res.json(result);
        });

        // Get room lock status
        this.app.get('/api/rooms/:roomId/status', (req, res) => {
            const { roomId } = req.params;
            const room = this.rooms.get(roomId);
            if (!room) {
                return res.status(404).json({ error: 'Room not found' });
            }
            res.json({
                roomId,
                locked: room.locked,
                lockedAt: room.lockedAt,
                lockedBy: room.lockedBy,
                canJoin: !room.locked,
                message: room.locked ? 'This room is locked.' : 'This room is not locked, and can be joined.'
            });
        });

        // Update room auto-lock settings
        this.app.put('/api/rooms/:roomId/autolock', (req, res) => {
            const { roomId } = req.params;
            const { autoLock } = req.body;
            const room = this.rooms.get(roomId);

            if (!room) {
                return res.status(404).json({ error: 'Room not found' });
            }

            // Clear existing auto-lock timer
            if (room.autoLockScheduled) {
                clearTimeout(room.autoLockScheduled);
                room.autoLockScheduled = null;
            }

            room.autoLock = autoLock;

            // Schedule new auto-lock if afterMinutes is set
            if (autoLock?.afterMinutes) {
                room.autoLockScheduled = setTimeout(() => {
                    this.lockRoom(roomId, 'auto-timer', `Auto-locked after ${autoLock.afterMinutes} minutes`);
                }, autoLock.afterMinutes * 60 * 1000);
            }

            res.json({ success: true, autoLock: room.autoLock });
        });

        // Get room media info (now playing, playback mode, etc.)
        this.app.get('/api/rooms/:roomId/media', (req, res) => {
            const { roomId } = req.params;
            const room = this.rooms.get(roomId);

            if (!room) {
                return res.status(404).json({ error: 'Room not found' });
            }

            // Check if media rooms module is loaded
            if (this.modules.mediaRooms) {
                const mediaInfo = this.modules.mediaRooms.getRoomMediaInfo(roomId);
                res.json({
                    roomId,
                    roomName: room.name,
                    ...mediaInfo
                });
            } else {
                res.json({
                    roomId,
                    roomName: room.name,
                    nowPlaying: { playing: false, message: 'Media module not loaded' },
                    playbackMode: 'standard'
                });
            }
        });

        // Get now playing for a room
        this.app.get('/api/rooms/:roomId/now-playing', (req, res) => {
            const { roomId } = req.params;

            if (this.modules.mediaRooms) {
                res.json(this.modules.mediaRooms.getNowPlaying(roomId));
            } else {
                res.json({ playing: false, message: 'Media module not loaded' });
            }
        });

        // Set current media for a room (admin/mod only)
        this.app.post('/api/rooms/:roomId/media', (req, res) => {
            const { roomId } = req.params;
            const { media } = req.body;

            if (!this.modules.mediaRooms) {
                return res.status(500).json({ error: 'Media module not loaded' });
            }

            const result = this.modules.mediaRooms.setCurrentMedia(roomId, media);
            res.json({ success: true, nowPlaying: this.modules.mediaRooms.getNowPlaying(roomId) });
        });

        // Set playback mode for a room
        this.app.put('/api/rooms/:roomId/playback-mode', (req, res) => {
            const { roomId } = req.params;
            const { mode, options } = req.body;

            if (!this.modules.mediaRooms) {
                return res.status(500).json({ error: 'Media module not loaded' });
            }

            const result = this.modules.mediaRooms.setPlaybackMode(roomId, mode, options || {});
            res.json({ success: true, playbackMode: mode, config: result });
        });

        // ==================== Message History API ====================

        // Get room message history
        this.app.get('/api/rooms/:roomId/messages', (req, res) => {
            const { roomId } = req.params;
            const { limit = 50, before } = req.query;

            const messages = this.getRoomMessages(roomId, parseInt(limit), before);
            res.json({
                roomId,
                messages,
                count: messages.length,
                hasMore: messages.length === parseInt(limit)
            });
        });

        // Get direct message history between two users
        this.app.get('/api/messages/dm/:userId1/:userId2', (req, res) => {
            const { userId1, userId2 } = req.params;
            const { limit = 50, before } = req.query;

            const messages = this.getDirectMessages(userId1, userId2, parseInt(limit), before);
            res.json({
                participants: [userId1, userId2],
                messages,
                count: messages.length,
                hasMore: messages.length === parseInt(limit)
            });
        });

        // Get all conversations for a user (list of DM threads)
        this.app.get('/api/messages/conversations/:userId', (req, res) => {
            const { userId } = req.params;
            const conversations = [];

            for (const [dmKey, messages] of this.directMessages.entries()) {
                if (dmKey.includes(userId) && messages.length > 0) {
                    const [user1, user2] = dmKey.split('_');
                    const otherUserId = user1 === userId ? user2 : user1;
                    const lastMessage = messages[messages.length - 1];
                    const unreadCount = messages.filter(m =>
                        m.receiverId === userId && !m.read
                    ).length;

                    conversations.push({
                        otherUserId,
                        lastMessage,
                        unreadCount,
                        messageCount: messages.length
                    });
                }
            }

            // Sort by most recent
            conversations.sort((a, b) =>
                new Date(b.lastMessage.timestamp) - new Date(a.lastMessage.timestamp)
            );

            res.json({ userId, conversations });
        });

        // Mark messages as read
        this.app.post('/api/messages/dm/:userId1/:userId2/read', (req, res) => {
            const { userId1, userId2 } = req.params;
            const dmKey = [userId1, userId2].sort().join('_');
            const messages = this.directMessages.get(dmKey);

            if (messages) {
                let markedCount = 0;
                messages.forEach(msg => {
                    if (msg.receiverId === userId1 && !msg.read) {
                        msg.read = true;
                        markedCount++;
                    }
                });
                res.json({ success: true, markedAsRead: markedCount });
            } else {
                res.json({ success: true, markedAsRead: 0 });
            }
        });

        // Get message statistics
        this.app.get('/api/messages/stats', (req, res) => {
            let totalRoomMessages = 0;
            let totalDMs = 0;
            let authenticatedMessages = 0;
            let guestMessages = 0;

            for (const messages of this.roomMessages.values()) {
                totalRoomMessages += messages.length;
                messages.forEach(m => {
                    if (m.isAuthenticated) authenticatedMessages++;
                    else guestMessages++;
                });
            }

            for (const messages of this.directMessages.values()) {
                totalDMs += messages.length;
                messages.forEach(m => {
                    if (m.isAuthenticated) authenticatedMessages++;
                    else guestMessages++;
                });
            }

            res.json({
                roomCount: this.roomMessages.size,
                dmConversationCount: this.directMessages.size,
                totalRoomMessages,
                totalDirectMessages: totalDMs,
                authenticatedMessages,
                guestMessages,
                guestMessageExpiry: '24 hours'
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

        // Compatibility endpoint used by older/native clients
        this.app.get('/api/health', (req, res) => {
            res.json({
                service: 'voicelink-local',
                status: 'healthy',
                timestamp: new Date().toISOString(),
                rooms: this.rooms.size,
                users: this.users.size
            });
        });

        // Internal scheduler (core module): admin has full control, users have limited visibility/actions
        this.app.get('/api/scheduler/status', (req, res) => {
            if (!this.modules.internalScheduler) {
                return res.status(503).json({ error: 'Internal scheduler unavailable' });
            }
            const role = this.getSchedulerRole(req);
            return res.json(this.modules.internalScheduler.getStatus(role));
        });

        this.app.get('/api/scheduler/health', (req, res) => {
            const { execSync } = require('child_process');
            const role = this.getSchedulerRole(req);
            const schedulerStatus = this.modules.internalScheduler
                ? this.modules.internalScheduler.getStatus(role)
                : null;
            const schedulerTasks = this.modules.internalScheduler
                ? this.modules.internalScheduler.listTasks(role)
                : [];
            const enabledBuiltinTasks = schedulerTasks.filter((t) => t.enabled).length;
            const builtinCronRunning = Boolean(this.modules.internalScheduler && enabledBuiltinTasks > 0);

            const checkSystemCron = (serviceName) => {
                try {
                    const out = execSync(`systemctl is-active ${serviceName}`, { stdio: ['ignore', 'pipe', 'ignore'] })
                        .toString()
                        .trim()
                        .toLowerCase();
                    return out === 'active';
                } catch {
                    return false;
                }
            };

            const systemCronRunning = checkSystemCron('cron') || checkSystemCron('crond');
            const atLeastOneRunning = systemCronRunning || builtinCronRunning;

            return res.json({
                ok: atLeastOneRunning,
                role,
                systemCronRunning,
                builtinCronRunning,
                enabledBuiltinTasks,
                guidance: atLeastOneRunning
                    ? 'At least one scheduler is running. Internal scheduler auto-starts when server is online.'
                    : 'No scheduler detected. Enable internal scheduler tasks or start system cron service.',
                schedulerStatus
            });
        });

        this.app.get('/api/scheduler/tasks', (req, res) => {
            if (!this.modules.internalScheduler) {
                return res.status(503).json({ error: 'Internal scheduler unavailable' });
            }
            const role = this.getSchedulerRole(req);
            return res.json({ tasks: this.modules.internalScheduler.listTasks(role), role });
        });

        this.app.get('/api/scheduler/logs', (req, res) => {
            if (!this.modules.internalScheduler) {
                return res.status(503).json({ error: 'Internal scheduler unavailable' });
            }
            const role = this.getSchedulerRole(req);
            const limit = Number(req.query.limit) || 50;
            return res.json({ logs: this.modules.internalScheduler.listLogs(role, limit), role });
        });

        this.app.post('/api/scheduler/tasks/:taskId/run', async (req, res) => {
            if (!this.modules.internalScheduler) {
                return res.status(503).json({ error: 'Internal scheduler unavailable' });
            }
            const role = this.getSchedulerRole(req);
            const task = this.modules.internalScheduler.listTasks(role).find((t) => t.id === req.params.taskId);
            if (!task) return res.status(404).json({ error: 'Task not found' });
            if (role !== 'admin' && !task.allowUserRun) {
                return res.status(403).json({ error: 'Task requires admin role' });
            }
            const result = await this.modules.internalScheduler.runTask(req.params.taskId, {
                actor: role,
                trigger: 'manual'
            });
            return res.json(result);
        });

        this.app.patch('/api/scheduler/tasks/:taskId', (req, res) => {
            if (!this.modules.internalScheduler) {
                return res.status(503).json({ error: 'Internal scheduler unavailable' });
            }
            const role = this.getSchedulerRole(req);
            const result = this.modules.internalScheduler.updateTask(req.params.taskId, req.body || {}, role);
            if (!result.success) {
                const status = result.error === 'Task not found' ? 404 : 403;
                return res.status(status).json(result);
            }
            return res.json(result);
        });

        const updateHub = process.env.VOICELINK_UPDATE_HUB || 'https://voicelink.devinecreations.net';
        const upstreamPolicyURL = process.env.VOICELINK_UPDATE_POLICY_URL || `${updateHub}/api/updates/policy`;
        const policyFilePath = path.join(__dirname, '../../data/updater/version-policy.json');
        const updatePolicyMirrors = (process.env.VOICELINK_UPDATE_MIRRORS || `${updateHub},https://64.20.46.178`)
            .split(',')
            .map((item) => item.trim())
            .filter(Boolean);
        const normalizeBaseURL = (value) => String(value || '').trim().replace(/\/+$/, '');
        const copyPartyBase = normalizeBaseURL(process.env.VOICELINK_COPYPARTY_BASE || process.env.COPYPARTY_BASE);
        const defaultMacDownloadURL = `${updateHub}/downloads/voicelink/VoiceLink-macOS.zip`;
        const macDownloadMirrors = Array.from(new Set([
            defaultMacDownloadURL,
            ...updatePolicyMirrors.map((base) => `${normalizeBaseURL(base)}/downloads/voicelink/VoiceLink-macOS.zip`),
            copyPartyBase ? `${copyPartyBase}/voicelink/VoiceLink-macOS.zip` : null
        ].filter(Boolean)));
        const defaultPolicy = {
            macos: {
                version: '1.0.0',
                buildNumber: 6,
                downloadURL: defaultMacDownloadURL,
                downloadMirrors: macDownloadMirrors,
                minimumSupportedVersion: '1.0.0',
                required: false,
                requiredReason: '',
                enforcedAfter: null,
                compatibilityModeUntil: null,
                releaseNotes: 'VoiceLink macOS update with updater compatibility and accessibility fixes.'
            },
            windows: {
                version: '1.0.3',
                buildNumber: 3,
                downloadURL: 'https://devinecreations.net/uploads/filedump/voicelink/VoiceLink%20Local-1.0.3-portable.exe',
                minimumSupportedVersion: '1.0.0',
                required: false,
                requiredReason: '',
                enforcedAfter: null,
                compatibilityModeUntil: null,
                releaseNotes: 'Latest Windows release with accessibility improvements and bug fixes.'
            },
            linux: {
                version: '1.0.3',
                buildNumber: 3,
                downloadURL: 'https://devinecreations.net/uploads/filedump/voicelink/VoiceLink-1.0.3-linux.AppImage',
                minimumSupportedVersion: '1.0.0',
                required: false,
                requiredReason: '',
                enforcedAfter: null,
                compatibilityModeUntil: null,
                releaseNotes: 'Linux release with AppImage support.'
            }
        };
        const policyOverrides = (() => {
            const raw = process.env.VOICELINK_UPDATE_POLICY_JSON;
            if (!raw) return {};
            try {
                const parsed = JSON.parse(raw);
                return typeof parsed === 'object' && parsed ? parsed : {};
            } catch (_) {
                return {};
            }
        })();
        const readDiskPolicyOverrides = () => {
            try {
                if (!fs.existsSync(policyFilePath)) return {};
                const parsed = JSON.parse(fs.readFileSync(policyFilePath, 'utf8'));
                return parsed && typeof parsed === 'object' ? parsed : {};
            } catch (_) {
                return {};
            }
        };
        const writeDiskPolicyOverrides = (payload) => {
            try {
                fs.mkdirSync(path.dirname(policyFilePath), { recursive: true });
                fs.writeFileSync(policyFilePath, JSON.stringify(payload, null, 2));
            } catch (error) {
                console.warn('[updates] Failed writing policy file:', error.message);
            }
        };
        let runtimePolicyOverrides = readDiskPolicyOverrides();
        const getMergedPolicy = () => Object.keys(defaultPolicy).reduce((acc, key) => {
            acc[key] = {
                ...defaultPolicy[key],
                ...(runtimePolicyOverrides[key] || {}),
                ...(policyOverrides[key] || {})
            };
            return acc;
        }, {});
        const fetchJSON = (url) => new Promise((resolve, reject) => {
            const client = String(url).startsWith('https://') ? https : http;
            client.get(url, (response) => {
                if (response.statusCode < 200 || response.statusCode > 299) {
                    return reject(new Error(`HTTP ${response.statusCode}`));
                }
                let body = '';
                response.on('data', (chunk) => body += chunk);
                response.on('end', () => {
                    try {
                        resolve(JSON.parse(body));
                    } catch (error) {
                        reject(error);
                    }
                });
            }).on('error', reject);
        });

        const compareVersions = (v1, v2) => {
            const p1 = String(v1 || '0.0.0').split('.').map(Number);
            const p2 = String(v2 || '0.0.0').split('.').map(Number);
            for (let i = 0; i < Math.max(p1.length, p2.length); i++) {
                const n1 = p1[i] || 0;
                const n2 = p2[i] || 0;
                if (n1 > n2) return 1;
                if (n1 < n2) return -1;
            }
            return 0;
        };

        // Policy endpoint for federated/self-hosted nodes to mirror VPS rules.
        this.app.get('/api/updates/policy', (req, res) => {
            const mergedPolicy = getMergedPolicy();
            res.json({
                source: 'local',
                hub: updateHub,
                upstream: upstreamPolicyURL,
                mirrors: updatePolicyMirrors,
                generatedAt: new Date().toISOString(),
                platforms: mergedPolicy
            });
        });

        // Pull update policy from upstream dev/VPS source and persist locally.
        this.app.post('/api/updates/policy/sync', async (req, res) => {
            try {
                const payload = await fetchJSON(upstreamPolicyURL);
                const platforms = payload && payload.platforms && typeof payload.platforms === 'object'
                    ? payload.platforms
                    : null;
                if (!platforms) {
                    return res.status(502).json({ success: false, error: 'Upstream policy payload missing platforms' });
                }
                runtimePolicyOverrides = platforms;
                writeDiskPolicyOverrides(runtimePolicyOverrides);
                return res.json({
                    success: true,
                    syncedAt: new Date().toISOString(),
                    upstream: upstreamPolicyURL,
                    platforms: Object.keys(runtimePolicyOverrides)
                });
            } catch (error) {
                return res.status(502).json({
                    success: false,
                    error: `Failed to sync upstream policy: ${error.message}`,
                    upstream: upstreamPolicyURL
                });
            }
        });

        // Updates check endpoint for desktop/native clients
        this.app.post('/api/updates/check', (req, res) => {
            const mergedPolicy = getMergedPolicy();
            const { platform, currentVersion } = req.body || {};
            const requestedPlatform = String(platform || 'macos').toLowerCase();
            const platformInfo = mergedPolicy[requestedPlatform] || mergedPolicy.macos;
            const current = currentVersion || '0.0.0';

            const hasUpdate = compareVersions(platformInfo.version, current) > 0;
            const belowMinimum = compareVersions(current, platformInfo.minimumSupportedVersion || '0.0.0') < 0;
            const enforcedAt = platformInfo.enforcedAfter ? Date.parse(platformInfo.enforcedAfter) : NaN;
            const enforcedActive = platformInfo.required === true && (
                !platformInfo.enforcedAfter || (!Number.isNaN(enforcedAt) && Date.now() >= enforcedAt)
            );
            const required = belowMinimum || enforcedActive;

            res.json({
                updateAvailable: hasUpdate || required,
                required,
                minimumSupportedVersion: platformInfo.minimumSupportedVersion || null,
                requiredReason: platformInfo.requiredReason || null,
                enforcedAfter: platformInfo.enforcedAfter || null,
                compatibilityModeUntil: platformInfo.compatibilityModeUntil || null,
                policyMirrors: updatePolicyMirrors,
                policyHub: updateHub,
                version: platformInfo.version,
                buildNumber: platformInfo.buildNumber,
                downloadURL: platformInfo.downloadURL || null,
                downloadMirrors: Array.isArray(platformInfo.downloadMirrors) ? platformInfo.downloadMirrors : [],
                releaseNotes: platformInfo.releaseNotes || null,
                platform: requestedPlatform,
                currentVersion: current
            });
        });

        // Get all available downloads
        this.app.get('/api/downloads', (req, res) => {
            res.json({
                platforms: {
                    macos: {
                        version: '1.0.0',
                        downloads: [
                            {
                                name: 'macOS Universal (DMG)',
                                url: 'https://devinecreations.net/uploads/filedump/voicelink/VoiceLink-1.0.0-macos.zip',
                                size: '144 MB',
                                type: 'native'
                            }
                        ]
                    },
                    windows: {
                        version: '1.0.3',
                        downloads: [
                            {
                                name: 'Windows Portable',
                                url: 'https://devinecreations.net/uploads/filedump/voicelink/VoiceLink%20Local-1.0.3-portable.exe',
                                size: '193 MB',
                                type: 'native'
                            },
                            {
                                name: 'Windows Setup',
                                url: 'https://devinecreations.net/uploads/filedump/voicelink/VoiceLink%20Local%20Setup%201.0.3.exe',
                                size: '194 MB',
                                type: 'native'
                            }
                        ]
                    },
                    linux: {
                        version: '1.0.3',
                        downloads: []
                    }
                },
                webClient: {
                    url: 'https://voicelink.devinecreations.net/',
                    description: 'No download required - access directly from your browser'
                }
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

        // Serve downloads page
        this.app.get('/downloads.html', (req, res) => {
            res.sendFile(path.join(__dirname, '..', '..', 'client', 'downloads.html'));
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
                { name: 'General Chat', description: 'Open space for casual conversations and meeting new people', maxUsers: 50, visibility: 'public' },
                { name: 'Music Lounge', description: 'Relaxed atmosphere to share and discuss music together', maxUsers: 20, visibility: 'public' },
                { name: 'Gaming Voice', description: 'Voice chat for gamers to coordinate and hang out', maxUsers: 10, visibility: 'public' },
                { name: 'Podcast Studio', description: 'Professional space for recording podcasts and interviews', maxUsers: 5, visibility: 'public' },
                { name: 'Chill Zone', description: 'Laid-back vibes for unwinding and casual chat', maxUsers: 30, visibility: 'public' },
                { name: 'Tech Talk', description: 'Discuss technology, coding, and the latest innovations', maxUsers: 25, visibility: 'public' },
                { name: 'Creative Corner', description: 'Space for artists, writers, and creators to collaborate', maxUsers: 15, visibility: 'public' },
                { name: 'Late Night', description: 'Night owl hangout for those burning the midnight oil', maxUsers: 20, visibility: 'public' }
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
                        description: roomConfig.description,
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
        this.integrationTokens = this.integrationTokens || new Map(); // integrationToken -> scoped bridge token

        const ensureAuthorized = (req, res, { requiredPermissions = [], roomId = null } = {}) => {
            const token = this.extractTokenFromRequest(req);
            const resolved = this.resolvePrincipalFromToken(token, req);
            if (!resolved.valid) {
                res.status(resolved.status || 401).json({ success: false, error: resolved.error || 'Unauthorized' });
                return null;
            }

            const principal = resolved.principal;
            for (const permission of this.normalizeTokenPermissions(requiredPermissions)) {
                if (!this.hasTokenPermission(principal.permissions, permission)) {
                    res.status(403).json({ success: false, error: `Missing permission: ${permission}` });
                    return null;
                }
            }

            if (roomId && principal.roomScope && !principal.isAdmin && principal.roomScope !== roomId) {
                res.status(403).json({ success: false, error: 'Token does not permit this room' });
                return null;
            }

            req.voicelinkPrincipal = principal;
            return principal;
        };

        const hasAdminAccess = (req) => {
            if (this.isAdminRequest(req)) return true;
            const token = this.extractTokenFromRequest(req);
            const resolved = this.resolvePrincipalFromToken(token, req);
            return Boolean(resolved.valid && resolved.principal?.isAdmin);
        };

        // ============================================
        // PUSHOVER NOTIFICATION ENDPOINTS
        // ============================================

        this.app.get('/api/notifications/pushover/status', (req, res) => {
            if (!hasAdminAccess(req)) {
                return res.status(403).json({ success: false, error: 'Admin access required' });
            }
            return res.json({
                success: true,
                config: this.maskedPushoverConfig(),
                inboxCount: this.notificationInbox.length
            });
        });

        this.app.post('/api/notifications/pushover/config', (req, res) => {
            if (!hasAdminAccess(req)) {
                return res.status(403).json({ success: false, error: 'Admin access required' });
            }
            const body = req.body || {};
            const config = this.pushoverConfig || {};
            if (body.appToken !== undefined) config.appToken = String(body.appToken || '').trim();
            if (body.userKey !== undefined) config.userKey = String(body.userKey || '').trim();
            if (body.device !== undefined) config.device = String(body.device || '').trim();
            if (body.sound !== undefined) config.sound = String(body.sound || '').trim();
            if (body.priority !== undefined) config.priority = Number(body.priority || 0);
            if (body.titlePrefix !== undefined) config.titlePrefix = String(body.titlePrefix || 'VoiceLink').trim() || 'VoiceLink';
            if (body.enabled !== undefined) config.enabled = Boolean(body.enabled);
            if (body.minDeferredSeconds !== undefined) config.minDeferredSeconds = Math.max(1, Number(body.minDeferredSeconds || 15));
            if (body.maxDeferredSeconds !== undefined) config.maxDeferredSeconds = Math.max(config.minDeferredSeconds || 15, Number(body.maxDeferredSeconds || 120));
            config.updatedAt = new Date().toISOString();
            this.pushoverConfig = config;

            const deferApply = body.deferApply !== false;
            if (config.enabled && config.appToken && config.userKey) {
                if (deferApply) {
                    this.schedulePushoverActivation();
                } else {
                    config.pendingActivationUntil = null;
                    config.active = true;
                    this.savePushoverConfig();
                }
            } else {
                config.active = false;
                config.pendingActivationUntil = null;
                this.savePushoverConfig();
            }

            return res.json({ success: true, config: this.maskedPushoverConfig() });
        });

        this.app.post('/api/notifications/pushover/test', async (req, res) => {
            if (!hasAdminAccess(req)) {
                return res.status(403).json({ success: false, error: 'Admin access required' });
            }
            const title = req.body?.title || `${this.pushoverConfig.titlePrefix || 'VoiceLink'} Test`;
            const message = req.body?.message || 'Pushover test notification from VoiceLink.';
            const result = await this.sendPushoverNotification({ title, message });
            return res.status(result.success ? 200 : 400).json({ success: result.success, ...result });
        });

        this.app.post('/api/notifications/pushover/send', async (req, res) => {
            if (!hasAdminAccess(req)) {
                return res.status(403).json({ success: false, error: 'Admin access required' });
            }
            const title = String(req.body?.title || `${this.pushoverConfig.titlePrefix || 'VoiceLink'} Event`).trim();
            const message = String(req.body?.message || 'VoiceLink notification event').trim();
            const url = String(req.body?.url || '').trim();
            const urlTitle = String(req.body?.urlTitle || '').trim();
            const result = await this.sendPushoverNotification({ title, message, url, urlTitle });
            return res.status(result.success ? 200 : 400).json({ success: result.success, ...result });
        });

        // Incoming/webhook notifications support (receive path).
        this.app.post('/api/notifications/incoming', (req, res) => {
            const webhookSecret = String(process.env.VOICELINK_NOTIFICATION_WEBHOOK_SECRET || '').trim();
            const providedSecret = String(req.headers['x-voicelink-secret'] || req.body?.secret || '').trim();
            if (webhookSecret && providedSecret !== webhookSecret) {
                return res.status(403).json({ success: false, error: 'Invalid notification secret' });
            }

            const event = {
                id: `notif_${Date.now()}_${Math.random().toString(36).slice(2, 8)}`,
                source: String(req.body?.source || 'external').trim(),
                title: String(req.body?.title || 'Incoming notification').trim(),
                message: String(req.body?.message || '').trim(),
                level: String(req.body?.level || 'info').trim(),
                payload: req.body?.payload || {},
                receivedAt: new Date().toISOString()
            };
            this.notificationInbox.unshift(event);
            this.notificationInbox = this.notificationInbox.slice(0, 500);
            this.io.emit('notification-received', event);
            return res.json({ success: true, eventId: event.id });
        });

        this.app.get('/api/notifications/incoming', (req, res) => {
            if (!hasAdminAccess(req)) {
                return res.status(403).json({ success: false, error: 'Admin access required' });
            }
            const limit = Math.min(200, Math.max(1, Number(req.query.limit || 50)));
            return res.json({ success: true, notifications: this.notificationInbox.slice(0, limit) });
        });

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
            const { apiKey, userId, userName, externalId, metadata = {}, provider, roles, groups, isAdmin } = req.body;

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

            const roleContext = RoleMapper.normalizeIdentity({
                provider: provider || metadata.provider || metadata.source || 'unknown',
                roles: roles || metadata.roles || [],
                groups: groups || metadata.groups || [],
                userName: userName || metadata.userName || metadata.username || '',
                userId: userId || externalId || '',
                email: metadata.email || metadata.userEmail || '',
                isAuthenticated: true,
                isAdmin: Boolean(isAdmin || metadata.isAdmin)
            });

            this.apiSessions.set(sessionToken, {
                userId: userId || externalId,
                userName,
                externalId,
                apiKey,
                appName: keyData.name,
                metadata,
                roleContext,
                createdAt: new Date(),
                expiresAt: new Date(Date.now() + 86400000) // 24 hours
            });

            res.json({
                success: true,
                sessionToken,
                roleContext,
                expiresAt: this.apiSessions.get(sessionToken).expiresAt
            });
        });

        // Resolve Mastodon OAuth scope policy by user role + instance.
        this.app.get('/api/auth/mastodon/scope-policy', (req, res) => {
            try {
                const policy = this.getMastodonScopePolicy({
                    instance: req.query.instance || '',
                    username: req.query.username || req.query.user || '',
                    email: req.query.email || '',
                    requestElevated: req.query.requestElevated
                });
                res.json({ success: true, ...policy });
            } catch (error) {
                console.error('[Auth] Failed to resolve Mastodon scope policy:', error.message);
                res.status(500).json({ success: false, error: 'Failed to resolve Mastodon scope policy' });
            }
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
                roleContext: session.roleContext || null,
                expiresAt: session.expiresAt
            });
        });

        // Resolve caller identity from token (session, api key, or integration token)
        this.app.get('/api/auth/me', (req, res) => {
            const token = this.extractTokenFromRequest(req);
            const resolved = this.resolvePrincipalFromToken(token, req);
            if (!resolved.valid) {
                return res.status(resolved.status || 401).json({ success: false, error: resolved.error || 'Unauthorized' });
            }
            const principal = resolved.principal;
            res.json({
                success: true,
                tokenType: principal.tokenType,
                name: principal.name,
                userId: principal.userId || null,
                userName: principal.userName || null,
                roomScope: principal.roomScope || null,
                permissions: principal.permissions,
                roleContext: principal.roleContext || null,
                isAdmin: Boolean(principal.isAdmin),
                expiresAt: principal.expiresAt || null
            });
        });

        // Introspect arbitrary token (for OpenClaw bridge and service integrations)
        this.app.post('/api/auth/introspect', (req, res) => {
            const token = String(req.body?.token || '').trim() || this.extractTokenFromRequest(req);
            const resolved = this.resolvePrincipalFromToken(token, req);
            if (!resolved.valid) {
                return res.status(resolved.status || 401).json({ success: false, valid: false, error: resolved.error || 'Unauthorized' });
            }
            const principal = resolved.principal;
            res.json({
                success: true,
                valid: true,
                principal: {
                    tokenType: principal.tokenType,
                    name: principal.name,
                    userId: principal.userId || null,
                    userName: principal.userName || null,
                    roomScope: principal.roomScope || null,
                    permissions: principal.permissions,
                    roleContext: principal.roleContext || null,
                    isAdmin: Boolean(principal.isAdmin),
                    expiresAt: principal.expiresAt || null
                }
            });
        });

        // VoiceLink agent safety policy (supports OpenClaw and other agents).
        this.app.get('/api/agents/policy', (req, res) => {
            const token = this.extractTokenFromRequest(req);
            const resolved = token ? this.resolvePrincipalFromToken(token, req) : null;
            const principal = resolved?.valid ? resolved.principal : null;
            const runtime = principal ? this.getAgentRuntimePolicy(principal) : this.getAgentRuntimePolicy({});
            res.json({
                success: true,
                version: this.agentPolicy.version || 1,
                safetyRules: this.agentPolicy.safetyRules || [],
                defaultStatusTemplates: this.agentPolicy.defaultStatusTemplates || {},
                effective: runtime
            });
        });

        // Exchange session/api key auth into a scoped integration token for room agents/OpenClaw.
        this.app.post('/api/auth/token', (req, res) => {
            const requestedPermissions = this.normalizeTokenPermissions(
                req.body?.permissions && req.body.permissions.length
                    ? req.body.permissions
                    : ['agent.chat']
            );
            const roomScope = req.body?.roomId ? String(req.body.roomId).trim() : null;
            const tokenLabel = String(req.body?.name || 'voicelink-integration').trim();
            const requestedLifetimeMs = Number(req.body?.expiresInMs || 3600000);
            const expiresInMs = Math.max(60000, Math.min(requestedLifetimeMs, 7 * 24 * 60 * 60 * 1000));

            const callerToken = this.extractTokenFromRequest(req) || String(req.body?.sessionToken || req.body?.apiKey || '').trim();
            const callerResolved = this.resolvePrincipalFromToken(callerToken, req);
            if (!callerResolved.valid) {
                return res.status(callerResolved.status || 401).json({ success: false, error: callerResolved.error || 'Unauthorized' });
            }
            const caller = callerResolved.principal;

            const isRequestingAdminOps = requestedPermissions.some((permission) => (
                permission.startsWith('admin.') || permission === 'admin.panel' || permission === 'agent.admin'
            ));
            if (isRequestingAdminOps && !caller.isAdmin) {
                return res.status(403).json({ success: false, error: 'Admin permissions require admin role' });
            }
            for (const permission of requestedPermissions) {
                if (!this.hasTokenPermission(caller.permissions, permission) && !caller.isAdmin) {
                    return res.status(403).json({ success: false, error: `Cannot mint permission not held by caller: ${permission}` });
                }
            }

            const integrationToken = `vlt_${uuidv4().replace(/-/g, '')}_${Date.now().toString(36)}`;
            const expiresAt = new Date(Date.now() + expiresInMs).toISOString();
            this.integrationTokens.set(integrationToken, {
                name: tokenLabel,
                issuedByType: caller.tokenType,
                issuedByName: caller.name,
                userId: caller.userId || '',
                userName: caller.userName || '',
                roleContext: caller.roleContext || null,
                permissions: requestedPermissions,
                roomScope,
                metadata: req.body?.metadata || {},
                createdAt: new Date().toISOString(),
                expiresAt
            });

            res.json({
                success: true,
                token: integrationToken,
                tokenType: 'integration',
                name: tokenLabel,
                permissions: requestedPermissions,
                roomScope,
                expiresAt
            });
        });

        // Upload profile avatar/photo for logged-in users.
        this.app.post('/api/profile/avatar/upload', (req, res) => {
            const token = this.extractTokenFromRequest(req);
            const resolved = this.resolvePrincipalFromToken(token, req);
            if (!resolved.valid) {
                return res.status(401).json({ success: false, error: 'Login required for avatar upload' });
            }

            const imageData = String(req.body?.imageData || '').trim();
            const caption = String(req.body?.caption || '').trim();
            const preserveMetadata = req.body?.preserveMetadata !== false;
            const removeMetadataFields = Array.isArray(req.body?.removeMetadataFields)
                ? req.body.removeMetadataFields.map((v) => String(v || '').trim()).filter(Boolean)
                : [];
            const providedMetadata = (req.body?.metadata && typeof req.body.metadata === 'object')
                ? req.body.metadata
                : {};
            if (!imageData.startsWith('data:image/')) {
                return res.status(400).json({ success: false, error: 'imageData must be a data:image/* URL' });
            }

            const match = imageData.match(/^data:(image\/[a-zA-Z0-9.+-]+);base64,(.+)$/);
            if (!match) {
                return res.status(400).json({ success: false, error: 'Invalid image data format' });
            }

            const mime = String(match[1] || '').toLowerCase();
            const base64Body = match[2] || '';
            const extensionByMime = {
                'image/jpeg': 'jpg',
                'image/jpg': 'jpg',
                'image/png': 'png',
                'image/webp': 'webp',
                'image/gif': 'gif'
            };
            const ext = extensionByMime[mime];
            if (!ext) {
                return res.status(400).json({ success: false, error: 'Unsupported image type' });
            }

            let fileBuffer;
            try {
                fileBuffer = Buffer.from(base64Body, 'base64');
            } catch {
                return res.status(400).json({ success: false, error: 'Invalid base64 image data' });
            }

            const maxBytes = 8 * 1024 * 1024;
            if (!fileBuffer || fileBuffer.length === 0) {
                return res.status(400).json({ success: false, error: 'Image is empty' });
            }
            if (fileBuffer.length > maxBytes) {
                return res.status(413).json({ success: false, error: 'Image too large (max 8MB)' });
            }

            const fileName = `avatar-${Date.now()}-${uuidv4().slice(0, 8)}.${ext}`;
            const uploadDir = path.join(__dirname, '../../data/uploads/avatars');

            try {
                fs.mkdirSync(uploadDir, { recursive: true });
                fs.writeFileSync(path.join(uploadDir, fileName), fileBuffer);
            } catch (error) {
                return res.status(500).json({ success: false, error: 'Failed to store avatar image', details: error.message });
            }

            const relativeUrl = `/uploads/avatars/${fileName}`;
            const origin = `${req.protocol}://${req.get('host')}`;
            const metadataPath = path.join(uploadDir, `${fileName}.json`);
            const metadataRecord = {
                fileName,
                mime,
                uploadedAt: new Date().toISOString(),
                preserveMetadata,
                removeMetadataFields,
                caption: caption || null,
                metadata: preserveMetadata ? { ...providedMetadata } : {}
            };
            const blockedPersonalMetadataKeys = new Set([
                'fileName',
                'originalFileName',
                'userName',
                'userId',
                'email',
                'fullName',
                'owner',
                'author'
            ]);
            for (const key of Array.from(Object.keys(metadataRecord.metadata || {}))) {
                if (blockedPersonalMetadataKeys.has(String(key))) {
                    delete metadataRecord.metadata[key];
                }
            }
            for (const key of removeMetadataFields) {
                delete metadataRecord.metadata[key];
            }
            try {
                fs.writeFileSync(metadataPath, JSON.stringify(metadataRecord, null, 2), 'utf8');
            } catch (error) {
                return res.status(500).json({ success: false, error: 'Avatar saved, but metadata record failed', details: error.message });
            }

            return res.json({
                success: true,
                url: relativeUrl,
                fullUrl: `${origin}${relativeUrl}`,
                bytes: fileBuffer.length,
                caption: caption || null,
                metadata: metadataRecord.metadata
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
            this.joinTokens.set(joinToken, {
                sessionToken,
                userId: session.userId,
                userName: session.userName,
                externalId: session.externalId,
                roleContext: session.roleContext || null,
                metadata: session.metadata || {},
                createdAt: new Date(),
                expiresAt: new Date(Date.now() + 15 * 60 * 1000)
            });

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

        // Room-scoped agent presence/status. Agent does not have to be active in all rooms.
        this.app.get('/api/rooms/:roomId/agent/status', (req, res) => {
            const roomId = String(req.params.roomId || '').trim();
            const room = this.rooms.get(roomId);
            if (!room) {
                return res.status(404).json({ success: false, error: 'Room not found' });
            }
            res.json({
                success: true,
                roomId,
                roomName: room.name,
                agent: this.getRoomAgentState(roomId)
            });
        });

        // Configure room agent presence/status text (owner/admin/mod context).
        this.app.put('/api/rooms/:roomId/agent/status', (req, res) => {
            const roomId = String(req.params.roomId || '').trim();
            const room = this.rooms.get(roomId);
            if (!room) {
                return res.status(404).json({ success: false, error: 'Room not found' });
            }
            const principal = ensureAuthorized(req, res, { requiredPermissions: ['agent.chat'], roomId });
            if (!principal) return;
            if (!this.canManageRoomAgent(principal, room) && !this.hasTokenPermission(principal.permissions, 'agent.admin')) {
                return res.status(403).json({ success: false, error: 'Only room owner/admin can manage room agent status' });
            }

            const previous = this.getRoomAgentState(roomId);
            const enabled = req.body?.enabled !== undefined ? Boolean(req.body.enabled) : previous.enabled;
            const statusType = String(req.body?.statusType || (enabled ? 'available' : 'offline')).trim().toLowerCase();
            const templates = this.agentPolicy?.defaultStatusTemplates || {};
            const statusText = String(
                req.body?.statusText ||
                templates[statusType] ||
                (enabled ? templates.available : templates.offline) ||
                (enabled ? "I'm here to help you manage your room." : 'No room agent active.')
            ).trim();
            const nextState = {
                ...previous,
                enabled,
                present: enabled,
                roomScoped: true,
                statusType,
                statusText,
                agentId: String(req.body?.agentId || previous.agentId || 'openclaw'),
                agentName: String(req.body?.agentName || previous.agentName || 'VoiceLink Agent'),
                allowedActions: this.normalizeTokenPermissions(req.body?.allowedActions || previous.allowedActions || ['chat']),
                updatedAt: new Date().toISOString(),
                updatedBy: principal.userName || principal.userId || principal.name || 'system'
            };
            this.roomAgents.set(roomId, nextState);
            this.io.to(roomId).emit('room-agent-status', { roomId, agent: nextState });

            res.json({
                success: true,
                roomId,
                roomName: room.name,
                agent: nextState
            });
        });

        // Room agent chat bridge to OpenClaw.
        this.app.post('/api/rooms/:roomId/agent/chat', async (req, res) => {
            const roomId = String(req.params.roomId || '').trim();
            const room = this.rooms.get(roomId);
            if (!room) {
                return res.status(404).json({ success: false, error: 'Room not found' });
            }
            const principal = ensureAuthorized(req, res, { requiredPermissions: ['agent.chat'], roomId });
            if (!principal) return;

            const agentState = this.getRoomAgentState(roomId);
            if (!agentState.enabled) {
                return res.status(409).json({
                    success: false,
                    error: 'No room agent is active in this room',
                    roomId,
                    agent: agentState
                });
            }

            const message = String(req.body?.message || '').trim();
            if (!message) {
                return res.status(400).json({ success: false, error: 'Message is required' });
            }

            const runtimePolicy = this.getAgentRuntimePolicy(principal);
            if (message.length > runtimePolicy.maxMessageLength) {
                return res.status(400).json({
                    success: false,
                    error: `Message exceeds max length (${runtimePolicy.maxMessageLength})`
                });
            }

            const intent = String(req.body?.intent || 'chat').trim().toLowerCase();
            const intentAllowed = runtimePolicy.allowedIntents.includes(intent) || runtimePolicy.allowedIntents.includes('*');
            if (!intentAllowed && !principal.isAdmin) {
                return res.status(403).json({
                    success: false,
                    error: `Intent not allowed for role ${runtimePolicy.role}`,
                    allowedIntents: runtimePolicy.allowedIntents
                });
            }
            const privilegedIntents = new Set(['admin', 'moderate', 'manage_room', 'run_admin_action']);
            if (privilegedIntents.has(intent) && !principal.isAdmin && !this.hasTokenPermission(principal.permissions, 'agent.admin')) {
                return res.status(403).json({ success: false, error: 'Admin permission required for this intent' });
            }

            const targetUserId = String(req.body?.targetUserId || '').trim();
            if (targetUserId && principal.userId && targetUserId !== principal.userId && !principal.isAdmin) {
                return res.status(403).json({ success: false, error: 'Cannot perform account actions for another user' });
            }

            const openClawBaseUrl = String(process.env.OPENCLAW_API_URL || 'http://127.0.0.1:18789').trim().replace(/\/+$/, '');
            const openClawChatPath = String(process.env.OPENCLAW_CHAT_PATH || '/api/chat').trim();
            const openClawToken = String(process.env.OPENCLAW_API_TOKEN || '').trim();
            const upstreamUrl = `${openClawBaseUrl}${openClawChatPath.startsWith('/') ? openClawChatPath : `/${openClawChatPath}`}`;

            const upstreamPayload = {
                roomId,
                roomName: room.name,
                message,
                intent,
                actor: {
                    tokenType: principal.tokenType,
                    userId: principal.userId || null,
                    userName: principal.userName || null,
                    isAdmin: Boolean(principal.isAdmin),
                    roleContext: principal.roleContext || null,
                    permissions: principal.permissions || []
                },
                metadata: req.body?.metadata || {}
            };

            try {
                const response = await fetch(upstreamUrl, {
                    method: 'POST',
                    headers: {
                        'Content-Type': 'application/json',
                        ...(openClawToken ? { Authorization: `Bearer ${openClawToken}` } : {})
                    },
                    body: JSON.stringify(upstreamPayload)
                });

                const contentType = String(response.headers.get('content-type') || '').toLowerCase();
                const body = contentType.includes('application/json')
                    ? await response.json().catch(() => ({}))
                    : { text: await response.text().catch(() => '') };

                if (!response.ok) {
                    return res.status(502).json({
                        success: false,
                        error: 'OpenClaw request failed',
                        upstreamStatus: response.status,
                        upstreamBody: body
                    });
                }

                const replyText = typeof body?.reply === 'string'
                    ? body.reply
                    : (typeof body?.message === 'string' ? body.message : null);
                if (replyText) {
                    this.io.to(roomId).emit('agent-message', {
                        id: uuidv4(),
                        roomId,
                        agentId: agentState.agentId,
                        agentName: agentState.agentName,
                        message: replyText,
                        timestamp: new Date().toISOString()
                    });
                }

                return res.json({
                    success: true,
                    roomId,
                    agent: {
                        agentId: agentState.agentId,
                        agentName: agentState.agentName,
                        statusType: agentState.statusType,
                        statusText: agentState.statusText
                    },
                    response: body
                });
            } catch (error) {
                return res.status(502).json({
                    success: false,
                    error: 'Failed to connect to OpenClaw endpoint',
                    details: error.message
                });
            }
        });

        // Admin-only room actions from room agent context.
        this.app.post('/api/rooms/:roomId/agent/action', (req, res) => {
            const roomId = String(req.params.roomId || '').trim();
            const room = this.rooms.get(roomId);
            if (!room) {
                return res.status(404).json({ success: false, error: 'Room not found' });
            }
            const principal = ensureAuthorized(req, res, { requiredPermissions: ['agent.admin'], roomId });
            if (!principal) return;
            if (!principal.isAdmin && !this.canManageRoomAgent(principal, room)) {
                return res.status(403).json({ success: false, error: 'Admin or room owner role required' });
            }

            const action = String(req.body?.action || '').trim().toLowerCase();
            const actorName = principal.userName || principal.userId || principal.name || 'agent';
            if (!action) {
                return res.status(400).json({ success: false, error: 'Action is required' });
            }
            const runtimePolicy = this.getAgentRuntimePolicy(principal);
            const actionAllowed = runtimePolicy.allowedActions.includes(action) || runtimePolicy.allowedActions.includes('*');
            if (!actionAllowed && !principal.isAdmin) {
                return res.status(403).json({
                    success: false,
                    error: `Action not allowed for role ${runtimePolicy.role}`,
                    allowedActions: runtimePolicy.allowedActions
                });
            }

            if (action === 'lock_room') {
                const result = this.lockRoom(roomId, actorName, String(req.body?.reason || 'Locked by room agent').trim());
                return res.json(result);
            }
            if (action === 'unlock_room') {
                const result = this.unlockRoom(roomId, actorName);
                return res.json(result);
            }
            if (action === 'announce') {
                const announcement = String(req.body?.message || '').trim();
                if (!announcement) {
                    return res.status(400).json({ success: false, error: 'Announcement message is required' });
                }
                this.io.to(roomId).emit('notification', {
                    type: 'room-agent',
                    roomId,
                    message: announcement,
                    by: actorName,
                    timestamp: new Date().toISOString()
                });
                return res.json({ success: true, roomId, message: announcement });
            }

            return res.status(400).json({
                success: false,
                error: 'Unsupported action',
                supportedActions: ['lock_room', 'unlock_room', 'announce']
            });
        });

        // Normalize external roles from provider into VoiceLink-native role model
        this.app.post('/api/roles/normalize', (req, res) => {
            const normalized = RoleMapper.normalizeIdentity(req.body || {});
            res.json({
                success: true,
                voicelinkRoleContext: normalized
            });
        });

        // Composr integration endpoints (optional/future-safe)
        this.app.get('/api/integrations/composr/status', (req, res) => {
            const composrBase = process.env.COMPOSR_BASE_URL || 'https://devinecreations.net';
            res.json({
                success: true,
                provider: 'composr',
                configuredBaseURL: composrBase,
                roleModel: 'voicelink',
                notes: 'Dormant by default. Use /api/integrations/composr/session when Composr auth is enabled.'
            });
        });

        this.app.post('/api/integrations/composr/session', (req, res) => {
            const body = req.body || {};
            const roleContext = RoleMapper.normalizeIdentity({
                provider: 'composr',
                roles: body.roles || body.composrGroups || [],
                groups: body.groups || [],
                userName: body.userName || body.username || '',
                userId: body.userId || body.externalId || '',
                email: body.email || body.userEmail || '',
                isAuthenticated: true,
                isAdmin: Boolean(body.isAdmin)
            });

            const sessionToken = 'vls_' + uuidv4() + '_' + Date.now().toString(36);
            this.apiSessions.set(sessionToken, {
                userId: body.userId || body.externalId || `composr_${Date.now()}`,
                userName: body.userName || body.username || 'Composr User',
                externalId: body.externalId || body.userId || null,
                apiKey: 'composr-direct',
                appName: 'composr',
                metadata: {
                    provider: 'composr',
                    composr: {
                        memberId: body.memberId || null,
                        forumUsername: body.forumUsername || body.username || null
                    }
                },
                roleContext,
                createdAt: new Date(),
                expiresAt: new Date(Date.now() + 24 * 60 * 60 * 1000)
            });

            res.json({
                success: true,
                provider: 'composr',
                sessionToken,
                roleContext,
                expiresAt: this.apiSessions.get(sessionToken).expiresAt
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
        // DEVICE PAIRING & MANAGEMENT
        // Remote authentication and access control
        // ============================================

        // Store for linked devices and pending email verifications
        this.linkedDevices = new Map(); // deviceId -> LinkedDevice
        this.pairingCodes = new Map(); // code -> { expiresAt, serverInfo }
        this.emailVerificationCodes = new Map(); // email -> { code, expiresAt, clientId }

        // Generate pairing code for this server
        this.app.post('/api/pairing/generate', (req, res) => {
            // Generate 6-character code (no confusing chars)
            const chars = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
            let code = '';
            for (let i = 0; i < 6; i++) {
                code += chars[Math.floor(Math.random() * chars.length)];
            }

            this.pairingCodes.set(code, {
                expiresAt: new Date(Date.now() + 60000), // 60 seconds
                serverInfo: {
                    id: this.serverId,
                    name: this.serverName || 'VoiceLink Server',
                    url: req.protocol + '://' + req.get('host')
                }
            });

            // Auto-cleanup after expiry
            setTimeout(() => {
                this.pairingCodes.delete(code);
            }, 60000);

            res.json({
                success: true,
                code,
                expiresAt: new Date(Date.now() + 60000)
            });
        });

        // Pair device with this server
        this.app.post('/api/pair', (req, res) => {
            const { code, clientId, clientName, authMethod, authToken, authUserId, authUsername, mastodonInstance, email } = req.body;

            if (!code || !clientId) {
                return res.status(400).json({ error: 'Code and client ID required' });
            }

            // Validate pairing code
            const pairingData = this.pairingCodes.get(code.toUpperCase());
            if (!pairingData) {
                return res.status(400).json({ error: 'Invalid or expired pairing code' });
            }

            if (new Date() > pairingData.expiresAt) {
                this.pairingCodes.delete(code.toUpperCase());
                return res.status(400).json({ error: 'Pairing code expired' });
            }

            // Generate access token for this device
            const accessToken = 'vldev_' + uuidv4() + '_' + Date.now().toString(36);
            const deviceId = 'dev_' + uuidv4().substring(0, 8);

            const linkedDevice = {
                id: deviceId,
                deviceName: clientName || 'Unknown Device',
                clientId,
                authMethod: authMethod || 'pairing',
                authUserId,
                authUsername,
                mastodonInstance,
                email,
                accessToken,
                linkedAt: new Date(),
                lastSeen: new Date(),
                isRevoked: false
            };

            this.linkedDevices.set(deviceId, linkedDevice);

            // Remove used pairing code
            this.pairingCodes.delete(code.toUpperCase());

            // Notify via WebSocket if available
            if (this.io) {
                this.io.emit('device-linked', {
                    deviceId,
                    deviceName: clientName,
                    authMethod
                });
            }

            res.json({
                success: true,
                accessToken,
                server: pairingData.serverInfo
            });
        });

        // Unlink device (client-initiated)
        this.app.post('/api/unlink', (req, res) => {
            const { clientId } = req.body;
            const authHeader = req.headers.authorization;

            let deviceFound = false;

            this.linkedDevices.forEach((device, id) => {
                if (device.clientId === clientId || device.accessToken === authHeader) {
                    this.linkedDevices.delete(id);
                    deviceFound = true;

                    // Notify via WebSocket
                    if (this.io) {
                        this.io.emit('device-unlinked', { deviceId: id });
                    }
                }
            });

            res.json({ success: deviceFound });
        });

        // List linked devices (server admin)
        this.app.get('/api/devices', (req, res) => {
            const devices = [];
            this.linkedDevices.forEach((device, id) => {
                devices.push({
                    id: device.id,
                    deviceName: device.deviceName,
                    authMethod: device.authMethod,
                    authUsername: device.authUsername,
                    linkedAt: device.linkedAt,
                    lastSeen: device.lastSeen,
                    isRevoked: device.isRevoked
                });
            });
            res.json({ devices });
        });

        // Revoke device access (server-initiated)
        this.app.post('/api/devices/:deviceId/revoke', (req, res) => {
            const { deviceId } = req.params;
            const device = this.linkedDevices.get(deviceId);

            if (!device) {
                return res.status(404).json({ error: 'Device not found' });
            }

            device.isRevoked = true;
            device.accessToken = null;

            // Notify device via WebSocket
            if (this.io) {
                this.io.emit('access-revoked', {
                    deviceId,
                    reason: req.body.reason || 'Access revoked by server administrator'
                });
            }

            res.json({ success: true, message: 'Device access revoked' });
        });

        // Delete device completely
        this.app.delete('/api/devices/:deviceId', (req, res) => {
            const { deviceId } = req.params;

            if (!this.linkedDevices.has(deviceId)) {
                return res.status(404).json({ error: 'Device not found' });
            }

            this.linkedDevices.delete(deviceId);

            // Notify via WebSocket
            if (this.io) {
                this.io.emit('device-removed', { deviceId });
            }

            res.json({ success: true, message: 'Device removed' });
        });

        // ============================================
        // EMAIL VERIFICATION
        // For email-based authentication
        // ============================================

        // Request email verification code
        this.app.post('/api/auth/email/request', async (req, res) => {
            const { email, clientId, clientName } = req.body;

            if (!email || !clientId) {
                return res.status(400).json({ error: 'Email and client ID required' });
            }

            // Validate email format
            const emailRegex = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
            if (!emailRegex.test(email)) {
                return res.status(400).json({ error: 'Invalid email format' });
            }

            // Rate limiting - check if code was recently sent
            const existing = this.emailVerificationCodes.get(email);
            if (existing && new Date() < new Date(existing.createdAt.getTime() + 60000)) {
                return res.status(429).json({ error: 'Please wait before requesting another code' });
            }

            // Generate 6-digit verification code
            const code = Math.floor(100000 + Math.random() * 900000).toString();

            this.emailVerificationCodes.set(email, {
                code,
                clientId,
                clientName,
                createdAt: new Date(),
                expiresAt: new Date(Date.now() + 300000), // 5 minutes
                attempts: 0
            });

            // Auto-cleanup after expiry
            setTimeout(() => {
                this.emailVerificationCodes.delete(email);
            }, 300000);

            // Try to send email if nodemailer is configured
            try {
                if (this.mailer) {
                    await this.mailer.sendMail({
                        from: this.emailFrom || 'noreply@voicelink.local',
                        to: email,
                        subject: 'VoiceLink Verification Code',
                        text: `Your VoiceLink verification code is: ${code}\n\nThis code expires in 5 minutes.\n\nIf you did not request this code, please ignore this email.`,
                        html: `
                            <div style="font-family: sans-serif; max-width: 400px; margin: 0 auto; padding: 20px;">
                                <h2 style="color: #6366f1;">VoiceLink Verification</h2>
                                <p>Your verification code is:</p>
                                <div style="font-size: 32px; font-weight: bold; letter-spacing: 4px; padding: 20px; background: #f3f4f6; border-radius: 8px; text-align: center;">
                                    ${code}
                                </div>
                                <p style="color: #666; font-size: 14px;">This code expires in 5 minutes.</p>
                                <p style="color: #999; font-size: 12px;">If you did not request this code, please ignore this email.</p>
                            </div>
                        `
                    });
                    res.json({ success: true, message: 'Verification code sent to email' });
                } else {
                    // No mailer configured - return code in response for testing
                    console.log(`[Email Verification] Code for ${email}: ${code}`);
                    res.json({
                        success: true,
                        message: 'Verification code generated (email not configured)',
                        // Only include code in development/testing
                        ...(process.env.NODE_ENV !== 'production' && { testCode: code })
                    });
                }
            } catch (err) {
                console.error('Failed to send verification email:', err);
                res.status(500).json({ error: 'Failed to send verification email' });
            }
        });

        // Verify email code
        this.app.post('/api/auth/email/verify', (req, res) => {
            const { email, code, clientId } = req.body;

            if (!email || !code) {
                return res.status(400).json({ error: 'Email and code required' });
            }

            const verification = this.emailVerificationCodes.get(email);

            if (!verification) {
                return res.status(400).json({ error: 'No verification pending for this email' });
            }

            if (new Date() > verification.expiresAt) {
                this.emailVerificationCodes.delete(email);
                return res.status(400).json({ error: 'Verification code expired' });
            }

            // Check attempts
            verification.attempts++;
            if (verification.attempts > 5) {
                this.emailVerificationCodes.delete(email);
                return res.status(429).json({ error: 'Too many attempts. Please request a new code.' });
            }

            if (verification.code !== code.toString()) {
                return res.status(400).json({ error: 'Invalid verification code' });
            }

            // Success - generate access token
            const accessToken = 'vlemail_' + uuidv4() + '_' + Date.now().toString(36);
            const userId = 'user_' + email.replace(/[^a-z0-9]/gi, '_').substring(0, 20) + '_' + Date.now().toString(36);

            // Clean up verification code
            this.emailVerificationCodes.delete(email);

            res.json({
                success: true,
                accessToken,
                userId,
                email
            });
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

        // Discover Jellyfin servers on the local network
        this.app.get('/api/jellyfin/discover', async (req, res) => {
            const discoveredServers = [];
            const timeout = parseInt(req.query.timeout) || 3000;

            // Get local network info
            const os = require('os');
            const nets = os.networkInterfaces();
            const localIPs = [];

            for (const name of Object.keys(nets)) {
                for (const net of nets[name]) {
                    if (net.family === 'IPv4' && !net.internal) {
                        localIPs.push(net.address);
                    }
                }
            }

            // Common Jellyfin ports (include custom multi-instance ports we use in production)
            const jellyfinPorts = [8096, 8920, 9096, 9097];

            // Build list of IPs to scan (local subnet)
            const scanTargets = [];
            for (const localIP of localIPs) {
                const subnet = localIP.split('.').slice(0, 3).join('.');
                // Scan common server IPs in subnet
                for (let i = 1; i <= 254; i++) {
                    for (const port of jellyfinPorts) {
                        scanTargets.push({ ip: `${subnet}.${i}`, port });
                    }
                }
            }

            // Also check localhost
            for (const port of jellyfinPorts) {
                scanTargets.unshift({ ip: '127.0.0.1', port });
                scanTargets.unshift({ ip: 'localhost', port });
            }

            // Limit concurrent scans
            const batchSize = 50;
            const checkedUrls = new Set();

            const checkServer = async (target) => {
                const url = `http://${target.ip}:${target.port}`;
                if (checkedUrls.has(url)) return null;
                checkedUrls.add(url);

                try {
                    const controller = new AbortController();
                    const timeoutId = setTimeout(() => controller.abort(), timeout);

                    const response = await fetch(`${url}/System/Info/Public`, {
                        signal: controller.signal
                    });
                    clearTimeout(timeoutId);

                    if (response.ok) {
                        const info = await response.json();
                        return {
                            url,
                            name: info.ServerName || 'Jellyfin Server',
                            version: info.Version,
                            id: info.Id,
                            localAddress: info.LocalAddress
                        };
                    }
                } catch (e) {
                    // Server not available at this address
                }
                return null;
            };

            // Quick scan - check localhost and first few IPs of each subnet
            const quickTargets = scanTargets.slice(0, 20);
            const quickResults = await Promise.all(quickTargets.map(checkServer));

            for (const result of quickResults) {
                if (result) discoveredServers.push(result);
            }

            // If user wants full scan
            if (req.query.fullScan === 'true' && scanTargets.length > 20) {
                for (let i = 20; i < scanTargets.length; i += batchSize) {
                    const batch = scanTargets.slice(i, i + batchSize);
                    const results = await Promise.all(batch.map(checkServer));

                    for (const result of results) {
                        if (result) discoveredServers.push(result);
                    }

                    // Early exit if we found enough servers
                    if (discoveredServers.length >= 10) break;
                }
            }

            res.json({
                servers: discoveredServers,
                scannedCount: checkedUrls.size,
                localIPs
            });
        });

        // Validate/test a Jellyfin server URL
        this.app.post('/api/jellyfin/validate', async (req, res) => {
            const { url, apiKey } = req.body;

            if (!url) {
                return res.status(400).json({ error: 'URL required' });
            }

            const serverUrl = url.replace(/\/$/, '');

            try {
                // First check public info (no auth needed)
                const publicResponse = await fetch(`${serverUrl}/System/Info/Public`);
                if (!publicResponse.ok) {
                    return res.json({
                        valid: false,
                        error: 'Not a valid Jellyfin server'
                    });
                }

                const publicInfo = await publicResponse.json();

                // If API key provided, test authentication
                if (apiKey) {
                    const authResponse = await fetch(`${serverUrl}/System/Info?api_key=${apiKey}`);
                    if (!authResponse.ok) {
                        return res.json({
                            valid: true,
                            authenticated: false,
                            serverName: publicInfo.ServerName,
                            version: publicInfo.Version,
                            error: 'API key invalid or insufficient permissions'
                        });
                    }

                    const authInfo = await authResponse.json();
                    return res.json({
                        valid: true,
                        authenticated: true,
                        serverName: authInfo.ServerName || publicInfo.ServerName,
                        version: authInfo.Version,
                        id: authInfo.Id,
                        operatingSystem: authInfo.OperatingSystem
                    });
                }

                res.json({
                    valid: true,
                    authenticated: false,
                    serverName: publicInfo.ServerName,
                    version: publicInfo.Version,
                    id: publicInfo.Id,
                    message: 'Server found - API key required for full access'
                });

            } catch (error) {
                res.json({
                    valid: false,
                    error: `Failed to connect: ${error.message}`
                });
            }
        });

        // Remove a configured Jellyfin server
        this.app.delete('/api/jellyfin/servers/:serverId', (req, res) => {
            const serverId = req.params.serverId;

            if (!this.jellyfinServers.has(serverId)) {
                return res.status(404).json({ error: 'Server not found' });
            }

            this.jellyfinServers.delete(serverId);
            res.json({ success: true, message: 'Server removed' });
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
                let directPlayUrl;
                
                if (type === 'audio') {
                    // Primary transcode stream (more compatible)
                    streamUrl = `${server.url}/Audio/${itemId}/universal?api_key=${server.apiKey}&AudioCodec=mp3&Container=mp3&TranscodingContainer=mp3&TranscodingProtocol=http&Container=mp3,mp4,aac,flac,ogg,wav`;
                    
                    // Alternative stream formats for fallback
                    const alternativeStreams = [
                        `${server.url}/Audio/${itemId}/stream?api_key=${server.apiKey}&static=true&format=mp3`,
                        `${server.url}/Audio/${itemId}/stream?api_key=${server.apiKey}&static=true&format=aac`,
                        `${server.url}/Audio/${itemId}/universal?api_key=${server.apiKey}&AudioCodec=aac&Container=aac&TranscodingContainer=aac&TranscodingProtocol=http`
                    ];
                    
                    // Direct download as fallback
                    directPlayUrl = `${server.url}/Items/${itemId}/Download?api_key=${server.apiKey}`;
                } else {
                    // Video streams
                    streamUrl = `${server.url}/Videos/${itemId}/stream?api_key=${server.apiKey}&Static=true`;
                    directPlayUrl = `${server.url}/Items/${itemId}/Download?api_key=${server.apiKey}`;
                }

                // Add caching headers and CORS support
                res.json({
                    success: true,
                    streamUrl,
                    directPlay: directPlayUrl,
                    alternativeStreams,
                    // Add additional metadata for better error handling
                    metadata: {
                        itemId,
                        type,
                        serverUrl: server.url,
                        timestamp: Date.now()
                    }
                });
            } catch (error) {
                console.error('Stream URL generation error:', error);
                res.json({ 
                    success: false, 
                    error: error.message,
                    timestamp: Date.now()
                });
            }
        });

        // Setup Mastodon bot routes
        this.mastodonBot.setupRoutes(this.app);

        // ============================================
        // DEPLOYMENT CONFIGURATION API
        // Settings backup, presets, and server config
        // ============================================

        // Room approval queue for federation
        this.roomApprovalQueue = new Map(); // roomId -> { room, submittedAt, status, reviewedAt }

        // Initialize deployment config
        deployConfig.init().then(() => {
            console.log('[LocalServer] Deployment configuration loaded');
        });

        // Get current server configuration
        this.app.get('/api/config', (req, res) => {
            const config = deployConfig.getConfig();
            const sanitize = req.query.sanitize !== 'false';

            if (sanitize) {
                // Remove sensitive data
                const safe = JSON.parse(JSON.stringify(config));
                if (safe.security) {
                    delete safe.security.sslKeyPath;
                }
                if (safe.mastodon?.instances) {
                    safe.mastodon.instances = safe.mastodon.instances.map(i => ({
                        ...i,
                        accessToken: i.accessToken ? '***' : null
                    }));
                }
                res.json(safe);
            } else {
                res.json(config);
            }
        });

        // Update server configuration
        this.app.put('/api/config', async (req, res) => {
            try {
                const updates = req.body;
                const config = deployConfig.getConfig();

                // Deep merge updates
                for (const section in updates) {
                    if (typeof updates[section] === 'object' && !Array.isArray(updates[section])) {
                        deployConfig.updateSection(section, updates[section]);
                    }
                }

                await deployConfig.save();
                res.json({ success: true, message: 'Configuration updated' });
            } catch (error) {
                res.status(500).json({ error: error.message });
            }
        });

        // Get specific config section
        this.app.get('/api/config/:section', (req, res) => {
            const section = deployConfig.get(req.params.section);
            if (section) {
                res.json(section);
            } else {
                res.status(404).json({ error: 'Section not found' });
            }
        });

        // Update specific config section
        this.app.put('/api/config/:section', async (req, res) => {
            try {
                deployConfig.updateSection(req.params.section, req.body);
                await deployConfig.save();
                res.json({ success: true });
            } catch (error) {
                res.status(500).json({ error: error.message });
            }
        });

        // Get available presets
        this.app.get('/api/config/presets/list', (req, res) => {
            res.json({ presets: deployConfig.getPresets() });
        });

        // Apply a preset
        this.app.post('/api/config/presets/apply', async (req, res) => {
            try {
                const { preset } = req.body;
                if (!PRESETS[preset]) {
                    return res.status(400).json({ error: 'Unknown preset' });
                }

                // Create backup before applying preset
                await deployConfig.createBackup('pre-preset-' + preset);

                const config = deployConfig.applyPreset(preset);
                await deployConfig.save();

                res.json({
                    success: true,
                    message: `Applied preset: ${PRESETS[preset].name}`,
                    config
                });
            } catch (error) {
                res.status(500).json({ error: error.message });
            }
        });

        // Create backup
        this.app.post('/api/config/backup', async (req, res) => {
            try {
                const { label } = req.body;
                const result = await deployConfig.createBackup(label);
                res.json({ success: true, ...result });
            } catch (error) {
                res.status(500).json({ error: error.message });
            }
        });

        // List backups
        this.app.get('/api/config/backups', (req, res) => {
            const backups = deployConfig.listBackups();
            res.json({ backups });
        });

        // Restore from backup
        this.app.post('/api/config/restore', async (req, res) => {
            try {
                const { filename } = req.body;
                const config = await deployConfig.restoreBackup(filename);
                res.json({ success: true, message: 'Configuration restored', config });
            } catch (error) {
                res.status(500).json({ error: error.message });
            }
        });

        // Export configuration for deployment
        this.app.get('/api/config/export', (req, res) => {
            const sanitize = req.query.sanitize !== 'false';
            const exported = deployConfig.exportConfig({ sanitize });

            res.setHeader('Content-Type', 'application/json');
            res.setHeader('Content-Disposition', 'attachment; filename=voicelink-config.json');
            res.json(exported);
        });

        // Import configuration
        this.app.post('/api/config/import', async (req, res) => {
            try {
                const { config: exported, skipVerification } = req.body;

                // Create backup before import
                await deployConfig.createBackup('pre-import');

                const config = deployConfig.importConfig(exported, { skipVerification });
                await deployConfig.save();

                res.json({ success: true, message: 'Configuration imported', config });
            } catch (error) {
                res.status(500).json({ error: error.message });
            }
        });

        // Generate deployment package
        this.app.get('/api/config/deployment-package', (req, res) => {
            const preset = req.query.preset;
            const package_ = deployConfig.generateDeploymentPackage(preset || null);

            res.setHeader('Content-Type', 'application/json');
            res.setHeader('Content-Disposition', 'attachment; filename=voicelink-deployment.json');
            res.json(package_);
        });

        // ============================================
        // FEDERATION CONTROL API
        // Per-room, global, and approval settings
        // ============================================

        // Get federation status
        this.app.get('/api/federation/status', (req, res) => {
            const config = deployConfig.get('federation');
            res.json({
                enabled: config?.enabled || false,
                mode: config?.mode || 'standalone',
                globalFederation: config?.globalFederation !== false, // default true
                roomApprovalRequired: config?.roomApprovalRequired || false,
                approvalHoldTime: config?.approvalHoldTime || 3600000, // 1 hour default
                pendingApprovals: this.roomApprovalQueue.size,
                connectedServers: this.federation.getConnectedServers().length
            });
        });

        // Update federation settings
        this.app.put('/api/federation/settings', async (req, res) => {
            try {
                const {
                    enabled,
                    mode,
                    globalFederation,
                    roomApprovalRequired,
                    approvalHoldTime,
                    trustedServers
                } = req.body;

                deployConfig.updateSection('federation', {
                    enabled: enabled !== undefined ? enabled : deployConfig.get('federation', 'enabled'),
                    mode: mode || deployConfig.get('federation', 'mode'),
                    globalFederation: globalFederation !== undefined ? globalFederation : true,
                    roomApprovalRequired: roomApprovalRequired || false,
                    approvalHoldTime: approvalHoldTime || 3600000,
                    trustedServers: trustedServers || deployConfig.get('federation', 'trustedServers')
                });

                await deployConfig.save();
                res.json({ success: true, message: 'Federation settings updated' });
            } catch (error) {
                res.status(500).json({ error: error.message });
            }
        });

        // Set room federation status (per-room control)
        this.app.put('/api/rooms/:roomId/federation', (req, res) => {
            const room = this.rooms.get(req.params.roomId);
            if (!room) {
                return res.status(404).json({ error: 'Room not found' });
            }

            const { federated, federationTier } = req.body;

            room.federated = federated !== undefined ? federated : room.federated;
            room.federationTier = federationTier || 'standard'; // 'none', 'standard', 'promoted'
            room.lastUpdated = new Date();

            this.rooms.set(req.params.roomId, room);

            // If newly federated, submit for approval if required
            const config = deployConfig.get('federation');
            if (federated && config?.roomApprovalRequired && !room.federationApproved) {
                this.roomApprovalQueue.set(req.params.roomId, {
                    room: { ...room },
                    submittedAt: new Date(),
                    status: 'pending',
                    reviewedAt: null
                });
            }

            // Broadcast change if federated
            if (federated && room.federationApproved) {
                this.federation.broadcastRoomChange('updated', room);
            }

            res.json({ success: true, federated: room.federated, federationTier: room.federationTier });
        });

        // Get room approval queue
        this.app.get('/api/federation/approval-queue', (req, res) => {
            const queue = [];
            this.roomApprovalQueue.forEach((data, roomId) => {
                if (data.status === 'pending') {
                    queue.push({
                        roomId,
                        name: data.room.name,
                        description: data.room.description,
                        submittedAt: data.submittedAt,
                        creatorHandle: data.room.creatorHandle
                    });
                }
            });

            // Sort by submission time
            queue.sort((a, b) => new Date(a.submittedAt) - new Date(b.submittedAt));
            res.json({ queue, count: queue.length });
        });

        // Approve/reject room for federation
        this.app.post('/api/federation/approve/:roomId', (req, res) => {
            const { approved, reason } = req.body;
            const queueItem = this.roomApprovalQueue.get(req.params.roomId);

            if (!queueItem) {
                return res.status(404).json({ error: 'Room not in approval queue' });
            }

            const room = this.rooms.get(req.params.roomId);
            if (!room) {
                this.roomApprovalQueue.delete(req.params.roomId);
                return res.status(404).json({ error: 'Room no longer exists' });
            }

            queueItem.status = approved ? 'approved' : 'rejected';
            queueItem.reviewedAt = new Date();
            queueItem.reason = reason;

            if (approved) {
                room.federationApproved = true;
                room.federationApprovedAt = new Date();
                this.rooms.set(req.params.roomId, room);

                // Now broadcast to federation
                this.federation.broadcastRoomChange('created', room);
            } else {
                room.federated = false;
                room.federationApproved = false;
                this.rooms.set(req.params.roomId, room);
            }

            res.json({
                success: true,
                status: queueItem.status,
                message: approved ? 'Room approved for federation' : 'Room rejected'
            });
        });

        // Auto-approve rooms after hold time (cron-style endpoint)
        this.app.post('/api/federation/process-queue', (req, res) => {
            const config = deployConfig.get('federation');
            const holdTime = config?.approvalHoldTime || 3600000;
            const now = Date.now();
            let processed = 0;

            this.roomApprovalQueue.forEach((data, roomId) => {
                if (data.status === 'pending') {
                    const elapsed = now - new Date(data.submittedAt).getTime();
                    if (elapsed >= holdTime) {
                        // Auto-approve after hold time
                        const room = this.rooms.get(roomId);
                        if (room) {
                            room.federationApproved = true;
                            room.federationApprovedAt = new Date();
                            this.rooms.set(roomId, room);
                            this.federation.broadcastRoomChange('created', room);

                            data.status = 'auto-approved';
                            data.reviewedAt = new Date();
                            processed++;
                        }
                    }
                }
            });

            res.json({ success: true, processed });
        });

        // ============================================
        // NODE OPERATOR FEDERATION PRIORITY API
        // Ecripto node operators get priority visibility
        // ============================================

        // Node operator status cache
        this.nodeOperatorCache = new Map(); // serverUrl -> { isNode, nodeType, verifiedAt, score }

        // Get this server's node operator status
        this.app.get('/api/federation/node-operator/status', (req, res) => {
            const ecriptoConfig = deployConfig.get('ecripto');
            const federationConfig = deployConfig.get('federation');

            res.json({
                isNode: ecriptoConfig?.nodeOperator?.isNode || false,
                nodeType: ecriptoConfig?.nodeOperator?.nodeType,
                nodeId: ecriptoConfig?.nodeOperator?.nodeId,
                walletAddress: ecriptoConfig?.nodeOperator?.nodeWalletAddress,
                verifiedAt: ecriptoConfig?.nodeOperator?.verifiedAt,
                priorityBoost: federationConfig?.nodeOperatorPriority?.priorityBoost || 100,
                priorityEnabled: federationConfig?.nodeOperatorPriority?.enabled !== false
            });
        });

        // Register/update this server as a node operator
        this.app.post('/api/federation/node-operator/register', async (req, res) => {
            const {
                nodeWalletAddress,
                nodeId,
                nodeType,
                verificationProof
            } = req.body;

            if (!nodeWalletAddress || !verificationProof) {
                return res.status(400).json({
                    error: 'Node wallet address and verification proof required'
                });
            }

            try {
                // TODO: Verify the proof against Ecripto network
                // For now, store the claim and mark for verification
                const ecriptoConfig = deployConfig.get('ecripto') || {};
                ecriptoConfig.nodeOperator = {
                    isNode: true,
                    nodeWalletAddress,
                    nodeId,
                    nodeType: nodeType || 'relay',
                    verifiedAt: new Date().toISOString(),
                    verificationProof,
                    pendingVerification: true // Will be verified on next sync
                };

                deployConfig.updateSection('ecripto', ecriptoConfig);
                await deployConfig.save();

                console.log('[NodeOperator] Registered as node operator:', nodeWalletAddress);

                res.json({
                    success: true,
                    message: 'Registered as node operator. Status will be verified.',
                    nodeOperator: {
                        isNode: true,
                        nodeType: nodeType || 'relay',
                        pendingVerification: true
                    }
                });

            } catch (error) {
                console.error('[NodeOperator] Registration error:', error);
                res.status(500).json({ error: error.message });
            }
        });

        // Verify another server's node operator status
        this.app.post('/api/federation/node-operator/verify', async (req, res) => {
            const { serverUrl, walletAddress, verificationProof } = req.body;

            if (!serverUrl) {
                return res.status(400).json({ error: 'Server URL required' });
            }

            try {
                // Check cache first
                const cached = this.nodeOperatorCache.get(serverUrl);
                const cacheAge = cached ? Date.now() - new Date(cached.verifiedAt).getTime() : Infinity;
                const cacheTimeout = deployConfig.get('federation')?.nodeOperatorPriority?.verificationInterval || 3600000;

                if (cached && cacheAge < cacheTimeout) {
                    return res.json({
                        cached: true,
                        ...cached
                    });
                }

                // Fetch node operator status from the remote server
                const response = await fetch(`${serverUrl}/api/federation/node-operator/status`);
                if (!response.ok) {
                    throw new Error('Failed to fetch node operator status');
                }

                const nodeStatus = await response.json();

                // Calculate priority score
                let priorityScore = 0;
                if (nodeStatus.isNode) {
                    const baseBoost = deployConfig.get('federation')?.nodeOperatorPriority?.priorityBoost || 100;

                    // Different node types get different boosts
                    switch (nodeStatus.nodeType) {
                        case 'validator':
                            priorityScore = baseBoost * 2; // Validators get highest priority
                            break;
                        case 'archive':
                            priorityScore = baseBoost * 1.5; // Archive nodes are valuable
                            break;
                        case 'relay':
                        default:
                            priorityScore = baseBoost; // Standard boost for relay nodes
                    }

                    // Check if this is a trusted node
                    const trustedNodes = deployConfig.get('federation')?.nodeOperatorPriority?.trustedNodes || [];
                    if (trustedNodes.includes(nodeStatus.walletAddress)) {
                        priorityScore *= 1.5; // Extra boost for manually trusted nodes
                    }
                }

                const verificationResult = {
                    serverUrl,
                    isNode: nodeStatus.isNode,
                    nodeType: nodeStatus.nodeType,
                    walletAddress: nodeStatus.walletAddress,
                    priorityScore,
                    verifiedAt: new Date().toISOString()
                };

                // Cache the result
                this.nodeOperatorCache.set(serverUrl, verificationResult);

                res.json({
                    cached: false,
                    ...verificationResult
                });

            } catch (error) {
                console.error('[NodeOperator] Verification error:', error);
                res.status(500).json({
                    error: error.message,
                    isNode: false,
                    priorityScore: 0
                });
            }
        });

        // Admin: Add trusted node operator
        this.app.post('/api/federation/node-operator/trust', (req, res) => {
            const { walletAddress, serverUrl, nodeType } = req.body;

            if (!walletAddress) {
                return res.status(400).json({ error: 'Wallet address required' });
            }

            const federationConfig = deployConfig.get('federation') || {};
            if (!federationConfig.nodeOperatorPriority) {
                federationConfig.nodeOperatorPriority = { enabled: true, trustedNodes: [] };
            }
            if (!federationConfig.nodeOperatorPriority.trustedNodes) {
                federationConfig.nodeOperatorPriority.trustedNodes = [];
            }

            // Add to trusted nodes if not already present
            if (!federationConfig.nodeOperatorPriority.trustedNodes.includes(walletAddress)) {
                federationConfig.nodeOperatorPriority.trustedNodes.push(walletAddress);
            }

            deployConfig.updateSection('federation', federationConfig);
            deployConfig.save();

            // Invalidate cache for this server
            if (serverUrl) {
                this.nodeOperatorCache.delete(serverUrl);
            }

            res.json({
                success: true,
                trustedNodes: federationConfig.nodeOperatorPriority.trustedNodes
            });
        });

        // Admin: Remove trusted node operator
        this.app.delete('/api/federation/node-operator/trust/:walletAddress', (req, res) => {
            const { walletAddress } = req.params;

            const federationConfig = deployConfig.get('federation') || {};
            if (federationConfig.nodeOperatorPriority?.trustedNodes) {
                federationConfig.nodeOperatorPriority.trustedNodes =
                    federationConfig.nodeOperatorPriority.trustedNodes.filter(w => w !== walletAddress);
            }

            deployConfig.updateSection('federation', federationConfig);
            deployConfig.save();

            res.json({
                success: true,
                trustedNodes: federationConfig.nodeOperatorPriority?.trustedNodes || []
            });
        });

        // Get federated rooms with node operator priority scoring
        this.app.get('/api/federation/rooms/prioritized', async (req, res) => {
            try {
                const federationConfig = deployConfig.get('federation');
                const priorityEnabled = federationConfig?.nodeOperatorPriority?.enabled !== false;

                // Get all federated rooms
                const federatedRooms = [];
                this.rooms.forEach((room, id) => {
                    if (room.federationTier && room.federationTier !== 'none' && room.federationApproved !== false) {
                        federatedRooms.push({
                            ...room,
                            priorityScore: 0
                        });
                    }
                });

                // Add remote server rooms with priority scoring
                if (this.federation) {
                    const connectedServers = this.federation.getConnectedServers?.() || [];

                    for (const server of connectedServers) {
                        // Get node operator score for this server
                        let nodeScore = 0;
                        if (priorityEnabled) {
                            const cached = this.nodeOperatorCache.get(server.url);
                            if (cached) {
                                nodeScore = cached.priorityScore || 0;
                            }
                        }

                        // Add rooms from this server with priority score
                        const serverRooms = server.rooms || [];
                        for (const room of serverRooms) {
                            let roomScore = nodeScore;

                            // Apply tier multiplier
                            if (room.federationTier === 'promoted') {
                                roomScore *= 1.5;
                            }

                            // Apply user count boost (more popular = slightly higher)
                            roomScore += Math.min((room.userCount || 0) * 2, 50);

                            federatedRooms.push({
                                ...room,
                                sourceServer: server.url,
                                priorityScore: roomScore,
                                isNodeOperator: nodeScore > 0
                            });
                        }
                    }
                }

                // Sort by priority score (highest first)
                federatedRooms.sort((a, b) => b.priorityScore - a.priorityScore);

                res.json({
                    rooms: federatedRooms,
                    totalCount: federatedRooms.length,
                    priorityEnabled
                });

            } catch (error) {
                console.error('[Federation] Prioritized rooms error:', error);
                res.status(500).json({ error: error.message });
            }
        });

        // ============================================
        // JELLYFIN MANAGEMENT API
        // Bot control, library import, backup, removal
        // ============================================

        this.jellyfinImports = new Map();

        // Get Jellyfin status
        this.app.get('/api/jellyfin/status', (req, res) => {
            const jellyfinConfig = deployConfig.get('jellyfin') || {};
            const botStatus = jellyfinConfig.bot?.status || 'disabled';
            const suspendedUntil = jellyfinConfig.bot?.suspendedUntil;

            let currentStatus = botStatus;
            if (botStatus === 'suspended' && suspendedUntil && new Date(suspendedUntil) < new Date()) {
                currentStatus = 'enabled';
                if (jellyfinConfig.suspension?.autoReEnable) {
                    jellyfinConfig.bot.status = 'enabled';
                    jellyfinConfig.bot.suspendedUntil = null;
                    deployConfig.updateSection('jellyfin', jellyfinConfig);
                    deployConfig.save();
                }
            }

            res.json({
                bundled: jellyfinConfig.bundled?.enabled || false,
                connected: !!jellyfinConfig.connection?.apiKey,
                serverUrl: jellyfinConfig.connection?.serverUrl,
                bot: { status: currentStatus, suspendedUntil, defaultRooms: jellyfinConfig.bot?.defaultRooms || [] },
                storage: jellyfinConfig.libraries?.storage || {},
                backup: { lastBackup: jellyfinConfig.backup?.lastBackup, lastBackupSize: jellyfinConfig.backup?.lastBackupSize }
            });
        });

        const defaultJellyfinLibraryPaths = [
            '/home/dom/apps/media',
            '/home/tappedin/apps/media'
        ];

        const buildLibraryPathStatus = (paths) => paths.map((libraryPath) => {
            const normalized = String(libraryPath || '').trim();
            if (!normalized) {
                return { path: normalized, exists: false, readable: false, writable: false, resolvedPath: null };
            }

            const status = {
                path: normalized,
                exists: fs.existsSync(normalized),
                readable: false,
                writable: false,
                resolvedPath: null
            };

            if (!status.exists) return status;

            try {
                status.resolvedPath = fs.realpathSync(normalized);
            } catch {
                status.resolvedPath = normalized;
            }

            try {
                fs.accessSync(normalized, fs.constants.R_OK);
                status.readable = true;
            } catch {}

            try {
                fs.accessSync(normalized, fs.constants.W_OK);
                status.writable = true;
            } catch {}

            return status;
        });

        // Get/set allowed Jellyfin library roots for VoiceLink admin control.
        this.app.get('/api/jellyfin/admin/library-paths', (req, res) => {
            const jellyfinConfig = deployConfig.get('jellyfin') || {};
            const configured = jellyfinConfig.libraries?.paths;
            const paths = Array.isArray(configured) && configured.length ? configured : defaultJellyfinLibraryPaths;
            res.json({
                success: true,
                paths,
                defaults: defaultJellyfinLibraryPaths,
                status: buildLibraryPathStatus(paths)
            });
        });

        this.app.post('/api/jellyfin/admin/library-paths', (req, res) => {
            const incoming = Array.isArray(req.body?.paths) ? req.body.paths : null;
            if (!incoming || incoming.length === 0) {
                return res.status(400).json({ success: false, error: 'paths[] is required' });
            }

            const normalized = incoming
                .map((value) => String(value || '').trim().replace(/\/+$/, ''))
                .filter(Boolean);

            const invalid = normalized.filter((value) => !value.startsWith('/home/') || !value.includes('/apps/media'));
            if (invalid.length) {
                return res.status(400).json({
                    success: false,
                    error: 'Only /home/*/apps/media* paths are allowed',
                    invalid
                });
            }

            const uniquePaths = [...new Set(normalized)];
            const jellyfinConfig = deployConfig.get('jellyfin') || {};
            jellyfinConfig.libraries = jellyfinConfig.libraries || {};
            jellyfinConfig.libraries.paths = uniquePaths;
            deployConfig.updateSection('jellyfin', jellyfinConfig);
            deployConfig.save();

            return res.json({
                success: true,
                paths: uniquePaths,
                status: buildLibraryPathStatus(uniquePaths)
            });
        });

        // Enable bot
        this.app.post('/api/jellyfin/bot/enable', (req, res) => {
            const { rooms, globalPlayback } = req.body;
            const jellyfinConfig = deployConfig.get('jellyfin') || {};
            if (!jellyfinConfig.bot) jellyfinConfig.bot = {};
            jellyfinConfig.bot.enabled = true;
            jellyfinConfig.bot.status = 'enabled';
            jellyfinConfig.bot.suspendedUntil = null;
            if (rooms) jellyfinConfig.bot.defaultRooms = rooms;
            if (globalPlayback !== undefined) jellyfinConfig.bot.globalPlayback = globalPlayback;
            deployConfig.updateSection('jellyfin', jellyfinConfig);
            deployConfig.save();
            res.json({ success: true, status: 'enabled' });
        });

        // Disable bot
        this.app.post('/api/jellyfin/bot/disable', (req, res) => {
            const jellyfinConfig = deployConfig.get('jellyfin') || {};
            if (!jellyfinConfig.bot) jellyfinConfig.bot = {};
            jellyfinConfig.bot.enabled = false;
            jellyfinConfig.bot.status = 'disabled';
            deployConfig.updateSection('jellyfin', jellyfinConfig);
            deployConfig.save();
            res.json({ success: true, status: 'disabled' });
        });

        // Suspend bot
        this.app.post('/api/jellyfin/bot/suspend', (req, res) => {
            const { duration, reason } = req.body;
            const jellyfinConfig = deployConfig.get('jellyfin') || {};
            const durations = { '24h': 86400000, '36h': 129600000, 'week': 604800000, 'month': 2592000000 };
            if (!durations[duration]) return res.status(400).json({ error: 'Invalid duration', allowed: Object.keys(durations) });
            if (!jellyfinConfig.bot) jellyfinConfig.bot = {};
            jellyfinConfig.bot.status = 'suspended';
            jellyfinConfig.bot.suspendedUntil = new Date(Date.now() + durations[duration]).toISOString();
            jellyfinConfig.bot.suspendReason = reason;
            deployConfig.updateSection('jellyfin', jellyfinConfig);
            deployConfig.save();
            res.json({ success: true, status: 'suspended', suspendedUntil: jellyfinConfig.bot.suspendedUntil });
        });

        // Room-specific bot config
        this.app.post('/api/jellyfin/bot/room/:roomId', (req, res) => {
            const { roomId } = req.params;
            const { enabled, library } = req.body;
            const jellyfinConfig = deployConfig.get('jellyfin') || {};
            if (!jellyfinConfig.bot) jellyfinConfig.bot = {};
            if (!jellyfinConfig.bot.roomOverrides) jellyfinConfig.bot.roomOverrides = {};
            jellyfinConfig.bot.roomOverrides[roomId] = { enabled: enabled !== false, library: library || 'Music' };
            deployConfig.updateSection('jellyfin', jellyfinConfig);
            deployConfig.save();
            res.json({ success: true, roomId, config: jellyfinConfig.bot.roomOverrides[roomId] });
        });

        // Import library via URL
        this.app.post('/api/jellyfin/library/import-url', async (req, res) => {
            const { url, targetPath } = req.body;
            const jellyfinConfig = deployConfig.get('jellyfin') || {};
            if (!jellyfinConfig.libraries?.remoteImport?.enabled) return res.status(403).json({ error: 'Remote import disabled' });

            const allowedExt = ['.zip', '.tar', '.tar.gz', '.mp3', '.m3u', '.flac', '.ogg', '.wav'];
            if (!allowedExt.some(ext => url.toLowerCase().endsWith(ext))) {
                return res.status(400).json({ error: 'File type not allowed', allowedExt });
            }

            const importId = 'import_' + uuidv4().slice(0, 8);
            const downloadPath = targetPath || jellyfinConfig.bundled?.mediaPath || '/tmp/jellyfin-import';
            this.jellyfinImports.set(importId, { id: importId, url, status: 'queued', startedAt: new Date() });

            res.json({ success: true, importId, message: 'Import queued. Check GET /api/jellyfin/library/import/' + importId });
            // Note: Actual download would use execFile for security in production
        });

        // Get import status
        this.app.get('/api/jellyfin/library/import/:importId', (req, res) => {
            const job = this.jellyfinImports?.get(req.params.importId);
            if (!job) return res.status(404).json({ error: 'Import not found' });
            res.json(job);
        });

        // Backup status
        this.app.get('/api/jellyfin/backup/status', (req, res) => {
            const backup = deployConfig.get('jellyfin')?.backup || {};
            res.json({
                enabled: backup.enabled, lastBackup: backup.lastBackup, lastBackupSize: backup.lastBackupSize,
                recommendation: !backup.lastBackup ? 'No backup exists. Create one before removal.' : 'Backup exists.'
            });
        });

        // List backups
        this.app.get('/api/jellyfin/backup/list', (req, res) => {
            const backupPath = deployConfig.get('jellyfin')?.backup?.backupPath || path.join(__dirname, '../../data/backups/jellyfin');
            if (!fs.existsSync(backupPath)) return res.json({ backups: [] });
            const files = fs.readdirSync(backupPath).filter(f => f.endsWith('.tar.gz')).map(f => ({
                filename: f, size: fs.statSync(path.join(backupPath, f)).size
            }));
            res.json({ backups: files });
        });

        // Create backup
        this.app.post('/api/jellyfin/backup/create', (req, res) => {
            const jellyfinConfig = deployConfig.get('jellyfin') || {};
            const backupPath = jellyfinConfig.backup?.backupPath || path.join(__dirname, '../../data/backups/jellyfin');
            const dataPath = jellyfinConfig.bundled?.dataPath;
            if (!dataPath) return res.status(400).json({ error: 'Data path not configured' });

            const timestamp = new Date().toISOString().replace(/[:.]/g, '-');
            jellyfinConfig.backup = jellyfinConfig.backup || {};
            jellyfinConfig.backup.lastBackup = new Date().toISOString();
            deployConfig.updateSection('jellyfin', jellyfinConfig);
            deployConfig.save();
            res.json({ success: true, backupPath, timestamp, message: 'Backup initiated' });
        });

        // Remove Jellyfin
        this.app.post('/api/jellyfin/remove', (req, res) => {
            const { confirmRemoval, removeMedia, confirmMediaRemoval, skipBackupCheck } = req.body;
            const jellyfinConfig = deployConfig.get('jellyfin') || {};

            if (!confirmRemoval) return res.status(400).json({ error: 'Set confirmRemoval: true' });

            if (!skipBackupCheck && !jellyfinConfig.backup?.lastBackup) {
                return res.status(400).json({ error: 'No backup. Create one first or set skipBackupCheck: true' });
            }

            if (removeMedia && !confirmMediaRemoval) {
                return res.status(400).json({ error: 'Set confirmMediaRemoval: true to remove media', warning: 'Cannot be undone!' });
            }

            // Clear config
            jellyfinConfig.connection = { serverUrl: null, apiKey: null, userId: null };
            jellyfinConfig.bot = { enabled: false, status: 'disabled', defaultRooms: [] };
            deployConfig.updateSection('jellyfin', jellyfinConfig);
            deployConfig.save();

            res.json({ success: true, removed: { config: true, media: removeMedia && confirmMediaRemoval }, message: 'Jellyfin removed' });
        });

        // Restore backup
        this.app.post('/api/jellyfin/backup/restore', (req, res) => {
            const { backupFile, confirmRestore } = req.body;
            if (!confirmRestore) return res.status(400).json({ error: 'Set confirmRestore: true' });
            if (!backupFile) return res.status(400).json({ error: 'Specify backupFile' });
            res.json({ success: true, message: 'Restore initiated for ' + backupFile });
        });

        // ============================================
        // JELLYFIN SERVICE MANAGEMENT API
        // Automatic process monitoring and restart
        // ============================================

        // Get all Jellyfin processes (discovered + managed)
        this.app.get('/api/jellyfin-service/processes', async (req, res) => {
            try {
                const processes = await this.jellyfinManager.getAllProcesses();
                res.json({ success: true, processes });
            } catch (error) {
                console.error('[JellyfinService] Error getting processes:', error);
                res.status(500).json({ error: error.message });
            }
        });

        // Get status of specific process
        this.app.get('/api/jellyfin-service/process/:name', async (req, res) => {
            try {
                const { name } = req.params;
                const status = await this.jellyfinManager.getProcessStatus(name);
                if (!status) {
                    return res.status(404).json({ error: `Process ${name} not found` });
                }
                res.json({ success: true, process: status });
            } catch (error) {
                console.error('[JellyfinService] Error getting process status:', error);
                res.status(500).json({ error: error.message });
            }
        });

        // Register a Jellyfin process for management
        this.app.post('/api/jellyfin-service/process/:name/register', (req, res) => {
            try {
                const { name } = req.params;
                const config = req.body;
                
                this.jellyfinManager.registerProcess(name, config);
                console.log(`[JellyfinService] Registered process: ${name}`);
                
                res.json({ 
                    success: true, 
                    message: `Process ${name} registered for management`,
                    config: this.jellyfinManager.processes.get(name)?.config
                });
            } catch (error) {
                console.error('[JellyfinService] Error registering process:', error);
                res.status(500).json({ error: error.message });
            }
        });

        // Start a specific Jellyfin process
        this.app.post('/api/jellyfin-service/process/:name/start', async (req, res) => {
            try {
                const { name } = req.params;
                const started = await this.jellyfinManager.startProcess(name);
                
                if (started) {
                    console.log(`[JellyfinService] Successfully started process: ${name}`);
                    res.json({ success: true, message: `Process ${name} started` });
                } else {
                    console.warn(`[JellyfinService] Failed to start process: ${name}`);
                    res.status(500).json({ error: `Failed to start process ${name}` });
                }
            } catch (error) {
                console.error('[JellyfinService] Error starting process:', error);
                res.status(500).json({ error: error.message });
            }
        });

        // Stop a specific Jellyfin process
        this.app.post('/api/jellyfin-service/process/:name/stop', async (req, res) => {
            try {
                const { name } = req.params;
                const { graceful = true } = req.body;
                
                await this.jellyfinManager.stopProcess(name, graceful);
                console.log(`[JellyfinService] Stopped process: ${name}`);
                
                res.json({ success: true, message: `Process ${name} stopped` });
            } catch (error) {
                console.error('[JellyfinService] Error stopping process:', error);
                res.status(500).json({ error: error.message });
            }
        });

        // Restart a specific Jellyfin process
        this.app.post('/api/jellyfin-service/process/:name/restart', async (req, res) => {
            try {
                const { name } = req.params;
                
                await this.jellyfinManager.restartProcess(name);
                console.log(`[JellyfinService] Restarting process: ${name}`);
                
                res.json({ success: true, message: `Process ${name} restart initiated` });
            } catch (error) {
                console.error('[JellyfinService] Error restarting process:', error);
                res.status(500).json({ error: error.message });
            }
        });

        // Auto-configure and register discovered Jellyfin processes
        this.app.post('/api/jellyfin-service/auto-configure', async (req, res) => {
            try {
                const processes = await this.jellyfinManager.discoverProcesses();
                let registered = 0;
                
                for (const process of processes) {
                    // Only register if not already managed
                    if (!this.jellyfinManager.processes.has(process.name)) {
                        const config = {
                            user: process.user,
                            command: process.command,
                            port: process.port,
                            workingDirectory: process.command.includes('/home/') ? 
                                process.command.match(/(\/home\/[^\/]+\/[^\/]+)/)?.[0] : null
                        };
                        
                        this.jellyfinManager.registerProcess(process.name, config);
                        registered++;
                    }
                }
                
                console.log(`[JellyfinService] Auto-configured ${registered} processes`);
                res.json({ 
                    success: true, 
                    message: `Auto-configured ${registered} processes`,
                    totalDiscovered: processes.length,
                    newlyRegistered: registered
                });
            } catch (error) {
                console.error('[JellyfinService] Error auto-configuring:', error);
                res.status(500).json({ error: error.message });
            }
        });

        // Get service manager status
        this.app.get('/api/jellyfin-service/status', (req, res) => {
            try {
                const status = {
                    monitoring: this.jellyfinManager.monitoringInterval !== null,
                    managedProcesses: this.jellyfinManager.processes.size,
                    restartCounters: Object.fromEntries(this.jellyfinManager.restartCounters),
                    config: this.jellyfinManager.config
                };
                
                res.json({ success: true, status });
            } catch (error) {
                console.error('[JellyfinService] Error getting status:', error);
                res.status(500).json({ error: error.message });
            }
        });

        // ============================================
        // DOCUMENTATION MANAGEMENT API
        // Ollama-powered doc generation with scheduling
        // ============================================

        this.docsConfig = {
            lastGenerated: null,
            pendingFeatures: [],
            scheduledUpdate: null,
            generationInProgress: false
        };

        // Load docs config from file
        const docsConfigPath = path.join(__dirname, '../../data/docs-config.json');
        if (fs.existsSync(docsConfigPath)) {
            try {
                this.docsConfig = JSON.parse(fs.readFileSync(docsConfigPath, 'utf8'));
            } catch (e) { /* use defaults */ }
        }

        // Get documentation status
        this.app.get('/api/docs/status', (req, res) => {
            const docsDir = path.join(__dirname, '../../docs');
            const publicDir = path.join(docsDir, 'public');
            const authDir = path.join(docsDir, 'authenticated');

            let publicCount = 0, authCount = 0;
            if (fs.existsSync(publicDir)) {
                publicCount = fs.readdirSync(publicDir).filter(f => f.endsWith('.html')).length;
            }
            if (fs.existsSync(authDir)) {
                authCount = fs.readdirSync(authDir).filter(f => f.endsWith('.html')).length;
            }

            res.json({
                lastGenerated: this.docsConfig.lastGenerated,
                publicDocs: publicCount,
                authenticatedDocs: authCount,
                pendingFeatures: this.docsConfig.pendingFeatures,
                scheduledUpdate: this.docsConfig.scheduledUpdate,
                generationInProgress: this.docsConfig.generationInProgress,
                ollamaAvailable: true // Assume available on server
            });
        });

        // Check for features needing documentation
        this.app.get('/api/docs/check-updates', (req, res) => {
            const configVersion = deployConfig.get('version') || '1.0.0';
            const docsVersion = this.docsConfig.documentedVersion || '0.0.0';

            // Compare features against documented features
            const currentFeatures = [
                'payments', 'jellyfin', 'federation', 'ecripto', 'escort',
                'spatial-audio', 'ios-audio', 'node-operator', 'whisper-mode'
            ];
            const documentedFeatures = this.docsConfig.documentedFeatures || [];

            const newFeatures = currentFeatures.filter(f => !documentedFeatures.includes(f));
            const needsUpdate = newFeatures.length > 0 || configVersion !== docsVersion;

            if (needsUpdate && newFeatures.length > 0) {
                this.docsConfig.pendingFeatures = newFeatures;
                // Notify admins via socket
                if (this.io) {
                    this.io.emit('admin-notification', {
                        type: 'docs-update-needed',
                        message: `${newFeatures.length} new feature(s) need documentation`,
                        features: newFeatures,
                        action: 'POST /api/docs/generate or schedule with /api/docs/schedule'
                    });
                }
            }

            res.json({
                needsUpdate,
                currentVersion: configVersion,
                documentedVersion: docsVersion,
                newFeatures,
                recommendation: needsUpdate
                    ? 'Documentation update recommended. Generate now or schedule.'
                    : 'Documentation is up to date.'
            });
        });

        // Schedule documentation generation
        this.app.post('/api/docs/schedule', (req, res) => {
            const { delay, time } = req.body; // delay in minutes or specific time

            let scheduledTime;
            if (delay) {
                scheduledTime = new Date(Date.now() + delay * 60000);
            } else if (time) {
                scheduledTime = new Date(time);
            } else {
                scheduledTime = new Date(Date.now() + 30 * 60000); // Default 30 min
            }

            this.docsConfig.scheduledUpdate = scheduledTime.toISOString();

            // Save config
            fs.writeFileSync(docsConfigPath, JSON.stringify(this.docsConfig, null, 2), 'utf8');

            // Schedule the job
            const delayMs = scheduledTime.getTime() - Date.now();
            if (delayMs > 0) {
                setTimeout(() => {
                    this.generateDocsInternal();
                }, delayMs);

                // Notify admins
                if (this.io) {
                    this.io.emit('admin-notification', {
                        type: 'docs-scheduled',
                        message: `Documentation generation scheduled for ${scheduledTime.toLocaleString()}`,
                        scheduledTime: this.docsConfig.scheduledUpdate
                    });
                }
            }

            res.json({
                success: true,
                scheduledTime: this.docsConfig.scheduledUpdate,
                message: `Documentation will be generated at ${scheduledTime.toLocaleString()}`
            });
        });

        // Generate documentation now
        this.app.post('/api/docs/generate', async (req, res) => {
            const { features, model } = req.body; // Optional: specific features, model override

            if (this.docsConfig.generationInProgress) {
                return res.status(409).json({ error: 'Documentation generation already in progress' });
            }

            res.json({
                success: true,
                message: 'Documentation generation started',
                status: 'Check GET /api/docs/status for progress'
            });

            // Run generation in background
            this.generateDocsInternal(features, model);
        });

        // Internal doc generation function
        this.generateDocsInternal = async (specificFeatures = null, model = 'llama3.2') => {
            this.docsConfig.generationInProgress = true;
            const docsDir = path.join(__dirname, '../../docs');
            const publicDir = path.join(docsDir, 'public');
            const authDir = path.join(docsDir, 'authenticated');

            [docsDir, publicDir, authDir].forEach(dir => {
                if (!fs.existsSync(dir)) fs.mkdirSync(dir, { recursive: true });
            });

            console.log('[Docs] Starting generation with Ollama...');

            // Notify start
            if (this.io) {
                this.io.emit('admin-notification', {
                    type: 'docs-generation-started',
                    message: 'Documentation generation has started'
                });
            }

            try {
                const { execSync } = require('child_process');
                const toolsPath = path.join(__dirname, '../tools/generate-docs.js');

                // Run the generator script
                execSync(`OLLAMA_MODEL=${model} node "${toolsPath}"`, {
                    cwd: path.join(__dirname, '../tools'),
                    timeout: 600000, // 10 min timeout
                    stdio: 'inherit'
                });

                this.docsConfig.lastGenerated = new Date().toISOString();
                this.docsConfig.documentedVersion = deployConfig.get('version') || '1.0.0';
                this.docsConfig.documentedFeatures = [
                    'payments', 'jellyfin', 'federation', 'ecripto', 'escort',
                    'spatial-audio', 'ios-audio', 'node-operator', 'whisper-mode'
                ];
                this.docsConfig.pendingFeatures = [];
                this.docsConfig.scheduledUpdate = null;

                console.log('[Docs] Generation complete');

                if (this.io) {
                    this.io.emit('admin-notification', {
                        type: 'docs-generation-complete',
                        message: 'Documentation generation completed successfully',
                        timestamp: this.docsConfig.lastGenerated
                    });
                }

            } catch (error) {
                console.error('[Docs] Generation failed:', error.message);

                if (this.io) {
                    this.io.emit('admin-notification', {
                        type: 'docs-generation-failed',
                        message: 'Documentation generation failed: ' + error.message
                    });
                }
            }

            this.docsConfig.generationInProgress = false;
            fs.writeFileSync(docsConfigPath, JSON.stringify(this.docsConfig, null, 2), 'utf8');
        };

        // List generated docs
        this.app.get('/api/docs/list', (req, res) => {
            const docsDir = path.join(__dirname, '../../docs');
            const publicDir = path.join(docsDir, 'public');
            const authDir = path.join(docsDir, 'authenticated');

            const listDir = (dir, type) => {
                if (!fs.existsSync(dir)) return [];
                return fs.readdirSync(dir)
                    .filter(f => f.endsWith('.html'))
                    .map(f => ({
                        name: f.replace('.html', ''),
                        file: f,
                        type,
                        path: `/${type === 'public' ? 'docs' : 'admin/docs'}/${f}`,
                        size: fs.statSync(path.join(dir, f)).size,
                        modified: fs.statSync(path.join(dir, f)).mtime
                    }));
            };

            res.json({
                public: listDir(publicDir, 'public'),
                authenticated: listDir(authDir, 'authenticated')
            });
        });

        // Serve documentation files
        this.app.use('/docs', express.static(path.join(__dirname, '../../docs/public')));
        this.app.use('/admin/docs', express.static(path.join(__dirname, '../../docs/authenticated')));

        // Serve release packages for installer downloads
        this.app.use('/releases', express.static(path.join(__dirname, '../../releases')));
        this.app.use('/exports', express.static(path.join(__dirname, '../../data/exports')));

        // Create a user data export archive and upload to CopyParty when enabled.
        this.app.post('/api/export/my-data', async (req, res) => {
            try {
                const includeMessages = this.parseBool(req.body?.includeMessages, true);
                const includeRooms = this.parseBool(req.body?.includeRooms, true);
                const useCopyParty = this.parseBool(req.body?.useCopyParty, true);
                const userId = String(
                    req.body?.userId
                    || req.headers['x-user-id']
                    || req.headers['remote-user']
                    || ''
                ).trim();
                const username = String(
                    req.body?.username
                    || req.headers['x-user-name']
                    || req.headers['remote-user']
                    || ''
                ).trim();

                if (!userId && !username) {
                    return res.status(400).json({ success: false, error: 'Missing user identity for export' });
                }

                const payload = this.buildUserDataExport({ userId, username, includeMessages, includeRooms });
                const archive = await this.createJsonZipArchive(payload, {
                    prefix: `user-export-${this.sanitizeExportSegment(userId || username, 'user')}`
                });

                let copyParty = { uploaded: false };
                if (useCopyParty) {
                    try {
                        copyParty = await this.uploadArchiveToCopyParty(archive.zipPath, archive.fileName);
                    } catch (error) {
                        copyParty = { uploaded: false, error: error.message };
                    }
                }

                res.json({
                    success: true,
                    userId: userId || null,
                    username: username || null,
                    archive: {
                        fileName: archive.fileName,
                        size: archive.size,
                        createdAt: archive.createdAt,
                        downloadUrl: archive.downloadUrl
                    },
                    copyParty
                });
            } catch (error) {
                console.error('[Export] Failed to export user data:', error.message);
                res.status(500).json({ success: false, error: error.message });
            }
        });

        // Admin: export migration snapshot + optional API push / rsync + Escort Me hook.
        this.app.post('/api/admin/migration/export', async (req, res) => {
            try {
                if (!this.isAdminRequest(req)) {
                    return res.status(403).json({ success: false, error: 'Admin access required' });
                }

                const useCopyParty = this.parseBool(req.body?.useCopyParty, true);
                const pushViaApi = this.parseBool(req.body?.pushViaApi, false);
                const useRsync = this.parseBool(req.body?.useRsync, false);
                const triggerRoomTransfer = this.parseBool(req.body?.triggerRoomTransfer, false);
                const targetServerUrl = String(req.body?.targetServerUrl || '').trim().replace(/\/+$/, '');
                const targetAdminKey = String(req.body?.targetAdminKey || process.env.VOICELINK_MIGRATION_TARGET_ADMIN_KEY || '').trim();
                const rsyncTarget = String(req.body?.rsyncTarget || process.env.VOICELINK_MIGRATION_RSYNC_TARGET || '').trim();

                const snapshot = this.buildAdminMigrationSnapshot(req.body || {});
                const archive = await this.createJsonZipArchive(snapshot, {
                    prefix: `migration-${this.sanitizeExportSegment(os.hostname(), 'server')}`
                });

                let copyParty = { uploaded: false };
                if (useCopyParty) {
                    try {
                        copyParty = await this.uploadArchiveToCopyParty(archive.zipPath, archive.fileName);
                    } catch (error) {
                        copyParty = { uploaded: false, error: error.message };
                    }
                }

                let apiPush = { pushed: false };
                if (pushViaApi && targetServerUrl) {
                    try {
                        const headers = { 'Content-Type': 'application/json' };
                        if (targetAdminKey) headers['x-admin-key'] = targetAdminKey;
                        const response = await fetch(`${targetServerUrl}/api/admin/migration/import`, {
                            method: 'POST',
                            headers,
                            body: JSON.stringify({
                                snapshot,
                                source: { host: os.hostname(), exportedAt: snapshot.generatedAt }
                            })
                        });
                        apiPush = {
                            pushed: response.ok,
                            status: response.status,
                            response: await response.json().catch(() => ({}))
                        };
                    } catch (error) {
                        apiPush = { pushed: false, error: error.message };
                    }
                }

                let rsync = { ran: false };
                if (useRsync) {
                    if (!rsyncTarget) {
                        rsync = { ran: false, error: 'Missing rsyncTarget or VOICELINK_MIGRATION_RSYNC_TARGET' };
                    } else {
                        try {
                            await this.runCommand('rsync', ['-az', '--partial', archive.zipPath, rsyncTarget]);
                            rsync = { ran: true, target: rsyncTarget };
                        } catch (error) {
                            rsync = { ran: false, error: error.message, target: rsyncTarget };
                        }
                    }
                }

                let roomTransfer = null;
                if (triggerRoomTransfer) {
                    const sourceRoomId = String(req.body?.sourceRoomId || '').trim();
                    const targetRoomId = String(req.body?.targetRoomId || '').trim();
                    if (sourceRoomId && targetRoomId) {
                        roomTransfer = this.startMigrationRoomTransfer({
                            sourceRoomId,
                            targetRoomId,
                            targetServerUrl
                        });
                    }
                }

                res.json({
                    success: true,
                    archive: {
                        fileName: archive.fileName,
                        size: archive.size,
                        createdAt: archive.createdAt,
                        downloadUrl: archive.downloadUrl
                    },
                    copyParty,
                    apiPush,
                    rsync,
                    roomTransfer
                });
            } catch (error) {
                console.error('[Migration] Export failed:', error.message);
                res.status(500).json({ success: false, error: error.message });
            }
        });

        // Admin: import migration snapshot.
        this.app.post('/api/admin/migration/import', (req, res) => {
            try {
                if (!this.isAdminRequest(req)) {
                    return res.status(403).json({ success: false, error: 'Admin access required' });
                }
                const snapshot = req.body?.snapshot || req.body;
                if (!snapshot || typeof snapshot !== 'object') {
                    return res.status(400).json({ success: false, error: 'Missing migration snapshot payload' });
                }
                const result = this.applyAdminMigrationSnapshot(snapshot);
                res.json({
                    success: true,
                    importedAt: new Date().toISOString(),
                    source: req.body?.source || null,
                    result
                });
            } catch (error) {
                res.status(500).json({ success: false, error: error.message });
            }
        });

        // Admin: direct hook into Escort Me room-to-room transfer flow.
        this.app.post('/api/admin/migration/room-transfer', (req, res) => {
            try {
                if (!this.isAdminRequest(req)) {
                    return res.status(403).json({ success: false, error: 'Admin access required' });
                }
                const sourceRoomId = String(req.body?.sourceRoomId || '').trim();
                const targetRoomId = String(req.body?.targetRoomId || '').trim();
                const targetServerUrl = String(req.body?.targetServerUrl || '').trim();
                if (!sourceRoomId || !targetRoomId) {
                    return res.status(400).json({ success: false, error: 'sourceRoomId and targetRoomId are required' });
                }

                const session = this.startMigrationRoomTransfer({
                    sourceRoomId,
                    targetRoomId,
                    targetServerUrl
                });
                res.json({ success: true, session });
            } catch (error) {
                res.status(500).json({ success: false, error: error.message });
            }
        });

        // ============================================
        // MODULE INSTALLER API
        // ============================================

        // Get available modules
        this.app.get('/api/modules', (req, res) => {
            const { sortBy = 'recommended', category = null } = req.query;
            const modules = this.moduleRegistry.getAvailableModules({ sortBy, category });
            res.json({
                modules,
                categories: this.moduleRegistry.getCategories()
            });
        });

        // Get installed modules
        this.app.get('/api/modules/installed', (req, res) => {
            res.json(this.moduleRegistry.getInstalledModules());
        });

        // Get single module details
        this.app.get('/api/modules/:moduleId', (req, res) => {
            const module = this.moduleRegistry.getModule(req.params.moduleId);
            if (!module) {
                return res.status(404).json({ error: 'Module not found' });
            }
            res.json(module);
        });

        // Install module
        this.app.post('/api/modules/:moduleId/install', (req, res) => {
            const result = this.moduleRegistry.installModule(req.params.moduleId, req.body.config);
            if (result.success) {
                // Reinitialize modules after install
                this.initializeModules();
            }
            res.json(result);
        });

        // Uninstall module
        this.app.post('/api/modules/:moduleId/uninstall', (req, res) => {
            const result = this.moduleRegistry.uninstallModule(req.params.moduleId);
            if (result.success) {
                // Clear module instance
                if (req.params.moduleId === 'two-factor-auth') {
                    this.modules.twoFactorAuth = null;
                } else if (req.params.moduleId === 'support-system') {
                    this.modules.supportSystem = null;
                }
            }
            res.json(result);
        });

        // Update module config
        this.app.put('/api/modules/:moduleId/config', (req, res) => {
            const result = this.moduleRegistry.updateModuleConfig(req.params.moduleId, req.body);
            if (result.success) {
                this.initializeModules();
            }
            res.json(result);
        });

        // Enable/disable module
        this.app.post('/api/modules/:moduleId/toggle', (req, res) => {
            const module = this.moduleRegistry.getModule(req.params.moduleId);
            if (!module?.installed) {
                return res.status(404).json({ error: 'Module not installed' });
            }
            const enabled = req.body.enabled !== undefined ? req.body.enabled : !module.config.enabled;
            const result = this.moduleRegistry.setModuleEnabled(req.params.moduleId, enabled);
            if (result.success) {
                this.initializeModules();
            }
            res.json(result);
        });

        // ============================================
        // TWO-FACTOR AUTHENTICATION API
        // ============================================

        // Check if 2FA module is enabled middleware
        const require2FAModule = (req, res, next) => {
            if (!this.modules.twoFactorAuth) {
                return res.status(503).json({ error: '2FA module not installed or enabled' });
            }
            next();
        };

        // Get 2FA status for user
        this.app.get('/api/2fa/status/:userId', require2FAModule, (req, res) => {
            const settings = this.modules.twoFactorAuth.getUserSettings(req.params.userId);
            const methods = this.modules.twoFactorAuth.getAvailableMethods(req.params.userId);
            res.json({
                enabled: settings.enabled,
                methods,
                required: this.modules.twoFactorAuth.is2FARequired(req.params.userId, req.query.role)
            });
        });

        // Setup TOTP
        this.app.post('/api/2fa/totp/setup', require2FAModule, (req, res) => {
            const { userId, accountName } = req.body;
            const result = this.modules.twoFactorAuth.setupTOTP(userId, accountName);
            res.json(result);
        });

        // Verify and activate TOTP
        this.app.post('/api/2fa/totp/verify', require2FAModule, (req, res) => {
            const { userId, code } = req.body;
            const result = this.modules.twoFactorAuth.verifyAndActivateTOTP(userId, code);
            res.json(result);
        });

        // Verify TOTP for login
        this.app.post('/api/2fa/totp/authenticate', require2FAModule, (req, res) => {
            const { userId, code } = req.body;
            const result = this.modules.twoFactorAuth.verifyTOTP(userId, code);
            res.json(result);
        });

        // Setup SMS 2FA
        this.app.post('/api/2fa/sms/setup', require2FAModule, async (req, res) => {
            const { userId, phoneNumber } = req.body;
            const result = await this.modules.twoFactorAuth.setupSMS(userId, phoneNumber);
            res.json(result);
        });

        // Verify SMS setup code
        this.app.post('/api/2fa/sms/verify-setup', require2FAModule, (req, res) => {
            const { userId, code } = req.body;
            const result = this.modules.twoFactorAuth.verifySMSSetup(userId, code);
            res.json(result);
        });

        // Send SMS code for login
        this.app.post('/api/2fa/sms/send', require2FAModule, async (req, res) => {
            const { userId } = req.body;
            const result = await this.modules.twoFactorAuth.sendSMSCode(userId);
            res.json(result);
        });

        // Verify SMS login code
        this.app.post('/api/2fa/sms/authenticate', require2FAModule, (req, res) => {
            const { userId, code } = req.body;
            const result = this.modules.twoFactorAuth.verifySMSLogin(userId, code);
            res.json(result);
        });

        // Setup email 2FA
        this.app.post('/api/2fa/email/setup', require2FAModule, async (req, res) => {
            const { userId, email } = req.body;
            const result = await this.modules.twoFactorAuth.setupEmail(userId, email);
            res.json(result);
        });

        // Verify email setup code
        this.app.post('/api/2fa/email/verify-setup', require2FAModule, (req, res) => {
            const { userId, code } = req.body;
            const result = this.modules.twoFactorAuth.verifyEmailSetup(userId, code);
            res.json(result);
        });

        // Send email code for login
        this.app.post('/api/2fa/email/send', require2FAModule, async (req, res) => {
            const { userId } = req.body;
            const result = await this.modules.twoFactorAuth.sendEmailCode(userId);
            res.json(result);
        });

        // Verify email login code
        this.app.post('/api/2fa/email/authenticate', require2FAModule, (req, res) => {
            const { userId, code } = req.body;
            const result = this.modules.twoFactorAuth.verifyEmailLogin(userId, code);
            res.json(result);
        });

        // Start passkey registration
        this.app.post('/api/2fa/passkey/register/start', require2FAModule, (req, res) => {
            const { userId, userName } = req.body;
            const options = this.modules.twoFactorAuth.startPasskeyRegistration(userId, userName);
            res.json(options);
        });

        // Complete passkey registration
        this.app.post('/api/2fa/passkey/register/complete', require2FAModule, (req, res) => {
            const { userId, credential } = req.body;
            const result = this.modules.twoFactorAuth.completePasskeyRegistration(userId, credential);
            res.json(result);
        });

        // Start passkey authentication
        this.app.post('/api/2fa/passkey/authenticate/start', require2FAModule, (req, res) => {
            const { userId } = req.body;
            const result = this.modules.twoFactorAuth.startPasskeyAuth(userId);
            res.json(result);
        });

        // Complete passkey authentication
        this.app.post('/api/2fa/passkey/authenticate/complete', require2FAModule, (req, res) => {
            const { userId, credential } = req.body;
            const result = this.modules.twoFactorAuth.completePasskeyAuth(userId, credential);
            res.json(result);
        });

        // Verify backup code
        this.app.post('/api/2fa/backup/verify', require2FAModule, (req, res) => {
            const { userId, code } = req.body;
            const result = this.modules.twoFactorAuth.verifyBackupCode(userId, code);
            res.json(result);
        });

        // Generate new backup codes
        this.app.post('/api/2fa/backup/generate', require2FAModule, (req, res) => {
            const { userId } = req.body;
            const codes = this.modules.twoFactorAuth.generateBackupCodes(userId);
            res.json({ success: true, codes });
        });

        // Disable 2FA (admin or self)
        this.app.post('/api/2fa/disable', require2FAModule, (req, res) => {
            const { userId } = req.body;
            const result = this.modules.twoFactorAuth.disable2FA(userId);
            res.json(result);
        });

        // Admin: Get 2FA statistics
        this.app.get('/api/2fa/admin/stats', require2FAModule, (req, res) => {
            res.json(this.modules.twoFactorAuth.getAdminStatus());
        });

        // ============================================
        // SUPPORT SYSTEM API
        // ============================================

        // Check if support module is enabled middleware
        const requireSupportModule = (req, res, next) => {
            if (!this.modules.supportSystem) {
                return res.status(503).json({ error: 'Support module not installed or enabled' });
            }
            next();
        };

        // Get support availability
        this.app.get('/api/support/status', requireSupportModule, (req, res) => {
            res.json(this.modules.supportSystem.isAvailable());
        });

        // Get support categories
        this.app.get('/api/support/categories', requireSupportModule, (req, res) => {
            res.json(this.modules.supportSystem.tickets.getCategories());
        });

        // Create ticket
        this.app.post('/api/support/tickets', requireSupportModule, async (req, res) => {
            const result = await this.modules.supportSystem.tickets.createTicket(req.body);
            res.json(result);
        });

        // Get user's tickets
        this.app.get('/api/support/tickets/user/:userId', requireSupportModule, (req, res) => {
            const tickets = this.modules.supportSystem.tickets.getUserTickets(
                req.params.userId,
                req.query
            );
            res.json(tickets);
        });

        // Get ticket by ID
        this.app.get('/api/support/tickets/:ticketId', requireSupportModule, (req, res) => {
            const ticket = this.modules.supportSystem.tickets.getTicket(req.params.ticketId);
            if (!ticket) {
                return res.status(404).json({ error: 'Ticket not found' });
            }
            res.json(ticket);
        });

        // Add reply to ticket
        this.app.post('/api/support/tickets/:ticketId/reply', requireSupportModule, async (req, res) => {
            const result = await this.modules.supportSystem.tickets.addReply(
                req.params.ticketId,
                req.body
            );
            res.json(result);
        });

        // Update ticket status
        this.app.put('/api/support/tickets/:ticketId/status', requireSupportModule, (req, res) => {
            const result = this.modules.supportSystem.tickets.updateStatus(
                req.params.ticketId,
                req.body.status,
                req.body.note
            );
            res.json(result);
        });

        // Rate ticket
        this.app.post('/api/support/tickets/:ticketId/rate', requireSupportModule, (req, res) => {
            const result = this.modules.supportSystem.tickets.addRating(
                req.params.ticketId,
                req.body.rating,
                req.body.feedback
            );
            res.json(result);
        });

        // Admin: Get all tickets
        this.app.get('/api/support/admin/tickets', requireSupportModule, (req, res) => {
            const result = this.modules.supportSystem.tickets.getAllTickets(req.query);
            res.json(result);
        });

        // Admin: Assign ticket
        this.app.post('/api/support/admin/tickets/:ticketId/assign', requireSupportModule, (req, res) => {
            const result = this.modules.supportSystem.tickets.assignTicket(
                req.params.ticketId,
                req.body.agentId,
                req.body.agentName
            );
            res.json(result);
        });

        // Admin: Get statistics
        this.app.get('/api/support/admin/stats', requireSupportModule, (req, res) => {
            res.json(this.modules.supportSystem.getStatistics());
        });

        // Admin: Manage agents
        this.app.get('/api/support/admin/agents', requireSupportModule, (req, res) => {
            res.json(this.modules.supportSystem.tickets.getAgents());
        });

        this.app.post('/api/support/admin/agents', requireSupportModule, (req, res) => {
            const result = this.modules.supportSystem.tickets.addAgent(req.body);
            res.json(result);
        });

        this.app.delete('/api/support/admin/agents/:agentId', requireSupportModule, (req, res) => {
            const result = this.modules.supportSystem.tickets.removeAgent(req.params.agentId);
            res.json(result);
        });

        // Live chat endpoints
        this.app.post('/api/support/chat/join', requireSupportModule, (req, res) => {
            const result = this.modules.supportSystem.liveChat.joinQueue(
                req.body.userId,
                req.body.userName,
                req.body.issue
            );
            res.json(result);
        });

        this.app.post('/api/support/chat/leave', requireSupportModule, (req, res) => {
            this.modules.supportSystem.liveChat.leaveQueue(req.body.queueId);
            res.json({ success: true });
        });

        this.app.get('/api/support/chat/status', requireSupportModule, (req, res) => {
            res.json(this.modules.supportSystem.liveChat.getQueueStatus());
        });

        // ============================================
        // VM MANAGER API
        // ============================================

        // Check if VM Manager module is enabled middleware
        const requireVMModule = (req, res, next) => {
            if (!this.modules.vmManager) {
                return res.status(503).json({ error: 'VM Manager module not installed or enabled' });
            }
            next();
        };

        // List all VMs
        this.app.get('/api/vms', requireVMModule, async (req, res) => {
            const vms = await this.modules.vmManager.listVMs();
            res.json({ success: true, vms });
        });

        // Get tracked VMs with assignments
        this.app.get('/api/vms/tracked', requireVMModule, (req, res) => {
            res.json({
                success: true,
                vms: this.modules.vmManager.getAllTrackedVMs()
            });
        });

        // Get VM statistics
        this.app.get('/api/vms/stats', requireVMModule, (req, res) => {
            res.json(this.modules.vmManager.getStatistics());
        });

        // Get VMs for user
        this.app.get('/api/vms/user/:userId', requireVMModule, (req, res) => {
            res.json({
                success: true,
                vms: this.modules.vmManager.getVMsForUser(req.params.userId)
            });
        });

        // Create VM
        this.app.post('/api/vms', requireVMModule, async (req, res) => {
            const result = await this.modules.vmManager.createVM(req.body);
            res.json(result);
        });

        // Get VM status
        this.app.get('/api/vms/:vmId/status', requireVMModule, async (req, res) => {
            const result = await this.modules.vmManager.getVMStatus(req.params.vmId);
            res.json(result);
        });

        // Start VM
        this.app.post('/api/vms/:vmId/start', requireVMModule, async (req, res) => {
            const result = await this.modules.vmManager.startVM(req.params.vmId);
            res.json(result);
        });

        // Stop VM
        this.app.post('/api/vms/:vmId/stop', requireVMModule, async (req, res) => {
            const result = await this.modules.vmManager.stopVM(req.params.vmId);
            res.json(result);
        });

        // Force stop VM
        this.app.post('/api/vms/:vmId/force-stop', requireVMModule, async (req, res) => {
            const result = await this.modules.vmManager.forceStopVM(req.params.vmId);
            res.json(result);
        });

        // Restart VM
        this.app.post('/api/vms/:vmId/restart', requireVMModule, async (req, res) => {
            const result = await this.modules.vmManager.restartVM(req.params.vmId);
            res.json(result);
        });

        // Suspend VM
        this.app.post('/api/vms/:vmId/suspend', requireVMModule, async (req, res) => {
            const result = await this.modules.vmManager.suspendVM(req.params.vmId);
            res.json(result);
        });

        // Resume VM
        this.app.post('/api/vms/:vmId/resume', requireVMModule, async (req, res) => {
            const result = await this.modules.vmManager.resumeVM(req.params.vmId);
            res.json(result);
        });

        // Delete VM
        this.app.delete('/api/vms/:vmId', requireVMModule, async (req, res) => {
            const result = await this.modules.vmManager.deleteVM(req.params.vmId);
            res.json(result);
        });

        // Resize VM
        this.app.put('/api/vms/:vmId/resize', requireVMModule, async (req, res) => {
            const result = await this.modules.vmManager.resizeVM(req.params.vmId, req.body);
            res.json(result);
        });

        // Get VNC console
        this.app.get('/api/vms/:vmId/console', requireVMModule, async (req, res) => {
            const result = await this.modules.vmManager.getConsole(req.params.vmId);
            res.json(result);
        });

        // Create snapshot
        this.app.post('/api/vms/:vmId/snapshot', requireVMModule, async (req, res) => {
            const result = await this.modules.vmManager.createSnapshot(req.params.vmId, req.body.name);
            res.json(result);
        });

        // List snapshots
        this.app.get('/api/vms/:vmId/snapshots', requireVMModule, async (req, res) => {
            const result = await this.modules.vmManager.listSnapshots(req.params.vmId);
            res.json(result);
        });

        // Restore snapshot
        this.app.post('/api/vms/:vmId/snapshot/:snapshotName/restore', requireVMModule, async (req, res) => {
            const result = await this.modules.vmManager.restoreSnapshot(req.params.vmId, req.params.snapshotName);
            res.json(result);
        });

        // Assign VM
        this.app.post('/api/vms/:vmId/assign', requireVMModule, (req, res) => {
            const result = this.modules.vmManager.assignVM(req.params.vmId, req.body);
            res.json(result);
        });

        // Unassign VM
        this.app.post('/api/vms/:vmId/unassign', requireVMModule, (req, res) => {
            const result = this.modules.vmManager.unassignVM(req.params.vmId);
            res.json(result);
        });

        // Trigger VM detection
        this.app.post('/api/vms/detect', requireVMModule, async (req, res) => {
            const result = await this.modules.vmManager.detectAndAssignVMs();
            res.json(result);
        });

        // Get OS images
        this.app.get('/api/vms/images', requireVMModule, async (req, res) => {
            const result = await this.modules.vmManager.getOSImages();
            res.json(result);
        });

        // ============================================
        // WHMCS INTEGRATION API
        // ============================================

        // Check if WHMCS module is enabled middleware
        const requireWHMCSModule = (req, res, next) => {
            if (!this.modules.whmcsIntegration) {
                return res.status(503).json({ error: 'WHMCS Integration module not installed or enabled' });
            }
            next();
        };

        // Get WHMCS integration statistics
        this.app.get('/api/whmcs/stats', requireWHMCSModule, (req, res) => {
            res.json(this.modules.whmcsIntegration.getStatistics());
        });

        // Get WHMCS client
        this.app.get('/api/whmcs/clients/:clientId', requireWHMCSModule, async (req, res) => {
            const client = await this.modules.whmcsIntegration.getClient(req.params.clientId);
            if (!client) {
                return res.status(404).json({ error: 'Client not found' });
            }
            res.json(client);
        });

        // Search client by email
        this.app.get('/api/whmcs/clients/search/:email', requireWHMCSModule, async (req, res) => {
            const client = await this.modules.whmcsIntegration.searchClientByEmail(req.params.email);
            res.json(client || { found: false });
        });

        // Get client services
        this.app.get('/api/whmcs/clients/:clientId/services', requireWHMCSModule, async (req, res) => {
            const services = await this.modules.whmcsIntegration.getClientServices(req.params.clientId);
            res.json({ success: true, services });
        });

        // Get service details
        this.app.get('/api/whmcs/services/:serviceId', requireWHMCSModule, async (req, res) => {
            const service = await this.modules.whmcsIntegration.getService(req.params.serviceId);
            if (!service) {
                return res.status(404).json({ error: 'Service not found' });
            }
            res.json(service);
        });

        // Get VM for service
        this.app.get('/api/whmcs/services/:serviceId/vm', requireWHMCSModule, (req, res) => {
            const vm = this.modules.whmcsIntegration.getVMForService(req.params.serviceId);
            res.json(vm || { found: false });
        });

        // Provision VM for service
        this.app.post('/api/whmcs/services/:serviceId/provision', requireWHMCSModule, async (req, res) => {
            const result = await this.modules.whmcsIntegration.provisionVMForService(
                req.params.serviceId,
                req.body
            );
            res.json(result);
        });

        // Terminate VM for service
        this.app.post('/api/whmcs/services/:serviceId/terminate', requireWHMCSModule, async (req, res) => {
            const result = await this.modules.whmcsIntegration.terminateVMForService(req.params.serviceId);
            res.json(result);
        });

        // Suspend VM for service
        this.app.post('/api/whmcs/services/:serviceId/suspend', requireWHMCSModule, async (req, res) => {
            const result = await this.modules.whmcsIntegration.suspendVMForService(req.params.serviceId);
            res.json(result);
        });

        // Unsuspend VM for service
        this.app.post('/api/whmcs/services/:serviceId/unsuspend', requireWHMCSModule, async (req, res) => {
            const result = await this.modules.whmcsIntegration.unsuspendVMForService(req.params.serviceId);
            res.json(result);
        });

        // Get all VM mappings
        this.app.get('/api/whmcs/vm-mappings', requireWHMCSModule, (req, res) => {
            res.json({
                success: true,
                mappings: this.modules.whmcsIntegration.getAllVMMappings()
            });
        });

        // Sync VMs with WHMCS services
        this.app.post('/api/whmcs/sync', requireWHMCSModule, async (req, res) => {
            const result = await this.modules.whmcsIntegration.syncVMsWithServices();
            res.json(result);
        });

        // WHMCS webhook handler
        this.app.post('/api/whmcs/webhook', requireWHMCSModule, async (req, res) => {
            const { action, ...data } = req.body;
            const result = await this.modules.whmcsIntegration.handleWebhook(action, data);
            res.json(result);
        });

        // ============================================
        // ROOMS BACKUP & PERSISTENCE
        // ============================================

        // Save current rooms to file
        this.app.post('/api/rooms/save', (req, res) => {
            try {
                const dataDir = path.join(__dirname, '../../data');
                if (!fs.existsSync(dataDir)) {
                    fs.mkdirSync(dataDir, { recursive: true });
                }

                const roomsData = Array.from(this.rooms.values()).map(room => ({
                    ...room,
                    users: [] // Don't persist user sessions
                }));

                fs.writeFileSync(
                    path.join(dataDir, 'rooms.json'),
                    JSON.stringify(roomsData, null, 2),
                    'utf8'
                );

                res.json({ success: true, count: roomsData.length });
            } catch (error) {
                res.status(500).json({ error: error.message });
            }
        });

        // Load rooms from file
        this.app.post('/api/rooms/load', (req, res) => {
            try {
                const roomsFile = path.join(__dirname, '../../data/rooms.json');
                if (!fs.existsSync(roomsFile)) {
                    return res.json({ success: true, count: 0, message: 'No saved rooms found' });
                }

                const roomsData = JSON.parse(fs.readFileSync(roomsFile, 'utf8'));
                let loaded = 0;

                for (const roomData of roomsData) {
                    if (!this.rooms.has(roomData.id)) {
                        roomData.users = []; // Reset users
                        this.rooms.set(roomData.id, roomData);
                        loaded++;
                    }
                }

                res.json({ success: true, count: loaded, total: this.rooms.size });
            } catch (error) {
                res.status(500).json({ error: error.message });
            }
        });

        // Admin refresh all rooms (clear and regenerate)
        this.app.post('/api/admin/rooms/refresh', async (req, res) => {
            try {
                const { keepDefault = true, regenerateDefaults = true } = req.body;

                // Clear non-default rooms if requested
                if (!keepDefault) {
                    for (const [roomId, room] of this.rooms) {
                        if (!room.isDefault) {
                            this.rooms.delete(roomId);
                            this.federation.broadcastRoomChange('deleted', { id: roomId });
                        }
                    }
                }

                // Regenerate default rooms if requested
                let regenerated = 0;
                if (regenerateDefaults) {
                    // Trigger default room generation
                    const defaultRooms = [
                        { name: 'General Chat', description: 'Open space for casual conversations and meeting new people', maxUsers: 50 },
                        { name: 'Music Lounge', description: 'Relaxed atmosphere to share and discuss music together', maxUsers: 20 },
                        { name: 'Gaming Voice', description: 'Voice chat for gamers to coordinate and hang out', maxUsers: 10 },
                        { name: 'Podcast Studio', description: 'Professional space for recording podcasts and interviews', maxUsers: 5 },
                        { name: 'Chill Zone', description: 'Laid-back vibes for unwinding and casual chat', maxUsers: 30 },
                        { name: 'Tech Talk', description: 'Discuss technology, coding, and the latest innovations', maxUsers: 25 },
                        { name: 'Creative Corner', description: 'Space for artists, writers, and creators to collaborate', maxUsers: 15 },
                        { name: 'Late Night', description: 'Night owl hangout for those burning the midnight oil', maxUsers: 20 }
                    ];

                    for (const config of defaultRooms) {
                        const exists = Array.from(this.rooms.values()).some(
                            r => r.name.toLowerCase() === config.name.toLowerCase()
                        );
                        if (!exists) {
                            const roomId = 'default_' + config.name.toLowerCase().replace(/\s+/g, '_');
                            const room = {
                                id: roomId,
                                name: config.name,
                                description: config.description,
                                maxUsers: config.maxUsers,
                                users: [],
                                visibility: 'public',
                                isDefault: true,
                                federated: true,
                                federationApproved: true,
                                createdAt: new Date()
                            };
                            this.rooms.set(roomId, room);
                            this.federation.broadcastRoomChange('created', room);
                            regenerated++;
                        }
                    }
                }

                res.json({
                    success: true,
                    totalRooms: this.rooms.size,
                    regenerated
                });
            } catch (error) {
                res.status(500).json({ error: error.message });
            }
        });

        // Admin restart server (graceful)
        this.app.post('/api/admin/restart', (req, res) => {
            res.json({ success: true, message: 'Server restart initiated' });

            // Give time for response to send
            setTimeout(() => {
                console.log('[Admin] Server restart requested');
                process.exit(0); // PM2 or systemd will restart
            }, 1000);
        });

        // ============================================
        // ECRIPTO WALLET INTEGRATION API
        // Room minting, access tiers, wallet-based access
        // ============================================

        // Store for access passes and minted rooms
        this.accessPasses = new Map(); // passId -> { userId, tier, roomId, expiresAt, walletAddress }
        this.mintedRooms = new Map(); // roomId -> { mintId, owner, price, forSale }

        // Get Ecripto integration status
        this.app.get('/api/ecripto/status', (req, res) => {
            const config = deployConfig.get('ecripto');
            res.json({
                enabled: config?.enabled || false,
                mintingEnabled: config?.mintingEnabled || false,
                walletAccessEnabled: config?.walletAccessEnabled || false,
                accessTiersEnabled: config?.accessTiers?.enabled || false,
                shopTabEnabled: config?.shopTabEnabled || false
            });
        });

        // Verify wallet ownership and get access level
        this.app.post('/api/ecripto/verify-wallet', async (req, res) => {
            const { walletAddress, signature, message } = req.body;
            const config = deployConfig.get('ecripto');

            if (!config?.enabled) {
                return res.json({ verified: false, reason: 'Ecripto not enabled' });
            }

            // TODO: Integrate with Ecripto API for signature verification
            // For now, return mock verification
            res.json({
                verified: true,
                walletAddress,
                accessLevel: 'standard',
                tokens: [],
                message: 'Wallet verification requires Ecripto API integration'
            });
        });

        // Purchase access tier for a room
        this.app.post('/api/ecripto/purchase-access', async (req, res) => {
            const { roomId, tier, walletAddress, transactionId } = req.body;
            const config = deployConfig.get('ecripto');

            if (!config?.accessTiers?.enabled) {
                return res.status(400).json({ error: 'Access tiers not enabled' });
            }

            const room = this.rooms.get(roomId);
            if (!room) {
                return res.status(404).json({ error: 'Room not found' });
            }

            // Find tier configuration
            const tierConfig = config.accessTiers.tiers.find(t => t.id === tier);
            if (!tierConfig) {
                return res.status(400).json({ error: 'Invalid tier' });
            }

            // TODO: Verify transaction with Ecripto API
            // For now, create pass directly
            const passId = 'pass_' + uuidv4();
            const pass = {
                id: passId,
                userId: walletAddress,
                walletAddress,
                tier,
                tierName: tierConfig.name,
                roomId,
                createdAt: new Date(),
                expiresAt: new Date(Date.now() + tierConfig.duration),
                transactionId
            };

            this.accessPasses.set(passId, pass);

            res.json({
                success: true,
                passId,
                expiresAt: pass.expiresAt,
                tier: tierConfig.name
            });
        });

        // Check access for a room
        this.app.get('/api/ecripto/check-access/:roomId', (req, res) => {
            const { walletAddress } = req.query;
            const roomId = req.params.roomId;
            const config = deployConfig.get('ecripto');

            if (!config?.enabled) {
                return res.json({ hasAccess: true, reason: 'Ecripto not enabled' });
            }

            const room = this.rooms.get(roomId);
            if (!room) {
                return res.status(404).json({ error: 'Room not found' });
            }

            // Check if room requires wallet access
            if (!room.requireWalletAccess) {
                return res.json({ hasAccess: true, reason: 'Room does not require wallet' });
            }

            // Check for valid access pass
            let hasAccess = false;
            let activePass = null;

            this.accessPasses.forEach((pass, passId) => {
                if (pass.walletAddress === walletAddress &&
                    pass.roomId === roomId &&
                    new Date(pass.expiresAt) > new Date()) {
                    hasAccess = true;
                    activePass = pass;
                }
            });

            res.json({
                hasAccess,
                activePass: activePass ? {
                    tier: activePass.tierName,
                    expiresAt: activePass.expiresAt
                } : null
            });
        });

        // List available access tiers
        this.app.get('/api/ecripto/access-tiers', (req, res) => {
            const config = deployConfig.get('ecripto');
            if (!config?.accessTiers?.enabled) {
                return res.json({ enabled: false, tiers: [] });
            }

            res.json({
                enabled: true,
                tiers: config.accessTiers.tiers
            });
        });

        // Mint a room (create NFT for room ownership)
        this.app.post('/api/ecripto/mint-room', async (req, res) => {
            const { roomId, walletAddress, price, metadata } = req.body;
            const config = deployConfig.get('ecripto');

            if (!config?.mintingEnabled) {
                return res.status(400).json({ error: 'Room minting not enabled' });
            }

            const room = this.rooms.get(roomId);
            if (!room) {
                return res.status(404).json({ error: 'Room not found' });
            }

            // Check if already minted
            if (this.mintedRooms.has(roomId)) {
                return res.status(400).json({ error: 'Room already minted' });
            }

            // TODO: Integrate with Ecripto API for actual minting
            const mintId = 'mint_' + uuidv4();
            const mintData = {
                mintId,
                roomId,
                owner: walletAddress,
                price: price || null,
                forSale: !!price,
                metadata: metadata || {},
                mintedAt: new Date()
            };

            this.mintedRooms.set(roomId, mintData);

            // Update room with mint info
            room.minted = true;
            room.mintId = mintId;
            room.mintOwner = walletAddress;
            this.rooms.set(roomId, room);

            res.json({
                success: true,
                mintId,
                message: 'Room minting requires Ecripto network integration'
            });
        });

        // Get minted rooms for shop/marketplace
        this.app.get('/api/ecripto/shop', (req, res) => {
            const config = deployConfig.get('ecripto');
            if (!config?.shopTabEnabled) {
                return res.json({ enabled: false, rooms: [] });
            }

            const forSaleRooms = [];
            this.mintedRooms.forEach((mintData, roomId) => {
                if (mintData.forSale) {
                    const room = this.rooms.get(roomId);
                    if (room) {
                        forSaleRooms.push({
                            roomId,
                            name: room.name,
                            description: room.description,
                            mintId: mintData.mintId,
                            price: mintData.price,
                            owner: mintData.owner,
                            users: room.users?.length || 0
                        });
                    }
                }
            });

            res.json({ enabled: true, rooms: forSaleRooms });
        });

        // ============================================
        // MASTODON SERVER DISCOVERY API
        // Find VoiceLink servers via Mastodon federation
        // ============================================

        // Store discovered servers
        this.discoveredServers = new Map(); // serverUrl -> { name, instance, lastSeen, rooms }

        // Discover servers on a Mastodon instance
        this.app.get('/api/discovery/mastodon/:instance', async (req, res) => {
            const instance = req.params.instance;
            const config = deployConfig.get('mastodonDiscovery');

            if (!config?.enabled) {
                return res.json({ enabled: false, servers: [] });
            }

            try {
                // Search for VoiceLink servers on this instance
                // This would query the instance's API for accounts/posts mentioning VoiceLink
                const instanceUrl = instance.startsWith('http') ? instance : `https://${instance}`;

                // TODO: Implement actual Mastodon API search
                // For now, return any cached servers for this domain
                const domainServers = [];
                this.discoveredServers.forEach((server, url) => {
                    if (server.instance === instance || url.includes(instance)) {
                        domainServers.push({
                            url,
                            name: server.name,
                            lastSeen: server.lastSeen,
                            roomCount: server.rooms?.length || 0
                        });
                    }
                });

                res.json({
                    instance,
                    servers: domainServers,
                    message: domainServers.length === 0 ?
                        'No VoiceLink servers found on this instance' :
                        `Found ${domainServers.length} server(s)`
                });
            } catch (error) {
                res.status(500).json({ error: error.message });
            }
        });

        // Get servers tied to a user's Mastodon profile
        this.app.get('/api/discovery/user/:handle', async (req, res) => {
            const handle = req.params.handle; // format: username@instance
            const config = deployConfig.get('mastodonDiscovery');

            if (!config?.showProfileServers) {
                return res.json({ enabled: false, servers: [] });
            }

            try {
                // Parse handle
                const [username, instance] = handle.includes('@') ?
                    handle.split('@').filter(Boolean) : [handle, null];

                if (!instance) {
                    return res.status(400).json({ error: 'Invalid handle format. Use username@instance' });
                }

                // TODO: Query user's profile for linked VoiceLink servers
                // This could be from profile fields, pinned posts, or a dedicated field
                const userServers = [];

                res.json({
                    handle,
                    servers: userServers,
                    message: 'Profile server discovery requires Mastodon API integration'
                });
            } catch (error) {
                res.status(500).json({ error: error.message });
            }
        });

        // Register this server for discovery
        this.app.post('/api/discovery/register', async (req, res) => {
            const { name, mastodonInstance, mastodonAccount, publicRooms } = req.body;
            const serverUrl = `${req.protocol}://${req.get('host')}`;

            // Store registration for federation
            this.discoveredServers.set(serverUrl, {
                name: name || deployConfig.get('server', 'name'),
                instance: mastodonInstance,
                account: mastodonAccount,
                lastSeen: new Date(),
                rooms: publicRooms || [],
                registered: true
            });

            res.json({
                success: true,
                serverUrl,
                message: 'Server registered for discovery'
            });
        });

        // Federated server list (all known servers)
        this.app.get('/api/discovery/servers', (req, res) => {
            const servers = [];
            this.discoveredServers.forEach((data, url) => {
                servers.push({
                    url,
                    name: data.name,
                    instance: data.instance,
                    lastSeen: data.lastSeen,
                    roomCount: data.rooms?.length || 0
                });
            });

            // Sort by last seen
            servers.sort((a, b) => new Date(b.lastSeen) - new Date(a.lastSeen));

            res.json({ servers, count: servers.length });
        });

        // ============================================
        // ROOM ACCESS FILTERING API
        // Filter by user, domain, mint status
        // ============================================

        // Filter rooms by various criteria
        this.app.get('/api/rooms/filter', (req, res) => {
            const {
                domain,         // Filter by Mastodon domain
                user,           // Filter by creator handle
                minted,         // Filter by mint status
                federated,      // Filter by federation status
                hasAccess,      // Filter by wallet access
                walletAddress   // Wallet for access check
            } = req.query;

            let filteredRooms = Array.from(this.rooms.values());

            // Filter by domain (creator's Mastodon instance)
            if (domain) {
                filteredRooms = filteredRooms.filter(room =>
                    room.creatorHandle?.includes(`@${domain}`)
                );
            }

            // Filter by user
            if (user) {
                filteredRooms = filteredRooms.filter(room =>
                    room.creatorHandle === user
                );
            }

            // Filter by mint status
            if (minted !== undefined) {
                const isMinted = minted === 'true';
                filteredRooms = filteredRooms.filter(room =>
                    isMinted ? room.minted : !room.minted
                );
            }

            // Filter by federation status
            if (federated !== undefined) {
                const isFederated = federated === 'true';
                filteredRooms = filteredRooms.filter(room =>
                    isFederated ? room.federated : !room.federated
                );
            }

            // Filter by wallet access
            if (hasAccess === 'true' && walletAddress) {
                filteredRooms = filteredRooms.filter(room => {
                    if (!room.requireWalletAccess) return true;

                    // Check for valid pass
                    let hasValidPass = false;
                    this.accessPasses.forEach(pass => {
                        if (pass.walletAddress === walletAddress &&
                            pass.roomId === room.id &&
                            new Date(pass.expiresAt) > new Date()) {
                            hasValidPass = true;
                        }
                    });
                    return hasValidPass;
                });
            }

            // Map to response format
            const rooms = filteredRooms.map(room => ({
                id: room.id,
                name: room.name,
                description: room.description,
                users: room.users?.length || 0,
                maxUsers: room.maxUsers,
                hasPassword: !!room.password,
                federated: room.federated,
                minted: room.minted,
                mintOwner: room.mintOwner,
                creatorHandle: room.creatorHandle
            }));

            res.json({ rooms, count: rooms.length });
        });

        // ============================================
        // STRIPE PAYMENT PROCESSING API
        // Credit card payments for access tiers
        // ============================================

        // Get Stripe configuration (publishable key only)
        this.app.get('/api/stripe/config', (req, res) => {
            const stripeConfig = deployConfig.get('stripe');
            if (stripeConfig && stripeConfig.publishableKey) {
                res.json({
                    publishableKey: stripeConfig.publishableKey,
                    enabled: true
                });
            } else {
                res.json({ enabled: false });
            }
        });

        // Create payment intent for room access
        this.app.post('/api/stripe/create-payment-intent', async (req, res) => {
            const stripeInstance = initStripe();
            if (!stripeInstance) {
                return res.status(400).json({ error: 'Stripe not configured' });
            }

            try {
                const { roomId, tier } = req.body;
                const ecriptoConfig = deployConfig.get('ecripto');

                // Get tier price
                const tierConfig = ecriptoConfig?.accessTiers?.tiers?.find(t => t.id === tier);
                if (!tierConfig || !tierConfig.price) {
                    return res.status(400).json({ error: 'Invalid tier or no price set' });
                }

                // Create payment intent
                const paymentIntent = await stripeInstance.paymentIntents.create({
                    amount: Math.round(tierConfig.price * 100), // Stripe uses cents
                    currency: 'usd',
                    metadata: {
                        roomId,
                        tier,
                        tierName: tierConfig.name
                    }
                });

                res.json({
                    clientSecret: paymentIntent.client_secret,
                    amount: tierConfig.price
                });

            } catch (error) {
                console.error('[Stripe] Payment intent error:', error);
                res.status(500).json({ error: error.message });
            }
        });

        // Stripe webhook for payment confirmations
        this.app.post('/api/stripe/webhook', express.raw({ type: 'application/json' }), async (req, res) => {
            const stripeInstance = initStripe();
            if (!stripeInstance) {
                return res.status(400).json({ error: 'Stripe not configured' });
            }

            const stripeConfig = deployConfig.get('stripe');
            const sig = req.headers['stripe-signature'];

            try {
                const event = stripeInstance.webhooks.constructEvent(
                    req.body,
                    sig,
                    stripeConfig.webhookSecret
                );

                // Handle successful payment
                if (event.type === 'payment_intent.succeeded') {
                    const paymentIntent = event.data.object;
                    const { roomId, tier } = paymentIntent.metadata;

                    // Create access pass
                    const ecriptoConfig = deployConfig.get('ecripto');
                    const tierConfig = ecriptoConfig?.accessTiers?.tiers?.find(t => t.id === tier);

                    if (tierConfig) {
                        const passId = 'pass_' + uuidv4();
                        const pass = {
                            id: passId,
                            tier,
                            tierName: tierConfig.name,
                            roomId,
                            createdAt: new Date(),
                            expiresAt: new Date(Date.now() + tierConfig.duration),
                            paymentIntentId: paymentIntent.id,
                            paymentMethod: 'stripe'
                        };
                        this.accessPasses.set(passId, pass);
                        console.log('[Stripe] Access pass created:', passId);
                    }
                }

                res.json({ received: true });

            } catch (error) {
                console.error('[Stripe] Webhook error:', error);
                res.status(400).json({ error: error.message });
            }
        });

        // ============================================
        // MULTI-PAYMENT PROVIDER API
        // Admin-configurable payment sources
        // ============================================

        // Get available payment providers (public - for checkout UI)
        this.app.get('/api/payments/providers', (req, res) => {
            const paymentsConfig = deployConfig.get('payments') || {};

            if (!paymentsConfig.enabled) {
                return res.json({ enabled: false, providers: [] });
            }

            const providers = [];
            const providerConfigs = paymentsConfig.providers || {};

            // Build list of enabled providers sorted by priority
            for (const [id, config] of Object.entries(providerConfigs)) {
                if (config.enabled) {
                    providers.push({
                        id,
                        displayName: config.displayName,
                        priority: config.priority || 99,
                        // Only expose safe public info
                        ...(id === 'stripe' && { publishableKey: config.publishableKey }),
                        ...(id === 'paypal' && { clientId: config.clientId, mode: config.mode }),
                        ...(id === 'crypto' && {
                            ecriptoEnabled: config.ecriptoEnabled,
                            addresses: config.addresses
                        }),
                        ...(id === 'cashapp' && { cashtag: config.cashtag }),
                        ...(id === 'manual' && {
                            instructions: config.instructions,
                            contactEmail: config.contactEmail,
                            contactMastodon: config.contactMastodon
                        })
                    });
                }
            }

            providers.sort((a, b) => a.priority - b.priority);

            res.json({
                enabled: true,
                defaultProvider: paymentsConfig.defaultProvider,
                currency: paymentsConfig.currency || 'usd',
                providers,
                pricing: {
                    roomAccess: paymentsConfig.pricing?.roomAccess?.enabled
                        ? paymentsConfig.pricing.roomAccess.tiers
                        : null,
                    donations: paymentsConfig.pricing?.donations?.enabled
                        ? {
                            suggestedAmounts: paymentsConfig.pricing.donations.suggestedAmounts,
                            allowCustomAmount: paymentsConfig.pricing.donations.allowCustomAmount,
                            minimumAmount: paymentsConfig.pricing.donations.minimumAmount
                        }
                        : null,
                    premiumFeatures: paymentsConfig.pricing?.premiumFeatures?.enabled
                        ? paymentsConfig.pricing.premiumFeatures.features
                        : null
                }
            });
        });

        // Admin: Get full payment configuration (sensitive data)
        this.app.get('/api/payments/admin/config', (req, res) => {
            // TODO: Add admin authentication check
            const paymentsConfig = deployConfig.get('payments') || {};
            res.json(paymentsConfig);
        });

        // Admin: Update payment configuration
        this.app.post('/api/payments/admin/config', (req, res) => {
            // TODO: Add admin authentication check
            const updates = req.body;

            try {
                deployConfig.updateSection('payments', updates);
                deployConfig.save();
                res.json({ success: true, message: 'Payment configuration updated' });
            } catch (error) {
                res.status(500).json({ error: error.message });
            }
        });

        // Admin: Enable/disable a payment provider
        this.app.post('/api/payments/admin/provider/:providerId/toggle', (req, res) => {
            const { providerId } = req.params;
            const { enabled } = req.body;

            const paymentsConfig = deployConfig.get('payments') || {};
            if (!paymentsConfig.providers?.[providerId]) {
                return res.status(404).json({ error: 'Provider not found' });
            }

            paymentsConfig.providers[providerId].enabled = enabled;
            deployConfig.updateSection('payments', paymentsConfig);
            deployConfig.save();

            res.json({
                success: true,
                provider: providerId,
                enabled
            });
        });

        // Admin: Configure a specific payment provider
        this.app.post('/api/payments/admin/provider/:providerId', (req, res) => {
            const { providerId } = req.params;
            const config = req.body;

            const paymentsConfig = deployConfig.get('payments') || {};
            if (!paymentsConfig.providers) {
                paymentsConfig.providers = {};
            }

            paymentsConfig.providers[providerId] = {
                ...paymentsConfig.providers[providerId],
                ...config
            };

            deployConfig.updateSection('payments', paymentsConfig);
            deployConfig.save();

            res.json({
                success: true,
                provider: providerId,
                message: `${providerId} configuration updated`
            });
        });

        // Admin: Set default payment provider
        this.app.post('/api/payments/admin/default', (req, res) => {
            const { provider } = req.body;

            const paymentsConfig = deployConfig.get('payments') || {};

            // Verify provider exists and is enabled
            if (provider && !paymentsConfig.providers?.[provider]?.enabled) {
                return res.status(400).json({
                    error: 'Provider must be enabled before setting as default'
                });
            }

            paymentsConfig.defaultProvider = provider;
            deployConfig.updateSection('payments', paymentsConfig);
            deployConfig.save();

            res.json({ success: true, defaultProvider: provider });
        });

        // Admin: Update pricing configuration
        this.app.post('/api/payments/admin/pricing', (req, res) => {
            const { roomAccess, donations, premiumFeatures } = req.body;

            const paymentsConfig = deployConfig.get('payments') || {};
            if (!paymentsConfig.pricing) {
                paymentsConfig.pricing = {};
            }

            if (roomAccess !== undefined) {
                paymentsConfig.pricing.roomAccess = roomAccess;
            }
            if (donations !== undefined) {
                paymentsConfig.pricing.donations = donations;
            }
            if (premiumFeatures !== undefined) {
                paymentsConfig.pricing.premiumFeatures = premiumFeatures;
            }

            deployConfig.updateSection('payments', paymentsConfig);
            deployConfig.save();

            res.json({ success: true, pricing: paymentsConfig.pricing });
        });

        // PayPal: Create order
        this.app.post('/api/payments/paypal/create-order', async (req, res) => {
            const paymentsConfig = deployConfig.get('payments') || {};
            const paypalConfig = paymentsConfig.providers?.paypal;

            if (!paypalConfig?.enabled || !paypalConfig?.clientId || !paypalConfig?.clientSecret) {
                return res.status(400).json({ error: 'PayPal not configured' });
            }

            const { amount, description, type, metadata } = req.body;

            try {
                // Get PayPal access token
                const auth = Buffer.from(`${paypalConfig.clientId}:${paypalConfig.clientSecret}`).toString('base64');
                const baseUrl = paypalConfig.mode === 'live'
                    ? 'https://api-m.paypal.com'
                    : 'https://api-m.sandbox.paypal.com';

                const tokenResponse = await fetch(`${baseUrl}/v1/oauth2/token`, {
                    method: 'POST',
                    headers: {
                        'Authorization': `Basic ${auth}`,
                        'Content-Type': 'application/x-www-form-urlencoded'
                    },
                    body: 'grant_type=client_credentials'
                });

                const tokenData = await tokenResponse.json();

                // Create order
                const orderResponse = await fetch(`${baseUrl}/v2/checkout/orders`, {
                    method: 'POST',
                    headers: {
                        'Authorization': `Bearer ${tokenData.access_token}`,
                        'Content-Type': 'application/json'
                    },
                    body: JSON.stringify({
                        intent: 'CAPTURE',
                        purchase_units: [{
                            amount: {
                                currency_code: paymentsConfig.currency?.toUpperCase() || 'USD',
                                value: amount.toFixed(2)
                            },
                            description: description || 'VoiceLink Payment'
                        }]
                    })
                });

                const orderData = await orderResponse.json();

                res.json({
                    orderId: orderData.id,
                    status: orderData.status
                });

            } catch (error) {
                console.error('[PayPal] Create order error:', error);
                res.status(500).json({ error: 'Failed to create PayPal order' });
            }
        });

        // PayPal: Capture order (after user approval)
        this.app.post('/api/payments/paypal/capture-order', async (req, res) => {
            const paymentsConfig = deployConfig.get('payments') || {};
            const paypalConfig = paymentsConfig.providers?.paypal;

            if (!paypalConfig?.enabled) {
                return res.status(400).json({ error: 'PayPal not configured' });
            }

            const { orderId, type, tier, roomId } = req.body;

            try {
                const auth = Buffer.from(`${paypalConfig.clientId}:${paypalConfig.clientSecret}`).toString('base64');
                const baseUrl = paypalConfig.mode === 'live'
                    ? 'https://api-m.paypal.com'
                    : 'https://api-m.sandbox.paypal.com';

                const tokenResponse = await fetch(`${baseUrl}/v1/oauth2/token`, {
                    method: 'POST',
                    headers: {
                        'Authorization': `Basic ${auth}`,
                        'Content-Type': 'application/x-www-form-urlencoded'
                    },
                    body: 'grant_type=client_credentials'
                });

                const tokenData = await tokenResponse.json();

                const captureResponse = await fetch(`${baseUrl}/v2/checkout/orders/${orderId}/capture`, {
                    method: 'POST',
                    headers: {
                        'Authorization': `Bearer ${tokenData.access_token}`,
                        'Content-Type': 'application/json'
                    }
                });

                const captureData = await captureResponse.json();

                if (captureData.status === 'COMPLETED') {
                    // Handle successful payment - create access pass if applicable
                    if (type === 'room_access' && tier && roomId) {
                        const tiers = paymentsConfig.pricing?.roomAccess?.tiers || [];
                        const tierConfig = tiers.find(t => t.id === tier);

                        if (tierConfig) {
                            const passId = 'pass_' + uuidv4();
                            const pass = {
                                id: passId,
                                tier,
                                tierName: tierConfig.name,
                                roomId,
                                createdAt: new Date(),
                                expiresAt: new Date(Date.now() + tierConfig.duration),
                                paypalOrderId: orderId,
                                paymentMethod: 'paypal'
                            };
                            this.accessPasses.set(passId, pass);
                            console.log('[PayPal] Access pass created:', passId);
                        }
                    }

                    res.json({
                        success: true,
                        status: 'COMPLETED',
                        orderId
                    });
                } else {
                    res.json({
                        success: false,
                        status: captureData.status,
                        details: captureData
                    });
                }

            } catch (error) {
                console.error('[PayPal] Capture error:', error);
                res.status(500).json({ error: 'Failed to capture PayPal payment' });
            }
        });

        // Manual payment: Submit payment notification
        this.app.post('/api/payments/manual/submit', (req, res) => {
            const paymentsConfig = deployConfig.get('payments') || {};
            const manualConfig = paymentsConfig.providers?.manual;

            if (!manualConfig?.enabled) {
                return res.status(400).json({ error: 'Manual payments not enabled' });
            }

            const { userId, userName, email, amount, type, tier, roomId, notes, transactionRef } = req.body;

            // Create pending payment record for admin review
            const paymentId = 'manual_' + uuidv4().slice(0, 8);
            const payment = {
                id: paymentId,
                userId,
                userName,
                email,
                amount,
                type,
                tier,
                roomId,
                notes,
                transactionRef,
                status: 'pending_review',
                submittedAt: new Date()
            };

            if (!this.pendingManualPayments) {
                this.pendingManualPayments = new Map();
            }
            this.pendingManualPayments.set(paymentId, payment);

            console.log('[Manual Payment] Submitted for review:', paymentId);

            res.json({
                success: true,
                paymentId,
                message: 'Payment submitted for admin review. You will be notified once approved.'
            });
        });

        // Admin: List pending manual payments
        this.app.get('/api/payments/manual/pending', (req, res) => {
            const payments = Array.from(this.pendingManualPayments?.values() || [])
                .filter(p => p.status === 'pending_review');
            res.json({ payments });
        });

        // Admin: Approve manual payment
        this.app.post('/api/payments/manual/approve/:paymentId', (req, res) => {
            const { paymentId } = req.params;
            const payment = this.pendingManualPayments?.get(paymentId);

            if (!payment) {
                return res.status(404).json({ error: 'Payment not found' });
            }

            payment.status = 'approved';
            payment.approvedAt = new Date();

            // Create access pass if applicable
            if (payment.type === 'room_access' && payment.tier && payment.roomId) {
                const paymentsConfig = deployConfig.get('payments') || {};
                const tiers = paymentsConfig.pricing?.roomAccess?.tiers || [];
                const tierConfig = tiers.find(t => t.id === payment.tier);

                if (tierConfig) {
                    const passId = 'pass_' + uuidv4();
                    const pass = {
                        id: passId,
                        tier: payment.tier,
                        tierName: tierConfig.name,
                        roomId: payment.roomId,
                        userId: payment.userId,
                        createdAt: new Date(),
                        expiresAt: new Date(Date.now() + tierConfig.duration),
                        manualPaymentId: paymentId,
                        paymentMethod: 'manual'
                    };
                    this.accessPasses.set(passId, pass);
                    console.log('[Manual Payment] Access pass created:', passId);
                }
            }

            res.json({ success: true, payment });
        });

        // Admin: Reject manual payment
        this.app.post('/api/payments/manual/reject/:paymentId', (req, res) => {
            const { paymentId } = req.params;
            const { reason } = req.body;
            const payment = this.pendingManualPayments?.get(paymentId);

            if (!payment) {
                return res.status(404).json({ error: 'Payment not found' });
            }

            payment.status = 'rejected';
            payment.rejectedAt = new Date();
            payment.rejectionReason = reason;

            res.json({ success: true, payment });
        });

        // ============================================
        // ESCORT ME FEATURE API
        // Guide users to another room together
        // ============================================

        // Active escort sessions
        this.escortSessions = new Map(); // escortId -> { leaderId, targetRoom, followers, status }

        // Start an escort session (room owner/admin)
        this.app.post('/api/escort/start', (req, res) => {
            const { leaderId, sourceRoomId, targetRoomId, leaderName } = req.body;

            // Verify leader is in the room
            const sourceRoom = this.rooms.get(sourceRoomId);
            if (!sourceRoom) {
                return res.status(404).json({ error: 'Source room not found' });
            }

            const leader = sourceRoom.users?.find(u => u.id === leaderId || u.socketId === leaderId);
            if (!leader) {
                return res.status(403).json({ error: 'Leader not in source room' });
            }

            // Create escort session
            const escortId = 'escort_' + uuidv4().slice(0, 8);
            const session = {
                id: escortId,
                leaderId,
                leaderName: leaderName || leader.name || 'Leader',
                sourceRoomId,
                targetRoomId,
                followers: [],
                status: 'active',
                createdAt: new Date(),
                expiresAt: new Date(Date.now() + 300000) // 5 minute expiry
            };

            this.escortSessions.set(escortId, session);

            // Notify room members
            this.io.to(sourceRoomId).emit('escort-started', {
                escortId,
                leaderName: session.leaderName,
                targetRoomId,
                message: `${session.leaderName} is leading everyone to another room. Click "Follow" to join!`
            });

            res.json({ success: true, escortId, session });
        });

        // Join an escort session (follow the leader)
        this.app.post('/api/escort/follow', (req, res) => {
            const { escortId, userId, userName } = req.body;

            const session = this.escortSessions.get(escortId);
            if (!session) {
                return res.status(404).json({ error: 'Escort session not found or expired' });
            }

            if (session.status !== 'active') {
                return res.status(400).json({ error: 'Escort session is no longer active' });
            }

            // Add to followers
            if (!session.followers.find(f => f.id === userId)) {
                session.followers.push({
                    id: userId,
                    name: userName || 'User',
                    joinedAt: new Date()
                });
            }

            res.json({
                success: true,
                targetRoomId: session.targetRoomId,
                followersCount: session.followers.length
            });
        });

        // Trigger the escort move (leader initiates the transition)
        this.app.post('/api/escort/move', (req, res) => {
            const { escortId, leaderId } = req.body;

            const session = this.escortSessions.get(escortId);
            if (!session) {
                return res.status(404).json({ error: 'Escort session not found' });
            }

            if (session.leaderId !== leaderId) {
                return res.status(403).json({ error: 'Only the leader can trigger the move' });
            }

            session.status = 'moving';

            // Notify all participants with whoosh sound trigger
            this.io.to(session.sourceRoomId).emit('escort-moving', {
                escortId,
                targetRoomId: session.targetRoomId,
                playSound: 'whoosh_leave', // Client plays leaving whoosh
                message: `Moving to ${session.targetRoomId}...`
            });

            // After brief delay, notify target room of incoming users
            setTimeout(() => {
                this.io.to(session.targetRoomId).emit('escort-arriving', {
                    escortId,
                    fromRoom: session.sourceRoomId,
                    leaderName: session.leaderName,
                    count: session.followers.length + 1, // +1 for leader
                    playSound: 'whoosh_arrive' // Client plays arrival whoosh
                });

                session.status = 'completed';
            }, 1500);

            res.json({
                success: true,
                followersCount: session.followers.length,
                targetRoomId: session.targetRoomId
            });
        });

        // Cancel escort session
        this.app.post('/api/escort/cancel', (req, res) => {
            const { escortId, leaderId } = req.body;

            const session = this.escortSessions.get(escortId);
            if (!session) {
                return res.status(404).json({ error: 'Escort session not found' });
            }

            if (session.leaderId !== leaderId) {
                return res.status(403).json({ error: 'Only the leader can cancel' });
            }

            session.status = 'cancelled';
            this.escortSessions.delete(escortId);

            // Notify room
            this.io.to(session.sourceRoomId).emit('escort-cancelled', {
                escortId,
                message: 'The escort session was cancelled'
            });

            res.json({ success: true });
        });

        // Get active escort in a room
        this.app.get('/api/escort/active/:roomId', (req, res) => {
            const roomId = req.params.roomId;
            let activeSession = null;

            this.escortSessions.forEach(session => {
                if (session.sourceRoomId === roomId && session.status === 'active') {
                    activeSession = {
                        escortId: session.id,
                        leaderName: session.leaderName,
                        targetRoomId: session.targetRoomId,
                        followersCount: session.followers.length,
                        expiresAt: session.expiresAt
                    };
                }
            });

            res.json({ active: !!activeSession, session: activeSession });
        });

        // Cleanup expired escort sessions periodically
        setInterval(() => {
            const now = Date.now();
            this.escortSessions.forEach((session, escortId) => {
                if (new Date(session.expiresAt).getTime() < now) {
                    this.escortSessions.delete(escortId);
                }
            });
        }, 60000); // Check every minute

        // ============================================
        // INSTALLATION WIZARD API
        // ============================================

        // Check if initial setup is needed
        this.app.get('/api/install/status', (req, res) => {
            const configPath = path.join(__dirname, '../../data/deploy.json');
            const isConfigured = fs.existsSync(configPath);

            let config = null;
            if (isConfigured) {
                try {
                    config = JSON.parse(fs.readFileSync(configPath, 'utf8'));
                } catch (e) {}
            }

            res.json({
                installed: isConfigured,
                configured: isConfigured && config?.server?.name,
                version: require('../../package.json').version,
                serverName: config?.server?.name || 'VoiceLink Server'
            });
        });

        // Check system requirements
        this.app.get('/api/install/requirements', async (req, res) => {
            const requirements = {
                node: { required: '18.0.0', current: process.version, ok: false },
                npm: { required: true, current: false, ok: false },
                writable: { required: true, current: false, ok: false },
                port: { required: true, current: false, ok: false }
            };

            // Check Node version
            const nodeVersion = process.version.replace('v', '');
            requirements.node.ok = this.compareVersions(nodeVersion, '18.0.0') >= 0;

            // Check npm
            try {
                const { execSync } = require('child_process');
                execSync('npm --version', { encoding: 'utf8' });
                requirements.npm.current = true;
                requirements.npm.ok = true;
            } catch (e) {}

            // Check writable data directory
            const dataDir = path.join(__dirname, '../../data');
            try {
                if (!fs.existsSync(dataDir)) {
                    fs.mkdirSync(dataDir, { recursive: true });
                }
                const testFile = path.join(dataDir, '.write-test');
                fs.writeFileSync(testFile, 'test');
                fs.unlinkSync(testFile);
                requirements.writable.current = true;
                requirements.writable.ok = true;
            } catch (e) {}

            // Check if port is available
            const port = parseInt(process.env.PORT) || 3010;
            requirements.port.current = port;
            requirements.port.ok = true; // If we're running, port is available

            const allPassed = Object.values(requirements).every(r => r.ok);

            res.json({
                success: allPassed,
                requirements
            });
        });

        // Save installation configuration
        this.app.post('/api/install/configure', (req, res) => {
            try {
                const {
                    serverName,
                    serverPort,
                    publicUrl,
                    adminPassword,
                    enableFederation,
                    enableMedia,
                    requireAuth
                } = req.body;

                // Validate required fields
                if (!serverName) {
                    return res.status(400).json({ success: false, error: 'Server name is required' });
                }

                const config = {
                    server: {
                        name: serverName,
                        port: parseInt(serverPort) || 3010,
                        publicUrl: publicUrl || null,
                        maxRooms: 100,
                        maxUsersPerRoom: 50,
                        defaultRoomDuration: 3600000
                    },
                    admin: {
                        passwordHash: adminPassword ? this.hashPassword(adminPassword) : null
                    },
                    federation: {
                        enabled: enableFederation || false,
                        mode: enableFederation ? 'spoke' : 'standalone',
                        hubUrl: enableFederation ? 'https://voicelink.devinecreations.net' : null
                    },
                    features: {
                        mediaStreaming: enableMedia || false,
                        jellyfin: enableMedia || false,
                        requireAuth: requireAuth || false
                    },
                    installedAt: new Date().toISOString(),
                    version: require('../../package.json').version
                };

                // Save configuration
                const configPath = path.join(__dirname, '../../data/deploy.json');
                const dataDir = path.dirname(configPath);

                if (!fs.existsSync(dataDir)) {
                    fs.mkdirSync(dataDir, { recursive: true });
                }

                fs.writeFileSync(configPath, JSON.stringify(config, null, 2));

                // Reload deploy config
                deployConfig.reload();

                res.json({
                    success: true,
                    message: 'Configuration saved successfully',
                    config: {
                        serverName: config.server.name,
                        publicUrl: config.server.publicUrl,
                        federation: config.federation.enabled
                    }
                });

            } catch (error) {
                console.error('[Install] Configuration error:', error);
                res.status(500).json({ success: false, error: error.message });
            }
        });

        // Complete installation
        this.app.post('/api/install/complete', (req, res) => {
            try {
                const configPath = path.join(__dirname, '../../data/deploy.json');

                if (!fs.existsSync(configPath)) {
                    return res.status(400).json({ success: false, error: 'Configuration not saved' });
                }

                const config = JSON.parse(fs.readFileSync(configPath, 'utf8'));
                config.installComplete = true;
                config.completedAt = new Date().toISOString();

                fs.writeFileSync(configPath, JSON.stringify(config, null, 2));

                res.json({
                    success: true,
                    message: 'Installation complete!',
                    redirectTo: '/client/index.html'
                });

            } catch (error) {
                res.status(500).json({ success: false, error: error.message });
            }
        });

        // Helper to hash admin password
        this.hashPassword = (password) => {
            const crypto = require('crypto');
            return crypto.createHash('sha256').update(password + 'voicelink-salt').digest('hex');
        };

        // Helper to compare versions
        this.compareVersions = (v1, v2) => {
            const parts1 = v1.split('.').map(Number);
            const parts2 = v2.split('.').map(Number);
            for (let i = 0; i < Math.max(parts1.length, parts2.length); i++) {
                const p1 = parts1[i] || 0;
                const p2 = parts2[i] || 0;
                if (p1 > p2) return 1;
                if (p1 < p2) return -1;
            }
            return 0;
        };
    }

    setupSocketHandlers() {
        this.io.on('connection', (socket) => {
            console.log(`User connected: ${socket.id}`);

            const serializeRooms = () => Array.from(this.rooms.values()).map((room) => ({
                id: room.id,
                roomId: room.id,
                name: room.name,
                description: room.description || '',
                userCount: room.users?.length || 0,
                users: room.users?.length || 0,
                isPrivate: !!room.isPrivate,
                maxUsers: room.maxUsers || 50,
                duration: room.duration || null,
                expiresAt: room.expiresAt || null
            }));

            const emitRoomList = () => {
                socket.emit('room-list', serializeRooms());
            };

            const broadcastRoomList = () => {
                const rooms = serializeRooms();
                this.io.emit('room-list', rooms);
                this.io.emit('room-list-updated', { rooms });
            };

            socket.on('get-rooms', () => {
                emitRoomList();
            });

            socket.on('create-room', (data = {}) => {
                const authUser = this.authenticatedUsers?.get(socket.id);
                const isAuthenticated = !!authUser;

                let duration = Number(data.duration);
                if (!Number.isFinite(duration) || duration <= 0) duration = null;

                // Guest limits: public rooms only, max 5 users, 10-30 minutes
                let isPrivate = !!data.isPrivate;
                let maxUsers = Number(data.maxUsers) || 50;
                if (!isAuthenticated) {
                    isPrivate = false;
                    maxUsers = Math.min(maxUsers, 5);
                    if (duration === null || duration > 1800000) duration = 1800000;
                    if (duration < 600000) duration = 600000;
                } else {
                    maxUsers = Math.min(maxUsers, 100);
                }

                const roomId = (data.roomId && String(data.roomId)) || uuidv4();
                const room = {
                    id: roomId,
                    name: data.name || `Room ${roomId.slice(0, 8)}`,
                    description: data.description || '',
                    isPrivate,
                    password: data.password || null,
                    users: [],
                    maxUsers,
                    duration,
                    createdAt: new Date(),
                    expiresAt: duration ? new Date(Date.now() + duration) : null
                };

                this.rooms.set(roomId, room);
                socket.emit('room-created', { roomId, room });
                broadcastRoomList();

                if (duration) {
                    setTimeout(() => {
                        const active = this.rooms.get(roomId);
                        if (!active) return;
                        if ((active.users?.length || 0) > 0) return;
                        this.rooms.delete(roomId);
                        this.io.emit('room-expired', { roomId });
                        broadcastRoomList();
                    }, duration);
                }
            });

            // User joins a room
            socket.on('join-room', (data = {}) => {
                const { roomId, userName, username, password, joinToken } = data;
                const room = this.rooms.get(roomId);

                if (!room) {
                    socket.emit('error', { message: 'Room not found' });
                    return;
                }

                if (room.password && room.password !== password) {
                    socket.emit('error', { message: 'Invalid password' });
                    return;
                }

                const existingInTarget = room.users.some(u => u.id === socket.id);
                if (!existingInTarget && room.users.length >= room.maxUsers) {
                    socket.emit('error', { message: 'Room is full' });
                    return;
                }

                // Clean stale membership for this socket before rejoining/switching rooms
                const existingUser = this.users.get(socket.id);
                if (existingUser?.roomId && existingUser.roomId !== roomId) {
                    const previousRoom = this.rooms.get(existingUser.roomId);
                    if (previousRoom) {
                        previousRoom.users = previousRoom.users.filter(u => u.id !== socket.id);
                        socket.to(existingUser.roomId).emit('user-left', { userId: socket.id });
                    }
                    socket.leave(existingUser.roomId);
                }

                // Check if user is authenticated (Mastodon/email/API session) or guest
                const authUser = this.authenticatedUsers.get(socket.id);
                let apiJoinIdentity = null;
                if (joinToken && this.joinTokens.has(joinToken)) {
                    const tokenData = this.joinTokens.get(joinToken);
                    if (new Date() <= new Date(tokenData.expiresAt)) {
                        apiJoinIdentity = tokenData;
                        this.joinTokens.delete(joinToken);
                    } else {
                        this.joinTokens.delete(joinToken);
                    }
                }
                const isAuthenticated = !!authUser || !!apiJoinIdentity;
                const roleContext = apiJoinIdentity?.roleContext || (authUser ? RoleMapper.normalizeIdentity({
                    provider: 'mastodon',
                    roles: authUser.roles || [],
                    groups: authUser.groups || [],
                    userName: authUser.userName || authUser.name || authUser.username || '',
                    userId: authUser.userId || '',
                    email: authUser.email || authUser.userEmail || '',
                    isAuthenticated: true,
                    isAdmin: Boolean(authUser.isAdmin)
                }) : RoleMapper.normalizeIdentity({ isAuthenticated: false }));

                // Add user to room
                const user = {
                    id: socket.id,
                    name: username || userName || `User ${socket.id.slice(0, 8)}`,
                    joinedAt: new Date(),
                    isAuthenticated: isAuthenticated,
                    authInfo: authUser || apiJoinIdentity || null,
                    roleContext,
                    audioSettings: {
                        muted: false,
                        volume: 1.0,
                        spatialPosition: { x: 0, y: 0, z: 0 },
                        outputDevice: 'default'
                    }
                };

                room.users = room.users.filter(u => u.id !== socket.id);
                room.users.push(user);
                this.users.set(socket.id, { ...user, roomId });

                socket.join(roomId);
                socket.emit('joined-room', { room, user });
                socket.to(roomId).emit('user-joined', user);

                console.log(`User ${user.name} joined room ${room.name}`);
            });

            socket.on('leave-room', () => {
                const user = this.users.get(socket.id);
                if (!user?.roomId) return;

                const room = this.rooms.get(user.roomId);
                if (room) {
                    room.users = room.users.filter(u => u.id !== socket.id);
                    socket.to(user.roomId).emit('user-left', { userId: socket.id });

                    if (room.users.length === 0) {
                        this.rooms.delete(user.roomId);
                        console.log(`Room ${room.name} deleted (empty)`);
                    }
                }

                socket.leave(user.roomId);
                this.users.delete(socket.id);
                this.audioRouting.delete(socket.id);
                broadcastRoomList();
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
                        roomId: user.roomId,
                        message: data.message,
                        timestamp: new Date(),
                        isAuthenticated: user.isAuthenticated || false,
                        replyTo: data.replyTo || null,
                        reactions: []
                    };

                    // Store message in room history
                    this.storeRoomMessage(user.roomId, message);

                    this.io.to(user.roomId).emit('chat-message', message);
                }
            });

            // Direct messages (DMs)
            socket.on('direct-message', (data) => {
                const user = this.users.get(socket.id);
                const { targetUserId, message: msgContent, replyTo } = data;

                if (user && targetUserId) {
                    const message = {
                        id: uuidv4(),
                        senderId: socket.id,
                        senderName: user.name,
                        receiverId: targetUserId,
                        message: msgContent,
                        timestamp: new Date(),
                        isAuthenticated: user.isAuthenticated || false,
                        replyTo: replyTo || null,
                        reactions: [],
                        read: false
                    };

                    // Store DM
                    this.storeDirectMessage(socket.id, targetUserId, message);

                    // Send to both sender and receiver
                    socket.emit('direct-message', message);
                    this.io.to(targetUserId).emit('direct-message', message);
                }
            });

            // Message reactions
            socket.on('message-reaction', (data) => {
                const { messageId, roomId, reaction, targetUserId } = data;
                const user = this.users.get(socket.id);

                if (user) {
                    const reactionData = {
                        messageId,
                        userId: socket.id,
                        userName: user.name,
                        reaction,
                        timestamp: new Date()
                    };

                    if (targetUserId) {
                        // DM reaction
                        this.addReactionToDirectMessage(socket.id, targetUserId, messageId, reactionData);
                        socket.emit('message-reaction', reactionData);
                        this.io.to(targetUserId).emit('message-reaction', reactionData);
                    } else if (roomId) {
                        // Room message reaction
                        this.addReactionToRoomMessage(roomId, messageId, reactionData);
                        this.io.to(roomId).emit('message-reaction', reactionData);
                    }
                }
            });

            // Fetch message history
            socket.on('get-room-messages', (data) => {
                const { roomId, limit = 50, before } = data;
                const messages = this.getRoomMessages(roomId, limit, before);
                socket.emit('room-messages', { roomId, messages });
            });

            socket.on('get-direct-messages', (data) => {
                const { targetUserId, limit = 50, before } = data;
                const messages = this.getDirectMessages(socket.id, targetUserId, limit, before);
                socket.emit('direct-messages', { targetUserId, messages });
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
                    broadcastRoomList();
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

    // ==================== Message Persistence Methods ====================

    /**
     * Store a room message
     * Messages from authenticated users persist forever
     * Messages from guests expire after 24 hours
     */
    storeRoomMessage(roomId, message) {
        if (!this.roomMessages.has(roomId)) {
            this.roomMessages.set(roomId, []);
        }

        const messages = this.roomMessages.get(roomId);
        messages.push(message);

        // Keep max 1000 messages per room in memory
        if (messages.length > 1000) {
            // Remove oldest messages, but prioritize keeping authenticated user messages
            const authenticated = messages.filter(m => m.isAuthenticated);
            const guest = messages.filter(m => !m.isAuthenticated);

            // Remove oldest guest messages first
            while (messages.length > 1000 && guest.length > 0) {
                const oldest = guest.shift();
                const idx = messages.findIndex(m => m.id === oldest.id);
                if (idx !== -1) messages.splice(idx, 1);
            }
        }
    }

    /**
     * Store a direct message
     * Uses sorted user IDs as key for consistent lookup
     */
    storeDirectMessage(senderId, receiverId, message) {
        const dmKey = [senderId, receiverId].sort().join('_');

        if (!this.directMessages.has(dmKey)) {
            this.directMessages.set(dmKey, []);
        }

        const messages = this.directMessages.get(dmKey);
        messages.push(message);

        // Keep max 500 messages per DM conversation
        if (messages.length > 500) {
            messages.shift();
        }
    }

    /**
     * Get room messages with optional pagination
     */
    getRoomMessages(roomId, limit = 50, before = null) {
        const messages = this.roomMessages.get(roomId) || [];

        let filtered = messages;
        if (before) {
            const beforeIdx = messages.findIndex(m => m.id === before);
            if (beforeIdx > 0) {
                filtered = messages.slice(0, beforeIdx);
            }
        }

        // Return most recent messages
        return filtered.slice(-limit);
    }

    /**
     * Get direct messages between two users
     */
    getDirectMessages(userId1, userId2, limit = 50, before = null) {
        const dmKey = [userId1, userId2].sort().join('_');
        const messages = this.directMessages.get(dmKey) || [];

        let filtered = messages;
        if (before) {
            const beforeIdx = messages.findIndex(m => m.id === before);
            if (beforeIdx > 0) {
                filtered = messages.slice(0, beforeIdx);
            }
        }

        return filtered.slice(-limit);
    }

    /**
     * Add reaction to a room message
     */
    addReactionToRoomMessage(roomId, messageId, reaction) {
        const messages = this.roomMessages.get(roomId);
        if (messages) {
            const message = messages.find(m => m.id === messageId);
            if (message) {
                if (!message.reactions) message.reactions = [];
                // Remove existing reaction from same user
                message.reactions = message.reactions.filter(r => r.userId !== reaction.userId);
                message.reactions.push(reaction);
            }
        }
    }

    /**
     * Add reaction to a direct message
     */
    addReactionToDirectMessage(userId1, userId2, messageId, reaction) {
        const dmKey = [userId1, userId2].sort().join('_');
        const messages = this.directMessages.get(dmKey);
        if (messages) {
            const message = messages.find(m => m.id === messageId);
            if (message) {
                if (!message.reactions) message.reactions = [];
                message.reactions = message.reactions.filter(r => r.userId !== reaction.userId);
                message.reactions.push(reaction);
            }
        }
    }

    /**
     * Start cleanup interval for guest messages
     * Runs every hour to remove guest messages older than 24 hours
     */
    startGuestMessageCleanup() {
        setInterval(() => {
            this.cleanupGuestMessages();
        }, 60 * 60 * 1000); // Every hour

        console.log('[Messages] Guest message cleanup scheduled (24h expiry)');
    }

    /**
     * Remove guest messages older than 24 hours
     */
    cleanupGuestMessages() {
        const now = Date.now();
        let removedCount = 0;

        // Clean room messages
        for (const [roomId, messages] of this.roomMessages.entries()) {
            const originalLength = messages.length;
            const filtered = messages.filter(msg => {
                // Keep authenticated user messages forever
                if (msg.isAuthenticated) return true;
                // Remove guest messages older than 24 hours
                const msgTime = new Date(msg.timestamp).getTime();
                return (now - msgTime) < this.GUEST_MESSAGE_EXPIRY;
            });

            if (filtered.length !== originalLength) {
                removedCount += originalLength - filtered.length;
                this.roomMessages.set(roomId, filtered);
            }
        }

        // Clean direct messages
        for (const [dmKey, messages] of this.directMessages.entries()) {
            const originalLength = messages.length;
            const filtered = messages.filter(msg => {
                if (msg.isAuthenticated) return true;
                const msgTime = new Date(msg.timestamp).getTime();
                return (now - msgTime) < this.GUEST_MESSAGE_EXPIRY;
            });

            if (filtered.length !== originalLength) {
                removedCount += originalLength - filtered.length;
                this.directMessages.set(dmKey, filtered);
            }
        }

        if (removedCount > 0) {
            console.log(`[Messages] Cleaned up ${removedCount} expired guest messages`);
        }
    }

    /**
     * Setup Jellyfin service management with default processes
     */
    setupJellyfinManagement() {
        console.log('[JellyfinService] Setting up Jellyfin service management...');

        // Register known Jellyfin processes based on discovered configurations
        const defaultProcesses = {
            'jellyfin-tappedin': {
                user: 'tappedin',
                command: '/home/tappedin/apps/jellyfin/jellyfin/jellyfin --datadir /home/tappedin/apps/jellyfin/config --cachedir /home/tappedin/apps/jellyfin/cache --webdir /home/tappedin/apps/jellyfin/jellyfin/jellyfin-web --published-server-url http://127.0.0.1:9096 --service --nowebclient=false',
                port: 9096,
                workingDirectory: '/home/tappedin/apps/jellyfin'
            },
            'jellyfin-dom': {
                user: 'dom',
                command: '/home/dom/apps/jellyfin/jellyfin/jellyfin --datadir /home/dom/apps/jellyfin/config --cachedir /home/dom/apps/jellyfin/cache --webdir /home/dom/apps/jellyfin/jellyfin/jellyfin-web --published-server-url http://127.0.0.1:9097 --service --nowebclient=false',
                port: 9097,
                workingDirectory: '/home/dom/apps/jellyfin'
            },
            'jellyfin-devinecr': {
                user: 'devinecr',
                command: '/home/devinecr/apps/jellyfin/jellyfin/jellyfin --datadir /home/devinecr/apps/jellyfin/config --cachedir /home/devinecr/apps/jellyfin/cache --webdir /home/devinecr/apps/jellyfin/jellyfin/jellyfin-web --published-server-url http://127.0.0.1:8096 --service --nowebclient=false',
                port: 8096,
                workingDirectory: '/home/devinecr/apps/jellyfin'
            }
        };

        // Register default processes
        Object.entries(defaultProcesses).forEach(([name, config]) => {
            this.jellyfinManager.registerProcess(name, config);
        });

        // Set up event listeners for Jellyfin manager
        this.jellyfinManager.on('processStarted', (name, pid) => {
            console.log(`[JellyfinService] Process ${name} started (PID: ${pid})`);
            this.io.emit('jellyfinProcessStarted', { name, pid });
        });

        this.jellyfinManager.on('processStopped', (name) => {
            console.log(`[JellyfinService] Process ${name} stopped`);
            this.io.emit('jellyfinProcessStopped', { name });
        });

        this.jellyfinManager.on('processAutoRestarted', (name) => {
            console.log(`[JellyfinService] Process ${name} was automatically restarted`);
            this.io.emit('jellyfinProcessAutoRestarted', { name });
        });

        this.jellyfinManager.on('processRestartFailed', (name) => {
            console.warn(`[JellyfinService] Failed to restart process ${name}`);
            this.io.emit('jellyfinProcessRestartFailed', { name });
        });

        console.log('[JellyfinService] Jellyfin service management configured');
    }

    start() {
        const PORT = process.env.PORT || 3010;
        this.server.listen(PORT, () => {
            console.log(`VoiceLink Local Server running on http://localhost:${PORT}`);
            console.log('Ready for P2P and server relay voice chat!');
            console.log('Connection modes: p2p (direct), relay (server), auto (fallback)');
        });
    }
}

// Start the server
new VoiceLinkLocalServer();

module.exports = VoiceLinkLocalServer;
