const express = require('express');
const http = require('http');
const https = require('https');
const socketIo = require('socket.io');
const path = require('path');
const cors = require('cors');
const fs = require('fs');
const crypto = require('crypto');
const net = require('net');
const { execFile } = require('child_process');
const { promisify } = require('util');
const { v4: uuidv4 } = require('uuid');
const nodemailer = require('nodemailer');
const { DatabaseStorageManager } = require('../services/database-storage');
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
const { DeploymentManagerModule } = require('../modules/deployment-manager');
let InternalScheduler = null;
try {
    ({ InternalScheduler } = require('../modules/internal-scheduler'));
} catch (error) {
    // Optional module: keep server running if scheduler module is not bundled.
    InternalScheduler = null;
}
const JellyfinServiceManager = require('../utils/jellyfin-service-manager');
const JellyfinAutoManager = require("../utils/jellyfin-auto-manager");
const FederatedJellyfinManager = require('../utils/federated-jellyfin-manager');
const fileTransferRoutes = require("./file-transfer");
const execFileAsync = promisify(execFile);
const databaseStorage = new DatabaseStorageManager({ deployConfig, appRoot: path.join(__dirname, '../..') });
try {
    if (databaseStorage.sqliteAvailable()) {
        databaseStorage.ensureSchema();
        databaseStorage.migrateDefaults();
    }
} catch (databaseBootstrapError) {
    console.warn('[Database] Bootstrap mirror skipped:', databaseBootstrapError.message);
}

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
        this.cachedMainServerRooms = [];
        this.cachedMainServerRoomsFetchedAt = 0;
        this.mainServerRoomFetchPromise = null;
        this.whmcsAuthSessions = new Map(); // token -> { user, expiresAt }
        this.activeSessionsByUser = new Map(); // userId -> Map(socketId -> sessionInfo)
        this.socketSessions = new Map(); // socketId -> sessionInfo
        this.deviceSessions = new Map(); // deviceId -> socketId

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

        // Initialize Federated Jellyfin Manager for multi-node support
        this.federatedJellyfin = new FederatedJellyfinManager({
            config: deployConfig.get("jellyfin")?.federated || {},
            dataDir: path.join(__dirname, "../../data")
        });

        // Initialize Jellyfin Auto-Manager
        this.jellyfinAutoManager = new JellyfinAutoManager(this.federatedJellyfin);
        this.jellyfinAutoManager.startAutoConnect();

        // Authenticated users (Mastodon OAuth)
        this.authenticatedUsers = new Map(); // socketId -> mastodon user info

        // Message persistence storage
        // Key: roomId, Value: array of messages
        this.roomMessages = new Map();
        // Key: `${senderId}_${receiverId}` (sorted), Value: array of DMs
        this.directMessages = new Map();
        this.botConversationState = new Map();
        this.botResponseMemory = new Map();
        this.botOllamaHealth = { checkedAt: 0, available: null };
        this.directMessageVisibility = new Map();
        this.directMessagePurgeRequests = new Map();
        this.clientAssetSyncNotifications = new Map();
        this.serverStartedAt = Date.now();
        this.restartNoticeSentAtByRoom = new Map();
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
            deploymentManager: null
        };
        this.internalSchedulerSyncPromise = null;
        this.initializeMailer();
        this.initializeModules().catch((error) => {
            console.error('[Modules] Initialization failed:', error.message);
        });

        this.setupMiddleware();
        this.setupRoutes();
        this.setupSocketHandlers();
        this.loadPersistedRooms();
        this.start();
    }

    initializeMailer() {
        const smtpHost = process.env.VOICELINK_SMTP_HOST || process.env.SMTP_HOST || '';
        const smtpPort = Number(process.env.VOICELINK_SMTP_PORT || process.env.SMTP_PORT || 587);
        const smtpUser = process.env.VOICELINK_SMTP_USER || process.env.SMTP_USER || '';
        const smtpPass = process.env.VOICELINK_SMTP_PASS || process.env.SMTP_PASS || '';
        const smtpSecureRaw = process.env.VOICELINK_SMTP_SECURE || process.env.SMTP_SECURE || '';
        const useInternalSmtp = String(process.env.VOICELINK_SMTP_INTERNAL || '').toLowerCase() === 'true';
        const smtpSecure = smtpSecureRaw
            ? String(smtpSecureRaw).toLowerCase() === 'true'
            : smtpPort === 465;

        this.emailFrom = process.env.VOICELINK_EMAIL_FROM || process.env.EMAIL_FROM || 'services@devine-creations.com';
        this.mailer = null;

        const host = smtpHost || (useInternalSmtp ? '127.0.0.1' : '');
        if (!host) {
            console.log('[Mail] SMTP not configured; email sending disabled');
            return;
        }

        const transportConfig = {
            host,
            port: smtpPort,
            secure: smtpSecure
        };

        if (smtpUser && smtpPass) {
            transportConfig.auth = { user: smtpUser, pass: smtpPass };
        }

        if (String(process.env.VOICELINK_SMTP_REQUIRE_TLS || '').toLowerCase() === 'false') {
            transportConfig.requireTLS = false;
            transportConfig.tls = { rejectUnauthorized: false };
        }

        try {
            this.mailer = nodemailer.createTransport(transportConfig);
            this.mailer.verify()
                .then(() => console.log(`[Mail] SMTP ready via ${host}:${smtpPort} as ${smtpUser || 'unauthenticated sender'}`))
                .catch((error) => console.warn('[Mail] SMTP verify failed:', error.message));
        } catch (error) {
            console.warn('[Mail] SMTP init failed:', error.message);
            this.mailer = null;
        }
    }

    getWhmcsConfig() {
        const moduleConfig = this.moduleRegistry?.getModule('whmcs-integration')?.config || {};
        const deployWhmcs = deployConfig.get('whmcs') || {};
        return {
            apiUrl: moduleConfig.apiUrl || deployWhmcs.apiUrl || process.env.WHMCS_API_URL || 'https://devine-creations.com/includes/api.php',
            identifier: moduleConfig.identifier || process.env.WHMCS_API_IDENTIFIER,
            secret: moduleConfig.secret || process.env.WHMCS_API_SECRET,
            accessKey: moduleConfig.accessKey || process.env.WHMCS_ACCESS_KEY,
            portalUrl: moduleConfig.portalUrl || deployWhmcs.portalUrl || process.env.WHMCS_PORTAL_URL || 'https://devine-creations.com/clientarea.php'
        };
    }

    normalizePortalSite(portalSite) {
        const raw = String(portalSite || '').trim().toLowerCase();
        if (!raw) return 'devine-creations.com';
        const withoutProtocol = raw.replace(/^https?:\/\//, '');
        const host = withoutProtocol.split('/')[0];
        if (!host) return 'devine-creations.com';
        const normalizedHost = host.replace(/\.+$/, '');
        const allowedHosts = new Set([
            'devine-creations.com',
            'www.devine-creations.com',
            'devinecreations.net',
            'www.devinecreations.net',
            'tappedin.fm',
            'www.tappedin.fm',
            'ecripto.app',
            'www.ecripto.app',
            'ecripto.token',
            'www.ecripto.token'
        ]);
        if (allowedHosts.has(normalizedHost)) return normalizedHost;
        if (/^[a-z0-9.-]+\.[a-z]{2,}$/i.test(normalizedHost)) return normalizedHost;
        return 'devine-creations.com';
    }

    getPortalUrlForSite(portalSite) {
        const host = this.normalizePortalSite(portalSite);
        if (host === 'devinecreations.net' || host === 'www.devinecreations.net') {
            return 'https://devinecreations.net/';
        }
        return `https://${host}/clientarea.php`;
    }

    getWhmcsAuthorityConfig() {
        const explicitBaseUrl = process.env.VOICELINK_WHMCS_AUTHORITY_URL
            || process.env.VOICELINK_AUTHORITY_URL
            || process.env.VOICELINK_MAIN_API_URL
            || MAIN_SERVER_URL;
        const baseUrl = String(explicitBaseUrl || '').trim().replace(/\/+$/, '');
        const mode = String(process.env.VOICELINK_WHMCS_AUTH_MODE || '').trim().toLowerCase();
        const sharedSecret = process.env.VOICELINK_AUTH_SHARED_SECRET || process.env.VOICELINK_AUTHORITY_SHARED_SECRET || '';
        return {
            baseUrl,
            mode,
            sharedSecret,
            enabled: Boolean(baseUrl),
            forceDelegate: mode === 'delegate' || mode === 'remote' || mode === 'authority'
        };
    }

    shouldDelegateWhmcsAuth() {
        const authority = this.getWhmcsAuthorityConfig();
        if (!authority.enabled) return false;
        if (authority.forceDelegate) return true;
        const adminBridge = this.getWhmcsAdminBridgeConfig();
        if (adminBridge.enabled && adminBridge.configPath) {
            return false;
        }
        const config = this.getWhmcsConfig();
        return !(config.identifier && config.secret);
    }

    async requestWhmcsAuthority(pathname, payload = {}, options = {}) {
        const authority = this.getWhmcsAuthorityConfig();
        if (!authority.enabled) {
            throw new Error('Central auth authority is not configured');
        }

        const url = `${authority.baseUrl}${pathname.startsWith('/') ? pathname : `/${pathname}`}`;
        const headers = {
            'Content-Type': 'application/json',
            'Accept': 'application/json',
            ...(options.headers || {})
        };
        if (authority.sharedSecret) {
            headers['x-voicelink-shared-secret'] = authority.sharedSecret;
        }

        const response = await fetch(url, {
            method: options.method || 'POST',
            headers,
            body: payload === null ? undefined : JSON.stringify(payload)
        });

        const data = await response.json().catch(() => ({}));
        if (!response.ok) {
            const message = data?.error || data?.message || `Authority request failed (${response.status})`;
            const error = new Error(message);
            error.status = response.status;
            error.payload = data;
            throw error;
        }
        return data;
    }

    applyAuthorityRoleOverrides(user = {}) {
        const adminEmails = new Set([
            ...(deployConfig.get('admin')?.adminEmails || []),
            ...String(process.env.VOICELINK_CENTRAL_ADMIN_EMAILS || '')
                .split(',')
                .map((value) => value.trim().toLowerCase())
                .filter(Boolean)
        ]);
        const moderatorEmails = new Set(
            String(process.env.VOICELINK_CENTRAL_MODERATOR_EMAILS || '')
                .split(',')
                .map((value) => value.trim().toLowerCase())
                .filter(Boolean)
        );
        const hostingRoleNames = [
            ...(Array.isArray(user.hostingRoles) ? user.hostingRoles : []),
            ...(Array.isArray(user.controlPanelRoles) ? user.controlPanelRoles : []),
            ...(Array.isArray(user.panelRoles) ? user.panelRoles : [])
        ].map((value) => String(value || '').trim().toLowerCase()).filter(Boolean);
        const hostingPermissions = new Set([
            ...(Array.isArray(user.hostingPermissions) ? user.hostingPermissions : []),
            ...(Array.isArray(user.controlPanelPermissions) ? user.controlPanelPermissions : []),
            ...(Array.isArray(user.panelPermissions) ? user.panelPermissions : [])
        ].map((value) => String(value || '').trim().toLowerCase()).filter(Boolean));
        const hasHostingOwnerRole = hostingRoleNames.some((value) => ['owner', 'server_owner', 'account_owner', 'reseller', 'root', 'administrator', 'admin'].includes(value));
        const hasHostingManagerRole = hostingRoleNames.some((value) => ['manager', 'operator', 'support', 'staff', 'moderator', 'site_owner', 'hosting_admin'].includes(value));
        const hasHostingAdminPermission = ['admin', 'owner', 'server.manage', 'server.admin', 'hosting.admin', 'hosting.owner', 'license.manage', 'install.manage'].some((permission) => hostingPermissions.has(permission));
        const hasHostingStaffPermission = ['support', 'staff', 'moderate', 'server.support', 'hosting.support', 'install.support'].some((permission) => hostingPermissions.has(permission));

        const email = String(user.email || '').trim().toLowerCase();
        const currentRole = this.normalizeUserRole(user.role);
        if (hasHostingOwnerRole || hasHostingAdminPermission) {
            user.role = currentRole === 'owner' ? 'owner' : 'admin';
            user.permissions = Array.from(new Set([...(user.permissions || []), ...this.buildPermissionsForRole(user.role), ...hostingPermissions]));
            user.isAdmin = true;
            user.isModerator = true;
        } else if (hasHostingManagerRole || hasHostingStaffPermission) {
            user.role = currentRole === 'owner' || currentRole === 'admin' ? currentRole : 'staff';
            user.permissions = Array.from(new Set([...(user.permissions || []), ...this.buildPermissionsForRole(user.role), ...hostingPermissions]));
            user.isModerator = true;
        }

        if (email && adminEmails.has(email)) {
            user.role = 'admin';
            user.permissions = Array.from(new Set([...(user.permissions || []), 'admin', 'staff', 'client']));
            user.isAdmin = true;
            user.isModerator = true;
        } else if (email && moderatorEmails.has(email)) {
            user.role = user.role === 'admin' ? 'admin' : 'staff';
            user.permissions = Array.from(new Set([...(user.permissions || []), 'staff', 'client']));
            user.isModerator = true;
        }

        const username = String(user.username || '').trim().toLowerCase();
        const localOverrideUser = Array.from(this.localAuthUsers?.values?.() || []).find((entry) => {
            const entryEmail = String(entry?.email || '').trim().toLowerCase();
            const entryUsername = String(entry?.username || '').trim().toLowerCase();
            return (!!email && entryEmail === email) || (!!username && entryUsername === username);
        });
        if (localOverrideUser) {
            const localRole = this.normalizeUserRole(localOverrideUser.role);
            if (this.roleRank(localRole) >= this.roleRank(user.role)) {
                user.role = localRole;
                user.permissions = Array.from(new Set([
                    ...(user.permissions || []),
                    ...this.buildPermissionsForRole(localRole),
                    ...(Array.isArray(localOverrideUser.permissions) ? localOverrideUser.permissions : [])
                ]));
                user.isAdmin = localRole === 'owner' || localRole === 'admin';
                user.isModerator = user.isAdmin || localRole === 'staff';
            }
        }

        return user;
    }

    async createDelegatedWhmcsSession(payload = {}) {
        const delegated = await this.requestWhmcsAuthority('/api/auth/whmcs/login', payload);
        if (!delegated?.user) {
            throw new Error('Central auth authority did not return a user');
        }

        const upstreamUser = delegated.user;
        const user = this.applyAuthorityRoleOverrides({
            ...upstreamUser,
            portalSite: this.normalizePortalSite(payload.portalSite || upstreamUser.portalSite),
            authProvider: upstreamUser.authProvider || 'whmcs'
        });

        const localSession = this.createAuthSession(
            this.whmcsAuthSessions,
            'whmcs',
            user,
            payload.remember === true
        );
        const localRecord = this.whmcsAuthSessions.get(localSession.token);
        if (localRecord) {
            localRecord.upstreamToken = delegated.token || null;
            localRecord.authorityBaseUrl = this.getWhmcsAuthorityConfig().baseUrl;
        }

        return {
            success: true,
            token: localSession.token,
            expiresAt: localSession.expiresAt,
            portalUrl: delegated.portalUrl || this.getPortalUrlForSite(user.portalSite),
            delegated: true,
            user
        };
    }

    async whmcsRequest(action, params = {}) {
        const config = this.getWhmcsConfig();
        if (!config.identifier || !config.secret) {
            throw new Error('WHMCS API credentials not configured');
        }

        const body = new URLSearchParams({
            identifier: config.identifier,
            secret: config.secret,
            action,
            responsetype: 'json',
            ...params
        });

        if (config.accessKey) {
            body.append('accesskey', config.accessKey);
        }

        const response = await fetch(config.apiUrl, {
            method: 'POST',
            headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
            body: body.toString()
        });

        const result = await response.json();
        if (result.result !== 'success') {
            const message = result.message || result.error || 'WHMCS request failed';
            throw new Error(message);
        }
        return result;
    }

    deriveWhmcsRole(client, services = []) {
        const roleConfig = deployConfig.get('whmcs')?.roles || {};
        const adminGroups = new Set(roleConfig.adminGroups || []);
        const staffGroups = new Set(roleConfig.staffGroups || []);
        const adminAddons = (roleConfig.adminAddons || []).map((addon) => addon.toLowerCase());
        const staffAddons = (roleConfig.staffAddons || []).map((addon) => addon.toLowerCase());

        const groupId = client?.groupid ? Number(client.groupid) : null;
        const groupName = (client?.groupname || '').toLowerCase();

        let role = 'user';
        if (groupId && adminGroups.has(groupId)) role = 'admin';
        else if (groupId && staffGroups.has(groupId)) role = 'staff';
        else if (groupName.includes('owner')) role = 'owner';
        else if (groupName.includes('admin')) role = 'admin';
        else if (groupName.includes('moderator') || groupName.includes('staff') || groupName.includes('support')) role = 'staff';
        else if (groupName.includes('member') || groupName.includes('client') || groupName.includes('customer')) role = 'user';

        const addonNames = [];
        services.forEach((service) => {
            if (Array.isArray(service.addons)) {
                service.addons.forEach((addon) => {
                    if (addon?.name) addonNames.push(addon.name.toLowerCase());
                });
            }
        });

        if (adminAddons.length && addonNames.some((name) => adminAddons.includes(name))) {
            role = 'admin';
        } else if (staffAddons.length && addonNames.some((name) => staffAddons.includes(name))) {
            role = role === 'admin' ? 'admin' : 'staff';
        }

        role = this.normalizeUserRole(role);
        const permissions = this.buildPermissionsForRole(role);

        return { role, permissions };
    }

    normalizeWhmcsOptionValue(value) {
        if (value === null || value === undefined) return null;
        if (typeof value === 'boolean') return value;
        if (typeof value === 'number') return value;
        const text = String(value).trim();
        if (!text) return null;
        const lower = text.toLowerCase();
        if (['yes', 'true', 'on', 'enabled', 'allow', 'allowed'].includes(lower)) return true;
        if (['no', 'false', 'off', 'disabled', 'deny', 'denied'].includes(lower)) return false;
        if (!Number.isNaN(Number(text))) return Number(text);
        return text;
    }

    normalizeUserRole(role) {
        const value = String(role || '').trim().toLowerCase();
        if (['owner', 'server_owner'].includes(value)) return 'owner';
        if (['admin', 'administrator', 'server_admin'].includes(value)) return 'admin';
        if (['moderator', 'mod', 'staff', 'support', 'manager', 'room_admin', 'room_moderator'].includes(value)) return 'staff';
        if (['member', 'client', 'customer', 'subscriber', 'user'].includes(value)) return 'user';
        return value || 'user';
    }

    buildPermissionsForRole(role) {
        const normalizedRole = this.normalizeUserRole(role);
        if (normalizedRole === 'owner') return ['owner', 'admin', 'staff', 'client'];
        if (normalizedRole === 'admin') return ['admin', 'staff', 'client'];
        if (normalizedRole === 'staff') return ['staff', 'client'];
        return ['client'];
    }

    roleRank(role) {
        const normalizedRole = this.normalizeUserRole(role);
        if (normalizedRole === 'owner') return 3;
        if (normalizedRole === 'admin') return 2;
        if (normalizedRole === 'staff') return 1;
        return 0;
    }

    clientFacingRole(role) {
        const normalizedRole = this.normalizeUserRole(role);
        return normalizedRole === 'staff' ? 'moderator' : normalizedRole;
    }

    extractServiceOptions(services = []) {
        const options = {};
        services.forEach((service) => {
            const collect = (entry) => {
                if (!entry) return;
                if (Array.isArray(entry)) {
                    entry.forEach((item) => {
                        const name = item?.name || item?.optionname;
                        const value = item?.value ?? item?.optionvalue ?? item?.qty ?? item?.optionid;
                        if (name) options[name] = this.normalizeWhmcsOptionValue(value);
                    });
                } else if (typeof entry === 'object') {
                    Object.keys(entry).forEach((key) => {
                        options[key] = this.normalizeWhmcsOptionValue(entry[key]);
                    });
                }
            };
            collect(service.configoptions);
            collect(service.customfields);
            collect(service.configurableoptions);
        });
        return options;
    }

    deriveWhmcsEntitlements(client, services = []) {
        const defaults = deployConfig.get('whmcs')?.entitlements || {};
        const optionMap = this.extractServiceOptions(services);
        const ownedDomains = Array.from(new Set(
            services
                .flatMap((service) => ([
                    service?.domain,
                    service?.customfields?.domain,
                    service?.customfields?.subdomain
                ]))
                .filter(Boolean)
                .map((value) => String(value).trim().toLowerCase())
                .filter(Boolean)
        ));
        const catalogText = services
            .flatMap((service) => ([
                service?.name,
                service?.productname,
                service?.groupname,
                service?.domain,
                service?.billingcycle
            ]))
            .filter(Boolean)
            .map((value) => String(value).toLowerCase());
        const joinedCatalog = catalogText.join(' | ');
        const hasHostingProduct = /(virtual private server|vps|self-host|self hosting|hosting|control panel|cpanel|web server|server)/.test(joinedCatalog);
        const hasServerOwnerProduct = /(virtual private server|vps|self-host|self hosting|web server|server)/.test(joinedCatalog);
        const inferredTier = /(enterprise|lifetime|yearly|annual)/.test(joinedCatalog)
            ? 'owner'
            : /(pro|business|starter|basic|standard|monthly|quarterly|weekly|free)/.test(joinedCatalog)
                ? 'member'
                : null;

        const readOption = (...keys) => {
            for (const key of keys) {
                if (Object.prototype.hasOwnProperty.call(optionMap, key)) {
                    return optionMap[key];
                }
            }
            return null;
        };

        const deviceTier = readOption('Device Tier', 'VoiceLink Device Tier', 'Device tier', 'DeviceTier')
            || defaults.deviceTier
            || 'standard';

        const maxDevicesRaw = readOption('Max Devices', 'Device Slots', 'VoiceLink Max Devices', 'MaxDeviceSlots');
        const maxDevices = Number.isFinite(maxDevicesRaw) ? Number(maxDevicesRaw) : (defaults.maxDevices ?? null);
        const installSlotsRaw = readOption('Install Slots', 'VoiceLink Install Slots', 'Max Installs', 'InstallSlots');
        const installSlots = Number.isFinite(installSlotsRaw) ? Number(installSlotsRaw) : (defaults.installSlots ?? 1);
        const serverSlotsRaw = readOption('Server Slots', 'VoiceLink Server Slots', 'Max Servers', 'ServerSlots');
        const serverSlots = Number.isFinite(serverSlotsRaw) ? Number(serverSlotsRaw) : (defaults.serverSlots ?? (hasServerOwnerProduct ? 1 : 0));
        const serverOwnerLicense = readOption('Server Owner License', 'VoiceLink Server Owner', 'Hosted Server License', 'ServerOwnerLicense');
        const hostedControlPanel = readOption('Hosting Control Panel', 'Control Panel Access', 'Hosting Panel Enabled');
        const hostedControlPanelRoles = readOption('Hosting Roles', 'Control Panel Roles', 'HostingRoleList');
        const hostedControlPanelPermissions = readOption('Hosting Permissions', 'Control Panel Permissions', 'HostingPermissionList');

        const allowMultiDeviceSettings = readOption('Allow Multi-Device Settings', 'Allow Multi Device Settings', 'Enable Multi-Device Settings');
        const allowDeviceList = readOption('Allow Device List', 'Enable Device List', 'Allow Device Management');
        const requiresIapApple = readOption('Require Apple IAP', 'Require iOS IAP', 'Apple IAP Required');
        const licenseTier = readOption('License Tier', 'VoiceLink License Tier', 'Support Tier', 'LicenseTier')
            || defaults.licenseTier
            || inferredTier
            || 'member';
        const normalizedServerOwnerLicense = serverOwnerLicense === null ? (defaults.serverOwnerLicense ?? hasServerOwnerProduct) : !!serverOwnerLicense;
        const normalizedHostingLinked = hostedControlPanel === null ? (defaults.hostingControlPanelLinked ?? hasHostingProduct) : !!hostedControlPanel;
        const inferredBillingModel = /(lifetime|perpetual)/.test(joinedCatalog)
            ? 'lifetime'
            : /(yearly|annual)/.test(joinedCatalog)
                ? 'yearly'
                : /(monthly|quarterly|weekly|subscription|recurring)/.test(joinedCatalog)
                    ? 'subscription'
                    : (defaults.billingModel || 'manual');
        const hostingRoles = Array.isArray(hostedControlPanelRoles)
            ? hostedControlPanelRoles
            : String(hostedControlPanelRoles || '')
                .split(/[;,|]/)
                .map((value) => value.trim())
                .filter(Boolean);
        const hostingPermissions = Array.isArray(hostedControlPanelPermissions)
            ? hostedControlPanelPermissions
            : String(hostedControlPanelPermissions || '')
                .split(/[;,|]/)
                .map((value) => value.trim())
                .filter(Boolean);

        if (normalizedServerOwnerLicense) {
            if (!hostingRoles.length) hostingRoles.push('server_owner');
            if (!hostingPermissions.length) hostingPermissions.push('hosting.owner', 'server.manage', 'license.manage', 'install.manage');
        } else if (normalizedHostingLinked && !hostingPermissions.length) {
            hostingPermissions.push('hosting.support');
        }

        return {
            deviceTier,
            maxDevices,
            installSlots,
            serverSlots,
            licenseTier,
            serverOwnerLicense: normalizedServerOwnerLicense,
            hostingControlPanelLinked: normalizedHostingLinked,
            hostingRoles,
            hostingPermissions,
            licenses: {
                user: {
                    type: normalizedServerOwnerLicense ? 'server_member' : 'member',
                    installsAllowed: installSlots,
                    devicesAllowed: maxDevices
                },
                server: {
                    type: normalizedServerOwnerLicense ? 'server_owner' : 'none',
                    installsAllowed: installSlots,
                    serversAllowed: serverSlots
                }
            },
            allowMultiDeviceSettings: allowMultiDeviceSettings === null ? (defaults.allowMultiDeviceSettings ?? true) : !!allowMultiDeviceSettings,
            allowDeviceList: allowDeviceList === null ? (defaults.allowDeviceList ?? true) : !!allowDeviceList,
            requiresIapApple: requiresIapApple === null ? (defaults.requiresIapApple ?? false) : !!requiresIapApple,
            billingModel: inferredBillingModel,
            allowsLicenseTransfer: inferredBillingModel === 'lifetime',
            requiresManualTransferApproval: inferredBillingModel !== 'lifetime',
            transferCooldownDays: inferredBillingModel === 'lifetime' ? 30 : 0,
            ownedDomains
        };
    }

    resolveWhmcsIdentity(identity = '') {
        const raw = String(identity || '').trim();
        if (!raw) return { identity: '', email: '', username: '' };

        const email = raw.includes('@') ? raw.toLowerCase() : '';
        const username = raw.includes('@') ? '' : raw.toLowerCase();
        if (email) {
            return { identity: raw, email, username: '' };
        }

        const aliases = new Map(
            String(process.env.VOICELINK_WHMCS_IDENTITY_ALIASES || '')
                .split(',')
                .map((entry) => entry.trim())
                .filter(Boolean)
                .map((entry) => {
                    const [alias, mappedEmail] = entry.split(':').map((part) => String(part || '').trim());
                    return [alias.toLowerCase(), mappedEmail.toLowerCase()];
                })
                .filter(([alias, mappedEmail]) => alias && mappedEmail)
        );
        const mappedEmail = aliases.get(username);
        if (mappedEmail) {
            return { identity: raw, email: mappedEmail, username };
        }

        const persistedAliasEmail = this.whmcsIdentityAliases?.get(username);
        if (persistedAliasEmail) {
            return { identity: raw, email: String(persistedAliasEmail).trim().toLowerCase(), username };
        }

        if (this.localAuthUsers?.size) {
            const localMatch = Array.from(this.localAuthUsers.values()).find((user) => {
                const candidate = String(user?.username || '').trim().toLowerCase();
                return candidate && candidate === username && String(user?.email || '').includes('@');
            });
            if (localMatch?.email) {
                return { identity: raw, email: String(localMatch.email).trim().toLowerCase(), username };
            }
        }

        return { identity: raw, email: '', username };
    }

    slugifyIdentityUsername(value = '') {
        return String(value || '')
            .trim()
            .toLowerCase()
            .replace(/@/g, '.')
            .replace(/[^a-z0-9._-]+/g, '-')
            .replace(/^-+|-+$/g, '')
            .replace(/-{2,}/g, '-')
            .slice(0, 32);
    }

    syncWhmcsIdentityAlias(email = '', preferredUsername = '', suffix = '') {
        const normalizedEmail = String(email || '').trim().toLowerCase();
        if (!normalizedEmail.includes('@')) return '';

        this.whmcsIdentityAliases = this.whmcsIdentityAliases || new Map();

        const existingLocal = this.localAuthUsers?.size
            ? Array.from(this.localAuthUsers.values()).find((user) => String(user?.email || '').trim().toLowerCase() === normalizedEmail)
            : null;
        const existingAlias = Array.from(this.whmcsIdentityAliases.entries())
            .find(([, mappedEmail]) => String(mappedEmail || '').trim().toLowerCase() === normalizedEmail)?.[0];

        const localPart = normalizedEmail.split('@')[0] || '';
        const candidates = [
            preferredUsername,
            existingLocal?.username,
            existingAlias,
            localPart,
            `${localPart}-${suffix || 'user'}`
        ]
            .map((candidate) => this.slugifyIdentityUsername(candidate))
            .filter(Boolean);

        let chosen = '';
        for (const candidate of candidates) {
            const aliasEmail = this.whmcsIdentityAliases.get(candidate);
            const localEmail = existingLocal?.username && this.slugifyIdentityUsername(existingLocal.username) === candidate
                ? normalizedEmail
                : null;
            if (!aliasEmail || String(aliasEmail).trim().toLowerCase() === normalizedEmail || localEmail === normalizedEmail) {
                chosen = candidate;
                break;
            }
        }

        if (!chosen) {
            chosen = this.slugifyIdentityUsername(`${localPart}-${suffix || Date.now().toString(36)}`) || `user-${Date.now().toString(36)}`;
        }

        this.whmcsIdentityAliases.set(chosen, normalizedEmail);
        return chosen;
    }

    getWhmcsAdminBridgeConfig() {
        return {
            enabled: process.env.VOICELINK_WHMCS_ADMIN_BRIDGE !== 'false',
            phpBin: process.env.VOICELINK_PHP_BIN || 'php',
            configPath: process.env.VOICELINK_WHMCS_CONFIG_PATH || '',
            adminUrl: process.env.VOICELINK_WHMCS_ADMIN_URL || ''
        };
    }

    async authenticateWhmcsAdmin(identity = '', password = '') {
        const config = this.getWhmcsAdminBridgeConfig();
        if (!config.enabled || !config.configPath) {
            return null;
        }

        const loginIdentity = String(identity || '').trim();
        const loginPassword = String(password || '');
        if (!loginIdentity || !loginPassword) {
            return null;
        }
        const helperPath = path.join(__dirname, '../tools/whmcs-admin-auth.php');

        try {
            const { stdout } = await execFileAsync(config.phpBin, [helperPath, loginIdentity, loginPassword, config.configPath], {
                timeout: 10000,
                maxBuffer: 1024 * 256
            });
            const parsed = JSON.parse(String(stdout || '{}').trim() || '{}');
            if (!parsed?.success || !parsed?.admin) {
                return null;
            }
            return parsed.admin;
        } catch (error) {
            console.warn('[WHMCS] Admin bridge failed:', error.message);
            return null;
        }
    }

    createAuthSession(store, prefix, user, remember = false) {
        const token = `${prefix}_${uuidv4()}_${Date.now().toString(36)}`;
        const ttlMs = remember ? 1000 * 60 * 60 * 24 * 30 : 1000 * 60 * 60 * 24;
        const expiresAt = new Date(Date.now() + ttlMs);
        store.set(token, { user, expiresAt, createdAt: new Date() });
        return { token, expiresAt };
    }

    getAuthSession(store, token) {
        const session = store.get(token);
        if (!session) return null;
        if (new Date() > session.expiresAt) {
            store.delete(token);
            return null;
        }
        return session;
    }

    registerSocketSession(socket, sessionInfo) {
        if (!sessionInfo?.userId) return;
        if (!this.activeSessionsByUser.has(sessionInfo.userId)) {
            this.activeSessionsByUser.set(sessionInfo.userId, new Map());
        }
        const userSessions = this.activeSessionsByUser.get(sessionInfo.userId);
        userSessions.set(socket.id, { ...sessionInfo, socketId: socket.id });
        this.socketSessions.set(socket.id, { ...sessionInfo, socketId: socket.id });
        if (sessionInfo.deviceId) {
            this.deviceSessions.set(sessionInfo.deviceId, socket.id);
        }
    }

    unregisterSocketSession(socketId) {
        const sessionInfo = this.socketSessions.get(socketId);
        if (!sessionInfo) return;
        const userSessions = this.activeSessionsByUser.get(sessionInfo.userId);
        if (userSessions) {
            userSessions.delete(socketId);
            if (userSessions.size === 0) {
                this.activeSessionsByUser.delete(sessionInfo.userId);
            }
        }
        if (sessionInfo.deviceId) {
            this.deviceSessions.delete(sessionInfo.deviceId);
        }
        this.socketSessions.delete(socketId);
    }

    getUserSessions(userId) {
        const sessions = this.activeSessionsByUser.get(userId);
        if (!sessions) return [];
        return Array.from(sessions.values());
    }

    getOtherUserSessions(userId, socketId) {
        const sessions = this.activeSessionsByUser.get(userId);
        if (!sessions) return [];
        return Array.from(sessions.values()).filter((session) => session.socketId !== socketId);
    }

    getRequesterContext(req) {
        const body = req.body || {};
        const query = req.query || {};
        const headers = req.headers || {};
        const userId = body.userId || body.user?.id || query.userId || headers['x-user-id'] || null;
        const userName = body.userName || body.username || body.creatorHandle || body.startedBy || query.userName || headers['x-user-name'] || null;
        const role = String(body.role || body.user?.role || query.role || headers['x-user-role'] || '').toLowerCase();
        const permissions = Array.isArray(body.permissions)
            ? body.permissions
            : (Array.isArray(body.user?.permissions) ? body.user.permissions : []);
        const isAdmin = body.isAdmin === true
            || body.user?.isAdmin === true
            || query.isAdmin === 'true'
            || headers['x-user-admin'] === 'true'
            || role === 'admin'
            || permissions.includes('admin');
        return {
            userId: userId ? String(userId) : null,
            userName: userName ? String(userName) : null,
            role,
            isAdmin
        };
    }

    ensureRoomJellyfinAccess(room) {
        if (!room) return null;
        if (!room.jellyfinAccess || typeof room.jellyfinAccess !== 'object') {
            room.jellyfinAccess = {};
        }
        const cfg = room.jellyfinAccess;
        if (!Array.isArray(cfg.allowedServerIds)) cfg.allowedServerIds = [];
        if (!cfg.allowedLibraryIdsByServer || typeof cfg.allowedLibraryIdsByServer !== 'object') cfg.allowedLibraryIdsByServer = {};
        if (!cfg.roomUserPermissions || typeof cfg.roomUserPermissions !== 'object') cfg.roomUserPermissions = {};
        if (typeof cfg.enabled !== 'boolean') cfg.enabled = true;
        if (typeof cfg.adminCanAccessAll !== 'boolean') cfg.adminCanAccessAll = true;
        if (typeof cfg.allowRoomOwnerUploads !== 'boolean') cfg.allowRoomOwnerUploads = true;
        if (typeof cfg.allowAuthenticatedUploads !== 'boolean') cfg.allowAuthenticatedUploads = false;
        return cfg;
    }

    canManageRoomJellyfin(room, requester) {
        if (!room || !requester) return false;
        if (requester.isAdmin) return true;
        if (!room.creatorHandle) return false;
        const creator = String(room.creatorHandle).toLowerCase();
        return (requester.userId && String(requester.userId).toLowerCase() === creator)
            || (requester.userName && String(requester.userName).toLowerCase() === creator);
    }

    getRoomJellyfinPermission(room, requester) {
        const cfg = this.ensureRoomJellyfinAccess(room);
        const keyFromId = requester?.userId ? `id:${requester.userId}` : null;
        const keyFromName = requester?.userName ? `name:${String(requester.userName).toLowerCase()}` : null;
        const explicit = (keyFromId && cfg.roomUserPermissions[keyFromId])
            || (keyFromName && cfg.roomUserPermissions[keyFromName])
            || null;
        const owner = this.canManageRoomJellyfin(room, requester) && !requester?.isAdmin;
        const defaults = {
            canUseLibraries: true,
            canUploadMedia: owner ? cfg.allowRoomOwnerUploads : cfg.allowAuthenticatedUploads,
            canManageRoomLibraries: owner,
            allowedServerIds: [],
            allowedLibraryIdsByServer: {}
        };
        return { ...defaults, ...(explicit || {}) };
    }

    isServerAllowedForRoom(room, serverId, requester) {
        const cfg = this.ensureRoomJellyfinAccess(room);
        if (!cfg.enabled) return false;
        if (requester?.isAdmin && cfg.adminCanAccessAll) return true;
        const perm = this.getRoomJellyfinPermission(room, requester);
        const fromUser = Array.isArray(perm.allowedServerIds) ? perm.allowedServerIds : [];
        const fromRoom = Array.isArray(cfg.allowedServerIds) ? cfg.allowedServerIds : [];
        const allowed = fromUser.length ? fromUser : fromRoom;
        if (!allowed.length) return true;
        return allowed.includes(serverId);
    }

    isLibraryAllowedForRoom(room, serverId, libraryId, requester) {
        const cfg = this.ensureRoomJellyfinAccess(room);
        if (requester?.isAdmin && cfg.adminCanAccessAll) return true;
        const perm = this.getRoomJellyfinPermission(room, requester);
        const roomMap = cfg.allowedLibraryIdsByServer?.[serverId];
        const userMap = perm.allowedLibraryIdsByServer?.[serverId];
        const allowed = Array.isArray(userMap) && userMap.length ? userMap : (Array.isArray(roomMap) ? roomMap : []);
        if (!allowed.length) return true;
        if (!libraryId) return false;
        return allowed.includes(String(libraryId));
    }

    /**
     * Initialize installed modules
     */
    async initializeModules() {
        console.log('[Modules] Initializing installed modules...');

        // Initialize 2FA module if installed
        if (this.moduleRegistry.isModuleEnabled('two-factor-auth')) {
            const config = this.moduleRegistry.getModule('two-factor-auth')?.config;
            this.modules.twoFactorAuth = new TwoFactorAuthModule({
                config,
                dataDir: path.join(__dirname, '../../data/2fa'),
                emailTransport: this.mailer
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
                emailTransport: this.mailer
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

        if (this.moduleRegistry.isModuleEnabled('media-rooms')) {
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
        } else {
            console.log('[Modules] Media Rooms module disabled; server-side streaming is unavailable until enabled');
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

        if (this.moduleRegistry.isModuleEnabled('deployment-manager')) {
            try {
                this.modules.deploymentManager = new DeploymentManagerModule({
                    config: this.moduleRegistry.getModule('deployment-manager')?.config || {},
                    dataDir: path.join(__dirname, '../../data/deployment-manager'),
                    deployConfig,
                    server: this,
                    mailer: this.mailer,
                    emailFrom: this.emailFrom
                });
                console.log('[Modules] Deployment Manager module initialized');
            } catch (e) {
                console.error('[Modules] Failed to initialize Deployment Manager:', e.message);
            }
        }

        // Initialize Internal Scheduler module when bundled.
        if (InternalScheduler) {
            this.initializeInternalSchedulerInstance();
        } else {
            this.modules.internalScheduler = null;
            console.log('[Modules] Internal Scheduler module not bundled; attempting sync from federation');
            this.ensureInternalSchedulerModule()
                .then((loaded) => {
                    if (loaded) {
                        this.initializeInternalSchedulerInstance();
                    } else {
                        console.log('[Modules] Internal Scheduler still unavailable after sync attempt');
                    }
                })
                .catch((error) => {
                    console.warn('[Modules] Internal Scheduler sync failed:', error.message);
                });
        }
    }

    initializeInternalSchedulerInstance() {
        if (!InternalScheduler) return false;
        if (this.modules.internalScheduler) return true;
        try {
            this.modules.internalScheduler = new InternalScheduler({
                io: this.io,
                dataDir: path.join(__dirname, '../../data/scheduler'),
                logger: console
            });
            console.log('[Modules] Internal Scheduler module initialized');
            return true;
        } catch (error) {
            console.error('[Modules] Failed to initialize Internal Scheduler:', error.message);
            this.modules.internalScheduler = null;
            return false;
        }
    }

    resolveModuleSyncSources() {
        const configured = deployConfig.getConfig() || {};
        const policyPrimary = configured.serverPolicies?.primaryServerUrl;
        const envPrimary = process.env.VOICELINK_MAIN_SERVER_URL || process.env.VOICELINK_PRIMARY_SERVER_URL;
        const federationTrusted = Array.isArray(configured.federation?.trustedServers)
            ? configured.federation.trustedServers
            : [];
        const envMirrors = String(process.env.VOICELINK_MODULE_MIRRORS || '')
            .split(',')
            .map((value) => value.trim())
            .filter(Boolean);
        const raw = [
            policyPrimary,
            envPrimary,
            MAIN_SERVER_URL,
            ...federationTrusted,
            ...envMirrors
        ];
        return ModuleRegistry.normalizeSourceUrls(raw);
    }

    async ensureInternalSchedulerModule() {
        if (InternalScheduler) return true;
        if (this.internalSchedulerSyncPromise) return this.internalSchedulerSyncPromise;

        this.internalSchedulerSyncPromise = (async () => {
            const sources = this.resolveModuleSyncSources();
            if (!sources.length) return false;

            const result = await this.moduleRegistry.syncModuleFromNetwork('internal-scheduler', {
                sources,
                adminKey: process.env.VOICELINK_ADMIN_KEY || '',
                timeoutMs: 12000
            });
            if (!result.success) {
                console.warn('[Modules] Internal Scheduler sync sources failed:', result.failures || result.error);
                return false;
            }

            try {
                const modulePath = path.join(__dirname, '../modules/internal-scheduler');
                try {
                    delete require.cache[require.resolve(modulePath)];
                } catch (_) {
                    // No cache entry yet.
                }
                ({ InternalScheduler } = require(modulePath));
                console.log(`[Modules] Internal Scheduler loaded from synced bundle (${result.sourceUrl})`);
                return true;
            } catch (error) {
                console.warn('[Modules] Internal Scheduler bundle downloaded but failed to load:', error.message);
                return false;
            }
        })();

        try {
            return await this.internalSchedulerSyncPromise;
        } finally {
            this.internalSchedulerSyncPromise = null;
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
        const baseUrl = String(process.env.VOICELINK_COPYPARTY_URL || 'https://voicelink.devinecreations.net')
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

    getClientUploadRoot() {
        const uploadRoot = path.join(__dirname, '../../data/uploads');
        fs.mkdirSync(uploadRoot, { recursive: true });
        return uploadRoot;
    }

    resolveClientUploadPath(requestPath = '') {
        const cleaned = String(requestPath || '')
            .trim()
            .replace(/\\/g, '/')
            .replace(/^\/+/, '');
        const normalized = path.posix.normalize(`/${cleaned}`);
        const normalizedRelative = normalized.replace(/^\/+/, '');
        if (!normalizedRelative || normalizedRelative.startsWith('..')) {
            return null;
        }
        const storageRelativePath = normalizedRelative.startsWith('uploads/')
            ? normalizedRelative.slice('uploads/'.length)
            : normalizedRelative;
        if (!storageRelativePath || storageRelativePath.startsWith('..')) {
            return null;
        }

        const uploadRoot = this.getClientUploadRoot();
        const absolutePath = path.join(uploadRoot, storageRelativePath);
        const relativeFsPath = path.relative(uploadRoot, absolutePath);
        if (!relativeFsPath || relativeFsPath.startsWith('..') || path.isAbsolute(relativeFsPath)) {
            return null;
        }

        return {
            absolutePath,
            relativePath: storageRelativePath,
            publicPath: normalized.startsWith('/uploads/') ? normalized : `/uploads/${storageRelativePath}`
        };
    }

    getRequestPublicBaseUrl(req) {
        const forwardedProto = String(req.headers['x-forwarded-proto'] || '').split(',')[0].trim();
        const proto = forwardedProto || req.protocol || 'https';
        const host = String(req.headers['x-forwarded-host'] || req.headers.host || '').split(',')[0].trim();
        const fallback = this.getCopyPartyExportConfig().baseUrl;
        if (!host) {
            return fallback;
        }
        return `${proto}://${host}`.replace(/\/+$/, '');
    }

    createClientUploadShareLink(req, requestPath, keepForever = false, expiresAt = null) {
        const resolved = this.resolveClientUploadPath(requestPath);
        if (!resolved || !fs.existsSync(resolved.absolutePath)) {
            return null;
        }
        const encodedPath = encodeURIComponent(resolved.publicPath);

        return {
            success: true,
            id: uuidv4(),
            filePath: resolved.publicPath,
            url: `${this.getRequestPublicBaseUrl(req)}/api/files/content?path=${encodedPath}`,
            token: null,
            keepForever: !!keepForever,
            expiresAt: expiresAt || null,
            createdAt: new Date().toISOString()
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

    getOpenLinkShareConfig() {
        const baseUrl = String(process.env.VOICELINK_OPENLINK_URL || 'https://openlink.tappedin.fm')
            .trim()
            .replace(/\/+$/, '');
        const regeneratePath = String(process.env.VOICELINK_OPENLINK_REGENERATE_PATH || '/api/regenerate').trim();
        return {
            enabled: Boolean(baseUrl),
            baseUrl,
            regeneratePath: regeneratePath.startsWith('/') ? regeneratePath : `/${regeneratePath}`
        };
    }

    createShareToken(seed = '') {
        const clean = this.sanitizeExportSegment(seed || uuidv4().slice(0, 8), 'share');
        return `${clean}-${Date.now().toString(36)}`;
    }

    withTimeoutSignal(timeoutMs = 6000) {
        const controller = new AbortController();
        const timer = setTimeout(() => controller.abort(), timeoutMs);
        return { signal: controller.signal, clear: () => clearTimeout(timer) };
    }

    async probeUrl(url, timeoutMs = 6000) {
        const probeHead = this.withTimeoutSignal(timeoutMs);
        try {
            const response = await fetch(url, {
                method: 'HEAD',
                signal: probeHead.signal
            });
            if (response.ok) {
                return { ok: true, status: response.status };
            }
            if (response.status !== 405) {
                return { ok: false, status: response.status };
            }
        } catch (error) {
            // Fall back to GET probe for hosts that do not support HEAD.
            if (error?.name !== 'AbortError') {
                // continue
            }
        } finally {
            probeHead.clear();
        }

        const probeGet = this.withTimeoutSignal(timeoutMs);
        try {
            const response = await fetch(url, {
                method: 'GET',
                signal: probeGet.signal
            });
            return { ok: response.ok, status: response.status };
        } catch (error) {
            return { ok: false, error: error.message };
        } finally {
            probeGet.clear();
        }
    }

    buildCopyPartyLink({ fileName = '', directUrl = '' } = {}) {
        if (directUrl && /^https?:\/\//i.test(directUrl)) {
            return { url: directUrl, configured: true };
        }
        const cfg = this.getCopyPartyExportConfig();
        if (!cfg.enabled || !fileName) {
            return { url: '', configured: false };
        }
        return {
            url: `${cfg.baseUrl}${cfg.exportPath}/${encodeURIComponent(fileName)}`,
            configured: true
        };
    }

    async buildOpenLinkShareLink({ token = '', timeoutMs = 6000 } = {}) {
        const cfg = this.getOpenLinkShareConfig();
        if (!cfg.enabled) {
            return { ok: false, reason: 'OpenLink not configured' };
        }

        const base = new URL(cfg.baseUrl);
        const shareToken = this.sanitizeExportSegment(token || this.createShareToken('olink'), 'olink');
        const regenerateUrl = `${cfg.baseUrl}${cfg.regeneratePath}/${encodeURIComponent(shareToken)}`;

        const regenTimeout = this.withTimeoutSignal(timeoutMs);
        try {
            const response = await fetch(regenerateUrl, {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: '{}',
                signal: regenTimeout.signal
            });
            if (!response.ok) {
                const text = await response.text().catch(() => '');
                return { ok: false, reason: `OpenLink regenerate failed (${response.status}): ${text.slice(0, 120)}` };
            }
        } catch (error) {
            return { ok: false, reason: `OpenLink regenerate failed: ${error.message}` };
        } finally {
            regenTimeout.clear();
        }

        const wildcardUrl = `${base.protocol}//${shareToken}.${base.host}`;
        const healthProbe = await this.probeUrl(`${wildcardUrl}/health`, timeoutMs);
        if (!healthProbe.ok) {
            return {
                ok: false,
                reason: `OpenLink wildcard check failed (${healthProbe.status || 'error'})`
            };
        }

        return {
            ok: true,
            provider: 'openlink',
            token: shareToken,
            url: wildcardUrl,
            regenerateUrl
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
            directMessages: includeMessages ? Object.fromEntries(this.directMessages.entries()) : {},
            directMessageVisibility: Object.fromEntries(this.directMessageVisibility.entries()),
            directMessagePurgeRequests: Object.fromEntries(this.directMessagePurgeRequests.entries())
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

        if (snapshot.directMessageVisibility && typeof snapshot.directMessageVisibility === 'object') {
            for (const [dmKey, visibility] of Object.entries(snapshot.directMessageVisibility)) {
                this.directMessageVisibility.set(dmKey, visibility && typeof visibility === 'object' ? visibility : {});
            }
        }

        if (snapshot.directMessagePurgeRequests && typeof snapshot.directMessagePurgeRequests === 'object') {
            for (const [dmKey, purgeRequests] of Object.entries(snapshot.directMessagePurgeRequests)) {
                this.directMessagePurgeRequests.set(dmKey, purgeRequests && typeof purgeRequests === 'object' ? purgeRequests : {});
            }
        }

        return result;
    }

    normalizeFederationServerUrl(serverUrl = '') {
        const value = String(serverUrl || '').trim();
        if (!value) return '';
        try {
            const parsed = new URL(value);
            return parsed.origin.replace(/\/+$/, '');
        } catch (error) {
            return value.replace(/\/+$/, '');
        }
    }

    extractFederationServerHost(serverUrl = '') {
        const value = String(serverUrl || '').trim();
        if (!value) return '';
        try {
            return new URL(value).hostname.toLowerCase();
        } catch (error) {
            return value
                .replace(/^https?:\/\//i, '')
                .replace(/\/.*$/, '')
                .replace(/:\d+$/, '')
                .toLowerCase();
        }
    }

    getLocalServerOrigins() {
        const config = deployConfig.getConfig?.() || {};
        const candidates = [
            process.env.VOICELINK_PUBLIC_URL,
            process.env.PUBLIC_URL,
            process.env.VOICELINK_WHMCS_AUTHORITY_URL,
            config?.server?.publicUrl,
            config?.server?.url,
            config?.server?.domain && `https://${config.server.domain}`,
            'http://127.0.0.1:3010',
            'http://127.0.0.1:3110',
            'http://localhost:3010',
            'http://localhost:3110'
        ].filter(Boolean);
        return Array.from(new Set(candidates.map((candidate) => this.normalizeFederationServerUrl(candidate)).filter(Boolean)));
    }

    isTrustedFederationPeer(serverUrl = '') {
        const normalized = this.normalizeFederationServerUrl(serverUrl);
        const host = this.extractFederationServerHost(serverUrl);
        if (!normalized) return false;
        const trustedServers = deployConfig.get('federation', 'trustedServers') || [];
        return trustedServers.some((entry) => {
            const trustedNormalized = this.normalizeFederationServerUrl(entry);
            const trustedHost = this.extractFederationServerHost(entry);
            return (trustedNormalized && trustedNormalized === normalized)
                || (trustedHost && host && trustedHost === host);
        });
    }

    buildRoomStatePayload(roomId) {
        const room = this.rooms.get(roomId);
        if (!room) return null;
        return {
            id: room.id,
            name: room.name,
            description: room.description || '',
            users: this.normalizeRoomUsers(roomId).map((user) => this.serializeRoomUser(user, roomId)).filter(Boolean),
            userCount: this.normalizeRoomUsers(roomId).length,
            maxUsers: room.maxUsers || 50,
            locked: room.locked || false
        };
    }

    buildClientRoomListPayload() {
        return Array.from(this.rooms.values()).map((room) => {
            const createdAt = room.createdAt ? new Date(room.createdAt) : null;
            const uptimeSeconds = createdAt
                ? Math.max(0, Math.floor((Date.now() - createdAt.getTime()) / 1000))
                : null;
            const liveUsers = this.normalizeRoomUsers(room.id);
            const lastActiveAt = liveUsers.length > 0
                ? liveUsers
                    .map((u) => (u?.lastActiveAt ? new Date(u.lastActiveAt) : null))
                    .filter(Boolean)
                    .sort((a, b) => b - a)[0]
                : null;
            const lastActiveUser = liveUsers.length > 0
                ? [...liveUsers].sort((a, b) => {
                    const left = a?.lastActiveAt ? new Date(a.lastActiveAt).getTime() : 0;
                    const right = b?.lastActiveAt ? new Date(b.lastActiveAt).getTime() : 0;
                    return right - left;
                })[0]
                : null;

            return {
                createdAt: createdAt ? createdAt.toISOString() : null,
                uptimeSeconds,
                lastActivityAt: lastActiveAt ? lastActiveAt.toISOString() : null,
                lastActiveUsername: lastActiveUser?.name || null,
                id: room.id,
                name: room.name,
                description: room.description || '',
                welcomeMessage: room.welcomeMessage || null,
                userCount: liveUsers.length,
                users: liveUsers.map((u) => ({
                    id: u.id,
                    name: u.name,
                    isAuthenticated: u.isAuthenticated || false
                })),
                maxUsers: room.maxUsers || 50,
                hasPassword: !!room.password,
                visibility: room.visibility || 'public',
                visibleToGuests: room.visibleToGuests !== false,
                isDefault: room.isDefault || false,
                locked: room.locked || false
            };
        });
    }

    emitRoomListToClients() {
        const roomList = this.buildClientRoomListPayload();
        this.io.emit('room-list', roomList);
        return roomList;
    }

    ensureTransferTargetRoom({
        sourceRoom,
        targetRoomId,
        targetRoomName = '',
        incomingUserCount = 0,
        hostedBy = '',
        targetServerUrl = ''
    } = {}) {
        if (!sourceRoom) {
            throw new Error('Source room not found');
        }

        const roomId = String(targetRoomId || '').trim() || sourceRoom.id;
        const resolvedName = String(targetRoomName || '').trim() || String(sourceRoom.name || '').trim() || `Room ${roomId.slice(0, 8)}`;
        let room = this.rooms.get(roomId);
        const existingUsers = room ? this.getLiveRoomUsers(roomId).length : 0;
        const requiredCapacity = Math.max(
            Number(sourceRoom.maxUsers || 50),
            existingUsers + Math.max(0, Number(incomingUserCount || 0))
        );

        let created = false;
        let expanded = false;
        let previousMaxUsers = room ? Number(room.maxUsers || 50) : null;

        if (!room) {
            room = {
                id: roomId,
                name: resolvedName,
                description: sourceRoom.description || '',
                password: sourceRoom.password || null,
                hasPassword: !!sourceRoom.password,
                maxUsers: requiredCapacity,
                users: [],
                visibility: sourceRoom.visibility || 'public',
                visibleToGuests: sourceRoom.visibleToGuests !== false,
                accessType: sourceRoom.accessType || 'hybrid',
                allowEmbed: sourceRoom.allowEmbed !== false,
                showInApp: sourceRoom.showInApp !== false,
                privacyLevel: sourceRoom.privacyLevel || sourceRoom.visibility || 'public',
                encrypted: !!sourceRoom.encrypted,
                creatorHandle: sourceRoom.creatorHandle || null,
                createdBy: sourceRoom.createdBy || sourceRoom.creatorHandle || 'system_migration',
                isDefault: !!sourceRoom.isDefault,
                template: sourceRoom.template || null,
                createdAt: new Date(),
                updatedAt: new Date(),
                updatedBy: 'system_migration',
                previousNames: Array.isArray(sourceRoom.previousNames) ? [...sourceRoom.previousNames] : [],
                audioSettings: sourceRoom.audioSettings || {
                    spatialAudio: true,
                    quality: 'high',
                    effects: []
                },
                locked: !!sourceRoom.locked,
                lockedAt: sourceRoom.lockedAt || null,
                lockedBy: sourceRoom.lockedBy || null,
                autoLock: sourceRoom.autoLock || null,
                autoLockScheduled: null,
                autoplayMusic: !!sourceRoom.autoplayMusic,
                autoplayPlaylist: sourceRoom.autoplayPlaylist || null,
                jellyfinAccess: sourceRoom.jellyfinAccess || {
                    enabled: true,
                    adminCanAccessAll: true,
                    allowRoomOwnerUploads: true,
                    allowAuthenticatedUploads: false,
                    allowedServerIds: [],
                    allowedLibraryIdsByServer: {},
                    roomUserPermissions: {}
                },
                migrationMetadata: {
                    hostedBy: hostedBy || targetServerUrl || null,
                    lastTransferPreparedAt: new Date().toISOString(),
                    sourceRoomId: sourceRoom.id
                }
            };
            this.rooms.set(roomId, room);
            created = true;
        }

        if (resolvedName && room.name !== resolvedName) {
            room.name = resolvedName;
        }

        if (!room.description && sourceRoom.description) {
            room.description = sourceRoom.description;
        }

        if (!room.migrationMetadata) {
            room.migrationMetadata = {};
        }
        room.migrationMetadata.hostedBy = hostedBy || targetServerUrl || room.migrationMetadata.hostedBy || null;
        room.migrationMetadata.lastTransferPreparedAt = new Date().toISOString();
        room.migrationMetadata.sourceRoomId = sourceRoom.id;

        if (requiredCapacity > Number(room.maxUsers || 50)) {
            if (!room.migrationMetadata.originalMaxUsers) {
                room.migrationMetadata.originalMaxUsers = Number(room.maxUsers || 50);
            }
            previousMaxUsers = Number(room.maxUsers || 50);
            room.maxUsers = requiredCapacity;
            expanded = true;
        }

        room.updatedAt = new Date();
        room.updatedBy = 'system_migration';
        this.rooms.set(roomId, room);
        this.saveRoomsToDisk();
        this.federation.broadcastRoomChange(created ? 'created' : 'updated', room);

        return {
            room,
            created,
            expanded,
            previousMaxUsers,
            requiredCapacity
        };
    }

    async notifyAdminRoomTransfer({
        sourceRoom,
        targetRoom,
        targetServerUrl = '',
        incomingUserCount = 0,
        expanded = false,
        previousMaxUsers = null,
        requiredCapacity = null
    } = {}) {
        const targetLabel = targetServerUrl || targetRoom?.name || 'target room';
        const lines = [
            `Room transfer prepared for ${sourceRoom?.name || sourceRoom?.id || 'room'}.`,
            `Target: ${targetRoom?.name || targetRoom?.id || 'unknown'}${targetServerUrl ? ` on ${targetServerUrl}` : ''}.`,
            `Incoming users: ${incomingUserCount}.`
        ];
        if (expanded) {
            lines.push(`Capacity auto-expanded from ${previousMaxUsers ?? 'unknown'} to ${requiredCapacity ?? targetRoom?.maxUsers ?? 'unknown'}.`);
        }

        return this.sendPushoverNotification({
            title: 'VoiceLink Room Transfer',
            message: lines.join('\n'),
            url: targetServerUrl || '',
            urlTitle: targetLabel
        });
    }

    async prepareRemoteTransferRoom({
        sourceRoom,
        sourceServerUrl = '',
        targetRoomId,
        targetRoomName = '',
        targetServerUrl,
        incomingUserCount = 0
    } = {}) {
        const normalizedTarget = this.normalizeFederationServerUrl(targetServerUrl);
        if (!normalizedTarget) {
            throw new Error('Target server URL is required');
        }
        if (!this.isTrustedFederationPeer(normalizedTarget)) {
            throw new Error('Target server is not in trusted federation peers');
        }

        const response = await fetch(`${normalizedTarget}/api/federation/prepare-transfer`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({
                sourceServerUrl: sourceServerUrl || this.getLocalServerOrigins()[0] || '',
                sourceRoom: {
                    id: sourceRoom.id,
                    name: sourceRoom.name,
                    description: sourceRoom.description || '',
                    maxUsers: Number(sourceRoom.maxUsers || 50),
                    visibility: sourceRoom.visibility || 'public',
                    accessType: sourceRoom.accessType || 'hybrid',
                    allowEmbed: sourceRoom.allowEmbed !== false,
                    showInApp: sourceRoom.showInApp !== false,
                    visibleToGuests: sourceRoom.visibleToGuests !== false,
                    creatorHandle: sourceRoom.creatorHandle || null,
                    createdBy: sourceRoom.createdBy || null,
                    template: sourceRoom.template || null
                },
                targetRoomId,
                targetRoomName,
                incomingUserCount: Number(incomingUserCount || 0)
            })
        });

        const body = await response.json().catch(() => ({}));
        if (!response.ok || body.success === false) {
            throw new Error(body.error || `Remote room preparation failed (${response.status})`);
        }
        return body;
    }

    executeLocalMigrationTransfer(session) {
        const sourceRoom = this.rooms.get(session.sourceRoomId);
        const targetRoom = this.rooms.get(session.targetRoomId);
        if (!sourceRoom || !targetRoom) {
            throw new Error('Source or target room not found');
        }

        const movingUsers = this.getLiveRoomUsers(session.sourceRoomId);
        const movedUsers = [];

        sourceRoom.users = (sourceRoom.users || []).filter((entry) => !movingUsers.some((user) => user.id === entry.id));
        targetRoom.users = (targetRoom.users || []).filter((entry) => !movingUsers.some((user) => user.id === entry.id));

        for (const user of movingUsers) {
            const socket = this.io?.sockets?.sockets?.get(user.id);
            if (!socket) continue;

            socket.leave(session.sourceRoomId);
            socket.join(session.targetRoomId);

            const movedUser = {
                ...user,
                roomId: session.targetRoomId,
                lastActiveAt: new Date()
            };
            this.users.set(user.id, movedUser);
            targetRoom.users.push(movedUser);
            movedUsers.push(movedUser);
        }

        this.rooms.set(session.sourceRoomId, sourceRoom);
        this.rooms.set(session.targetRoomId, targetRoom);

        const targetState = this.buildRoomStatePayload(session.targetRoomId);
        for (const movedUser of movedUsers) {
            this.io.to(movedUser.id).emit('joined-room', {
                room: targetState,
                user: movedUser
            });
        }

        this.io.to(session.sourceRoomId).emit('escort-moving', {
            escortId: session.id,
            targetRoomId: session.targetRoomId,
            playSound: 'whoosh_leave',
            message: `Moving to ${targetRoom.name}...`
        });
        this.io.to(session.targetRoomId).emit('escort-arriving', {
            escortId: session.id,
            fromRoom: session.sourceRoomId,
            leaderName: session.leaderName,
            count: movedUsers.length,
            playSound: 'whoosh_arrive'
        });

        this.emitRoomUsersSnapshot(session.sourceRoomId);
        this.emitRoomUsersSnapshot(session.targetRoomId);
        this.saveRoomsToDisk();

        return {
            movedUsers: movedUsers.length,
            targetRoomId: session.targetRoomId
        };
    }

    async startMigrationRoomTransfer({ sourceRoomId, targetRoomId, targetServerUrl = '', targetRoomName = '' } = {}) {
        this.ensureEscortSessionsStore();
        const sourceRoom = this.rooms.get(sourceRoomId);
        if (!sourceRoom) {
            throw new Error('Source room not found');
        }

        const incomingUsers = this.getLiveRoomUsers(sourceRoomId);
        const normalizedTargetServerUrl = this.normalizeFederationServerUrl(targetServerUrl);
        const localOrigins = this.getLocalServerOrigins();
        const isLocalTransfer = !normalizedTargetServerUrl || localOrigins.includes(normalizedTargetServerUrl);

        let prepareResult = null;
        if (isLocalTransfer) {
            prepareResult = this.ensureTransferTargetRoom({
                sourceRoom,
                targetRoomId,
                targetRoomName,
                incomingUserCount: incomingUsers.length,
                hostedBy: localOrigins[0] || null
            });
        } else {
            prepareResult = await this.prepareRemoteTransferRoom({
                sourceRoom,
                sourceServerUrl: localOrigins[0] || '',
                targetRoomId,
                targetRoomName,
                targetServerUrl: normalizedTargetServerUrl,
                incomingUserCount: incomingUsers.length
            });
        }

        const escortId = `escort_migration_${uuidv4().slice(0, 8)}`;
        const session = {
            id: escortId,
            leaderId: 'system_migration',
            leaderName: 'Server Migration',
            sourceRoomId,
            targetRoomId,
            targetServerUrl: normalizedTargetServerUrl || null,
            followers: incomingUsers.map((user) => user.id),
            status: isLocalTransfer ? 'moving' : 'active',
            migrationMode: true,
            localTransfer: isLocalTransfer,
            incomingUserCount: incomingUsers.length,
            prepareResult,
            createdAt: new Date(),
            expiresAt: new Date(Date.now() + 10 * 60 * 1000)
        };
        this.escortSessions.set(escortId, session);

        void this.notifyAdminRoomTransfer({
            sourceRoom,
            targetRoom: prepareResult?.room || prepareResult?.targetRoom || null,
            targetServerUrl: normalizedTargetServerUrl,
            incomingUserCount: incomingUsers.length,
            expanded: !!prepareResult?.expanded,
            previousMaxUsers: prepareResult?.previousMaxUsers ?? null,
            requiredCapacity: prepareResult?.requiredCapacity ?? prepareResult?.room?.maxUsers ?? null
        });

        this.io.to(sourceRoomId).emit('escort-started', {
            escortId,
            leaderName: session.leaderName,
            targetRoomId,
            targetServerUrl: session.targetServerUrl,
            migrationMode: true,
            message: normalizedTargetServerUrl
                ? `Server migration in progress. Follow to move to ${targetRoomId} on ${normalizedTargetServerUrl}`
                : `Server migration in progress. Follow to move to ${targetRoomId}.`,
            incomingUserCount: incomingUsers.length,
            capacityExpanded: !!prepareResult?.expanded
        });

        if (isLocalTransfer) {
            const transferResult = this.executeLocalMigrationTransfer(session);
            session.status = 'completed';
            session.completedAt = new Date();
            session.transferResult = transferResult;
        }

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
        this.app.use(express.json());
        this.app.use('/uploads', express.static(this.getClientUploadRoot()));
        this.app.use(express.static(path.join(__dirname, '..', '..', 'client')));
        this.app.use("/api/file-transfer", fileTransferRoutes);
    }

    /**
     * Fetch rooms from main signal server
     */
    async fetchMainServerRooms() {
        const config = deployConfig.getConfig() || {};
        const configuredMainServer = process.env.MAIN_SERVER_URL
            || config.federation?.hubUrl
            || MAIN_SERVER_URL;
        const trustedServers = Array.isArray(config.federation?.trustedServers)
            ? config.federation.trustedServers
            : [];
        const configuredPublicUrl = process.env.PUBLIC_URL
            || config.server?.publicUrl
            || null;

        const normalizeUrl = (value) => {
            if (!value || typeof value !== 'string') return null;
            try {
                const parsed = new URL(value.includes('://') ? value : `https://${value}`);
                return parsed.origin.toLowerCase();
            } catch {
                return value.trim().toLowerCase().replace(/\/+$/, '');
            }
        };

        const currentOrigin = normalizeUrl(configuredPublicUrl);
        const candidateOrigins = [
            configuredMainServer,
            ...trustedServers
        ]
            .map(normalizeUrl)
            .filter(Boolean);
        const targetOrigins = Array.from(new Set(candidateOrigins))
            .filter((origin) => origin && (!currentOrigin || origin !== currentOrigin));

        if (targetOrigins.length === 0) {
            return [];
        }

        const cacheIsFresh = Array.isArray(this.cachedMainServerRooms)
            && this.cachedMainServerRooms.length > 0
            && (Date.now() - this.cachedMainServerRoomsFetchedAt) < 15000;
        if (cacheIsFresh) {
            return this.cachedMainServerRooms;
        }

        if (this.mainServerRoomFetchPromise) {
            return this.mainServerRoomFetchPromise;
        }

        this.mainServerRoomFetchPromise = new Promise((resolve) => {
            const fetchSingleServer = (origin) => new Promise((serverResolve) => {
                const url = `${origin}/api/rooms?source=app`;
                const client = origin.startsWith('https://') ? https : http;

                client.get(url, { timeout: 5000 }, (response) => {
                    let data = '';
                    response.on('data', (chunk) => { data += chunk; });
                    response.on('end', () => {
                        try {
                            const rooms = JSON.parse(data);
                            const hostLabel = (() => {
                                try {
                                    return new URL(origin).host;
                                } catch {
                                    return origin;
                                }
                            })();
                            const normalizedRooms = Array.isArray(rooms)
                                ? rooms.map((room) => ({
                                    ...room,
                                    serverSource: room.serverSource || hostLabel,
                                    serverTitle: room.serverTitle || hostLabel,
                                    serverApiBase: room.serverApiBase || origin
                                }))
                                : [];
                            serverResolve(normalizedRooms);
                        } catch (error) {
                            console.error(`[LocalServer] Failed to parse rooms from ${origin}:`, error.message);
                            serverResolve([]);
                        }
                    });
                }).on('error', (error) => {
                    console.error(`[LocalServer] Room fetch error from ${origin}:`, error.message);
                    serverResolve([]);
                }).on('timeout', function onTimeout() {
                    this.destroy(new Error('timeout'));
                    serverResolve([]);
                });
            });

            Promise.all(targetOrigins.map((origin) => fetchSingleServer(origin)))
                .then((results) => {
                    const merged = results.flat();
                    const deduped = [];
                    const seen = new Set();
                    for (const room of merged) {
                        const key = `${room.id || ''}|${String(room.serverApiBase || '').toLowerCase()}`;
                        if (seen.has(key)) continue;
                        seen.add(key);
                        deduped.push(room);
                    }
                    this.cachedMainServerRooms = deduped;
                    this.cachedMainServerRoomsFetchedAt = Date.now();
                    resolve(deduped);
                })
                .catch((error) => {
                    console.error('[LocalServer] Federated room fetch failed:', error.message);
                    resolve(this.cachedMainServerRooms || []);
                })
                .finally(() => {
                    this.mainServerRoomFetchPromise = null;
                });
        });

        return this.mainServerRoomFetchPromise;
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
        this.emitRoomSystemMessage(
            roomId,
            `${room.name || 'This room'} was locked${room.lockReason ? `: ${room.lockReason}` : '.'}`,
            { lockedBy: room.lockedBy }
        );

        // Broadcast to federated servers
        this.federation.broadcastRoomChange('locked', room);
        this.emitRoomListToClients();

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
        this.emitRoomSystemMessage(
            roomId,
            `${room.name || 'This room'} was unlocked.`,
            { unlockedBy: unlockedBy || 'system' }
        );

        // Broadcast to federated servers
        this.federation.broadcastRoomChange('unlocked', room);
        this.emitRoomListToClients();

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

    getConnectedSocketSet() {
        if (!this.io?.sockets?.sockets) {
            return new Set();
        }
        return new Set(this.io.sockets.sockets.keys());
    }

    getLiveRoomUsers(roomId) {
        const room = this.rooms.get(roomId);
        if (!room) return [];

        const connectedSockets = this.getConnectedSocketSet();
        const liveUsers = [];
        const seen = new Set();

        // Authoritative source: active socket/user map.
        for (const [socketId, user] of this.users.entries()) {
            if (user?.roomId !== roomId) continue;
            if (!connectedSockets.has(socketId)) continue;
            if (seen.has(socketId)) continue;
            liveUsers.push(user);
            seen.add(socketId);
        }

        // Compatibility source: persisted room.users entries.
        const roomUsers = Array.isArray(room.users) ? room.users : [];
        for (const roomUser of roomUsers) {
            if (!roomUser?.id || seen.has(roomUser.id)) continue;
            if (!connectedSockets.has(roomUser.id)) continue;
            liveUsers.push(roomUser);
            seen.add(roomUser.id);
        }

        return liveUsers;
    }

    normalizeRoomUsers(roomId) {
        const room = this.rooms.get(roomId);
        if (!room) return [];
        room.users = this.getLiveRoomUsers(roomId);
        const botName = 'VoiceLink Bot';
        const virtualUsers = [{
            id: `bot:${roomId}`,
            roomId,
            name: botName,
            username: botName,
            displayName: botName,
            joinedAt: room.createdAt || new Date(),
            lastActiveAt: new Date(),
            isSpeaking: false,
            isAuthenticated: true,
            isBot: true,
            authProvider: 'voicelink_bot',
            role: 'bot',
            audioSettings: {
                muted: true,
                deafened: true
            }
        }];
        return [...room.users, ...virtualUsers];
    }

    serializeRoomUser(user, roomId = null) {
        if (!user) return null;
        const authInfo = user.authInfo || {};
        const isAuthenticated = !!user.isAuthenticated;
        const isBot = !!user.isBot;
        const resolvedRole = authInfo.role || user.role || (isBot ? 'bot' : isAuthenticated ? null : 'visitor');
        const resolvedAuthProvider = authInfo.authProvider || authInfo.provider || user.authProvider || (isBot ? 'internal_bot' : isAuthenticated ? null : 'visitor');
        return {
            id: user.id,
            userId: user.id,
            odId: user.id,
            name: user.name,
            username: authInfo.username || user.username || user.name,
            displayName: authInfo.displayName || authInfo.name || user.displayName || user.name,
            email: authInfo.email || user.email || null,
            role: resolvedRole,
            authProvider: resolvedAuthProvider,
            isAuthenticated,
            isBot,
            hasAudioControls: user.isBot ? !!user.hasAudioControls : true,
            statusMessage: user.statusMessage || (user.isBot ? 'Use /bot help or @VoiceLink Bot to interact.' : null),
            joinedAt: user.joinedAt || null,
            lastActiveAt: user.lastActiveAt || user.lastSeenAt || null,
            muted: !!(user.audioSettings?.muted),
            deafened: !!(user.audioSettings?.deafened),
            speaking: !!user.isSpeaking,
            isSpeaking: !!user.isSpeaking,
            roomId: roomId || user.roomId || null,
            activeRoomId: roomId || user.roomId || null,
            presence: roomId || user.roomId ? 'active' : 'online',
            status: roomId || user.roomId ? 'active' : 'online'
        };
    }

    canUserModerateRoom(user, room = null) {
        if (!user) return false;
        const authInfo = user.authInfo || {};
        const role = this.normalizeUserRole(authInfo.role || user.role);
        if (role === 'owner' || role === 'admin' || role === 'staff') return true;
        if (!room) return false;
        const createdBy = String(room.createdBy || '').trim().toLowerCase();
        const userEmail = String(authInfo.email || user.email || '').trim().toLowerCase();
        const userName = String(authInfo.username || user.username || user.name || '').trim().toLowerCase();
        return !!createdBy && (createdBy === userEmail || createdBy === userName);
    }

    emitRoomJoinRequest(roomId, requestEntry) {
        const room = this.rooms.get(roomId);
        if (!room) return;
        const moderators = this.getLiveRoomUsers(roomId).filter((user) => this.canUserModerateRoom(user, room));
        const payload = {
            roomId,
            roomName: room.name,
            requestId: requestEntry.id,
            requesterName: requestEntry.userName,
            requesterId: requestEntry.userId,
            requestedAt: requestEntry.requestedAt
        };

        for (const moderator of moderators) {
            if (moderator.id) {
                this.io.to(moderator.id).emit('room-join-request', payload);
            }
        }

        this.emitSystemActionNotification({
            type: 'room_join_request',
            title: `Join request for ${room.name}`,
            message: `${requestEntry.userName} requested access to locked room ${room.name}.`,
            roomId,
            requestId: requestEntry.id
        });
    }

    emitSystemActionNotification({
        type = 'system_action',
        title = 'VoiceLink System',
        message = '',
        severity = 'info',
        targetUserId = null,
        roomId = null,
        metadata = {}
    } = {}) {
        if (!this.io) return;
        const payload = {
            id: uuidv4(),
            type: String(type || 'system_action'),
            title: String(title || 'VoiceLink System'),
            message: String(message || ''),
            severity: String(severity || 'info'),
            timestamp: new Date().toISOString(),
            roomId: roomId || null,
            targetUserId: targetUserId || null,
            ...((metadata && typeof metadata === 'object') ? metadata : {})
        };

        if (targetUserId) {
            this.io.to(targetUserId).emit('admin-notification', payload);
            this.io.to(targetUserId).emit('system-action-notification', payload);
            return;
        }
        if (roomId) {
            this.io.to(roomId).emit('admin-notification', payload);
            this.io.to(roomId).emit('system-action-notification', payload);
            return;
        }

        this.io.emit('admin-notification', payload);
        this.io.emit('system-action-notification', payload);
    }

    emitAdminScopedNotification({
        type = 'system_action',
        title = 'VoiceLink System',
        message = '',
        severity = 'info',
        metadata = {}
    } = {}) {
        if (!this.io) return;
        const payload = {
            id: uuidv4(),
            type: String(type || 'system_action'),
            title: String(title || 'VoiceLink System'),
            message: String(message || ''),
            severity: String(severity || 'info'),
            timestamp: new Date().toISOString(),
            ...((metadata && typeof metadata === 'object') ? metadata : {})
        };

        const adminTargets = new Set();
        for (const [socketId, user] of this.users.entries()) {
            const role = String(user?.role || user?.authInfo?.role || '').toLowerCase();
            const isAdminLike = Boolean(user?.isAdmin || user?.isModerator || ['owner', 'admin', 'staff'].includes(role));
            if (isAdminLike) {
                adminTargets.add(socketId || user?.id);
            }
        }

        if (!adminTargets.size) {
            this.emitSystemActionNotification({
                type,
                title,
                message,
                severity,
                metadata
            });
            return;
        }

        for (const target of adminTargets) {
            if (!target) continue;
            this.io.to(target).emit('admin-notification', payload);
            this.io.to(target).emit('system-action-notification', payload);
        }
    }

    getConfiguredBackgroundStreamForRoom(room = {}) {
        const backgroundConfig = deployConfig.get('backgroundStreams') || {};
        if (backgroundConfig.enabled === false) return null;
        const streams = Array.isArray(backgroundConfig.streams) ? backgroundConfig.streams : [];
        const roomId = String(room.id || '').trim();
        const roomName = String(room.name || '').trim();
        const matchedStreams = [];

        const wildcardToRegex = (pattern = '') => new RegExp(`^${String(pattern)
            .replace(/[.+?^${}()|[\]\\]/g, '\\$&')
            .replace(/\*/g, '.*')}$`, 'i');

        for (const stream of streams) {
            if (!stream || stream.autoPlay === false) continue;
            const explicitRooms = Array.isArray(stream.rooms) ? stream.rooms.map((value) => String(value).trim()) : [];
            const patterns = Array.isArray(stream.roomPatterns) ? stream.roomPatterns : [];
            const matchesRoom = roomId && explicitRooms.includes(roomId);
            const matchesPattern = roomName && patterns.some((pattern) => {
                try {
                    return wildcardToRegex(pattern).test(roomName);
                } catch {
                    return false;
                }
            });
            if (!matchesRoom && !matchesPattern) continue;

            const streamUrl = String(stream.streamUrl || stream.url || '').trim();
            if (!streamUrl) continue;
            matchedStreams.push({
                id: String(stream.id || '').trim() || `background:${roomId || roomName}`,
                name: String(stream.name || 'Background Stream').trim() || 'Background Stream',
                streamUrl,
                volume: Number.isFinite(Number(stream.volume)) ? Number(stream.volume) : (Number.isFinite(Number(backgroundConfig.defaultVolume)) ? Number(backgroundConfig.defaultVolume) : null),
                hidden: !!stream.hidden
            });
        }

        if (matchedStreams.length === 0) {
            return null;
        }

        if (backgroundConfig.shuffleEnabled !== true || matchedStreams.length === 1) {
            return matchedStreams[0];
        }

        const intervalMinutes = Math.max(1, Number(backgroundConfig.shuffleIntervalMinutes) || 15);
        const slot = Math.floor(Date.now() / (intervalMinutes * 60 * 1000));
        const roomSeed = `${roomId}|${roomName}`;
        let hash = 0;
        for (let i = 0; i < roomSeed.length; i += 1) {
            hash = ((hash << 5) - hash) + roomSeed.charCodeAt(i);
            hash |= 0;
        }
        const index = Math.abs(hash + slot) % matchedStreams.length;
        return matchedStreams[index];
    }

    getMessageSettingsConfig() {
        const config = deployConfig.getConfig() || {};
        const messageSettings = config.messageSettings || {};
        return {
            keepRoomMessages: messageSettings.keepRoomMessages !== false,
            keepDirectMessages: messageSettings.keepDirectMessages !== false,
            initialLoadCount: Math.min(100, Math.max(1, Number(messageSettings.initialLoadCount || 20))),
            scrollbackLimit: Math.min(5000, Math.max(20, Number(messageSettings.scrollbackLimit || 5000))),
            roomMessageCap: Math.min(5000, Math.max(20, Number(messageSettings.roomMessageCap || 1000))),
            directMessageCap: Math.min(5000, Math.max(20, Number(messageSettings.directMessageCap || 500))),
            guestRetentionHours: Math.min(24 * 30, Math.max(1, Number(messageSettings.guestRetentionHours || 24))),
            authenticatedRetentionDays: Math.min(3650, Math.max(1, Number(messageSettings.authenticatedRetentionDays || 30))),
            deleteRoomMessagesWhenEmpty: !!messageSettings.deleteRoomMessagesWhenEmpty,
            keepAttachmentMessages: messageSettings.keepAttachmentMessages !== false,
            botMemoryMessageLimit: Math.min(5000, Math.max(0, Number(messageSettings.botMemoryMessageLimit || 250))),
            botMemoryDays: Math.min(3650, Math.max(1, Number(messageSettings.botMemoryDays || 30)))
        };
    }

    getMessageExpiryMs(isAuthenticated) {
        const settings = this.getMessageSettingsConfig();
        if (isAuthenticated) {
            return settings.authenticatedRetentionDays * 24 * 60 * 60 * 1000;
        }
        return settings.guestRetentionHours * 60 * 60 * 1000;
    }

    isTextLikeAttachment(message = {}) {
        const name = String(message.attachmentName || '').trim().toLowerCase();
        if (!name) return false;
        const textExtensions = [
            '.txt', '.md', '.markdown', '.json', '.csv', '.tsv', '.log',
            '.js', '.ts', '.jsx', '.tsx', '.html', '.htm', '.css',
            '.xml', '.yaml', '.yml', '.ini', '.cfg'
        ];
        return textExtensions.some(ext => name.endsWith(ext));
    }

    async fetchAttachmentTextPreview(message = {}, maxChars = 700) {
        const attachmentURL = String(message.attachmentURL || '').trim();
        if (!attachmentURL || !/^https?:\/\//i.test(attachmentURL)) {
            return null;
        }

        const timeout = this.withTimeoutSignal(6000);
        try {
            const response = await fetch(attachmentURL, {
                method: 'GET',
                signal: timeout.signal
            });
            if (!response.ok) {
                return null;
            }
            const text = await response.text();
            const normalized = String(text || '')
                .replace(/\r\n/g, '\n')
                .replace(/\n{3,}/g, '\n\n')
                .trim();
            if (!normalized) {
                return null;
            }
            return normalized.slice(0, maxChars);
        } catch (_error) {
            return null;
        } finally {
            timeout.clear();
        }
    }

    async buildBotAttachmentReply(user, message) {
        const attachmentName = String(message.attachmentName || 'attachment').trim();
        const caption = String(message.attachmentCaption || '').trim();

        if (!attachmentName && !message.attachmentURL) {
            return null;
        }

        const looksLikeFolderShare = /^\d+\s+files?$/i.test(attachmentName) || attachmentName.toLowerCase().includes('folder');
        if (looksLikeFolderShare) {
            return `${user.name || 'You'} shared ${attachmentName}. I can acknowledge multi-file shares here; deeper per-file processing can be enabled through the room bot modules.`;
        }

        if (this.isTextLikeAttachment(message)) {
            const preview = await this.fetchAttachmentTextPreview(message);
            if (preview) {
                const previewSummary = preview.length >= 700 ? `${preview}...` : preview;
                return `I inspected ${attachmentName}. Preview:\n${previewSummary}`;
            }
            return `I detected a text attachment named ${attachmentName}, but I could not read it from the shared link right now.`;
        }

        if (caption) {
            return `I received ${attachmentName}. Caption: ${caption}`;
        }

        return `I received ${attachmentName}. This room bot can acknowledge the file, but deeper processing for that file type is not enabled yet.`;
    }

    extractURLsFromText(text = '') {
        const value = String(text || '');
        const explicitMatches = value.match(/\bhttps?:\/\/[^\s<>"']+/gi) || [];
        const domainMatches = value.match(/\b(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,}(?:\/[^\s<>"']*)?/gi) || [];
        const combined = [...explicitMatches, ...domainMatches]
            .map(url => url.trim().replace(/[),.!?;:]+$/g, ''))
            .filter(Boolean)
            .filter(url => !url.includes('@'));
        const normalized = combined.map((url) => {
            if (/^https?:\/\//i.test(url)) {
                return url;
            }
            return `https://${url}`;
        });
        return Array.from(new Set(normalized));
    }

    async validateMessageURL(rawURL) {
        const value = String(rawURL || '').trim();
        if (!value) {
            return { valid: false, reason: 'empty link' };
        }
        const candidates = /^https?:\/\//i.test(value)
            ? [value]
            : [`https://${value}`, `http://${value}`];

        const isPrivateIPAddress = (host) => {
            const family = net.isIP(host);
            if (!family) {
                return false;
            }

            if (family === 4) {
                const parts = host.split('.').map(part => Number(part));
                const [a, b] = parts;
                if (a === 10 || a === 127 || a === 0) return true;
                if (a === 169 && b === 254) return true;
                if (a === 172 && b >= 16 && b <= 31) return true;
                if (a === 192 && b === 168) return true;
                if (a >= 224) return true;
                return false;
            }

            const lowered = host.toLowerCase();
            return lowered === '::1'
                || lowered.startsWith('fc')
                || lowered.startsWith('fd')
                || lowered.startsWith('fe80:')
                || lowered.startsWith('::ffff:127.');
        };

        let lastReason = 'invalid URL format';
        for (const candidate of candidates) {
            let parsed;
            try {
                parsed = new URL(candidate);
            } catch {
                lastReason = 'invalid URL format';
                continue;
            }

            if (!/^https?:$/i.test(parsed.protocol)) {
                lastReason = 'unsupported URL scheme';
                continue;
            }

            const hostname = String(parsed.hostname || '').toLowerCase();
            if (!hostname) {
                lastReason = 'missing hostname';
                continue;
            }

            if (hostname === 'localhost' || hostname.endsWith('.local')) {
                return { valid: false, reason: 'local-only address' };
            }

            if (isPrivateIPAddress(hostname)) {
                return { valid: false, reason: 'private or loopback address' };
            }

            const timeout = this.withTimeoutSignal(5000);
            try {
                let response = await fetch(parsed.toString(), {
                    method: 'HEAD',
                    redirect: 'follow',
                    signal: timeout.signal
                });

                if (response.status === 405 || response.status === 501) {
                    timeout.clear();
                    const retryTimeout = this.withTimeoutSignal(5000);
                    try {
                        response = await fetch(parsed.toString(), {
                            method: 'GET',
                            redirect: 'follow',
                            signal: retryTimeout.signal,
                            headers: {
                                Range: 'bytes=0-1024'
                            }
                        });
                    } finally {
                        retryTimeout.clear();
                    }
                }

                if (!response.ok) {
                    if (
                        response.status >= 500
                        || response.status === 429
                        || response.status === 401
                        || response.status === 403
                    ) {
                        return {
                            valid: true,
                            normalizedURL: parsed.toString(),
                            validationDeferred: true
                        };
                    }
                    lastReason = `remote server returned ${response.status}`;
                    continue;
                }

                return { valid: true, normalizedURL: response.url || parsed.toString() };
            } catch (error) {
                const message = String(error?.name || error?.message || '').toLowerCase();
                if (message.includes('abort') || message.includes('timeout')) {
                    return {
                        valid: true,
                        normalizedURL: parsed.toString(),
                        validationDeferred: true
                    };
                }
                return {
                    valid: true,
                    normalizedURL: parsed.toString(),
                    validationDeferred: true
                };
            } finally {
                timeout.clear();
            }
        }

        return { valid: false, reason: lastReason };
    }

    async sanitizeMessageLinks(message = {}, context = {}) {
        const originalContent = String(message.message || message.content || '').trim();
        const urls = this.extractURLsFromText(originalContent);
        if (!urls.length) {
            return { message, notice: null };
        }

        let sanitizedContent = originalContent;
        const invalidLinks = [];

        for (const url of urls) {
            const validation = await this.validateMessageURL(url);
            if (!validation.valid) {
                invalidLinks.push({ url, reason: validation.reason });
                sanitizedContent = sanitizedContent.split(url).join('[link removed]');
            }
        }

        if (!invalidLinks.length) {
            return { message, notice: null };
        }

        sanitizedContent = sanitizedContent.replace(/\s{2,}/g, ' ').trim();
        if (!sanitizedContent || sanitizedContent === '[link removed]') {
            sanitizedContent = '[link removed: invalid or unreachable]';
        }

        const updatedMessage = {
            ...message,
            message: sanitizedContent,
            content: sanitizedContent
        };

        const firstInvalid = invalidLinks[0];
        const actorName = context.actorName || message.userName || message.senderName || 'A user';
        const scopeLabel = context.roomName || context.channelName || 'this conversation';
        const notice = {
            id: uuidv4(),
            userId: context.noticeUserId || 'system',
            senderId: context.noticeUserId || 'system',
            userName: context.noticeUserName || 'System',
            senderName: context.noticeUserName || 'System',
            message: `${actorName}'s link was removed in ${scopeLabel}: ${firstInvalid.reason}.`,
            content: `${actorName}'s link was removed in ${scopeLabel}: ${firstInvalid.reason}.`,
            timestamp: new Date(),
            isAuthenticated: true,
            type: 'system',
            reactions: []
        };

        return { message: updatedMessage, notice };
    }

    findConnectedUserByName(query = '') {
        const needle = String(query || '').trim().toLowerCase();
        if (!needle) return null;
        for (const user of this.users.values()) {
            const candidates = [
                user.name,
                user.username,
                user.displayName,
                user.authInfo?.username,
                user.authInfo?.displayName,
                user.authInfo?.email
            ].map((value) => String(value || '').trim().toLowerCase()).filter(Boolean);
            if (candidates.some((value) => value === needle || value.includes(needle) || needle.includes(value))) {
                return user;
            }
        }
        return null;
    }

    describeConnectedUserLocation(query = '') {
        const user = this.findConnectedUserByName(query);
        if (!user) return null;
        if (user.roomId) {
            const room = this.rooms.get(user.roomId);
            return `${user.name || user.username || 'That user'} is in ${room?.name || 'a room'}.`;
        }
        return `${user.name || user.username || 'That user'} is online and browsing outside of a room.`;
    }

    describeCurrentRoomMedia(roomId) {
        const room = this.rooms.get(roomId);
        if (!room) return null;
        const configuredBackgroundStream = this.getConfiguredBackgroundStreamForRoom(room);
        if (configuredBackgroundStream?.streamUrl) {
            const streamTitle = configuredBackgroundStream.name || 'Background Stream';
            return `${room.name} is playing [${streamTitle}](${configuredBackgroundStream.streamUrl}).`;
        }
        const mediaRooms = this.modules?.mediaRooms;
        const active = mediaRooms?.getRoomPlaybackState ? mediaRooms.getRoomPlaybackState(roomId) : null;
        if (active?.title || active?.streamUrl) {
            const mediaTitle = active.title || 'Media';
            return active.streamUrl
                ? `${room.name} is playing [${mediaTitle}](${active.streamUrl}).`
                : `${room.name} is playing ${mediaTitle}.`;
        }
        return `${room.name} does not have active room media right now.`;
    }

    getBotConversationKey(roomId, userId) {
        return `${roomId || 'global'}:${userId || 'unknown'}`;
    }

    getRecentRoomConversationContext(roomId, limit = 8) {
        const messages = this.getRoomMessages(roomId, Math.max(1, limit * 3));
        return messages
            .filter(message => !message?.isBot)
            .slice(-limit)
            .map(message => {
                const speaker = message.userName || message.senderName || 'User';
                const content = String(message.message || message.content || '').trim();
                return content ? `${speaker}: ${content}` : null;
            })
            .filter(Boolean);
    }

    isBotConversationActive(roomId, userId) {
        const key = this.getBotConversationKey(roomId, userId);
        const state = this.botConversationState.get(key);
        if (!state) return false;
        return (Date.now() - state.lastAddressedAt) <= (10 * 60 * 1000);
    }

    updateBotConversationState(roomId, userId, source) {
        const key = this.getBotConversationKey(roomId, userId);
        this.botConversationState.set(key, {
            lastAddressedAt: Date.now(),
            lastPrompt: String(source || '').trim()
        });
    }

    normalizeBotFingerprint(source = '') {
        return String(source || '')
            .toLowerCase()
            .replace(/\s+/g, ' ')
            .trim();
    }

    getBotConversationMemory(roomId, userId, limit = 8) {
        const key = this.getBotConversationKey(roomId, userId);
        const state = this.botConversationState.get(key);
        if (!state || !Array.isArray(state.history)) return [];
        return state.history.slice(-Math.max(1, limit));
    }

    rememberBotTurn(roomId, userId, role, content) {
        const key = this.getBotConversationKey(roomId, userId);
        const existing = this.botConversationState.get(key) || {};
        const history = Array.isArray(existing.history) ? existing.history.slice(-11) : [];
        const trimmed = String(content || '').trim();
        if (!trimmed) return;
        history.push({
            role: role === 'assistant' ? 'assistant' : 'user',
            content: trimmed,
            at: Date.now()
        });
        this.botConversationState.set(key, {
            ...existing,
            lastAddressedAt: Date.now(),
            lastPrompt: role === 'user' ? trimmed : existing.lastPrompt,
            history
        });
    }

    getBotOllamaConfig() {
        return {
            host: String(process.env.OLLAMA_HOST || 'http://127.0.0.1:11434').trim().replace(/\/+$/, ''),
            enabled: String(process.env.VOICELINK_BOT_OLLAMA_ENABLED || 'true').trim().toLowerCase() !== 'false',
            conversationModel: String(process.env.VOICELINK_BOT_OLLAMA_CONVERSATION_MODEL || 'qwen2.5:7b').trim(),
            codingModel: String(process.env.VOICELINK_BOT_OLLAMA_CODING_MODEL || 'qwen2.5:7b').trim(),
            researchModel: String(process.env.VOICELINK_BOT_OLLAMA_RESEARCH_MODEL || 'gpt-oss:20b').trim(),
            timeoutMs: Math.max(4000, Number(process.env.VOICELINK_BOT_OLLAMA_TIMEOUT_MS) || 15000)
        };
    }

    classifyBotPromptIntent(source = '') {
        const lowered = String(source || '').toLowerCase();
        const codingPatterns = [
            'code', 'coding', 'debug', 'bug', 'stack trace', 'exception', 'swift', 'javascript', 'typescript',
            'python', 'php', 'node', 'api', 'endpoint', 'json', 'yaml', 'regex', 'compile', 'build error',
            'function', 'class ', 'sql', 'schema', 'docker', 'nginx', 'pm2', 'git ', 'commit', 'patch'
        ];
        const researchPatterns = [
            'research', 'compare', 'explain', 'how does', 'how do', 'what is', 'why does', 'summarize',
            'walk me through', 'teach me', 'best way', 'recommend', 'pros and cons'
        ];
        if (codingPatterns.some((pattern) => lowered.includes(pattern))) return 'coding';
        if (researchPatterns.some((pattern) => lowered.includes(pattern))) return 'research';
        return 'conversation';
    }

    selectOllamaModelForBotPrompt(source = '') {
        const config = this.getBotOllamaConfig();
        const intent = this.classifyBotPromptIntent(source);
        if (intent === 'coding') return { intent, model: config.codingModel || config.conversationModel };
        if (intent === 'research') return { intent, model: config.researchModel || config.conversationModel };
        return { intent, model: config.conversationModel };
    }

    async isBotOllamaAvailable(force = false) {
        const config = this.getBotOllamaConfig();
        if (!config.enabled) return false;
        const now = Date.now();
        if (!force && this.botOllamaHealth.available !== null && (now - this.botOllamaHealth.checkedAt) < 30000) {
            return this.botOllamaHealth.available;
        }
        try {
            const controller = new AbortController();
            const timer = setTimeout(() => controller.abort(), Math.min(config.timeoutMs, 5000));
            const response = await fetch(`${config.host}/api/tags`, { method: 'GET', signal: controller.signal });
            clearTimeout(timer);
            this.botOllamaHealth = { checkedAt: now, available: response.ok };
            return response.ok;
        } catch (error) {
            this.botOllamaHealth = { checkedAt: now, available: false };
            return false;
        }
    }

    buildBotOllamaPrompt({ user, room, roomPurpose, motd, source, recentContext, memory }) {
        const userName = user?.name || user?.username || 'User';
        const roomName = room?.name || 'this room';
        const memoryLines = memory.map((entry) => `${entry.role === 'assistant' ? 'VoiceLink Bot' : userName}: ${entry.content}`);
        const roomLines = recentContext.slice(-6);
        return [
            'You are VoiceLink Bot inside a live voice/chat room.',
            'Be conversational, concise, and useful.',
            'Do not use stiff fallback wording when a user starts a normal conversation.',
            'Prefer answering normally first. Only offer next-step help after the main answer.',
            'If the question is about coding, answer like a practical engineer.',
            `Room: ${roomName}`,
            `Room purpose: ${roomPurpose}`,
            motd ? `Message of the day: ${motd}` : null,
            roomLines.length ? `Recent room context:\n${roomLines.join('\n')}` : null,
            memoryLines.length ? `Conversation memory:\n${memoryLines.join('\n')}` : null,
            `Latest user message from ${userName}: ${String(source || '').trim()}`
        ].filter(Boolean).join('\n\n');
    }

    async generateBotOllamaReply(user, roomId, source = '') {
        const config = this.getBotOllamaConfig();
        if (!config.enabled) return null;
        const available = await this.isBotOllamaAvailable();
        if (!available) return null;

        const room = this.rooms.get(roomId);
        const deploy = deployConfig.getConfig() || {};
        const motd = typeof deploy.server?.motd === 'string' ? deploy.server.motd.trim() : '';
        const roomDescription = typeof room?.description === 'string' ? room.description.trim() : '';
        const serverName = deploy.server?.name || 'VoiceLink';
        const roomPurpose = roomDescription || `${room?.name || 'This room'} is part of ${serverName}.`;
        const recentContext = this.getRecentRoomConversationContext(roomId, 6);
        const memory = this.getBotConversationMemory(roomId, user?.id || user?.userId || user?.socketId || user?.name, 8);
        const { model, intent } = this.selectOllamaModelForBotPrompt(source);
        const prompt = this.buildBotOllamaPrompt({ user, room, roomPurpose, motd, source, recentContext, memory });

        try {
            const controller = new AbortController();
            const timer = setTimeout(() => controller.abort(), config.timeoutMs);
            const response = await fetch(`${config.host}/api/generate`, {
                method: 'POST',
                headers: { 'Content-Type': 'application/json', 'Accept': 'application/json' },
                signal: controller.signal,
                body: JSON.stringify({
                    model,
                    prompt,
                    stream: false,
                    options: { temperature: intent === 'coding' ? 0.2 : 0.5 }
                })
            });
            clearTimeout(timer);
            if (!response.ok) return null;
            const data = await response.json().catch(() => ({}));
            const reply = String(data?.response || '').trim();
            return reply || null;
        } catch (error) {
            return null;
        }
    }

    rememberBotReply(roomId, userId, prompt, reply) {
        const now = Date.now();
        const normalizedPrompt = this.normalizeBotFingerprint(prompt);
        const normalizedReply = this.normalizeBotFingerprint(reply);
        const roomKey = `room:${roomId || 'global'}`;
        const userKey = `user:${roomId || 'global'}:${userId || 'unknown'}`;
        const payload = {
            at: now,
            prompt: normalizedPrompt,
            reply: normalizedReply
        };
        this.botResponseMemory.set(roomKey, payload);
        this.botResponseMemory.set(userKey, payload);

        if (this.botResponseMemory.size > 2500) {
            const cutoff = now - (10 * 60 * 1000);
            for (const [key, value] of this.botResponseMemory.entries()) {
                if (!value?.at || value.at < cutoff) {
                    this.botResponseMemory.delete(key);
                }
            }
        }
    }

    shouldSuppressBotReply(roomId, userId, prompt, reply, explicitBotAddress = false) {
        const now = Date.now();
        const normalizedPrompt = this.normalizeBotFingerprint(prompt);
        const normalizedReply = this.normalizeBotFingerprint(reply);
        if (!normalizedReply) return true;

        const roomKey = `room:${roomId || 'global'}`;
        const userKey = `user:${roomId || 'global'}:${userId || 'unknown'}`;
        const roomState = this.botResponseMemory.get(roomKey);
        const userState = this.botResponseMemory.get(userKey);

        const rapidDuplicateUserReply =
            !!userState
            && userState.reply === normalizedReply
            && (now - userState.at) < 90000;

        const repeatedPromptBurst =
            !!userState
            && normalizedPrompt
            && userState.prompt === normalizedPrompt
            && (now - userState.at) < 45000;

        const rapidDuplicateRoomReply =
            !explicitBotAddress
            && !!roomState
            && roomState.reply === normalizedReply
            && (now - roomState.at) < 25000;

        const mirroredPrompt = normalizedPrompt && normalizedPrompt === normalizedReply;

        if (rapidDuplicateUserReply || repeatedPromptBurst || rapidDuplicateRoomReply || mirroredPrompt) {
            return true;
        }

        this.rememberBotReply(roomId, userId, prompt, reply);
        return false;
    }

    dismissBotConversation(roomId, userId) {
        this.botConversationState.delete(this.getBotConversationKey(roomId, userId));
    }

    getBotCommandRole(user = {}) {
        const explicitRole = user?.authInfo?.role || user?.role;
        if (explicitRole) {
            return this.normalizeUserRole(explicitRole);
        }
        if (user?.isAuthenticated) {
            return 'user';
        }
        return 'visitor';
    }

    getBotCommandPermissions(user = {}, destination = {}) {
        const role = this.getBotCommandRole(user);
        const normalizedRole = this.normalizeUserRole(role);
        const isAuthenticated = !!(user?.isAuthenticated || user?.authInfo?.isAuthenticated || user?.authInfo?.email || user?.authInfo?.username);
        const isPrivileged = normalizedRole === 'owner' || normalizedRole === 'admin' || normalizedRole === 'staff';
        const userId = String(user?.id || user?.userId || '').trim();
        const currentRoomId = String(user?.roomId || '').trim();
        const sameRoomTarget = destination?.type === 'room' && String(destination.roomId || '') === currentRoomId;
        const selfTarget = destination?.type === 'user' && String(destination.userId || '') === userId;

        if (isPrivileged) {
            return {
                allowed: true,
                role: normalizedRole,
                policy: 'full'
            };
        }

        if (!isAuthenticated) {
            return {
                allowed: false,
                role: normalizedRole,
                policy: 'guest',
                reason: 'You must be signed in to run bot file commands.'
            };
        }

        if (sameRoomTarget || selfTarget) {
            return {
                allowed: true,
                role: normalizedRole,
                policy: 'self_service'
            };
        }

        return {
            allowed: false,
            role: normalizedRole,
            policy: 'self_service',
            reason: 'Your current role can only generate files for your current room or yourself.'
        };
    }

    findConnectedRoomByName(query = '') {
        const needle = String(query || '').trim().toLowerCase();
        if (!needle) return null;
        for (const room of this.rooms.values()) {
            const candidates = [
                room.id,
                room.name,
                room.description
            ].map((value) => String(value || '').trim().toLowerCase()).filter(Boolean);
            if (candidates.some((value) => value === needle || value.includes(needle) || needle.includes(value))) {
                return room;
            }
        }
        return null;
    }

    parseBotCommandDestination(source = '', currentRoomId = null) {
        const text = String(source || '').trim();
        const lowered = text.toLowerCase();
        const defaultRoom = this.rooms.get(currentRoomId);
        const destination = {
            type: 'room',
            roomId: currentRoomId,
            roomName: defaultRoom?.name || currentRoomId || 'current room',
            fromPattern: 'default'
        };

        if (/\b(to|in|into)\s+(this|current)\s+room\b/i.test(lowered) || /\b(send|upload)\s+here\b/i.test(lowered)) {
            return destination;
        }

        const roomMatch = text.match(/\b(?:to|in|into)\s+room\s+["“]?([^"\n]+?)["”]?(?:\s|$)/i);
        if (roomMatch?.[1]) {
            const targetRoom = this.findConnectedRoomByName(roomMatch[1]);
            if (targetRoom?.id) {
                return {
                    type: 'room',
                    roomId: targetRoom.id,
                    roomName: targetRoom.name || targetRoom.id,
                    fromPattern: 'named_room'
                };
            }
        }

        const explicitUserMatch = text.match(/\b(?:to|for|dm|message)\s+user\s+@?([a-z0-9_.@-]{2,80})\b/i);
        const mentionCandidates = Array.from(text.matchAll(/@([a-z0-9_.-]{2,64})/gi)).map((match) => match[1]);
        const mentionTarget = mentionCandidates.find((value) => !/^voicelink$/i.test(value) && !/^bot$/i.test(value));
        const userQuery = explicitUserMatch?.[1] || mentionTarget || null;
        if (userQuery) {
            const targetUser = this.findConnectedUserByName(userQuery);
            if (targetUser?.id) {
                return {
                    type: 'user',
                    userId: targetUser.id,
                    userName: targetUser.name || targetUser.username || userQuery,
                    roomId: currentRoomId,
                    fromPattern: explicitUserMatch?.[1] ? 'explicit_user' : 'mention_user'
                };
            }
        }

        return destination;
    }

    deliverBotFileToDestination(destination = {}, sourceRoomId, replyMessage = '', attachmentName = null, attachmentURL = null) {
        if (!attachmentName || !attachmentURL) {
            return;
        }

        if (destination.type === 'user' && destination.userId) {
            const timestamp = new Date();
            const senderId = `bot:${sourceRoomId || 'global'}`;
            const dmMessage = {
                id: uuidv4(),
                senderId,
                senderName: 'VoiceLink Bot',
                receiverId: destination.userId,
                message: replyMessage || `Generated and uploaded ${attachmentName}.`,
                content: replyMessage || `Generated and uploaded ${attachmentName}.`,
                timestamp,
                isAuthenticated: true,
                isBot: true,
                authProvider: 'voicelink_bot',
                type: 'text',
                attachmentName,
                attachmentURL,
                reactions: [],
                read: false
            };
            this.storeDirectMessage(senderId, destination.userId, dmMessage);
            this.io.to(destination.userId).emit('direct-message', dmMessage);
            return;
        }

        if (destination.type === 'room' && destination.roomId && destination.roomId !== sourceRoomId) {
            const botMessage = {
                id: uuidv4(),
                userId: `bot:${destination.roomId}`,
                userName: 'VoiceLink Bot',
                message: replyMessage || `Generated and uploaded ${attachmentName}.`,
                timestamp: new Date(),
                isAuthenticated: true,
                isBot: true,
                authProvider: 'voicelink_bot',
                attachmentName,
                attachmentURL,
                reactions: []
            };
            this.storeRoomMessage(destination.roomId, botMessage);
            this.io.to(destination.roomId).emit('chat-message', botMessage);
        }
    }

    async uploadFileToCopyParty(filePath, fileName, contentType = 'application/octet-stream') {
        const config = this.getCopyPartyExportConfig();
        if (!config.enabled) {
            return { uploaded: false, reason: 'CopyParty not configured' };
        }

        const uploadUrl = `${config.baseUrl}${config.exportPath}/${encodeURIComponent(fileName)}`;
        const headers = { 'Content-Type': contentType };
        if (config.username) {
            const auth = Buffer.from(`${config.username}:${config.password || ''}`).toString('base64');
            headers.Authorization = `Basic ${auth}`;
        }

        const response = await fetch(uploadUrl, {
            method: 'PUT',
            headers,
            body: fs.readFileSync(filePath)
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

    async executeRoomBotCommand(user, roomId, source = '') {
        const normalized = String(source || '').trim();
        const lowered = normalized.toLowerCase();
        const addressed = lowered.includes('@voicelink') || lowered.includes('@voicelink bot') || lowered.startsWith('/bot') || lowered.startsWith('/vb');
        if (!addressed) return { handled: false };
        const asksRole =
            lowered.includes('my role')
            || lowered.includes('current role')
            || lowered.includes('what role')
            || lowered.includes('which role')
            || lowered.includes('what can i do');
        if (asksRole) {
            const role = this.getBotCommandRole(user);
            const policy = this.getBotCommandPermissions(user, { type: 'room', roomId });
            const accessLine = policy.policy === 'full'
                ? 'You can run bot exports to any room or user.'
                : policy.policy === 'self_service'
                    ? 'You can run bot exports for your current room or yourself.'
                    : 'You need to sign in before using bot file commands.';
            return {
                handled: true,
                reply: `Your current role is ${role}. ${accessLine}`
            };
        }

        const asksGenerateText = lowered.includes('generate text file') || lowered.includes('create text file');
        const asksUpload = lowered.includes('upload') || lowered.includes('send');
        if (!asksGenerateText && !asksUpload) {
            return { handled: false };
        }

        const destination = this.parseBotCommandDestination(normalized, roomId);
        const permissions = this.getBotCommandPermissions(user, destination);
        if (!permissions.allowed) {
            return {
                handled: true,
                reply: `Command denied. ${permissions.reason || 'You do not have permission to run this command.'}`
            };
        }

        if (!asksGenerateText) {
            return {
                handled: true,
                reply: 'I can generate and upload text files now. Example: "@voicelink generate text file of recent room updates and upload to this room" or "... send to @username".'
            };
        }

        const targetRoomId = destination.type === 'room' && destination.roomId ? destination.roomId : roomId;
        const room = this.rooms.get(targetRoomId) || this.rooms.get(roomId);
        const recentContext = this.getRecentRoomConversationContext(targetRoomId, 14);
        const now = new Date().toISOString();
        const titleLine = `VoiceLink Bot Export - ${room?.name || roomId}`;
        const bodyLines = [
            titleLine,
            `Generated: ${now}`,
            `Requested by: ${user?.name || user?.username || 'User'}`,
            `Requested role: ${permissions.role}`,
            `Delivery target: ${destination.type === 'user' ? `user:${destination.userName || destination.userId}` : `room:${destination.roomName || destination.roomId}`}`,
            '',
            'Recent conversation:',
            ...(recentContext.length ? recentContext : ['No recent conversation captured.'])
        ];
        const textContent = bodyLines.join('\n');

        const exportDir = path.join(__dirname, '../../data/exports');
        fs.mkdirSync(exportDir, { recursive: true });
        const fileName = `${this.sanitizeExportSegment(room?.name || 'room', 'room')}-notes-${Date.now()}.txt`;
        const filePath = path.join(exportDir, fileName);
        fs.writeFileSync(filePath, textContent, 'utf8');

        try {
            const upload = await this.uploadFileToCopyParty(filePath, fileName, 'text/plain; charset=utf-8');
            if (!upload.uploaded || !upload.url) {
                return {
                    handled: true,
                    reply: 'I generated the text file but could not upload it because CopyParty export is not configured.'
                };
            }
            this.deliverBotFileToDestination(
                destination,
                roomId,
                `Generated and uploaded ${fileName}.`,
                fileName,
                upload.url
            );
            const deliveredToCurrentRoom = destination.type === 'room' && destination.roomId === roomId;
            const deliveryLabel = destination.type === 'user'
                ? `user ${destination.userName || destination.userId}`
                : `room ${destination.roomName || destination.roomId}`;
            return {
                handled: true,
                reply: `Generated and uploaded ${fileName} to ${deliveryLabel}.`,
                attachmentName: deliveredToCurrentRoom ? fileName : null,
                attachmentURL: deliveredToCurrentRoom ? upload.url : null
            };
        } catch (error) {
            return {
                handled: true,
                reply: `I generated the text file but upload failed: ${error.message}`
            };
        }
    }

    isLikelyBotFollowUp(source = '') {
        const text = String(source || '').trim();
        if (!text || text.length < 3) return false;
        const lowered = text.toLowerCase();
        if (lowered.startsWith('/bot') || lowered.startsWith('/vb') || /@voicelink(?:\s+bot)?\b/.test(lowered)) {
            return true;
        }
        if (text.length < 8) return false;
        return /^(what about|how about|can you|could you|would you|please|tell me|show me|explain|summarize|list|continue|also|and)\b/.test(lowered);
    }

    decodeHtmlEntities(input = '') {
        return String(input || '')
            .replace(/&amp;/gi, '&')
            .replace(/&lt;/gi, '<')
            .replace(/&gt;/gi, '>')
            .replace(/&quot;/gi, '"')
            .replace(/&#39;/gi, "'")
            .replace(/&nbsp;/gi, ' ')
            .replace(/\s+/g, ' ')
            .trim();
    }

    async fetchLinkContext(rawURL = '') {
        const candidate = String(rawURL || '').trim();
        if (!candidate) return null;

        const validation = await this.validateMessageURL(candidate);
        if (!validation.valid) return null;
        const url = validation.normalizedURL || candidate;

        const timeout = this.withTimeoutSignal(6000);
        try {
            const response = await fetch(url, {
                method: 'GET',
                redirect: 'follow',
                signal: timeout.signal,
                headers: {
                    'User-Agent': 'Mozilla/5.0 (VoiceLink Bot)',
                    Accept: 'text/html,application/xhtml+xml'
                }
            });
            if (!response.ok) return null;

            const contentType = String(response.headers.get('content-type') || '').toLowerCase();
            if (!contentType.includes('text/html')) return null;

            const html = String(await response.text() || '').slice(0, 160000);
            if (!html) return null;

            const readMeta = (propertyName) => {
                const escaped = propertyName.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
                const patterns = [
                    new RegExp(`<meta[^>]+property=["']${escaped}["'][^>]+content=["']([^"']+)["'][^>]*>`, 'i'),
                    new RegExp(`<meta[^>]+name=["']${escaped}["'][^>]+content=["']([^"']+)["'][^>]*>`, 'i'),
                    new RegExp(`<meta[^>]+content=["']([^"']+)["'][^>]+property=["']${escaped}["'][^>]*>`, 'i'),
                    new RegExp(`<meta[^>]+content=["']([^"']+)["'][^>]+name=["']${escaped}["'][^>]*>`, 'i')
                ];
                for (const pattern of patterns) {
                    const match = html.match(pattern);
                    if (match?.[1]) return this.decodeHtmlEntities(match[1]);
                }
                return null;
            };

            const titleMatch = html.match(/<title[^>]*>([^<]+)<\/title>/i);
            const title = readMeta('og:title') || (titleMatch?.[1] ? this.decodeHtmlEntities(titleMatch[1]) : null);
            const description = readMeta('og:description') || readMeta('description');
            let host = null;
            try {
                host = new URL(response.url || url).host;
            } catch (_error) {
                host = null;
            }

            return {
                host,
                title: title || null,
                description: description || null,
                url: response.url || url
            };
        } catch (_error) {
            return null;
        } finally {
            timeout.clear();
        }
    }

    getClawXDownloadBaseUrl() {
        const configured = String(
            process.env.CLAWX_DOWNLOAD_BASE_URL
            || process.env.VOICELINK_CLAWX_DOWNLOAD_BASE
            || 'https://devinecreations.net/downloads/clawx'
        ).trim();
        return configured.replace(/\/+$/, '');
    }

    getClawXDownloadLinks() {
        const base = this.getClawXDownloadBaseUrl();
        return {
            latestWindows: `${base}/ClawX-windows-latest.exe`,
            latestMacIntel: `${base}/ClawX-macOS-Intel-latest.zip`,
            windowsX64: `${base}/ClawX-0.1.23-win-x64.exe`,
            windowsArm64: `${base}/ClawX-0.1.23-win-arm64.exe`,
            windowsCombined: `${base}/ClawX-0.1.23-win.exe`,
            macIntel: `${base}/ClawX-0.1.23-mac-x64.zip`,
            macAppleSilicon: `${base}/ClawX-0.1.23-mac-arm64.zip`
        };
    }

    inferRequestedOSFromText(source = '') {
        const lowered = String(source || '').toLowerCase();
        if (!lowered) return null;

        if (/\b(win|windows|win10|win11|pc)\b/.test(lowered)) return 'windows';
        if (/\b(mac|macos|osx)\b/.test(lowered)) {
            if (/\b(intel|x64)\b/.test(lowered)) return 'mac-intel';
            if (/\b(apple silicon|arm64|m1|m2|m3|m4)\b/.test(lowered)) return 'mac-arm';
            return 'mac';
        }
        if (/\b(linux|ubuntu|debian|fedora|arch)\b/.test(lowered)) return 'linux';
        return null;
    }

    inferClientOSFromUser(user = {}) {
        const platformCandidate = String(
            user?.platform
            || user?.deviceInfo?.platform
            || user?.authInfo?.platform
            || ''
        ).toLowerCase();
        if (!platformCandidate) return null;

        if (platformCandidate.includes('win')) return 'windows';
        if (platformCandidate.includes('mac') || platformCandidate.includes('darwin')) return 'mac';
        if (platformCandidate.includes('linux')) return 'linux';
        return null;
    }

    buildClawXDownloadReply(user = {}, source = '') {
        const links = this.getClawXDownloadLinks();
        const explicitOS = this.inferRequestedOSFromText(source);
        const inferredOS = explicitOS || this.inferClientOSFromUser(user);

        if (inferredOS === 'windows') {
            return `ClawX for Windows: [Latest Windows build](${links.latestWindows}), [Windows x64](${links.windowsX64}), and [Windows ARM64](${links.windowsArm64}).`;
        }
        if (inferredOS === 'mac-intel') {
            return `ClawX for Intel macOS: [Intel macOS build](${links.latestMacIntel}).`;
        }
        if (inferredOS === 'mac-arm') {
            return `ClawX for Apple Silicon macOS: [Apple Silicon build](${links.macAppleSilicon}).`;
        }
        if (inferredOS === 'mac') {
            return `ClawX for macOS: [Intel build](${links.latestMacIntel}) or [Apple Silicon build](${links.macAppleSilicon}).`;
        }
        if (inferredOS === 'linux') {
            return `ClawX Linux package is not published yet in this channel. Current releases are [Windows](${links.latestWindows}) and [Intel macOS](${links.latestMacIntel}).`;
        }

        return `ClawX downloads: [Windows](${links.latestWindows}), [Intel macOS](${links.latestMacIntel}), and [Apple Silicon macOS](${links.macAppleSilicon}). Tell me your OS and I will return one exact link.`;
    }

    async buildBotTextReply(user, roomId, source = '') {
        const room = this.rooms.get(roomId);
        const users = this.normalizeRoomUsers(roomId);
        const config = deployConfig.getConfig() || {};
        const motd = typeof config.server?.motd === 'string' ? config.server.motd.trim() : '';
        const roomDescription = typeof room?.description === 'string' ? room.description.trim() : '';
        const serverName = config.server?.name || 'VoiceLink';
        const roomPurpose = roomDescription || `${room?.name || 'This room'} is part of ${serverName}.`;
        const recentContext = this.getRecentRoomConversationContext(roomId);
        const lowered = String(source || '').trim().toLowerCase();
        const conversationalGreeting = lowered
            .replace(/@voicelink\b/g, '')
            .replace(/@voicelink\s+bot\b/g, '')
            .replace(/voicelink\s+bot\b/g, '')
            .replace(/[!,.?]/g, ' ')
            .replace(/\s+/g, ' ')
            .trim();
        const sourceLinks = this.extractURLsFromText(source || '');

        const asksClawX =
            lowered.includes('clawx')
            || lowered.includes('openclaw app')
            || lowered.includes('download clawx')
            || lowered.includes('install clawx')
            || lowered.includes('openclaw desktop');
        if (asksClawX) {
            return this.buildClawXDownloadReply(user, source);
        }

        if (sourceLinks.length) {
            const linkContext = await this.fetchLinkContext(sourceLinks[0]);
            if (linkContext) {
                const segments = [];
                if (linkContext.host) {
                    segments.push(`${linkContext.host}`);
                }
                if (linkContext.title) {
                    segments.push(`Title: ${linkContext.title}.`);
                }
                if (linkContext.description) {
                    segments.push(`Summary: ${linkContext.description.slice(0, 260)}${linkContext.description.length > 260 ? '…' : ''}`);
                }
                if (segments.length) {
                    return segments.join(' ');
                }
            }
            return 'I saw that link. I could not fetch the page summary right now.';
        }

        if (
            lowered.includes("what's new")
            || lowered.includes("whats new")
            || lowered.includes("latest update")
            || lowered.includes("latest updates")
            || lowered.includes("new features")
            || lowered.includes("latest info")
        ) {
            const highlights = [
                'Room details now use the full in-room actions/details panel.',
                'Chat link previews support bare domains and show titles faster.',
                'Bot replies are less repetitive and now summarize posted links.',
                'Startup + status-menu behavior was tuned for smoother room return.'
            ];
            const roomStatus = `${room?.name || 'This room'} currently has ${users.length} participant${users.length === 1 ? '' : 's'}.`;
            const mediaStatus = this.describeCurrentRoomMedia(roomId);
            const motdLine = motd ? `Message of the day: ${motd}` : 'No message of the day is currently configured.';
            return `Latest VoiceLink updates: ${highlights.join(' ')} ${roomStatus} ${mediaStatus} ${motdLine}`;
        }

        if (!conversationalGreeting || conversationalGreeting === 'hi' || conversationalGreeting === 'hello' || conversationalGreeting === 'hey') {
            const contextParts = [roomPurpose];
            if (motd) {
                contextParts.push(`Message of the day: ${motd}`);
            }
            return `${serverName}. ${contextParts.join(' ')} If you want, I can tell you what this room is for, what media is playing, or how to do something here.`;
        }
        if (lowered.includes('help')) {
            return 'Commands: /me action, /bot help, /vb help, /bot status, /vb status, /bot users, /bot motd, /bot server. If you want, I can also tell you what this room is about, what media is playing, or which download to use.';
        }
        if (
            lowered.includes('what is this room about') ||
            lowered.includes('what is this room for') ||
            lowered.includes('about this room') ||
            lowered.includes('room about') ||
            lowered.includes('room purpose')
        ) {
            const messageBits = [
                `${room?.name || 'This room'} is hosted by ${serverName}.`,
                roomPurpose
            ];
            if (motd) {
                messageBits.push(`Message of the day: ${motd}`);
            }
            return messageBits.join(' ');
        }
        if (lowered.includes('status')) {
            return `${room?.name || 'This room'} currently has ${users.length} participant${users.length === 1 ? '' : 's'} and is ${room?.isPrivate ? 'private' : 'public'}. If you want, I can tell you who is here or what is active in the room.`;
        }
        if (lowered.includes('users') || lowered.includes('who')) {
            if (lowered.includes('where is ') || lowered.startsWith('where ')) {
                const query = lowered
                    .replace('/vb', '')
                    .replace('/bot', '')
                    .replace('/voicebot', '')
                    .replace('@voicelink bot', '')
                    .replace('where is', '')
                    .replace('where', '')
                    .trim();
                const locationReply = this.describeConnectedUserLocation(query);
                if (locationReply) {
                    return locationReply;
                }
            }
            const names = users.map(entry => entry.displayName || entry.username || entry.name).slice(0, 10);
            return names.length ? `In room: ${names.join(', ')}. If you want, I can tell you more about one of them.` : 'No users are currently in this room.';
        }
        if (lowered.includes('playing') || lowered.includes('media') || lowered.includes('music') || lowered.includes('stream') || lowered.includes('song')) {
            return this.describeCurrentRoomMedia(roomId);
        }
        if (lowered.includes('motd')) {
            return motd ? `Message of the day: ${motd}` : 'No message of the day is currently configured.';
        }
        if (lowered.includes('admin') || lowered.includes('manage')) {
            if (user?.authInfo?.role === 'admin' || user?.authInfo?.role === 'owner' || user?.isAuthenticated) {
                return 'I can explain safe admin actions and, when server policy allows it, help with room status, media status, moderation prompts, and guided management steps.';
            }
            return 'Admin actions are only available to authorized administrators and moderators.';
        }
        if (lowered.includes('server')) {
            return `${serverName} allows up to ${config.server?.maxUsers || config.rooms?.maxUsers || 500} users and ${config.rooms?.maxRooms || 100} rooms.`;
        }
        if (lowered.includes('composr')) {
            const roomSpecific = roomDescription
                ? `This room is used for people to learn about the CMS, chat about features, and work on development around it. ${roomPurpose}`
                : `This room is used for people to learn about the CMS, chat about features, and work on development around it.`;
            return `Composr is a PHP-based CMS and community platform with built-in forums, member features, permissions, and extensibility. ${roomSpecific} If you want, I can tell you how to set it up, structure content, handle permissions, or connect it to VoiceLink.`;
        }
        if (lowered.includes('topic') || lowered.includes('research') || lowered.includes('tell me about')) {
            const localFirstReply = this.buildLocalTopicResearchReply(user, roomId, source);
            if (localFirstReply) {
                return localFirstReply;
            }
            return `${roomPurpose} If you want, I can tell you how to work with this room's subject, the current media, server context, or a named topic like Composr.`;
        }
        if (lowered === 'test' || lowered === 'testing' || lowered === 'ping') {
            return `Message received. If you want, I can help with something in ${room?.name || 'this room'}.`;
        }

        if (recentContext.length) {
            return `I got that. If you want, I can help with something in ${room?.name || 'this room'}.`;
        }

        return `I got your message. If you want, I can help with room status, users, media, or the next step here.`;
    }

    getDefaultLobbyWelcomeMessage() {
        return 'WELCOME! PICK A ROOM TO JOIN! IF ITS EMPTY, YOU CAN INVITE SOMEONE FROM THE MENU.\n\nHAVE FUN! HAPPY CHATTING!';
    }

    formatDurationWords(totalSeconds) {
        const seconds = Math.max(0, Number(totalSeconds) || 0);
        const days = Math.floor(seconds / 86400);
        const hours = Math.floor((seconds % 86400) / 3600);
        const minutes = Math.floor((seconds % 3600) / 60);
        const parts = [];
        if (days) parts.push(`${days} day${days === 1 ? '' : 's'}`);
        if (hours) parts.push(`${hours} hour${hours === 1 ? '' : 's'}`);
        if (minutes || parts.length === 0) parts.push(`${minutes} minute${minutes === 1 ? '' : 's'}`);
        return parts.slice(0, 2).join(', ');
    }

    buildWelcomeTemplateContext({ user = null, room = null, config = null } = {}) {
        const resolvedConfig = config || deployConfig.getConfig() || {};
        const roomUsers = room?.id ? this.normalizeRoomUsers(room.id) : [];
        const lastActiveUser = roomUsers.length
            ? [...roomUsers].sort((left, right) => {
                const leftTime = left?.lastActiveAt ? new Date(left.lastActiveAt).getTime() : 0;
                const rightTime = right?.lastActiveAt ? new Date(right.lastActiveAt).getTime() : 0;
                return rightTime - leftTime;
            })[0]
            : null;
        const motd = typeof resolvedConfig.server?.motd === 'string' ? resolvedConfig.server.motd.trim() : '';
        const publicUrl = String(resolvedConfig.server?.publicUrl || '').replace(/\/+$/, '');
        const supportLink = (() => {
            if (!publicUrl) {
                return '/docs/contact.html';
            }
            try {
                const host = new URL(publicUrl).host?.toLowerCase() || '';
                if (host === 'voicelink.devinecreations.net' || host === 'www.voicelink.devinecreations.net') {
                    return 'https://devine-creations.com/contact';
                }
            } catch (_) {
                // Ignore parse errors and fall back to the local support page.
            }
            return `${publicUrl}/docs/contact.html`;
        })();
        return {
            user_name: user?.name || user?.displayName || 'Guest',
            display_name: user?.displayName || user?.name || 'Guest',
            room_name: room?.name || '',
            room_description: room?.description || '',
            server_name: resolvedConfig.server?.name || 'VoiceLink',
            server_description: resolvedConfig.server?.description || '',
            last_user: lastActiveUser?.displayName || lastActiveUser?.name || '',
            user_count: String(roomUsers.length || 0),
            uptime: this.formatDurationWords(process.uptime()),
            motd,
            build_version: this.appVersion || resolvedConfig.version || '1.0.0',
            platform: 'server',
            support_link: supportLink
        };
    }

    expandMessageTemplate(template, context = {}) {
        if (typeof template !== 'string') return '';
        return template
            .replace(/\{\{\s*([a-zA-Z0-9_]+)\s*\}\}/g, (_, token) => {
                const value = context[token];
                return value === undefined || value === null ? '' : String(value);
            })
            .replace(/[ \t]+\n/g, '\n')
            .replace(/\n{3,}/g, '\n\n')
            .trim();
    }

    buildLobbyWelcomeMessage(user = null) {
        const config = deployConfig.getConfig() || {};
        const template = typeof config.server?.lobbyWelcomeMessage === 'string' && config.server.lobbyWelcomeMessage.trim()
            ? config.server.lobbyWelcomeMessage.trim()
            : this.getDefaultLobbyWelcomeMessage();
        return this.expandMessageTemplate(template, this.buildWelcomeTemplateContext({ user, config }));
    }

    buildRoomWelcomeMessage({ user = null, room = null, includeMotd = true } = {}) {
        if (!room) return '';
        const config = deployConfig.getConfig() || {};
        const motdSettings = config.server?.motdSettings || {};
        const roomTemplate = typeof room.welcomeMessage === 'string' ? room.welcomeMessage.trim() : '';
        const motd = typeof config.server?.motd === 'string' ? config.server.motd.trim() : '';
        const context = this.buildWelcomeTemplateContext({ user, room, config });
        const parts = [];

        if (roomTemplate) {
            parts.push(this.expandMessageTemplate(roomTemplate, context));
        }

        if (includeMotd && motd && motdSettings.enabled !== false && motdSettings.showInRoom !== false) {
            const motdText = this.expandMessageTemplate(motd, context);
            if (motdSettings.appendToWelcomeMessage && parts.length) {
                parts[parts.length - 1] = `${parts[parts.length - 1]}\n\n${motdText}`;
            } else if (!parts.length) {
                parts.push(motdText);
            }
        }

        if (!parts.length) {
            const roomName = room?.name || 'this room';
            const userName = user?.name || user?.authInfo?.displayName || user?.authInfo?.username || 'there';
            parts.push(`Welcome to ${roomName}, ${userName}. If you want, I can help with this room.`);
        }

        return parts.filter(Boolean).join('\n\n').trim();
    }

    shouldAnnounceRecentRestart() {
        const elapsedMs = Date.now() - (this.serverStartedAt || Date.now());
        return elapsedMs >= 0 && elapsedMs <= (10 * 60 * 1000);
    }

    buildRecentRestartRoomNotice(room = null) {
        if (!this.shouldAnnounceRecentRestart()) return '';
        const roomName = room?.name || 'This room';
        const ago = this.formatDurationWords(Math.floor((Date.now() - this.serverStartedAt) / 1000));
        return `System. VoiceLink server restarted ${ago} ago. ${roomName} has reconnected.`;
    }

    inferBotTopicLabel(source = '', reply = '') {
        const combined = `${source} ${reply}`.toLowerCase();
        if (combined.includes('composr')) return 'composr';
        if (combined.includes('motd') || combined.includes('message of the day')) return 'motd';
        if (combined.includes('media') || combined.includes('music') || combined.includes('stream')) return 'media';
        if (combined.includes('update') || combined.includes("what's new") || combined.includes('latest')) return 'updates';
        if (combined.includes('status') || combined.includes('users') || combined.includes('server')) return 'status';
        return 'general';
    }

    findBotReplyTarget(roomId, sourceMessage = {}, reply = '') {
        const topic = this.inferBotTopicLabel(sourceMessage.message || sourceMessage.content || '', reply);
        const messages = this.getRoomMessages(roomId, 120);
        for (let index = messages.length - 1; index >= 0; index -= 1) {
            const candidate = messages[index];
            if (!candidate?.isBot) continue;
            if (candidate.botTopic === topic) {
                return { replyTo: candidate.id, botTopic: topic };
            }
        }
        return {
            replyTo: sourceMessage.id || null,
            botTopic: topic
        };
    }

    buildLocalTopicResearchReply(user, roomId, source = '') {
        const room = this.rooms.get(roomId);
        const config = deployConfig.getConfig() || {};
        const users = this.normalizeRoomUsers(roomId);
        const topic = String(source || '').replace(/^.*?(tell me about|research|what is)\s+/i, '').trim();
        const segments = [
            room?.description ? `${room.name}: ${room.description}` : '',
            config.server?.description ? `${config.server.name || 'VoiceLink'}: ${config.server.description}` : '',
            users.length ? `${room?.name || 'This room'} currently has ${users.length} participant${users.length === 1 ? '' : 's'}.` : '',
            this.getRecentRoomConversationContext(roomId).slice(-2).join(' ')
        ].filter(Boolean);
        if (!segments.length) return '';
        const topicLead = topic ? `From local VoiceLink data about ${topic}: ` : 'From local VoiceLink data: ';
        return `${topicLead}${segments.join(' ')} If you want, I can tell you how to work with that here before I look anywhere else.`;
    }

    trimMessagesToCap(messages, cap) {
        while (messages.length > cap) {
            const removableIndex = messages.findIndex(msg => !(msg.attachmentURL || msg.attachmentName));
            if (removableIndex === -1) {
                messages.shift();
            } else {
                messages.splice(removableIndex, 1);
            }
        }
    }

    cleanupRoomMessagesIfEmpty(roomId) {
        const settings = this.getMessageSettingsConfig();
        if (!settings.deleteRoomMessagesWhenEmpty) return;
        this.roomMessages.delete(roomId);
    }

    emitRoomUsersSnapshot(roomId) {
        const room = this.rooms.get(roomId);
        if (!room) return;
        const liveUsers = this.normalizeRoomUsers(roomId);
        const serializedUsers = liveUsers.map(user => this.serializeRoomUser(user, roomId)).filter(Boolean);
        const payload = {
            roomId,
            count: serializedUsers.length,
            users: serializedUsers
        };
        this.io.to(roomId).emit('room-users', payload);
        this.io.to(roomId).emit('room-user-count', payload);
    }

    getConnectedUsersCount() {
        const connectedSockets = this.getConnectedSocketSet();
        let count = 0;
        for (const socketId of this.users.keys()) {
            if (connectedSockets.has(socketId)) {
                count++;
            }
        }
        return count;
    }

    getRoomMonitorSnapshot() {
        const rooms = [];
        for (const room of this.rooms.values()) {
            const users = this.normalizeRoomUsers(room.id);
            rooms.push({
                roomId: room.id,
                name: room.name,
                userCount: users.length,
                users: users.map(user => ({
                    id: user.id,
                    name: user.name,
                    joinedAt: user.joinedAt || null,
                    isAuthenticated: !!user.isAuthenticated
                })),
                maxUsers: room.maxUsers || 50,
                locked: !!room.locked,
                isDefault: !!room.isDefault,
                visibility: room.visibility || 'public',
                accessType: room.accessType || 'hybrid'
            });
        }
        return rooms;
    }

    setupRoutes() {
        // API Routes - now fetches from main server and merges with local
        const authPortalBase = process.env.AUTH_PORTAL_URL || 'https://auth.devinecreations.net';

        // Health check endpoint for monitoring
        this.app.get("/health", (req, res) => {
            res.json({
                service: "voicelink-local",
                status: "healthy",
                timestamp: new Date().toISOString(),
                rooms: this.rooms.size,
                users: this.users.size
            });
        });

        // ============================================
        // WHMCS AUTHENTICATION
        // ============================================

        const isWhmcsTwoFactorError = (message = '') => message.toLowerCase().includes('two factor');

        this.app.post('/api/auth/whmcs/login', async (req, res) => {
            const portalSite = this.normalizePortalSite(req.body.portalSite);
            const identity = String(req.body.identity || req.body.email || req.body.username || '').trim();
            const resolvedIdentity = this.resolveWhmcsIdentity(identity);
            const email = resolvedIdentity.email;
            const password = req.body.password || req.body.password2;
            const twoFactorCode = req.body.twoFactorCode || req.body.twofa || null;
            const remember = req.body.remember === true;
            const mastodonHandle = req.body.mastodonHandle || null;

            if (!identity || !password) {
                return res.status(400).json({ success: false, error: 'Email or username and password required' });
            }

            try {
                if (this.shouldDelegateWhmcsAuth()) {
                    const result = await this.createDelegatedWhmcsSession({
                        ...req.body,
                        portalSite,
                        identity,
                        email
                    });
                    return res.json(result);
                }
                const bridgedAdmin = await this.authenticateWhmcsAdmin(identity, password);
                if (bridgedAdmin) {
                    const roleName = String(bridgedAdmin.roleName || '').trim().toLowerCase();
                    const role = roleName.includes('owner')
                        ? 'owner'
                        : roleName.includes('support') || roleName.includes('staff') || Number(bridgedAdmin.roleId) !== 1
                            ? 'staff'
                            : 'admin';
                    const entitlements = {
                        ...this.deriveWhmcsEntitlements({}, []),
                        licenseTier: role === 'owner' ? 'owner' : 'admin',
                        serverOwnerLicense: true,
                        serverSlots: 10,
                        hostingControlPanelLinked: true,
                        hostingRoles: [bridgedAdmin.roleName || role],
                        hostingPermissions: this.buildPermissionsForRole(role),
                        licenses: {
                            user: {
                                type: 'admin',
                                installsAllowed: 10,
                                devicesAllowed: null
                            },
                            server: {
                                type: 'server_owner',
                                installsAllowed: 10,
                                serversAllowed: 10
                            }
                        }
                    };
                    const user = this.applyAuthorityRoleOverrides({
                        id: `whmcs-admin:${bridgedAdmin.id}`,
                        whmcsAdminId: bridgedAdmin.id,
                        username: this.syncWhmcsIdentityAlias(bridgedAdmin.email || '', bridgedAdmin.username, bridgedAdmin.id) || bridgedAdmin.username,
                        email: bridgedAdmin.email || '',
                        displayName: bridgedAdmin.username,
                        fullHandle: bridgedAdmin.username,
                        role,
                        permissions: this.buildPermissionsForRole(role),
                        isAdmin: role === 'owner' || role === 'admin',
                        isModerator: role === 'staff',
                        authProvider: 'whmcs_admin',
                        portalSite,
                        entitlements,
                        deviceTier: entitlements.deviceTier,
                        maxDevices: entitlements.maxDevices,
                        mastodonHandle
                    });
                    decorateUserWithCanonicalAccount(user, 'whmcs_admin', {
                        externalId: bridgedAdmin.id,
                        email: bridgedAdmin.email || '',
                        username: user.username,
                        displayName: user.displayName
                    });
                    const session = this.createAuthSession(this.whmcsAuthSessions, 'whmcs', user, remember);
                    persistLocalAuthUsers();
                    return res.json({
                        success: true,
                        token: session.token,
                        expiresAt: session.expiresAt,
                        portalUrl: this.getPortalUrlForSite(portalSite),
                        user
                    });
                }
                if (!email) {
                    return res.status(400).json({
                        success: false,
                        error: 'WHMCS username login requires either a configured identity alias or WHMCS admin bridge on this server'
                    });
                }

                let clientDetails = null;
                try {
                    const clientResponse = await this.whmcsRequest('GetClientsDetails', { email });
                    clientDetails = clientResponse.client || clientResponse.clientdetails || null;
                } catch (error) {
                    console.warn('[WHMCS] Client lookup failed:', error.message);
                }

                if (clientDetails?.twofactorenabled && !twoFactorCode) {
                    return res.status(401).json({
                        success: false,
                        requires2FA: true,
                        message: 'Two-factor authentication code required'
                    });
                }

                try {
                    await this.whmcsRequest('ValidateLogin', {
                        email,
                        password2: password,
                        ...(twoFactorCode ? { twofa: twoFactorCode } : {})
                    });
                } catch (error) {
                    if (isWhmcsTwoFactorError(error.message) && !twoFactorCode) {
                        return res.status(401).json({
                            success: false,
                            requires2FA: true,
                            message: 'Two-factor authentication code required'
                        });
                    }
                    throw error;
                }

                if (!clientDetails) {
                    const clientResponse = await this.whmcsRequest('GetClientsDetails', { email });
                    clientDetails = clientResponse.client || clientResponse.clientdetails || null;
                }

                if (!clientDetails) {
                    return res.status(404).json({ success: false, error: 'Client not found' });
                }

                let services = [];
                try {
                    const servicesResponse = await this.whmcsRequest('GetClientsProducts', { clientid: clientDetails.id });
                    services = servicesResponse.products?.product || [];
                } catch (error) {
                    console.warn('[WHMCS] Services lookup failed:', error.message);
                }

                const { role, permissions } = this.deriveWhmcsRole(clientDetails, services);
                const entitlements = this.deriveWhmcsEntitlements(clientDetails, services);
                const displayName = [clientDetails.firstname, clientDetails.lastname].filter(Boolean).join(' ').trim()
                    || clientDetails.companyname
                    || clientDetails.email
                    || 'VoiceLink User';

                const syncedUsername = this.syncWhmcsIdentityAlias(clientDetails.email || email, resolvedIdentity.username || clientDetails.username || displayName, clientDetails.id);
                const user = this.applyAuthorityRoleOverrides({
                    id: `whmcs:${clientDetails.id}`,
                    whmcsClientId: clientDetails.id,
                    email: clientDetails.email || email,
                    username: syncedUsername || undefined,
                    displayName,
                    fullHandle: clientDetails.email || email,
                    role,
                    permissions,
                    isAdmin: role === 'admin',
                    isModerator: role === 'staff',
                    authProvider: 'whmcs',
                    portalSite,
                    entitlements,
                    deviceTier: entitlements.deviceTier,
                    maxDevices: entitlements.maxDevices,
                    mastodonHandle
                });
                decorateUserWithCanonicalAccount(user, 'whmcs', {
                    externalId: clientDetails.id,
                    email: clientDetails.email || email,
                    username: syncedUsername || clientDetails.username || displayName,
                    displayName
                });

                const session = this.createAuthSession(this.whmcsAuthSessions, 'whmcs', user, remember);
                persistLocalAuthUsers();
                res.json({
                    success: true,
                    token: session.token,
                    expiresAt: session.expiresAt,
                    portalUrl: this.getPortalUrlForSite(portalSite),
                    user
                });
            } catch (error) {
                console.error('[WHMCS] Login failed:', error.message);
                res.status(401).json({ success: false, error: error.message || 'Login failed' });
            }
        });

        this.app.get('/api/auth/whmcs/session/:token', (req, res) => {
            const session = this.getAuthSession(this.whmcsAuthSessions, req.params.token);
            if (!session) {
                return res.status(401).json({ valid: false });
            }
            res.json({ valid: true, user: session.user, expiresAt: session.expiresAt });
        });

        this.app.post('/api/auth/whmcs/logout', (req, res) => {
            const { token } = req.body;
            if (token) {
                this.whmcsAuthSessions.delete(token);
            }
            res.json({ success: true });
        });

        this.app.post('/api/auth/whmcs/sso/start', async (req, res) => {
            const portalSite = this.normalizePortalSite(req.body.portalSite);
            const token = req.body.token;
            const destination = req.body.destination || 'clientarea:home';
            let session = token ? this.getAuthSession(this.whmcsAuthSessions, token) : null;

            try {
                if (this.shouldDelegateWhmcsAuth()) {
                    const delegatedPayload = {
                        ...req.body,
                        portalSite,
                        token: session?.upstreamToken || req.body.token || null
                    };
                    const delegated = await this.requestWhmcsAuthority('/api/auth/whmcs/sso/start', delegatedPayload);
                    return res.json({
                        success: true,
                        redirectUrl: delegated.redirectUrl || delegated.portalUrl || this.getPortalUrlForSite(portalSite),
                        token: token || session?.token || null,
                        portalUrl: delegated.portalUrl || this.getPortalUrlForSite(portalSite),
                        delegated: true
                    });
                }

                if (!session) {
                    const identity = String(req.body.identity || req.body.email || req.body.username || '').trim();
                    const resolvedIdentity = this.resolveWhmcsIdentity(identity);
                    const email = resolvedIdentity.email;
                    const password = req.body.password || req.body.password2;
                    const twoFactorCode = req.body.twoFactorCode || req.body.twofa || null;
                    if (!identity || !password) {
                        return res.status(400).json({ success: false, error: 'Email or username and password required' });
                    }
                    const bridgedAdmin = await this.authenticateWhmcsAdmin(identity, password);
                    if (bridgedAdmin) {
                        const adminBaseUrl = this.getWhmcsAdminBridgeConfig().adminUrl || `${this.getPortalUrlForSite(portalSite).replace(/\/+$/, '')}/admin/`;
                        return res.json({
                            success: true,
                            redirectUrl: adminBaseUrl,
                            token: null,
                            portalUrl: adminBaseUrl,
                            admin: true
                        });
                    }
                    if (!email) {
                        return res.status(400).json({ success: false, error: 'WHMCS username login requires either a configured identity alias or WHMCS admin bridge on this server' });
                    }

                    try {
                        await this.whmcsRequest('ValidateLogin', {
                            email,
                            password2: password,
                            ...(twoFactorCode ? { twofa: twoFactorCode } : {})
                        });
                    } catch (error) {
                        if (isWhmcsTwoFactorError(error.message) && !twoFactorCode) {
                            return res.status(401).json({
                                success: false,
                                requires2FA: true,
                                message: 'Two-factor authentication code required'
                            });
                        }
                        throw error;
                    }

                    const clientResponse = await this.whmcsRequest('GetClientsDetails', { email });
                    const clientDetails = clientResponse.client || clientResponse.clientdetails;
                    if (!clientDetails) {
                        return res.status(404).json({ success: false, error: 'Client not found' });
                    }

                    const { role, permissions } = this.deriveWhmcsRole(clientDetails, []);
                    const entitlements = this.deriveWhmcsEntitlements(clientDetails, []);
                    const displayName = [clientDetails.firstname, clientDetails.lastname].filter(Boolean).join(' ').trim()
                        || clientDetails.companyname
                        || clientDetails.email
                        || 'VoiceLink User';

                    const syncedUsername = this.syncWhmcsIdentityAlias(clientDetails.email || email, resolvedIdentity.username || clientDetails.username || displayName, clientDetails.id);
                    const user = this.applyAuthorityRoleOverrides({
                        id: `whmcs:${clientDetails.id}`,
                        whmcsClientId: clientDetails.id,
                        email: clientDetails.email || email,
                        username: syncedUsername || undefined,
                        displayName,
                        fullHandle: clientDetails.email || email,
                        role,
                        permissions,
                        isAdmin: role === 'admin',
                        isModerator: role === 'staff',
                        authProvider: 'whmcs',
                        portalSite,
                        entitlements,
                        deviceTier: entitlements.deviceTier,
                        maxDevices: entitlements.maxDevices
                    });
                    decorateUserWithCanonicalAccount(user, 'whmcs', {
                        externalId: clientDetails.id,
                        email: clientDetails.email || email,
                        username: syncedUsername || clientDetails.username || displayName,
                        displayName
                    });

                    const created = this.createAuthSession(this.whmcsAuthSessions, 'whmcs', user, req.body.remember === true);
                    persistLocalAuthUsers();
                    session = { user, expiresAt: created.expiresAt };
                    session.token = created.token;
                }

                const ssoResult = await this.whmcsRequest('CreateSsoToken', {
                    client_id: session.user.whmcsClientId,
                    destination
                });

                res.json({
                    success: true,
                    redirectUrl: ssoResult.redirect_url || ssoResult.redirecturl || ssoResult.redirectUrl || this.getPortalUrlForSite(portalSite),
                    token: token || session.token,
                    portalUrl: this.getPortalUrlForSite(portalSite)
                });
            } catch (error) {
                console.error('[WHMCS] SSO failed:', error.message);
                res.status(500).json({ success: false, error: error.message || 'SSO failed' });
            }
        });

        this.app.get('/api/rooms', async (req, res) => {
            const source = req.query.source || 'app'; // 'app', 'web', 'all'
            const includeHidden = req.query.includeHidden === 'true';
            const localServerApiBase = (
                process.env.PUBLIC_URL
                || deployConfig.getConfig()?.server?.publicUrl
                || `${req.protocol}://${req.get('host')}`
            ).replace(/\/+$/, '');

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

            const localRoomList = localRooms.map(room => {
                const configuredBackgroundStream = this.getConfiguredBackgroundStreamForRoom(room);
                return {
                    ...(configuredBackgroundStream ? {
                        backgroundStream: configuredBackgroundStream.streamUrl,
                        streamVolume: configuredBackgroundStream.volume,
                        nowPlaying: {
                            playing: true,
                            title: configuredBackgroundStream.name,
                            source: 'background_stream'
                        }
                    } : {}),
                    id: room.id,
                    name: room.name,
                    description: room.description || '',
                    users: this.normalizeRoomUsers(room.id).length,
                    userCount: this.normalizeRoomUsers(room.id).length,
                    maxUsers: room.maxUsers,
                    hasPassword: !!room.password,
                    visibility: room.visibility,
                    accessType: room.accessType,
                    allowEmbed: room.allowEmbed,
                    visibleToGuests: room.visibleToGuests,
                    isDefault: room.isDefault || false,
                    template: room.template || null,
                    serverSource: 'local',
                    creatorHandle: room.creatorHandle || null,
                    createdBy: room.createdBy || room.creatorHandle || null,
                    createdAt: room.createdAt || null,
                    updatedBy: room.updatedBy || room.createdBy || room.creatorHandle || null,
                    updatedAt: room.updatedAt || room.lastUpdated || room.createdAt || null,
                    previousNames: Array.isArray(room.previousNames) ? room.previousNames : [],
                    serverTitle: this.serverName || null,
                    serverDomain: deployConfig.getConfig()?.server?.domain || null,
                    serverApiBase: localServerApiBase,
                    motd: deployConfig.getConfig()?.server?.motd || null,
                    hostServerName: room.hostServerName || this.serverName || null,
                    hostServerOwner: room.hostServerOwner || null,
                    // Lock status
                    locked: room.locked || false,
                    lockedAt: room.lockedAt || null,
                    canJoin: !room.locked
                };
            });

            // Merge and dedupe exact room instance collisions while keeping multi-server room variants.
            const mergedRooms = [];
            const seenRoomInstances = new Set();
            for (const room of [...mainServerRooms, ...localRoomList]) {
                const instanceKey = `${room.id || ''}|${String(room.serverApiBase || room.serverSource || '').toLowerCase()}`;
                if (seenRoomInstances.has(instanceKey)) continue;
                seenRoomInstances.add(instanceKey);
                mergedRooms.push(room);
            }

            const hasAuthContext = Boolean(
                req.headers.authorization
                || req.headers['x-user-email']
                || req.headers['x-user-id']
                || req.query.authenticated === 'true'
            );

            let filteredRooms = mergedRooms;
            if (!hasAuthContext) {
                filteredRooms = mergedRooms.filter((room) => {
                    const visibility = String(room.visibility || '').toLowerCase();
                    if (visibility === 'private') return false;
                    if (room.isPrivate === true) return false;
                    if (room.visibleToGuests === false) return false;
                    return true;
                });
            }

            const platform = String(req.query.client || req.query.platform || '').trim().toLowerCase();
            const sortBy = String(req.query.sort || (platform === 'ios' ? 'activity' : 'name')).trim().toLowerCase();
            filteredRooms = filteredRooms
                .map((room) => ({
                    ...room,
                    sortWeight: Number(room.userCount ?? room.users ?? 0),
                    lastActivityAt: room.updatedAt || room.createdAt || null
                }))
                .sort((a, b) => {
                    if (sortBy === 'activity' || sortBy === 'users') {
                        const byUsers = (Number(b.sortWeight || 0) - Number(a.sortWeight || 0));
                        if (byUsers !== 0) return byUsers;
                    }
                    if (sortBy === 'recent') {
                        const at = new Date(a.lastActivityAt || 0).getTime();
                        const bt = new Date(b.lastActivityAt || 0).getTime();
                        if (bt !== at) return bt - at;
                    }
                    return String(a.name || '').localeCompare(String(b.name || ''));
                });

            console.log(`[LocalServer] Returning ${filteredRooms.length} rooms (${mainServerRooms.length} main + ${localRoomList.length} local)`);
            res.json(filteredRooms);
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
                autoplayMusic = false,
                autoplayPlaylist = null,
                isAuthenticated = false
            } = req.body;
            const roomId = req.body.roomId || uuidv4();

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
                name: name || `Room ${roomId.slice(0, 8)}`,
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
                createdBy: creatorHandle || null,
                isDefault: isDefault || false,
                template: template || null,
                createdAt: new Date(),
                updatedAt: new Date(),
                updatedBy: creatorHandle || null,
                previousNames: [],
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
                autoLockScheduled: null,  // Timeout ID for scheduled auto-lock
                autoplayMusic: autoplayMusic !== undefined ? autoplayMusic : false,  // Auto-play music when room is empty
                autoplayPlaylist: autoplayPlaylist || null,  // Playlist ID for autoplay
                jellyfinAccess: {
                    enabled: true,
                    adminCanAccessAll: true,
                    allowRoomOwnerUploads: true,
                    allowAuthenticatedUploads: false,
                    allowedServerIds: [],
                    allowedLibraryIdsByServer: {},
                    roomUserPermissions: {}
                }
            };

            this.rooms.set(roomId, room);

            this.saveRoomsToDisk(); // Auto-save rooms
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


        // Update room autoplay settings (admin only)
        this.app.put('/api/rooms/:roomId/autoplay', (req, res) => {
            const { roomId } = req.params;
            const { autoplayMusic, autoplayPlaylist, adminKey } = req.body;

            const room = this.rooms.get(roomId);
            if (!room) {
                return res.status(404).json({ error: 'Room not found' });
            }

            // Update autoplay settings
            if (autoplayMusic !== undefined) {
                room.autoplayMusic = autoplayMusic;
            }
            if (autoplayPlaylist !== undefined) {
                room.autoplayPlaylist = autoplayPlaylist;
            }

            this.saveRoomsToDisk();

            res.json({
                success: true,
                roomId,
                autoplayMusic: room.autoplayMusic,
                autoplayPlaylist: room.autoplayPlaylist,
                message: `Autoplay ${room.autoplayMusic ? 'enabled' : 'disabled'} for room`
            });
        });

        // Get room autoplay settings
        this.app.get('/api/rooms/:roomId/autoplay', (req, res) => {
            const { roomId } = req.params;
            const room = this.rooms.get(roomId);
            if (!room) {
                return res.status(404).json({ error: 'Room not found' });
            }
            res.json({
                roomId,
                autoplayMusic: room.autoplayMusic || false,
                autoplayPlaylist: room.autoplayPlaylist || null
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
            const defaultLimit = this.getMessageSettingsConfig().initialLoadCount;
            const { limit = defaultLimit, before } = req.query;

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
            const defaultLimit = this.getMessageSettingsConfig().initialLoadCount;
            const { limit = defaultLimit, before } = req.query;
            const viewerId = String(req.query?.viewerId || userId1).trim();

            const messages = this.getDirectMessages(userId1, userId2, parseInt(limit), before, viewerId);
            const dmKey = [userId1, userId2].sort().join('_');
            res.json({
                participants: [userId1, userId2],
                messages,
                count: messages.length,
                hasMore: messages.length === parseInt(limit),
                history: this.getDirectMessageMeta(dmKey)
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
                        messageCount: messages.length,
                        history: this.getDirectMessageMeta(dmKey)
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

        this.app.post('/api/messages/dm/:userId1/:userId2/history/hide', (req, res) => {
            const { userId1, userId2 } = req.params;
            const viewerId = String(req.body?.viewerId || userId1).trim();
            const clearBefore = req.body?.clearBefore || new Date().toISOString();
            const visibility = this.hideDirectMessagesForUser(userId1, userId2, viewerId, clearBefore);
            res.json({ success: true, viewerId, visibility });
        });

        this.app.post('/api/messages/dm/:userId1/:userId2/history/restore', (req, res) => {
            const { userId1, userId2 } = req.params;
            const viewerId = String(req.body?.viewerId || userId1).trim();
            const visibility = this.restoreDirectMessagesForUser(userId1, userId2, viewerId);
            res.json({ success: true, viewerId, visibility });
        });

        this.app.post('/api/messages/dm/:userId1/:userId2/history/purge', (req, res) => {
            const { userId1, userId2 } = req.params;
            const viewerId = String(req.body?.viewerId || userId1).trim();
            const clearBefore = req.body?.clearBefore || new Date().toISOString();
            const removeAttachments = req.body?.removeAttachments === true;
            const result = this.requestDirectMessagePurge(userId1, userId2, viewerId, clearBefore, { removeAttachments });
            res.json(result);
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
            const roomSnapshot = this.getRoomMonitorSnapshot();
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
                connectedUsers: this.getConnectedUsersCount(),
                roomPresence: roomSnapshot.map(room => ({
                    roomId: room.roomId,
                    name: room.name,
                    userCount: room.userCount
                })),
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
                users: this.getConnectedUsersCount()
            });
        });

        // API info endpoint (alias for mobile apps)
        this.app.get('/api/info', (req, res) => {
            res.json({
                service: 'voicelink-local',
                status: 'healthy',
                version: '1.0.1',
                timestamp: new Date().toISOString(),
                rooms: this.rooms.size,
                users: this.getConnectedUsersCount()
            });
        });

        // Room/user monitoring endpoint for desktop/web API polling and push sync logic.
        this.app.get(['/api/monitor', '/api_monitor', '/api/minitor', '/api_minitor'], (req, res) => {
            const pollIntervalSeconds = Math.max(1, Math.min(60, parseInt(req.query.interval || '5', 10) || 5));
            const roomSnapshot = this.getRoomMonitorSnapshot();
            const totalUsersInRooms = roomSnapshot.reduce((sum, room) => sum + room.userCount, 0);
            const connectedUsers = this.getConnectedUsersCount();

            res.json({
                service: 'voicelink-local',
                status: 'ok',
                timestamp: new Date().toISOString(),
                pollIntervalSeconds,
                connectedUsers,
                roomUsers: totalUsersInRooms,
                rooms: {
                    total: roomSnapshot.length,
                    active: roomSnapshot.filter(room => room.userCount > 0).length,
                    items: roomSnapshot
                },
                websocket: {
                    recommendedEvents: ['room-user-count', 'user-joined', 'user-left', 'joined-room']
                }
            });
        });

        // Authelia SSO helper endpoints
        this.app.get('/api/auth/authelia/user', (req, res) => {
            const user = req.headers['remote-user'] || null;
            const rawGroups = req.headers['remote-groups'] || '';
            const groups = String(rawGroups)
                .split(',')
                .map(group => group.trim())
                .filter(Boolean);

            if (!user) {
                return res.json({ authenticated: false });
            }

            const normalizedGroups = groups.map(group => group.toLowerCase());
            const isAdmin = normalizedGroups.includes('admins') ||
                normalizedGroups.includes('admin') ||
                normalizedGroups.includes('wheel') ||
                normalizedGroups.includes('sudo');

            res.json({
                authenticated: true,
                user,
                name: req.headers['remote-name'] || user,
                email: req.headers['remote-email'] || '',
                groups,
                isAdmin
            });
        });

        this.app.get('/api/auth/authelia/login', (req, res) => {
            const rd = req.query.rd || `${req.protocol}://${req.get('host')}/`;
            const redirectUrl = `${authPortalBase}/?rd=${encodeURIComponent(rd)}`;
            res.redirect(302, redirectUrl);
        });

        this.app.get('/api/auth/authelia/logout', (req, res) => {
            const rd = req.query.rd || `${req.protocol}://${req.get('host')}/`;
            const redirectUrl = `${authPortalBase}/logout?rd=${encodeURIComponent(rd)}`;
            res.redirect(302, redirectUrl);
        });

        const inferPlatformFromRequest = (req) => {
            const explicit = String(req.query?.os || req.query?.platform || req.headers['x-client-platform'] || '').trim().toLowerCase();
            const normalize = (value) => {
                if (!value) return '';
                if (['mac', 'macos', 'osx', 'darwin', 'macintosh'].includes(value)) return 'macos';
                if (['win', 'windows', 'win32', 'win64'].includes(value)) return 'windows';
                if (['linux', 'ubuntu', 'debian'].includes(value)) return 'linux';
                if (['ios', 'iphone', 'ipad'].includes(value)) return 'ios';
                if (['android'].includes(value)) return 'android';
                return '';
            };

            const normalized = normalize(explicit);
            if (normalized) return normalized;

            const userAgent = String(req.headers['user-agent'] || '').toLowerCase();
            if (userAgent.includes('windows')) return 'windows';
            if (userAgent.includes('mac os x') || userAgent.includes('macintosh')) return 'macos';
            if (userAgent.includes('linux')) return 'linux';
            if (userAgent.includes('iphone') || userAgent.includes('ipad') || userAgent.includes('ios')) return 'ios';
            if (userAgent.includes('android')) return 'android';
            return 'macos';
        };

        const getDownloadRoot = () => {
            const downloadRootCandidates = [
                process.env.VOICELINK_DOWNLOAD_ROOT,
                path.join(process.cwd(), 'downloads', 'voicelink'),
                '/home/devinecr/downloads/voicelink'
            ].filter(Boolean);
            return downloadRootCandidates.find((candidate) => fs.existsSync(candidate)) || downloadRootCandidates[0];
        };

        const getDownloadBase = (req) => {
            if (process.env.VOICELINK_DOWNLOAD_BASE) {
                return process.env.VOICELINK_DOWNLOAD_BASE;
            }

            const host = String(req.get('host') || '').toLowerCase();
            const mainHostedDomains = [
                'voicelink.devinecreations.net',
                'devinecreations.net',
                'devine-creations.com',
                'raywonderis.me'
            ];
            const isMainHostedDomain = mainHostedDomains.some((domain) => host.includes(domain));

            if (isMainHostedDomain) {
                return 'https://devinecreations.net/uploads/filedump/shared/apps/voicelink';
            }

            return `${req.protocol}://${req.get('host')}/downloads/voicelink`;
        };

        const getSmartDlBase = (req) => `${req.protocol}://${req.get('host')}/api/dl`;

        // Smart download endpoint: serve local file when present; otherwise redirect to the fastest reachable mirror.
        this.app.get('/api/dl/:target', async (req, res) => {
            const platform = inferPlatformFromRequest(req);
            const rawTarget = String(req.params?.target || '').trim().toLowerCase();
            const downloadRoot = getDownloadRoot();

            const platformDefaults = {
                macos: ['VoiceLink-1.0.0-macos.pkg', 'VoiceLinkMacOS.zip'],
                windows: ['VoiceLink-1.0.0-windows-portable.exe', 'VoiceLink-1.0.0-windows-setup.exe', 'VoiceLink-windows.zip'],
                linux: ['VoiceLink-linux.AppImage', 'voicelink-local_1.0.0_amd64.deb']
            };

            const aliasMap = {
                latest: platformDefaults[platform] || platformDefaults.macos,
                client: platformDefaults[platform] || platformDefaults.macos,
                desktop: platformDefaults[platform] || platformDefaults.macos,
                macos: platformDefaults.macos,
                windows: platformDefaults.windows,
                linux: platformDefaults.linux
            };

            const requestedCandidates = aliasMap[rawTarget]
                || (rawTarget ? [path.basename(rawTarget)] : (platformDefaults[platform] || platformDefaults.macos));

            const localCandidate = requestedCandidates
                .map((filename) => ({
                    filename,
                    absolutePath: downloadRoot ? path.join(downloadRoot, filename) : ''
                }))
                .find((entry) => entry.absolutePath && fs.existsSync(entry.absolutePath));

            if (localCandidate) {
                return res.download(localCandidate.absolutePath, localCandidate.filename);
            }

            const selectedFile = requestedCandidates[0];
            const mirrorBases = [
                getDownloadBase(req),
                ...(String(process.env.VOICELINK_DOWNLOAD_MIRRORS || '')
                    .split(',')
                    .map((item) => item.trim())
                    .filter(Boolean))
            ];
            const copyPartyLink = this.buildCopyPartyLink({ fileName: selectedFile });
            if (copyPartyLink?.configured && copyPartyLink?.url) {
                mirrorBases.push(copyPartyLink.url);
            }

            const mirrorUrls = [...new Set(mirrorBases
                .map((base) => {
                    if (!base) return '';
                    if (/^https?:\/\//i.test(base) && base.includes(selectedFile)) return base;
                    return `${String(base).replace(/\/+$/, '')}/${encodeURIComponent(selectedFile)}`;
                })
                .filter(Boolean))];

            const timeoutMs = Math.max(800, Math.min(Number(req.query?.timeoutMs) || 3500, 12000));
            const probePromises = mirrorUrls.map((url) => (async () => {
                const started = Date.now();
                const check = await this.probeUrl(url, timeoutMs);
                if (!check.ok) throw new Error(`${check.status || check.error || 'unreachable'}`);
                return { url, latencyMs: Date.now() - started };
            })());

            try {
                const winner = await Promise.any(probePromises);
                res.setHeader('X-VoiceLink-DL-Platform', platform);
                res.setHeader('X-VoiceLink-DL-Source', 'mirror');
                res.setHeader('X-VoiceLink-DL-Latency', String(winner.latencyMs));
                return res.redirect(302, winner.url);
            } catch (error) {
                return res.status(404).json({
                    success: false,
                    error: 'No reachable download source found for requested target',
                    target: rawTarget || 'latest',
                    platform,
                    attempted: mirrorUrls
                });
            }
        });

        // Updates check endpoint for native clients
        this.app.post('/api/updates/check', (req, res) => {
            const { platform, currentVersion, buildNumber } = req.body;
            const downloadBase = getDownloadBase(req);
            const resolvedDownloadRoot = getDownloadRoot();
            const requestedChannelRaw = String(
                req.body?.distChannel
                || req.headers['x-dist-channel']
                || req.query?.distChannel
                || process.env.DIST_CHANNEL
                || 'direct'
            ).trim().toLowerCase();
            const isStoreManagedChannel = ['appstore', 'testflight', 'mac_app_store', 'playstore', 'windows_store'].includes(requestedChannelRaw);

            const readChecksum = (filename) => {
                if (!resolvedDownloadRoot) return null;
                const checksumPath = path.join(resolvedDownloadRoot, `${filename}.sha256`);
                if (!fs.existsSync(checksumPath)) return null;
                const raw = fs.readFileSync(checksumPath, 'utf8').trim();
                if (!raw) return null;
                return raw.split(/\s+/)[0] || null;
            };

            const fileExists = (filename) => {
                if (!resolvedDownloadRoot) return false;
                return fs.existsSync(path.join(resolvedDownloadRoot, filename));
            };

            // Latest versions for each platform
            const latestVersions = {
                macos: {
                    version: '1.0.4',
                    buildNumber: 26,
                    downloadURL: `${downloadBase}/VoiceLink-1.0.0-macos.pkg`,
                    smartTarget: 'macos',
                    releaseNotes: 'Latest macOS build includes full room details/actions alignment, faster chat link title previews, improved status-menu room return behavior, and less repetitive bot responses.'
                },
                windows: {
                    version: '1.0.4',
                    buildNumber: 26,
                    downloadURL: `${downloadBase}/VoiceLink-1.0.0-windows-portable.exe`,
                    smartTarget: 'windows',
                    releaseNotes: 'Latest Windows build includes federation-aware room listing and improved auth flow. Setup installer and builder package are available on the downloads page.'
                },
                linux: {
                    version: '1.0.4',
                    buildNumber: 26,
                    downloadURL: `${downloadBase}/VoiceLink-linux.AppImage`,
                    smartTarget: 'linux',
                    releaseNotes: 'Linux client release with AppImage and .deb installer support.'
                }
            };

            const platformInfo = latestVersions[platform] || latestVersions.macos;

            // Compare versions
            const compareVersions = (v1, v2) => {
                const p1 = v1.split('.').map(Number);
                const p2 = v2.split('.').map(Number);
                for (let i = 0; i < Math.max(p1.length, p2.length); i++) {
                    const n1 = p1[i] || 0;
                    const n2 = p2[i] || 0;
                    if (n1 > n2) return 1;
                    if (n1 < n2) return -1;
                }
                return 0;
            };

            const hasUpdate = compareVersions(platformInfo.version, currentVersion || '0.0.0') > 0;
            const updateAllowed = !isStoreManagedChannel;
            const checksumByPlatform = {
                macos: readChecksum('VoiceLink-1.0.0-macos.pkg'),
                windows: readChecksum('VoiceLink-1.0.0-windows-portable.exe'),
                linux: readChecksum('VoiceLink-linux.AppImage')
            };

            const windowsArtifacts = {
                portable: fileExists('VoiceLink-1.0.0-windows-portable.exe'),
                setup: fileExists('VoiceLink-1.0.0-windows-setup.exe'),
                buildZip: fileExists('VoiceLink-1.0.0-windows-build.zip')
            };

            res.json({
                updateAvailable: updateAllowed ? hasUpdate : false,
                version: platformInfo.version,
                buildNumber: platformInfo.buildNumber,
                downloadURL: updateAllowed && hasUpdate ? platformInfo.downloadURL : null,
                smartDownloadURL: updateAllowed && hasUpdate ? `${getSmartDlBase(req)}/${platformInfo.smartTarget}?os=${encodeURIComponent(platformInfo.smartTarget)}` : null,
                releaseNotes: updateAllowed && hasUpdate ? platformInfo.releaseNotes : null,
                checksum: checksumByPlatform[platform] || null,
                updateSource: updateAllowed ? 'self-updater' : 'store-managed',
                distChannel: requestedChannelRaw,
                message: updateAllowed ? null : 'Updates are managed by the app store channel for this build.',
                platform: platform || 'unknown',
                currentVersion: currentVersion || 'unknown',
                windowsArtifacts
            });
        });

        // Get all available downloads
        this.app.get('/api/downloads', (req, res) => {
            const downloadBase = getDownloadBase(req);
            const smartDlBase = getSmartDlBase(req);
            const resolvedDownloadRoot = getDownloadRoot();

            const readChecksum = (filename) => {
                if (!resolvedDownloadRoot) return null;
                const checksumPath = path.join(resolvedDownloadRoot, `${filename}.sha256`);
                if (!fs.existsSync(checksumPath)) return null;
                const raw = fs.readFileSync(checksumPath, 'utf8').trim();
                return raw ? (raw.split(/\s+/)[0] || null) : null;
            };

            const buildEntry = (filename, name, type, size = 'Current build', platform = '') => ({
                name,
                url: `${downloadBase}/${filename}`,
                smartUrl: `${smartDlBase}/${encodeURIComponent(filename)}${platform ? `?os=${encodeURIComponent(platform)}` : ''}`,
                size,
                type,
                checksum: readChecksum(filename),
                checksumUrl: `${downloadBase}/${filename}.sha256`
            });

            res.json({
                platforms: {
                    macos: {
                        version: '1.0.4',
                        downloads: [
                            buildEntry('VoiceLink-1.0.0-macos.pkg', 'macOS Installer (.pkg)', 'native', 'Current build', 'macos'),
                            buildEntry('VoiceLinkMacOS.zip', 'macOS ZIP (Alternative)', 'native', 'Current build', 'macos')
                        ]
                    },
                    windows: {
                        version: '1.0.4',
                        downloads: [
                            buildEntry('VoiceLink-1.0.0-windows-portable.exe', 'Windows Portable EXE', 'native', 'Current build', 'windows'),
                            buildEntry('VoiceLink-1.0.0-windows-setup.exe', 'Windows Setup EXE Installer', 'native', 'Current build', 'windows'),
                            buildEntry('VoiceLink-1.0.0-windows-build.zip', 'Windows Installer Builder ZIP', 'tools', 'Current build', 'windows')
                        ]
                    },
                    linux: {
                        version: '1.0.4',
                        downloads: [
                            buildEntry('VoiceLink-linux.AppImage', 'Linux AppImage', 'native', 'Current build', 'linux'),
                            buildEntry('voicelink-local_1.0.0_amd64.deb', 'Linux DEB', 'native', 'Current build', 'linux')
                        ]
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

        const clientRootDir = path.join(__dirname, '..', '..', 'client');
        const docsRootDir = path.join(__dirname, '..', '..', 'docs');
        const directHtmlRoots = [
            clientRootDir,
            path.join(clientRootDir, 'docs'),
            docsRootDir,
            path.join(docsRootDir, 'public')
        ];
        const sendDirectHtmlFile = (req, res, next) => {
            const requestPath = decodeURIComponent(req.path || '').replace(/\/+/g, '/');
            if (!/\.html?$/i.test(requestPath)) {
                return next();
            }

            const relativePath = requestPath.replace(/^\/+/, '');
            for (const baseDir of directHtmlRoots) {
                const basePath = path.resolve(baseDir);
                const candidatePath = path.resolve(baseDir, relativePath);
                if (!candidatePath.startsWith(`${basePath}${path.sep}`) && candidatePath !== basePath) {
                    continue;
                }
                if (fs.existsSync(candidatePath) && fs.statSync(candidatePath).isFile()) {
                    return res.sendFile(candidatePath);
                }
            }

            return next();
        };

        this.app.get(/.*\.html?$/i, sendDirectHtmlFile);

        // Serve the main client
        this.app.get('/', (req, res) => {
            res.sendFile(path.join(clientRootDir, 'index.html'));
        });

        // Serve downloads page
        this.app.get('/downloads.html', (req, res) => {
            res.sendFile(path.join(clientRootDir, 'downloads.html'));
        });

        // Setup federation API routes
        this.federation.setupRoutes(this.app);

        // Protocol handler redirect (vcl:// and legacy voicelink:// URLs)
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
                protocolUrl: `vcl://join/${roomId}?server=${encodeURIComponent(serverUrl)}`,
                legacyProtocolUrl: `voicelink://join/${roomId}?server=${encodeURIComponent(serverUrl)}`,
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
            this.emitRoomListToClients();

            this.saveRoomsToDisk(); // Auto-save after deletion
            res.json({ success: true, message: 'Room deleted' });
        });

        // Update room settings
        this.app.put('/api/rooms/:roomId', (req, res) => {
            const { roomId } = req.params;
            const updates = req.body;
            const room = this.rooms.get(roomId);
            const actingUser = this.getAnyAuthUserFromRequest ? this.getAnyAuthUserFromRequest(req) : null;
            const requestedBy = String(
                actingUser?.username
                || actingUser?.displayName
                || actingUser?.email
                || updates.updatedBy
                || updates.creatorHandle
                || ''
            ).trim();

            if (!room) {
                return res.status(404).json({ error: 'Room not found' });
            }

            const normalizedPreviousNames = Array.isArray(room.previousNames)
                ? room.previousNames.map((value) => String(value || '').trim()).filter(Boolean)
                : [];
            const proposedName = typeof updates.name === 'string' ? updates.name.trim() : '';
            const currentName = String(room.name || '').trim();

            // Apply updates
            if (proposedName && proposedName !== currentName) {
                const dedupedHistory = [
                    currentName,
                    ...normalizedPreviousNames.filter((value) => value.toLowerCase() !== currentName.toLowerCase())
                ].filter(Boolean);
                room.previousNames = Array.from(new Set(dedupedHistory)).slice(0, 5);
                room.name = proposedName;
            } else if (!Array.isArray(room.previousNames)) {
                room.previousNames = normalizedPreviousNames;
            }
            if (updates.description !== undefined) room.description = String(updates.description || '');
            if (updates.welcomeMessage !== undefined) room.welcomeMessage = String(updates.welcomeMessage || '').trim() || null;
            if (updates.maxUsers) room.maxUsers = updates.maxUsers;
            if (updates.visibility) room.visibility = updates.visibility;
            if (updates.accessType) room.accessType = updates.accessType;
            if (updates.visibleToGuests !== undefined) room.visibleToGuests = !!updates.visibleToGuests;
            if (updates.allowEmbed !== undefined) room.allowEmbed = !!updates.allowEmbed;
            if (updates.showInApp !== undefined) room.showInApp = !!updates.showInApp;
            if (updates.password !== undefined) room.password = updates.password || null;
            if (updates.isDefault !== undefined) room.isDefault = updates.isDefault;
            if (updates.locked !== undefined) room.locked = !!updates.locked;
            if (updates.enabled !== undefined) room.enabled = !!updates.enabled;
            if (updates.hidden !== undefined) room.hidden = !!updates.hidden;

            room.lastUpdated = new Date();
            room.updatedAt = room.lastUpdated;
            if (requestedBy) {
                room.updatedBy = requestedBy;
            }
            this.rooms.set(roomId, room);
            this.federation.broadcastRoomChange('updated', room);
            this.emitRoomListToClients();
            this.saveRoomsToDisk();

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
        // DEVICE PAIRING & MANAGEMENT
        // Remote authentication and access control
        // ============================================

        const localAuthDataPath = path.join(__dirname, '../../data/local-auth-users.json');
        this.localAuthUsers = this.localAuthUsers || new Map();
        this.whmcsIdentityAliases = this.whmcsIdentityAliases || new Map();
        this.localAuthSessions = this.localAuthSessions || new Map();
        this.localAuthSessionTtlMs = 30 * 24 * 60 * 60 * 1000; // 30 days
        // If SMTP is not configured, allow credential registration without blocking on email code.
        this.localAuthVerificationRequired = process.env.VOICELINK_REQUIRE_EMAIL_VERIFICATION !== 'false' && !!this.mailer;

        const persistLocalAuthUsers = () => {
            try {
                const users = Array.from(this.localAuthUsers.values());
                const whmcsAliases = Object.fromEntries(Array.from(this.whmcsIdentityAliases.entries()).sort(([a], [b]) => a.localeCompare(b)));
                const payload = { users, whmcsAliases };
                fs.writeFileSync(localAuthDataPath, JSON.stringify(payload, null, 2));
                try {
                    databaseStorage.mirrorJsonFile('accounts', 'local-auth-users', localAuthDataPath, payload);
                } catch (mirrorError) {
                    console.warn('[Auth] Database mirror skipped:', mirrorError.message);
                }
            } catch (error) {
                console.error('[Auth] Failed to persist local auth users:', error.message);
            }
        };

        if (!this.localAuthLoaded) {
            this.localAuthLoaded = true;
            try {
                if (fs.existsSync(localAuthDataPath)) {
                    const parsed = JSON.parse(fs.readFileSync(localAuthDataPath, 'utf8') || '{}');
                    const users = Array.isArray(parsed.users) ? parsed.users : [];
                    users.forEach((user) => {
                        if (user?.id) this.localAuthUsers.set(user.id, user);
                    });
                    const aliases = parsed.whmcsAliases && typeof parsed.whmcsAliases === 'object'
                        ? Object.entries(parsed.whmcsAliases)
                        : [];
                    aliases.forEach(([alias, email]) => {
                        const normalizedAlias = normalizeUsername(alias);
                        const normalizedEmail = normalizeEmail(email);
                        if (normalizedAlias && normalizedEmail) {
                            this.whmcsIdentityAliases.set(normalizedAlias, normalizedEmail);
                        }
                    });
                    console.log(`[Auth] Loaded ${this.localAuthUsers.size} local credential users`);
                }
            } catch (error) {
                console.error('[Auth] Failed loading local auth users:', error.message);
            }
        }

        const normalizeEmail = (email) => String(email || '').trim().toLowerCase();
        const normalizeUsername = (username) => String(username || '').trim().toLowerCase();
        const validateEmail = (email) => /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(String(email || '').trim());
        const validateUsername = (username) => /^[a-zA-Z0-9._-]{3,32}$/.test(String(username || '').trim());
        const normalizeUserRole = (role) => {
            const value = String(role || '').trim().toLowerCase();
            if (['owner', 'server_owner'].includes(value)) return 'owner';
            if (['admin', 'administrator', 'server_admin'].includes(value)) return 'admin';
            if (['moderator', 'mod', 'staff', 'support', 'manager', 'room_admin', 'room_moderator'].includes(value)) return 'staff';
            if (['member', 'client', 'customer', 'subscriber', 'user'].includes(value)) return 'user';
            return value || 'user';
        };
        const buildPermissionsForRole = (role) => {
            const normalizedRole = normalizeUserRole(role);
            if (normalizedRole === 'owner') return ['owner', 'admin', 'staff', 'client'];
            if (normalizedRole === 'admin') return ['admin', 'staff', 'client'];
            if (normalizedRole === 'staff') return ['staff', 'client'];
            return ['client'];
        };
        const normalizeCreditEntry = (entry = {}, fallback = {}) => {
            const amount = Number(entry.amount ?? fallback.amount ?? 0);
            if (!Number.isFinite(amount) || amount === 0) return null;
            return {
                id: String(entry.id || fallback.id || `credit_${uuidv4()}`).trim(),
                amount,
                source: String(entry.source || fallback.source || 'manual').trim() || 'manual',
                spendAllowed: entry.spendAllowed !== false,
                featureScope: Array.isArray(entry.featureScope)
                    ? entry.featureScope.map((value) => String(value || '').trim()).filter(Boolean)
                    : Array.isArray(fallback.featureScope)
                        ? fallback.featureScope.map((value) => String(value || '').trim()).filter(Boolean)
                        : ['all'],
                grantedBy: String(entry.grantedBy || fallback.grantedBy || '').trim() || null,
                grantedAt: String(entry.grantedAt || fallback.grantedAt || new Date().toISOString()),
                expiresAt: entry.expiresAt ? String(entry.expiresAt) : (fallback.expiresAt ? String(fallback.expiresAt) : null),
                serverScope: String(entry.serverScope || fallback.serverScope || '').trim() || null,
                roomScope: String(entry.roomScope || fallback.roomScope || '').trim() || null,
                nonTransferable: entry.nonTransferable !== false,
                metadata: (entry.metadata && typeof entry.metadata === 'object') ? entry.metadata : ((fallback.metadata && typeof fallback.metadata === 'object') ? fallback.metadata : {})
            };
        };
        const buildCreditEntitlements = (existing = {}) => {
            const ledger = Array.isArray(existing?.ledger)
                ? existing.ledger.map((entry) => normalizeCreditEntry(entry)).filter(Boolean)
                : [];
            const balance = ledger.reduce((sum, entry) => sum + Number(entry.amount || 0), 0);
            return {
                enabled: existing?.enabled !== false,
                currency: String(existing?.currency || 'credits').trim() || 'credits',
                balance,
                available: balance,
                spendPriority: Array.isArray(existing?.spendPriority) && existing.spendPriority.length
                    ? existing.spendPriority
                    : ['promo', 'admin_grant', 'subscription', 'wallet'],
                adminGrantsSpendableByDefault: existing?.adminGrantsSpendableByDefault !== false,
                ledger
            };
        };
        const buildAffiliateEntitlements = (existing = {}) => ({
            enabled: existing?.enabled === true,
            affiliateId: String(existing?.affiliateId || '').trim() || null,
            referralCode: String(existing?.referralCode || '').trim() || null,
            referralLink: String(existing?.referralLink || '').trim() || null,
            attributionSource: String(existing?.attributionSource || '').trim() || null,
            attributionToken: String(existing?.attributionToken || '').trim() || null,
            rewardProfile: (existing?.rewardProfile && typeof existing.rewardProfile === 'object') ? existing.rewardProfile : {},
            rewards: Array.isArray(existing?.rewards) ? existing.rewards : []
        });
        const buildStealthPresenceEntitlements = (role, existing = {}) => {
            const normalizedRole = normalizeUserRole(role);
            const isPrivilegedRole = ['owner', 'admin', 'staff'].includes(normalizedRole);
            return {
                enabled: existing?.enabled === true || isPrivilegedRole,
                available: existing?.available === true || isPrivilegedRole,
                canUseInvisible: existing?.canUseInvisible === true || isPrivilegedRole,
                canPostAnonymously: existing?.canPostAnonymously === true || isPrivilegedRole,
                canObserveSilently: existing?.canObserveSilently === true || isPrivilegedRole,
                canViewHiddenUsers: existing?.canViewHiddenUsers === true || isPrivilegedRole,
                canEnableForOwnedRooms: existing?.canEnableForOwnedRooms === true || isPrivilegedRole,
                creditEligible: existing?.creditEligible !== false,
                policy: (existing?.policy && typeof existing.policy === 'object')
                    ? existing.policy
                    : {
                        defaultRoomPolicy: isPrivilegedRole ? 'admins_only' : 'disabled',
                        anonymousLabel: 'Announcement',
                        adminRevealOnEnforcement: true
                    },
                guardrails: (existing?.guardrails && typeof existing.guardrails === 'object')
                    ? existing.guardrails
                    : {
                        anonymousPostsPerMinute: 6,
                        roomSwitchesPerMinute: 10,
                        observeSessionLimitMinutes: 180,
                        autoSuspendThreshold: 3
                    }
            };
        };
        const buildPartnerAccessEntitlements = (existing = {}) => ({
            openclaw: {
                bonusAccess: existing?.openclaw?.bonusAccess === true,
                source: String(existing?.openclaw?.source || '').trim() || null
            },
            clawdx: {
                bonusAccess: existing?.clawdx?.bonusAccess === true,
                source: String(existing?.clawdx?.source || '').trim() || null
            },
            thriveMessenger: {
                bonusAccess: existing?.thriveMessenger?.bonusAccess === true,
                source: String(existing?.thriveMessenger?.source || '').trim() || null
            }
        });
        const buildDefaultEntitlements = (role, existing = {}) => {
            const normalizedRole = normalizeUserRole(role);
            const deviceTier = existing?.deviceTier || (normalizedRole === 'owner' ? 'owner' : normalizedRole === 'admin' ? 'admin' : 'standard');
            const maxDevices = existing?.maxDevices ?? null;
            const installSlots = existing?.installSlots ?? 1;
            const serverSlots = existing?.serverSlots ?? (normalizedRole === 'owner' || normalizedRole === 'admin' ? 1 : 0);
            const serverOwnerLicense = existing?.serverOwnerLicense ?? (normalizedRole === 'owner' || normalizedRole === 'admin');
            const billingModel = existing?.billingModel || 'manual';
            return {
                deviceTier,
                maxDevices,
                installSlots,
                serverSlots,
                billingModel,
                licenseTier: existing?.licenseTier || (normalizedRole === 'owner' ? 'owner' : normalizedRole === 'admin' ? 'admin' : normalizedRole === 'staff' ? 'staff' : 'member'),
                serverOwnerLicense,
                hostingControlPanelLinked: existing?.hostingControlPanelLinked === true,
                hostingRoles: Array.isArray(existing?.hostingRoles) ? existing.hostingRoles : [],
                hostingPermissions: Array.isArray(existing?.hostingPermissions) ? existing.hostingPermissions : [],
                licenses: existing?.licenses || {
                    user: {
                        type: 'member',
                        installsAllowed: installSlots,
                        devicesAllowed: maxDevices
                    },
                    server: {
                        type: serverOwnerLicense ? 'server_owner' : 'none',
                        installsAllowed: installSlots,
                        serversAllowed: serverSlots
                    }
                },
                allowMultiDeviceSettings: existing?.allowMultiDeviceSettings !== false,
                allowDeviceList: existing?.allowDeviceList !== false,
                requiresIapApple: existing?.requiresIapApple === true,
                allowsLicenseTransfer: existing?.allowsLicenseTransfer === true,
                requiresManualTransferApproval: existing?.requiresManualTransferApproval === true,
                transferCooldownDays: Number.isFinite(existing?.transferCooldownDays) ? Number(existing.transferCooldownDays) : 30,
                purchaseSources: Array.isArray(existing?.purchaseSources) ? existing.purchaseSources : [],
                appStore: existing?.appStore || null,
                credits: buildCreditEntitlements(existing?.credits || {}),
                affiliate: buildAffiliateEntitlements(existing?.affiliate || {}),
                stealthPresence: buildStealthPresenceEntitlements(normalizedRole, existing?.stealthPresence || {}),
                partnerAccess: buildPartnerAccessEntitlements(existing?.partnerAccess || {})
            };
        };
        const issueLocalAuthToken = (userId) => {
            const token = `vl_local_${uuidv4()}_${Date.now().toString(36)}`;
            this.localAuthSessions.set(token, {
                userId,
                createdAt: new Date(),
                expiresAt: new Date(Date.now() + this.localAuthSessionTtlMs)
            });
            return token;
        };
        const tokenFromRequest = (req) => {
            const header = req.headers.authorization || req.headers.Authorization;
            if (header && typeof header === 'string' && header.startsWith('Bearer ')) {
                return header.slice(7).trim();
            }
            return String(req.body?.accessToken || req.query?.accessToken || '').trim() || null;
        };
        const getUserFromToken = (token) => {
            if (!token) return null;
            const session = this.localAuthSessions.get(token);
            if (!session) return null;
            if (new Date() > new Date(session.expiresAt)) {
                this.localAuthSessions.delete(token);
                return null;
            }
            return this.localAuthUsers.get(session.userId) || null;
        };
        const getWhmcsUserFromToken = (token) => {
            if (!token) return null;
            const session = this.getAuthSession(this.whmcsAuthSessions, token);
            return session?.user || null;
        };
        this.getLocalAuthUserFromRequest = (req) => getUserFromToken(tokenFromRequest(req));
        this.getAnyAuthUserFromRequest = (req) => getUserFromToken(tokenFromRequest(req)) || getWhmcsUserFromToken(tokenFromRequest(req));
        this.isLocalAdminRequest = (req) => {
            const user = this.getAnyAuthUserFromRequest(req);
            if (!user) return false;
            const role = String(user.role || 'user').toLowerCase();
            return role === 'owner' || role === 'admin';
        };
        const hashPassword = (password, salt) => crypto.pbkdf2Sync(
            String(password || ''),
            salt,
            120000,
            64,
            'sha512'
        ).toString('hex');
        const buildPasswordHash = (password) => {
            const salt = crypto.randomBytes(16).toString('hex');
            const hash = hashPassword(password, salt);
            return { salt, hash };
        };
        const findLocalUserByIdentity = (identity) => {
            const value = String(identity || '').trim();
            if (!value) return null;
            const email = normalizeEmail(value);
            const username = normalizeUsername(value);
            for (const user of this.localAuthUsers.values()) {
                if (normalizeEmail(user.email) === email || normalizeUsername(user.username) === username) {
                    return user;
                }
            }
            return null;
        };
        const buildLinkedAuthRecord = (provider = '', payload = {}) => ({
            provider: String(provider || payload.authProvider || 'local').trim().toLowerCase() || 'local',
            email: normalizeEmail(payload.email || ''),
            username: normalizeUsername(payload.username || payload.displayName || ''),
            externalId: String(payload.externalId || payload.id || '').trim() || null,
            linkedAt: payload.linkedAt || new Date().toISOString(),
            lastUsedAt: new Date().toISOString()
        });
        const mergeLinkedAuthMethods = (user, provider = '', payload = {}) => {
            if (!user) return user;
            const next = buildLinkedAuthRecord(provider, payload);
            const methods = Array.isArray(user.linkedAuthMethods) ? [...user.linkedAuthMethods] : [];
            const existingIndex = methods.findIndex((entry) =>
                String(entry?.provider || '').trim().toLowerCase() === next.provider
                && (
                    (next.email && normalizeEmail(entry?.email || '') === next.email)
                    || (next.username && normalizeUsername(entry?.username || '') === next.username)
                    || (next.externalId && String(entry?.externalId || '').trim() === next.externalId)
                )
            );
            if (existingIndex >= 0) {
                methods[existingIndex] = {
                    ...methods[existingIndex],
                    ...next,
                    linkedAt: methods[existingIndex].linkedAt || next.linkedAt,
                    lastUsedAt: next.lastUsedAt
                };
            } else {
                methods.push(next);
            }
            user.linkedAuthMethods = methods;
            return user;
        };
        const linkCanonicalAccountByEmail = (provider = '', payload = {}) => {
            const email = normalizeEmail(payload.email || '');
            const username = normalizeUsername(payload.username || payload.displayName || '');
            if (!email && !username) return null;
            const localUser = findLocalUserByIdentity(email || username);
            if (!localUser) return null;
            mergeLinkedAuthMethods(localUser, provider, payload);
            if (email && !normalizeEmail(localUser.email)) {
                localUser.email = email;
            }
            if (username && !normalizeUsername(localUser.username)) {
                localUser.username = username;
            }
            if (!String(localUser.displayName || '').trim() && String(payload.displayName || '').trim()) {
                localUser.displayName = String(payload.displayName || '').trim();
            }
            localUser.updatedAt = new Date().toISOString();
            this.localAuthUsers.set(localUser.id, localUser);
            persistLocalAuthUsers();
            return localUser;
        };
        const decorateUserWithCanonicalAccount = (user, provider = '', payload = {}) => {
            if (!user) return user;
            const canonical = linkCanonicalAccountByEmail(provider, {
                id: payload.id || user.id,
                email: payload.email || user.email,
                username: payload.username || user.username,
                displayName: payload.displayName || user.displayName,
                externalId: payload.externalId || user.whmcsClientId || user.whmcsAdminId || user.id
            });
            if (!canonical) {
                user.linkedAuthMethods = Array.isArray(user.linkedAuthMethods) ? user.linkedAuthMethods : [];
                return user;
            }
            user.accountId = canonical.id;
            user.canonicalAccountId = canonical.id;
            user.canonicalEmail = canonical.email || user.email || null;
            user.linkedLocalUserId = canonical.id;
            user.linkedAuthMethods = Array.isArray(canonical.linkedAuthMethods) ? canonical.linkedAuthMethods : [];
            user.displayName = user.displayName || canonical.displayName || canonical.username || user.username;
            return user;
        };
        const getLocal2FAState = (user) => {
            if (!user?.id || !this.modules.twoFactorAuth) {
                return { required: false, enabled: false, methods: [] };
            }
            const normalizedRole = normalizeUserRole(user.role);
            const methods = this.modules.twoFactorAuth.getAvailableMethods(user.id);
            const enabled = this.modules.twoFactorAuth.has2FAEnabled(user.id);
            const required = enabled && this.modules.twoFactorAuth.is2FARequired(user.id, normalizedRole === 'owner' ? 'admin' : normalizedRole);
            return { required, enabled, methods };
        };
        const sendLocalTwoFactorCode = async (user, preferredMethod = '') => {
            if (!user?.id || !this.modules.twoFactorAuth) {
                return { success: false, error: 'Two-factor authentication not available' };
            }
            const settings = this.modules.twoFactorAuth.getUserSettings(user.id);
            const normalizedMethod = String(preferredMethod || '').trim().toLowerCase();
            const emailConfigured = settings?.methods?.email?.enabled && settings?.methods?.email?.verified;
            const smsConfigured = settings?.methods?.sms?.enabled && settings?.methods?.sms?.verified;

            let method = normalizedMethod;
            if (!method) {
                if (emailConfigured) method = 'email';
                else if (smsConfigured) method = 'sms';
            }

            if (method === 'email') {
                return this.modules.twoFactorAuth.sendEmailCode(user.id);
            }
            if (method === 'sms') {
                return this.modules.twoFactorAuth.sendSMSCode(user.id);
            }
            return { success: false, error: 'Selected 2FA method does not support code delivery', methods: this.modules.twoFactorAuth.getAvailableMethods(user.id) };
        };
        const verifyLocalTwoFactorCode = (user, code) => {
            if (!user?.id || !this.modules.twoFactorAuth) {
                return { success: false, error: 'Two-factor authentication not available' };
            }
            const token = String(code || '').replace(/\s+/g, '');
            if (!token) {
                return { success: false, error: 'Two-factor authentication code required' };
            }

            const availableMethods = this.modules.twoFactorAuth.getAvailableMethods(user.id);
            const orderedTypes = availableMethods.map((method) => method.type);
            if (!orderedTypes.includes('totp')) orderedTypes.unshift('totp');
            if (!orderedTypes.includes('backup')) orderedTypes.push('backup');

            for (const type of orderedTypes) {
                let result = null;
                if (type === 'totp') result = this.modules.twoFactorAuth.verifyTOTP(user.id, token);
                else if (type === 'email') result = this.modules.twoFactorAuth.verifyEmailLogin(user.id, token);
                else if (type === 'sms') result = this.modules.twoFactorAuth.verifySMSLogin(user.id, token);
                else if (type === 'backup') result = this.modules.twoFactorAuth.verifyBackupCode(user.id, token);

                if (result?.success) {
                    return { success: true, method: type };
                }
            }

            return {
                success: false,
                error: 'Invalid verification code',
                methods: availableMethods
            };
        };
        const describePasskeyState = (user) => {
            const supported = !!this.modules.twoFactorAuth;
            if (!supported || !user) {
                return {
                    supported,
                    eligible: false,
                    registered: false,
                    count: 0,
                    recommendedAfterMinutes: 10
                };
            }

            const linkedLocalUser = (user.linkedLocalUserId && this.localAuthUsers.get(user.linkedLocalUserId))
                || (user.canonicalAccountId && this.localAuthUsers.get(user.canonicalAccountId))
                || findLocalUserByIdentity(user.email || user.username || '');
            const targetUser = linkedLocalUser || user;
            const settings = targetUser?.id ? this.modules.twoFactorAuth.getUserSettings(targetUser.id) : null;
            const credentials = settings?.methods?.passkey?.credentials || [];
            const registered = credentials.length > 0;
            const normalizedRole = normalizeUserRole(targetUser?.role || user.role);
            const eligible = Boolean(targetUser?.id && (targetUser?.email || targetUser?.username) && normalizedRole !== 'guest');

            return {
                supported,
                eligible,
                registered,
                count: credentials.length,
                recommendedAfterMinutes: 10
            };
        };
        const publicLocalUser = (user) => ({
            id: user.id,
            username: user.username,
            email: user.email,
            displayName: user.displayName || user.username,
            authMethod: 'email',
            authProvider: user.authProvider || 'local',
            role: normalizeUserRole(user.role),
            permissions: Array.isArray(user.permissions) && user.permissions.length ? user.permissions : buildPermissionsForRole(user.role),
            entitlements: buildDefaultEntitlements(user.role, user.entitlements),
            isAdmin: ['owner', 'admin'].includes(normalizeUserRole(user.role)),
            isModerator: normalizeUserRole(user.role) === 'staff',
            isVerified: !!user.isVerified,
            createdAt: user.createdAt,
            linkedAuthMethods: Array.isArray(user.linkedAuthMethods) ? user.linkedAuthMethods : [],
            passkey: describePasskeyState(user)
        });

        // Local credential auth (email + username + password)
        this.app.post('/api/auth/local/register', (req, res) => {
            const email = normalizeEmail(req.body?.email);
            const username = normalizeUsername(req.body?.username);
            const displayName = String(req.body?.displayName || req.body?.username || '').trim();
            const password = String(req.body?.password || '');
            const verificationCode = String(req.body?.verificationCode || '').trim();
            const clientId = String(req.body?.clientId || '').trim();

            if (!email || !username || !password) {
                return res.status(400).json({ error: 'Email, username, and password are required' });
            }
            if (!validateEmail(email)) {
                return res.status(400).json({ error: 'Invalid email format' });
            }
            if (!validateUsername(username)) {
                return res.status(400).json({ error: 'Username must be 3-32 chars (letters, numbers, ., _, -)' });
            }
            if (password.length < 8) {
                return res.status(400).json({ error: 'Password must be at least 8 characters' });
            }
            if (findLocalUserByIdentity(email) || findLocalUserByIdentity(username)) {
                return res.status(409).json({ error: 'An account with this email or username already exists' });
            }

            if (this.localAuthVerificationRequired) {
                const verification = this.emailVerificationCodes.get(email);
                if (!verification) {
                    return res.status(400).json({ error: 'Email verification required. Request a code first.' });
                }
                if (new Date() > verification.expiresAt) {
                    this.emailVerificationCodes.delete(email);
                    return res.status(400).json({ error: 'Verification code expired. Request a new code.' });
                }
                if (clientId && verification.clientId && verification.clientId !== clientId) {
                    return res.status(400).json({ error: 'Verification must be completed on the same device' });
                }
                if (!verificationCode || verification.code !== verificationCode) {
                    return res.status(400).json({ error: 'Invalid verification code' });
                }
                this.emailVerificationCodes.delete(email);
            }

            const { salt, hash } = buildPasswordHash(password);
            const hasOwner = Array.from(this.localAuthUsers.values()).some((u) =>
                String(u.role || '').toLowerCase() === 'owner'
            );
            const assignedRole = hasOwner ? 'user' : 'owner';
            const user = {
                id: `usr_${uuidv4()}`,
                username,
                displayName: displayName || username,
                email,
                linkedAuthMethods: [buildLinkedAuthRecord('local', { email, username, displayName, externalId: username })],
                passwordSalt: salt,
                passwordHash: hash,
                role: assignedRole,
                permissions: buildPermissionsForRole(assignedRole),
                entitlements: buildDefaultEntitlements(assignedRole),
                isVerified: this.localAuthVerificationRequired,
                createdAt: new Date().toISOString(),
                updatedAt: new Date().toISOString()
            };

            mergeLinkedAuthMethods(user, 'local', {
                email: user.email,
                username: user.username,
                displayName: user.displayName,
                externalId: user.id
            });
            this.localAuthUsers.set(user.id, user);
            persistLocalAuthUsers();
            const accessToken = issueLocalAuthToken(user.id);

            return res.json({
                success: true,
                accessToken,
                user: publicLocalUser(user)
            });
        });

        this.app.post('/api/auth/local/login', (req, res) => {
            const identity = String(req.body?.identity || req.body?.email || req.body?.username || '').trim();
            const password = String(req.body?.password || '');
            const twoFactorCode = String(req.body?.twoFactorCode || req.body?.otp || '').trim();
            if (!identity || !password) {
                return res.status(400).json({ error: 'Identity and password are required' });
            }

            const user = findLocalUserByIdentity(identity);
            if (!user) {
                return res.status(401).json({ error: 'Invalid credentials' });
            }

            const candidate = hashPassword(password, user.passwordSalt);
            const expectedBuffer = Buffer.from(user.passwordHash || '', 'hex');
            const candidateBuffer = Buffer.from(candidate, 'hex');
            if (expectedBuffer.length !== candidateBuffer.length || !crypto.timingSafeEqual(expectedBuffer, candidateBuffer)) {
                return res.status(401).json({ error: 'Invalid credentials' });
            }

            if (this.localAuthVerificationRequired && !user.isVerified) {
                return res.status(403).json({ error: 'Account is not verified' });
            }

            mergeLinkedAuthMethods(user, 'local', {
                email: user.email,
                username: user.username,
                displayName: user.displayName,
                externalId: user.id
            });

            const twoFactorState = getLocal2FAState(user);
            if (twoFactorState.required) {
                if (!twoFactorCode) {
                    return res.status(401).json({
                        success: false,
                        requires2FA: true,
                        availableMethods: twoFactorState.methods,
                        error: 'Two-factor authentication code required'
                    });
                }

                const verificationResult = verifyLocalTwoFactorCode(user, twoFactorCode);
                if (!verificationResult.success) {
                    return res.status(401).json({
                        success: false,
                        requires2FA: true,
                        availableMethods: twoFactorState.methods,
                        error: verificationResult.error || 'Invalid verification code'
                    });
                }
            }

            user.updatedAt = new Date().toISOString();
            this.localAuthUsers.set(user.id, user);
            persistLocalAuthUsers();
            const accessToken = issueLocalAuthToken(user.id);

            return res.json({
                success: true,
                accessToken,
                user: publicLocalUser(user)
            });
        });

        this.app.post('/api/auth/local/2fa/challenge', async (req, res) => {
            const identity = String(req.body?.identity || req.body?.email || req.body?.username || '').trim();
            const password = String(req.body?.password || '');
            const preferredMethod = String(req.body?.method || '').trim().toLowerCase();
            if (!identity || !password) {
                return res.status(400).json({ success: false, error: 'Identity and password are required' });
            }

            const user = findLocalUserByIdentity(identity);
            if (!user) {
                return res.status(401).json({ success: false, error: 'Invalid credentials' });
            }

            const candidate = hashPassword(password, user.passwordSalt);
            const expectedBuffer = Buffer.from(user.passwordHash || '', 'hex');
            const candidateBuffer = Buffer.from(candidate, 'hex');
            if (expectedBuffer.length !== candidateBuffer.length || !crypto.timingSafeEqual(expectedBuffer, candidateBuffer)) {
                return res.status(401).json({ success: false, error: 'Invalid credentials' });
            }

            const twoFactorState = getLocal2FAState(user);
            if (!twoFactorState.required) {
                return res.json({
                    success: true,
                    requires2FA: false,
                    availableMethods: twoFactorState.methods
                });
            }

            const challengeResult = await sendLocalTwoFactorCode(user, preferredMethod);
            if (!challengeResult.success) {
                return res.status(400).json({
                    success: false,
                    requires2FA: true,
                    availableMethods: twoFactorState.methods,
                    error: challengeResult.error || 'Unable to send verification code'
                });
            }

            return res.json({
                success: true,
                requires2FA: true,
                method: preferredMethod || 'email',
                hint: challengeResult.hint || null,
                expiresIn: challengeResult.expiresIn || null,
                availableMethods: twoFactorState.methods
            });
        });

        this.app.get('/api/auth/local/me', (req, res) => {
            const token = tokenFromRequest(req);
            const user = getUserFromToken(token);
            if (!user) {
                return res.status(401).json({ error: 'Unauthorized' });
            }
            return res.json({ success: true, user: publicLocalUser(user) });
        });

        this.app.post('/api/auth/local/logout', (req, res) => {
            const token = tokenFromRequest(req);
            if (token) this.localAuthSessions.delete(token);
            return res.json({ success: true });
        });

        this.ownerSetupTokens = this.ownerSetupTokens || new Map();
        this.adminInviteTokens = this.adminInviteTokens || new Map();

        this.app.post('/api/auth/local/owner-token', (req, res) => {
            const hasOwner = Array.from(this.localAuthUsers.values()).some((u) =>
                String(u.role || '').toLowerCase() === 'owner'
            );
            if (hasOwner && !this.isLocalAdminRequest(req)) {
                return res.status(403).json({ success: false, error: 'Admin authentication required' });
            }
            const token = `vlowner_${uuidv4()}_${Date.now().toString(36)}`;
            const expiresAt = new Date(Date.now() + 15 * 60 * 1000);
            this.ownerSetupTokens.set(token, { createdAt: new Date(), expiresAt });
            return res.json({ success: true, token, expiresAt });
        });

        this.app.post('/api/auth/local/claim-owner', (req, res) => {
            const token = String(req.body?.token || '').trim();
            const identity = String(req.body?.identity || req.body?.email || req.body?.username || '').trim();
            if (!token || !identity) {
                return res.status(400).json({ success: false, error: 'Token and identity are required' });
            }
            const record = this.ownerSetupTokens.get(token);
            if (!record || new Date() > new Date(record.expiresAt)) {
                this.ownerSetupTokens.delete(token);
                return res.status(400).json({ success: false, error: 'Token is invalid or expired' });
            }
            const user = findLocalUserByIdentity(identity);
            if (!user) {
                return res.status(404).json({ success: false, error: 'User not found' });
            }
            user.role = 'owner';
            user.updatedAt = new Date().toISOString();
            this.localAuthUsers.set(user.id, user);
            this.ownerSetupTokens.delete(token);
            persistLocalAuthUsers();
            return res.json({ success: true, user: publicLocalUser(user) });
        });

        const licensingStatePath = path.join(__dirname, '../../data/licensing-state.json');
        this.licensingState = this.licensingState || { licenses: {} };
        if (!this.licensingLoaded) {
            this.licensingLoaded = true;
            try {
                if (fs.existsSync(licensingStatePath)) {
                    const parsed = JSON.parse(fs.readFileSync(licensingStatePath, 'utf8') || '{}');
                    this.licensingState = {
                        licenses: parsed.licenses && typeof parsed.licenses === 'object' ? parsed.licenses : {}
                    };
                }
            } catch (error) {
                console.error('[Licensing] Failed loading licensing state:', error.message);
            }
        }

        const persistLicensingState = () => {
            try {
                fs.writeFileSync(licensingStatePath, JSON.stringify(this.licensingState, null, 2));
            } catch (error) {
                console.error('[Licensing] Failed persisting licensing state:', error.message);
            }
        };

        const licensingConfig = () => {
            const cfg = deployConfig.get('licensing') || {};
            return {
                registrationDelayMinutes: Number.isFinite(cfg.registrationDelayMinutes) ? Number(cfg.registrationDelayMinutes) : 15,
                defaultMaxDevices: Number.isFinite(cfg.defaultMaxDevices) ? Number(cfg.defaultMaxDevices) : 3,
                defaultInstallSlots: Number.isFinite(cfg.defaultInstallSlots) ? Number(cfg.defaultInstallSlots) : 1,
                defaultServerSlots: Number.isFinite(cfg.defaultServerSlots) ? Number(cfg.defaultServerSlots) : 0,
                autoRemoveOldestDeviceOnOverflow: cfg.autoRemoveOldestDeviceOnOverflow !== false,
                machineHistoryRetentionDays: Math.min(3650, Math.max(30, Number(cfg.machineHistoryRetentionDays || 90)))
            };
        };

        const makeLicenseKey = () => `VL-${crypto.randomBytes(4).toString('hex').toUpperCase()}-${crypto.randomBytes(4).toString('hex').toUpperCase()}`;

        const normalizeLicenseIdentityKey = ({ email = '', username = '', authProvider = '', id = '' } = {}) => {
            const normalizedEmail = normalizeEmail(email);
            if (normalizedEmail) return `email:${normalizedEmail}`;
            const normalizedUsername = normalizeUsername(username);
            if (normalizedUsername && authProvider) return `${String(authProvider).trim().toLowerCase()}:${normalizedUsername}`;
            if (normalizedUsername) return `username:${normalizedUsername}`;
            if (id) return `id:${String(id).trim().toLowerCase()}`;
            return '';
        };

        const normalizeBoundDomain = (value = '') => String(value || '')
            .trim()
            .toLowerCase()
            .replace(/^https?:\/\//, '')
            .replace(/\/.*$/, '')
            .replace(/:\d+$/, '')
            .replace(/\.$/, '');

        const normalizeBoundIp = (value = '') => String(value || '')
            .trim()
            .replace(/^\[|\]$/g, '');

        const extractDomainFromUrl = (value = '') => {
            try {
                const candidate = String(value || '').trim();
                if (!candidate) return '';
                const url = new URL(candidate.includes('://') ? candidate : `https://${candidate}`);
                return normalizeBoundDomain(url.hostname);
            } catch {
                return '';
            }
        };

        const mergeBoundDomainsIntoRecord = (record = {}, incoming = []) => {
            const current = Array.isArray(record.boundDomains) ? record.boundDomains : [];
            const merged = new Map();
            [...current, ...incoming].forEach((entry = {}) => {
                const domain = normalizeBoundDomain(entry.domain || entry.hostname || '');
                if (!domain) return;
                const existing = merged.get(domain) || {};
                merged.set(domain, {
                    domain,
                    type: entry.type || existing.type || (domain.split('.').length > 2 ? 'subdomain' : 'domain'),
                    source: entry.source || existing.source || 'manual',
                    status: entry.status || existing.status || 'active',
                    linkedAt: existing.linkedAt || entry.linkedAt || new Date().toISOString(),
                    lastSeen: entry.lastSeen || existing.lastSeen || new Date().toISOString(),
                    serverId: entry.serverId || existing.serverId || null,
                    nodeId: entry.nodeId || existing.nodeId || null,
                    nodeUrl: entry.nodeUrl || existing.nodeUrl || null,
                    ipAddress: entry.ipAddress || existing.ipAddress || null,
                    installType: entry.installType || existing.installType || 'server'
                });
            });
            record.boundDomains = Array.from(merged.values());
        };

        const mergeInstallEndpointsIntoRecord = (record = {}, incoming = []) => {
            const current = Array.isArray(record.installEndpoints) ? record.installEndpoints : [];
            const merged = new Map();
            [...current, ...incoming].forEach((entry = {}) => {
                const key = [
                    String(entry.serverId || '').trim(),
                    String(entry.nodeId || '').trim(),
                    normalizeBoundDomain(entry.domain || ''),
                    normalizeBoundIp(entry.ipAddress || ''),
                    String(entry.nodeUrl || '').trim()
                ].join('|');
                if (!key.replace(/\|/g, '')) return;
                merged.set(key, {
                    serverId: entry.serverId || null,
                    nodeId: entry.nodeId || null,
                    nodeUrl: entry.nodeUrl || null,
                    domain: normalizeBoundDomain(entry.domain || ''),
                    ipAddress: normalizeBoundIp(entry.ipAddress || ''),
                    privateIpAddress: normalizeBoundIp(entry.privateIpAddress || ''),
                    installType: entry.installType || 'server',
                    selfHosted: entry.selfHosted !== false,
                    federationEligible: entry.federationEligible !== false,
                    moduleRepoAccess: entry.moduleRepoAccess !== false,
                    linkedAt: entry.linkedAt || new Date().toISOString(),
                    lastSeen: entry.lastSeen || new Date().toISOString()
                });
            });
            record.installEndpoints = Array.from(merged.values());
        };

        const publicLicenseRecord = (record = {}, installContext = {}) => {
            const cfg = licensingConfig();
            const devices = (Array.isArray(record.devices) ? record.devices : []).map((device = {}) => ({
                id: device.id || device.uuid || null,
                uuid: device.uuid || device.id || null,
                name: device.name || 'Desktop Client',
                platform: device.platform || 'unknown',
                osVersion: device.osVersion || null,
                model: device.model || null,
                authProvider: device.authProvider || null,
                authMethod: device.authMethod || null,
                linkedAt: device.linkedAt || null,
                lastSeen: device.lastSeen || null
            }));
            const serverInstalls = Array.isArray(record.serverInstalls) ? record.serverInstalls : [];
            const maxDevices = Number.isFinite(record.maxDevices) ? Number(record.maxDevices) : cfg.defaultMaxDevices;
            const installSlots = Number.isFinite(record.installSlots) ? Number(record.installSlots) : cfg.defaultInstallSlots;
            const serverSlots = Number.isFinite(record.serverSlots) ? Number(record.serverSlots) : cfg.defaultServerSlots;
            const pendingUntil = record.pendingUntil || null;
            const pendingMs = pendingUntil ? Math.max(0, new Date(pendingUntil).getTime() - Date.now()) : 0;
            pruneMachineHistory(record);
            return {
                licenseKey: record.licenseKey || null,
                status: pendingMs > 0 ? 'pending' : 'licensed',
                pendingUntil,
                remainingMinutes: pendingMs > 0 ? Math.ceil(pendingMs / 60000) : 0,
                remainingMs: pendingMs,
                activatedDevices: devices.length,
                maxDevices,
                remainingSlots: maxDevices === null ? null : Math.max(0, maxDevices - devices.length),
                installSlots,
                serverSlots,
                devices,
                recentMachines: record.machineHistory || [],
                linkedServers: serverInstalls,
                boundDomains: Array.isArray(record.boundDomains) ? record.boundDomains : [],
                installEndpoints: Array.isArray(record.installEndpoints) ? record.installEndpoints : [],
                owners: Array.isArray(record.owners) ? record.owners : [],
                coOwners: Array.isArray(record.coOwners) ? record.coOwners : [],
                entitlements: record.entitlements || {},
                primaryEmail: record.primaryEmail || null,
                ownershipPolicy: record.ownershipPolicy || null,
                lastEvictedDevice: record.lastEvictedDevice || null,
                activationState: installContext.identityKey && (record.owners || []).concat(record.coOwners || []).some((entry) => entry.identityKey === installContext.identityKey)
                    ? 'authorized'
                    : 'licensed'
            };
        };

        const findLicenseRecordByKey = (licenseKey = '') => {
            const target = String(licenseKey || '').trim();
            if (!target) return null;
            return Object.values(this.licensingState.licenses || {}).find((record) => record?.licenseKey === target) || null;
        };

        const findLicenseRecordByIdentityKey = (identityKey = '') => {
            const target = String(identityKey || '').trim();
            if (!target) return null;
            return this.licensingState.licenses[target] || null;
        };

        const principalMatchesLicense = (record = {}, principal = {}) => {
            const principalEmail = normalizeEmail(principal.email || '');
            const principalIdentityKey = String(principal.identityKey || '').trim();
            const ownershipEntries = []
                .concat(Array.isArray(record.owners) ? record.owners : [])
                .concat(Array.isArray(record.coOwners) ? record.coOwners : []);

            if (principalIdentityKey && ownershipEntries.some((entry) => entry.identityKey === principalIdentityKey)) {
                return true;
            }
            if (principalEmail && ownershipEntries.some((entry) => normalizeEmail(entry.email || '') === principalEmail)) {
                return true;
            }
            return false;
        };

        const enforceLicensePrincipalAccess = (record = {}, principal = {}) => {
            const canonicalEmail = normalizeEmail(record.primaryEmail || '');
            const principalEmail = normalizeEmail(principal.email || '');
            if (!canonicalEmail) return { allowed: true };
            if (!principalEmail) {
                return { allowed: false, error: 'Canonical account email required for this license' };
            }
            if (canonicalEmail === principalEmail || principalMatchesLicense(record, principal)) {
                return { allowed: true };
            }
            return { allowed: false, error: 'This license belongs to a different account email' };
        };

        const findLicenseRecordByNode = (serverId = '', nodeId = '') => {
            const cleanServerId = String(serverId || '').trim();
            const cleanNodeId = String(nodeId || '').trim();
            if (!cleanServerId || !cleanNodeId) return null;
            return Object.values(this.licensingState.licenses || {}).find((record) =>
                (record.nodeRegistrations || {})[cleanServerId]?.nodeId === cleanNodeId
            ) || null;
        };

        const selectOldestDeviceForEviction = (devices = []) => {
            if (!Array.isArray(devices) || devices.length === 0) return null;
            return [...devices].sort((a = {}, b = {}) => {
                const aTime = new Date(a.lastSeen || a.linkedAt || 0).getTime() || 0;
                const bTime = new Date(b.lastSeen || b.linkedAt || 0).getTime() || 0;
                return aTime - bTime;
            })[0] || null;
        };

        const ensureInstallSlotAvailable = (record, incomingUuid = '') => {
            const cfg = licensingConfig();
            record.devices = Array.isArray(record.devices) ? record.devices : [];
            const maxDevices = record.maxDevices ?? cfg.defaultMaxDevices;
            if (maxDevices === null || maxDevices <= 0) {
                return { evictedDevice: null };
            }

            const existing = record.devices.find((device) => device.uuid === incomingUuid || device.id === incomingUuid);
            if (existing || record.devices.length < maxDevices) {
                return { evictedDevice: null };
            }

            if (!cfg.autoRemoveOldestDeviceOnOverflow) {
                return { error: 'Device limit reached', evictedDevice: null };
            }

            const evictedDevice = selectOldestDeviceForEviction(record.devices);
            if (!evictedDevice) {
                return { error: 'Device limit reached', evictedDevice: null };
            }

            record.devices = record.devices.filter((device) => device.uuid !== evictedDevice.uuid && device.id !== evictedDevice.id);
            record.lastEvictedDevice = {
                id: evictedDevice.id || evictedDevice.uuid || null,
                uuid: evictedDevice.uuid || evictedDevice.id || null,
                name: evictedDevice.name || 'Desktop Client',
                platform: evictedDevice.platform || 'unknown',
                osVersion: evictedDevice.osVersion || null,
                evictedAt: new Date().toISOString(),
                reason: 'install_limit_reached'
            };
            return { evictedDevice: record.lastEvictedDevice };
        };

        const pruneMachineHistory = (record) => {
            const retentionMs = licensingConfig().machineHistoryRetentionDays * 24 * 60 * 60 * 1000;
            const cutoff = Date.now() - retentionMs;
            record.machineHistory = (Array.isArray(record.machineHistory) ? record.machineHistory : []).filter((entry = {}) => {
                const seenAt = new Date(entry.lastSeen || entry.firstSeen || 0).getTime() || 0;
                return seenAt >= cutoff;
            });
        };

        const rememberMachine = (record, machine = {}, state = 'seen') => {
            record.machineHistory = Array.isArray(record.machineHistory) ? record.machineHistory : [];
            const uuid = String(machine.uuid || machine.id || '').trim();
            if (!uuid) return null;
            const nowIso = new Date().toISOString();
            const existing = record.machineHistory.find((entry) => entry.uuid === uuid || entry.id === uuid);
            if (existing) {
                existing.name = machine.name || existing.name || 'Desktop Client';
                existing.platform = machine.platform || existing.platform || 'unknown';
                existing.osVersion = machine.osVersion || existing.osVersion || null;
                existing.model = machine.model || existing.model || null;
                existing.authProvider = machine.authProvider || existing.authProvider || null;
                existing.authMethod = machine.authMethod || existing.authMethod || null;
                existing.lastSeen = nowIso;
                existing.state = state || existing.state || 'seen';
                if (state === 'active') {
                    existing.lastActivatedAt = nowIso;
                }
                pruneMachineHistory(record);
                return existing;
            }
            const historyEntry = {
                id: uuid,
                uuid,
                name: machine.name || 'Desktop Client',
                platform: machine.platform || 'unknown',
                osVersion: machine.osVersion || null,
                model: machine.model || null,
                authProvider: machine.authProvider || null,
                authMethod: machine.authMethod || null,
                firstSeen: nowIso,
                lastSeen: nowIso,
                lastActivatedAt: state === 'active' ? nowIso : null,
                state
            };
            record.machineHistory.push(historyEntry);
            pruneMachineHistory(record);
            return historyEntry;
        };

        const notifyLicenseInstallEvent = async ({
            principal = {},
            record = {},
            device = {},
            action = 'installed',
            evictedDevice = null
        } = {}) => {
            const recipient = normalizeEmail(principal.email);
            const deviceName = String(device.name || 'Desktop Client').trim() || 'Desktop Client';
            const platform = String(device.platform || 'unknown').trim() || 'unknown';
            const osVersion = String(device.osVersion || '').trim();
            const title = action === 'evicted'
                ? 'VoiceLink install replaced'
                : 'VoiceLink install activated';
            const summary = action === 'evicted'
                ? `A new VoiceLink install on ${deviceName} (${platform}${osVersion ? ` ${osVersion}` : ''}) replaced your oldest active install.`
                : `VoiceLink was activated on ${deviceName} (${platform}${osVersion ? ` ${osVersion}` : ''}).`;
            const evictionText = evictedDevice
                ? `\n\nRemoved oldest install: ${evictedDevice.name || 'Desktop Client'} (${evictedDevice.platform || 'unknown'}${evictedDevice.osVersion ? ` ${evictedDevice.osVersion}` : ''})`
                : '';
            const statusUrl = `${MAIN_SERVER_URL}/downloads.html`;

            if (recipient && this.mailer) {
                try {
                    await this.mailer.sendMail({
                        from: this.emailFrom || 'services@devine-creations.com',
                        to: recipient,
                        subject: title,
                        text: `${summary}${evictionText}\n\nLicense: ${record.licenseKey || 'Pending'}\nActive installs: ${(record.devices || []).length}\n\nStatus: ${statusUrl}`,
                        html: `
                            <div style="font-family: sans-serif; max-width: 560px; margin: 0 auto; padding: 20px;">
                                <h2 style="color: #2563eb;">${title}</h2>
                                <p>${summary}</p>
                                ${evictedDevice ? `<p><strong>Removed oldest install:</strong> ${evictedDevice.name || 'Desktop Client'} (${evictedDevice.platform || 'unknown'}${evictedDevice.osVersion ? ` ${evictedDevice.osVersion}` : ''})</p>` : ''}
                                <p><strong>License:</strong> ${record.licenseKey || 'Pending'}</p>
                                <p><strong>Active installs:</strong> ${(record.devices || []).length}</p>
                                <p><a href="${statusUrl}">Manage VoiceLink</a></p>
                            </div>
                        `
                    });
                } catch (error) {
                    console.warn('[Licensing] Failed to send install notification email:', error.message);
                }
            }

            if (this.pushoverConfig?.active && this.pushoverConfig?.appToken && this.pushoverConfig?.userKey) {
                try {
                    await this.sendPushoverNotification({
                        title,
                        message: `${summary}${evictedDevice ? ` Removed: ${evictedDevice.name || 'Desktop Client'}.` : ''}`,
                        url: statusUrl,
                        urlTitle: 'Manage VoiceLink'
                    });
                } catch (error) {
                    console.warn('[Licensing] Failed to send install Pushover notification:', error.message);
                }
            }
        };

        const buildNormalizedLicenseIdentity = async (req, payload = {}) => {
            const authUser = this.getAnyAuthUserFromRequest(req);
            const identity = String(payload.identity || payload.email || payload.username || req.headers['x-user-email'] || '').trim();
            const principal = {
                id: String(authUser?.id || payload.id || '').trim(),
                email: normalizeEmail(authUser?.email || payload.email || req.headers['x-user-email'] || ''),
                username: normalizeUsername(authUser?.username || payload.username || identity),
                displayName: String(authUser?.displayName || payload.displayName || identity || '').trim() || null,
                role: normalizeUserRole(authUser?.role || payload.role || 'user'),
                authProvider: String(authUser?.authProvider || payload.authProvider || 'local').trim().toLowerCase() || 'local',
                entitlements: authUser?.entitlements || payload.entitlements || null
            };

            if (!principal.email && identity) {
                const localUser = findLocalUserByIdentity(identity);
                if (localUser) {
                    principal.id = principal.id || localUser.id;
                    principal.email = principal.email || normalizeEmail(localUser.email);
                    principal.username = principal.username || normalizeUsername(localUser.username);
                    principal.role = normalizeUserRole(localUser.role || principal.role);
                    principal.authProvider = String(localUser.authProvider || principal.authProvider || 'local').trim().toLowerCase();
                    principal.entitlements = principal.entitlements || localUser.entitlements || null;
                }
            }

            if (!principal.email && identity) {
                const whmcsIdentity = this.resolveWhmcsIdentity(identity);
                principal.email = principal.email || normalizeEmail(whmcsIdentity.email);
                principal.username = principal.username || normalizeUsername(whmcsIdentity.username);
            }

            if (principal.email || principal.username) {
                const linkedLocalUser = findLocalUserByIdentity(principal.email || principal.username);
                if (linkedLocalUser) {
                    mergeLinkedAuthMethods(linkedLocalUser, principal.authProvider || 'local', {
                        email: principal.email,
                        username: principal.username,
                        displayName: principal.displayName,
                        externalId: principal.id
                    });
                    linkedLocalUser.updatedAt = new Date().toISOString();
                    this.localAuthUsers.set(linkedLocalUser.id, linkedLocalUser);
                    persistLocalAuthUsers();
                    principal.id = principal.id || linkedLocalUser.id;
                    principal.email = principal.email || normalizeEmail(linkedLocalUser.email);
                    principal.username = principal.username || normalizeUsername(linkedLocalUser.username);
                    principal.displayName = principal.displayName || linkedLocalUser.displayName || linkedLocalUser.username || null;
                    principal.role = normalizeUserRole(linkedLocalUser.role || principal.role);
                    principal.entitlements = principal.entitlements || linkedLocalUser.entitlements || null;
                }
            }

            principal.identityKey = normalizeLicenseIdentityKey(principal);
            return principal;
        };

        const resolveLicenseEntitlements = async (principal = {}) => {
            const defaults = buildDefaultEntitlements(principal.role || 'user');
            const current = principal.entitlements || {};
            const appStoreEntitlements = current?.appStore?.entitlements || current?.iosPurchases?.entitlements || {};
            const purchaseSources = new Set([
                ...(Array.isArray(defaults.purchaseSources) ? defaults.purchaseSources : []),
                ...(Array.isArray(current.purchaseSources) ? current.purchaseSources : []),
                ...(current?.appStore ? ['app_store'] : []),
                ...(current?.iosPurchases ? ['ios_app_store'] : [])
            ]);

            if (principal.email) {
                try {
                    const clientResponse = await this.whmcsRequest('GetClientsDetails', { email: principal.email });
                    const clientDetails = clientResponse.client || clientResponse.clientdetails || null;
                    if (clientDetails) {
                        let services = [];
                        try {
                            const servicesResponse = await this.whmcsRequest('GetClientsProducts', { clientid: clientDetails.id });
                            services = servicesResponse.products?.product || [];
                        } catch (error) {
                            console.warn('[Licensing] WHMCS product lookup failed:', error.message);
                        }
                        return {
                            ...defaults,
                            ...this.deriveWhmcsEntitlements(clientDetails, services),
                            ...appStoreEntitlements,
                            ...current
                        };
                    }
                } catch (error) {
                    // Keep generic defaults for non-WHMCS identities.
                }
            }

            return {
                ...defaults,
                ...appStoreEntitlements,
                ...current,
                purchaseSources: Array.from(purchaseSources)
            };
        };

        const ensureLicenseRecordForPrincipal = async (principal = {}, options = {}) => {
            if (!principal.identityKey) return null;
            const cfg = licensingConfig();
            const now = new Date();
            let record = findLicenseRecordByIdentityKey(principal.identityKey);
            const entitlements = await resolveLicenseEntitlements(principal);

            if (!record) {
                const installSlots = Number.isFinite(entitlements.installSlots) ? Number(entitlements.installSlots) : cfg.defaultInstallSlots;
                const serverSlots = Number.isFinite(entitlements.serverSlots) ? Number(entitlements.serverSlots) : cfg.defaultServerSlots;
                const maxDevices = Number.isFinite(entitlements.maxDevices) ? Number(entitlements.maxDevices) : cfg.defaultMaxDevices;
                record = {
                    identityKey: principal.identityKey,
                    licenseKey: makeLicenseKey(),
                    primaryEmail: principal.email || null,
                    createdAt: now.toISOString(),
                    updatedAt: now.toISOString(),
                    pendingUntil: new Date(now.getTime() + cfg.registrationDelayMinutes * 60 * 1000).toISOString(),
                    owners: [{
                        identityKey: principal.identityKey,
                        id: principal.id || null,
                        email: principal.email || null,
                        username: principal.username || null,
                        displayName: principal.displayName || null,
                        role: principal.role || 'user',
                        authProvider: principal.authProvider || 'local'
                    }],
                    coOwners: [],
                    devices: [],
                    machineHistory: [],
                    serverInstalls: [],
                    boundDomains: [],
                    installEndpoints: [],
                    nodeRegistrations: {},
                    entitlements,
                    ownershipPolicy: {
                        billingModel: entitlements.billingModel || 'manual',
                        allowsTransfer: entitlements.allowsLicenseTransfer === true,
                        requiresManualTransferApproval: entitlements.requiresManualTransferApproval === true,
                        transferCooldownDays: Number.isFinite(entitlements.transferCooldownDays) ? Number(entitlements.transferCooldownDays) : 30
                    },
                    maxDevices,
                    installSlots,
                    serverSlots
                };
                this.licensingState.licenses[principal.identityKey] = record;
            } else {
                record.updatedAt = now.toISOString();
                if (!record.primaryEmail && principal.email) record.primaryEmail = principal.email;
                record.entitlements = { ...(record.entitlements || {}), ...entitlements };
                record.ownershipPolicy = {
                    ...(record.ownershipPolicy || {}),
                    billingModel: entitlements.billingModel || record.ownershipPolicy?.billingModel || 'manual',
                    allowsTransfer: entitlements.allowsLicenseTransfer === true,
                    requiresManualTransferApproval: entitlements.requiresManualTransferApproval === true,
                    transferCooldownDays: Number.isFinite(entitlements.transferCooldownDays) ? Number(entitlements.transferCooldownDays) : (record.ownershipPolicy?.transferCooldownDays ?? 30)
                };
                if (Number.isFinite(entitlements.maxDevices)) record.maxDevices = Number(entitlements.maxDevices);
                if (Number.isFinite(entitlements.installSlots)) record.installSlots = Number(entitlements.installSlots);
                if (Number.isFinite(entitlements.serverSlots)) record.serverSlots = Number(entitlements.serverSlots);
                if (Array.isArray(entitlements.ownedDomains) && entitlements.ownedDomains.length) {
                    mergeBoundDomainsIntoRecord(record, entitlements.ownedDomains.map((domain) => ({
                        domain,
                        source: 'whmcs',
                        installType: 'server'
                    })));
                }
                record.owners = Array.isArray(record.owners) ? record.owners : [];
                if (!record.owners.some((entry) => entry.identityKey === principal.identityKey)) {
                    record.owners.push({
                        identityKey: principal.identityKey,
                        id: principal.id || null,
                        email: principal.email || null,
                        username: principal.username || null,
                        displayName: principal.displayName || null,
                        role: principal.role || 'user',
                        authProvider: principal.authProvider || 'local'
                    });
                }
            }

            if (options.serverId && options.nodeId) {
                const cleanServerId = String(options.serverId).trim();
                const normalizedNodeUrl = String(options.nodeUrl || '').trim() || null;
                const explicitDomain = normalizeBoundDomain(options.domain || '');
                const inferredDomain = extractDomainFromUrl(normalizedNodeUrl || '');
                const boundDomain = explicitDomain || inferredDomain;
                const publicIpAddress = normalizeBoundIp(options.ipAddress || '');
                const privateIpAddress = normalizeBoundIp(options.privateIpAddress || '');
                record.nodeRegistrations = record.nodeRegistrations || {};
                record.nodeRegistrations[cleanServerId] = {
                    nodeId: String(options.nodeId).trim(),
                    nodeUrl: normalizedNodeUrl,
                    installType: options.installType || 'desktop',
                    registeredAt: record.nodeRegistrations[cleanServerId]?.registeredAt || now.toISOString(),
                    lastSeen: now.toISOString()
                };

                if (boundDomain) {
                    mergeBoundDomainsIntoRecord(record, [{
                        domain: boundDomain,
                        source: options.domainSource || 'install',
                        serverId: cleanServerId,
                        nodeId: String(options.nodeId).trim(),
                        nodeUrl: normalizedNodeUrl,
                        ipAddress: publicIpAddress || null,
                        installType: options.installType || 'server',
                        lastSeen: now.toISOString()
                    }]);
                }
                mergeInstallEndpointsIntoRecord(record, [{
                    serverId: cleanServerId,
                    nodeId: String(options.nodeId).trim(),
                    nodeUrl: normalizedNodeUrl,
                    domain: boundDomain || '',
                    ipAddress: publicIpAddress || '',
                    privateIpAddress,
                    installType: options.installType || 'server',
                    selfHosted: options.selfHosted !== false,
                    federationEligible: options.federationEligible !== false,
                    moduleRepoAccess: options.moduleRepoAccess !== false,
                    lastSeen: now.toISOString()
                }]);

                if ((options.installType || 'desktop') === 'server') {
                    record.serverInstalls = Array.isArray(record.serverInstalls) ? record.serverInstalls : [];
                    const existingServer = record.serverInstalls.find((entry) => entry.serverId === cleanServerId);
                    if (existingServer) {
                        existingServer.nodeId = String(options.nodeId).trim();
                        existingServer.nodeUrl = String(options.nodeUrl || '').trim() || existingServer.nodeUrl || null;
                        existingServer.lastSeen = now.toISOString();
                    } else {
                        record.serverInstalls.push({
                            id: uuidv4(),
                            serverId: cleanServerId,
                            nodeId: String(options.nodeId).trim(),
                            nodeUrl: String(options.nodeUrl || '').trim() || null,
                            linkedAt: now.toISOString(),
                            lastSeen: now.toISOString()
                        });
                    }
                }
            }

            persistLicensingState();
            return record;
        };

        this.app.post('/api/licensing/register', async (req, res) => {
            const serverId = String(req.body?.serverId || '').trim();
            const nodeId = String(req.body?.nodeId || '').trim();
            const nodeUrl = String(req.body?.nodeUrl || '').trim();
            const installType = String(req.body?.installType || '').trim().toLowerCase() === 'server' ? 'server' : 'desktop';

            if (!serverId || !nodeId) {
                return res.status(400).json({ status: 'error', error: 'serverId and nodeId are required' });
            }

            const principal = await buildNormalizedLicenseIdentity(req, {
                identity: req.body?.identity || req.body?.email || req.body?.username || req.body?.userEmail || '',
                email: req.body?.email || req.body?.userEmail || '',
                username: req.body?.username || '',
                authProvider: req.body?.authProvider || ''
            });

            if (!principal.identityKey) {
                return res.status(401).json({ status: 'error', error: 'Authenticated or identifiable user required for licensing' });
            }

            const existingByNode = findLicenseRecordByNode(serverId, nodeId);
            const record = existingByNode || await ensureLicenseRecordForPrincipal(principal, {
                serverId,
                nodeId,
                nodeUrl,
                domain: req.body?.domain || '',
                domainSource: req.body?.domainSource || '',
                ipAddress: req.body?.ipAddress || '',
                privateIpAddress: req.body?.privateIpAddress || '',
                selfHosted: req.body?.selfHosted !== false,
                federationEligible: req.body?.federationEligible !== false,
                moduleRepoAccess: req.body?.moduleRepoAccess !== false,
                installType
            });
            if (!record) {
                return res.status(500).json({ status: 'error', error: 'Unable to create license record' });
            }
            const accessCheck = enforceLicensePrincipalAccess(record, principal);
            if (!accessCheck.allowed) {
                return res.status(403).json({ status: 'error', error: accessCheck.error });
            }

            if (!existingByNode && installType !== 'server') {
                record.devices = Array.isArray(record.devices) ? record.devices : [];
                const uuid = String(req.body?.deviceInfo?.uuid || '').trim();
                const machineInfo = {
                    id: uuid,
                    uuid,
                    name: String(req.body?.deviceInfo?.name || 'Desktop Client').trim() || 'Desktop Client',
                    platform: String(req.body?.deviceInfo?.platform || 'unknown').trim() || 'unknown',
                    osVersion: String(req.body?.deviceInfo?.osVersion || '').trim() || null,
                    model: String(req.body?.deviceInfo?.model || '').trim() || null,
                    authProvider: principal.authProvider || null,
                    authMethod: req.body?.authMethod || req.headers['x-auth-method'] || null
                };
                if (uuid) {
                    rememberMachine(record, machineInfo, record.devices.some((device) => device.uuid === uuid || device.id === uuid) ? 'active' : 'pending_activation');
                }
                if (uuid && !record.devices.some((device) => device.uuid === uuid || device.id === uuid)) {
                    record.pendingActivationDevice = machineInfo;
                }
            }

            persistLicensingState();
            const pendingMs = record.pendingUntil ? Math.max(0, new Date(record.pendingUntil).getTime() - Date.now()) : 0;
            return res.json({
                ...publicLicenseRecord(record, principal),
                status: pendingMs > 0 ? 'pending' : 'already_licensed',
                activationRequired: installType !== 'server' && !!record.pendingActivationDevice,
                serverId,
                nodeId
            });
        });

        this.app.get('/api/licensing/status/:serverId/:nodeId', async (req, res) => {
            const record = findLicenseRecordByNode(req.params.serverId, req.params.nodeId);
            if (!record) {
                return res.json({ status: 'not_registered' });
            }
            return res.json(publicLicenseRecord(record));
        });

        this.app.get('/api/licensing/me', async (req, res) => {
            const principal = await buildNormalizedLicenseIdentity(req, {});
            if (!principal.identityKey) {
                return res.status(401).json({ success: false, error: 'Unauthorized' });
            }
            const record = findLicenseRecordByIdentityKey(principal.identityKey)
                || await ensureLicenseRecordForPrincipal(principal, {});
            if (!record) {
                return res.status(500).json({ success: false, error: 'Unable to create license record' });
            }
            const accessCheck = enforceLicensePrincipalAccess(record, principal);
            if (!accessCheck.allowed) {
                return res.status(403).json({ success: false, error: accessCheck.error });
            }
            return res.json({ success: true, ...publicLicenseRecord(record, principal) });
        });

        this.app.post('/api/licensing/sync-entitlements', async (req, res) => {
            const principal = await buildNormalizedLicenseIdentity(req, req.body || {});
            if (!principal.identityKey) {
                return res.status(401).json({ success: false, error: 'Authenticated account required' });
            }

            const record = await ensureLicenseRecordForPrincipal(principal, {});
            if (!record) {
                return res.status(500).json({ success: false, error: 'Unable to create license record' });
            }
            const accessCheck = enforceLicensePrincipalAccess(record, principal);
            if (!accessCheck.allowed) {
                return res.status(403).json({ success: false, error: accessCheck.error });
            }

            const source = String(req.body?.source || req.body?.provider || '').trim().toLowerCase() || 'manual';
            const entitlements = req.body?.entitlements && typeof req.body.entitlements === 'object' ? req.body.entitlements : {};
            const appStorePayload = req.body?.appStore && typeof req.body.appStore === 'object' ? req.body.appStore : null;

            record.entitlements = {
                ...(record.entitlements || {}),
                ...entitlements
            };

            if (source === 'app_store' || source === 'ios_app_store' || appStorePayload) {
                record.entitlements.appStore = {
                    ...(record.entitlements.appStore || {}),
                    ...(appStorePayload || {}),
                    source,
                    syncedAt: new Date().toISOString()
                };
            }

            const mergedEntitlements = await resolveLicenseEntitlements({
                ...principal,
                entitlements: record.entitlements
            });
            record.entitlements = mergedEntitlements;
            if (Number.isFinite(mergedEntitlements.maxDevices)) record.maxDevices = Number(mergedEntitlements.maxDevices);
            if (Number.isFinite(mergedEntitlements.installSlots)) record.installSlots = Number(mergedEntitlements.installSlots);
            if (Number.isFinite(mergedEntitlements.serverSlots)) record.serverSlots = Number(mergedEntitlements.serverSlots);
            record.updatedAt = new Date().toISOString();
            persistLicensingState();

            return res.json({ success: true, source, ...publicLicenseRecord(record, principal) });
        });

        this.app.post('/api/licensing/validate', async (req, res) => {
            const licenseKey = String(req.body?.licenseKey || '').trim();
            const uuid = String(req.body?.deviceInfo?.uuid || '').trim();
            const record = findLicenseRecordByKey(licenseKey);
            if (!record) {
                return res.status(404).json({ valid: false, error: 'License not found' });
            }
            const principal = await buildNormalizedLicenseIdentity(req, req.body || {});
            const accessCheck = enforceLicensePrincipalAccess(record, principal);
            if (!accessCheck.allowed) {
                return res.status(403).json({ valid: false, error: accessCheck.error });
            }
            const pendingMs = record.pendingUntil ? Math.max(0, new Date(record.pendingUntil).getTime() - Date.now()) : 0;
            if (pendingMs > 0) {
                return res.json({ valid: false, status: 'pending', remainingMinutes: Math.ceil(pendingMs / 60000), remainingMs: pendingMs });
            }

            const device = uuid ? (record.devices || []).find((entry) => entry.uuid === uuid || entry.id === uuid) : null;
            if (!device) {
                return res.json({
                    valid: false,
                    deviceActivated: false,
                    activationRequired: true,
                    activatedDevices: (record.devices || []).length,
                    maxDevices: record.maxDevices ?? licensingConfig().defaultMaxDevices,
                    remainingSlots: record.maxDevices === null ? null : Math.max(0, (record.maxDevices ?? licensingConfig().defaultMaxDevices) - (record.devices || []).length),
                    message: 'Device not activated'
                });
            }
            device.lastSeen = new Date().toISOString();
            persistLicensingState();
            return res.json({ valid: true, deviceActivated: true, ...publicLicenseRecord(record) });
        });

        this.app.post('/api/licensing/activate', async (req, res) => {
            const licenseKey = String(req.body?.licenseKey || '').trim();
            const uuid = String(req.body?.deviceInfo?.uuid || '').trim();
            const record = findLicenseRecordByKey(licenseKey);
            if (!record) {
                return res.status(404).json({ success: false, error: 'License not found' });
            }
            const principal = await buildNormalizedLicenseIdentity(req, req.body || {});
            const accessCheck = enforceLicensePrincipalAccess(record, principal);
            if (!accessCheck.allowed) {
                return res.status(403).json({ success: false, error: accessCheck.error });
            }
            if (!uuid) {
                return res.status(400).json({ success: false, error: 'Device UUID required' });
            }

            const pendingMs = record.pendingUntil ? Math.max(0, new Date(record.pendingUntil).getTime() - Date.now()) : 0;
            if (pendingMs > 0) {
                return res.status(409).json({ success: false, error: 'License pending activation', remainingMinutes: Math.ceil(pendingMs / 60000) });
            }

            record.devices = Array.isArray(record.devices) ? record.devices : [];
            const existing = record.devices.find((entry) => entry.uuid === uuid || entry.id === uuid);
            if (!existing) {
                const slotResult = ensureInstallSlotAvailable(record, uuid);
                if (slotResult.error) {
                    return res.status(409).json({ success: false, error: slotResult.error, ...publicLicenseRecord(record) });
                }
                const newDevice = {
                    id: uuid,
                    uuid,
                    name: String(req.body?.deviceInfo?.name || 'Desktop Client').trim() || 'Desktop Client',
                    platform: String(req.body?.deviceInfo?.platform || 'unknown').trim() || 'unknown',
                    osVersion: String(req.body?.deviceInfo?.osVersion || '').trim() || null,
                    model: String(req.body?.deviceInfo?.model || '').trim() || null,
                    authProvider: req.body?.authProvider || req.headers['x-auth-provider'] || null,
                    authMethod: req.body?.authMethod || req.headers['x-auth-method'] || null,
                    linkedAt: new Date().toISOString(),
                    lastSeen: new Date().toISOString()
                };
                record.devices.push(newDevice);
                const principal = await buildNormalizedLicenseIdentity(req, {});
                rememberMachine(record, newDevice, 'active');
                record.pendingActivationDevice = null;
                void notifyLicenseInstallEvent({
                    principal,
                    record,
                    device: newDevice,
                    action: 'installed',
                    evictedDevice: slotResult.evictedDevice || null
                });
            } else {
                existing.lastSeen = new Date().toISOString();
                existing.platform = String(req.body?.deviceInfo?.platform || existing.platform || 'unknown').trim() || 'unknown';
                existing.osVersion = String(req.body?.deviceInfo?.osVersion || existing.osVersion || '').trim() || null;
                existing.model = String(req.body?.deviceInfo?.model || existing.model || '').trim() || null;
                rememberMachine(record, existing, 'active');
            }
            record.updatedAt = new Date().toISOString();
            persistLicensingState();
            return res.json({ success: true, ...publicLicenseRecord(record) });
        });

        this.app.post('/api/licensing/deactivate', async (req, res) => {
            const licenseKey = String(req.body?.licenseKey || '').trim();
            const deviceId = String(req.body?.deviceId || '').trim();
            const record = findLicenseRecordByKey(licenseKey);
            if (!record) {
                return res.status(404).json({ success: false, error: 'License not found' });
            }
            const principal = await buildNormalizedLicenseIdentity(req, req.body || {});
            const accessCheck = enforceLicensePrincipalAccess(record, principal);
            if (!accessCheck.allowed) {
                return res.status(403).json({ success: false, error: accessCheck.error });
            }
            record.devices = (record.devices || []).filter((entry) => entry.id !== deviceId && entry.uuid !== deviceId);
            if (Array.isArray(record.machineHistory)) {
                const machine = record.machineHistory.find((entry) => entry.id === deviceId || entry.uuid === deviceId);
                if (machine) {
                    machine.state = 'deactivated';
                    machine.lastSeen = new Date().toISOString();
                }
            }
            record.updatedAt = new Date().toISOString();
            persistLicensingState();
            return res.json({ success: true, ...publicLicenseRecord(record) });
        });

        this.app.post('/api/licensing/heartbeat', async (req, res) => {
            const licenseKey = String(req.body?.licenseKey || '').trim();
            const uuid = String(req.body?.deviceInfo?.uuid || '').trim();
            const record = findLicenseRecordByKey(licenseKey);
            if (!record) {
                return res.status(404).json({ success: false, error: 'License not found' });
            }
            const principal = await buildNormalizedLicenseIdentity(req, req.body || {});
            const accessCheck = enforceLicensePrincipalAccess(record, principal);
            if (!accessCheck.allowed) {
                return res.status(403).json({ success: false, error: accessCheck.error });
            }
            const device = (record.devices || []).find((entry) => entry.uuid === uuid || entry.id === uuid);
            if (device) device.lastSeen = new Date().toISOString();
            record.updatedAt = new Date().toISOString();
            persistLicensingState();
            return res.json({ success: true });
        });

        this.app.post('/api/licensing/ownership/share', async (req, res) => {
            if (!this.isLocalAdminRequest(req)) {
                return res.status(403).json({ success: false, error: 'Admin authentication required' });
            }

            const licenseKey = String(req.body?.licenseKey || '').trim();
            const targetIdentity = String(req.body?.identity || req.body?.email || req.body?.username || '').trim();
            const access = String(req.body?.access || 'co-owner').trim().toLowerCase();
            const record = findLicenseRecordByKey(licenseKey);
            if (!record) {
                return res.status(404).json({ success: false, error: 'License not found' });
            }

            const principal = await buildNormalizedLicenseIdentity(req, {
                identity: targetIdentity,
                email: req.body?.email || '',
                username: req.body?.username || '',
                authProvider: req.body?.authProvider || 'shared'
            });
            if (!principal.identityKey) {
                return res.status(400).json({ success: false, error: 'Target identity required' });
            }

            const bucket = access === 'owner' ? 'owners' : 'coOwners';
            record[bucket] = Array.isArray(record[bucket]) ? record[bucket] : [];
            if (!record[bucket].some((entry) => entry.identityKey === principal.identityKey)) {
                record[bucket].push({
                    identityKey: principal.identityKey,
                    id: principal.id || null,
                    email: principal.email || null,
                    username: principal.username || null,
                    displayName: principal.displayName || null,
                    role: access === 'owner' ? 'owner' : 'co-owner',
                    authProvider: principal.authProvider || 'shared'
                });
            }
            record.updatedAt = new Date().toISOString();
            persistLicensingState();
            return res.json({ success: true, ...publicLicenseRecord(record) });
        });

        this.app.post('/api/licensing/ownership/transfer', async (req, res) => {
            const actor = await buildNormalizedLicenseIdentity(req, {});
            const licenseKey = String(req.body?.licenseKey || '').trim();
            const record = findLicenseRecordByKey(licenseKey);
            if (!record) {
                return res.status(404).json({ success: false, error: 'License not found' });
            }

            const actorAccess = enforceLicensePrincipalAccess(record, actor);
            const actorIsAdmin = this.isLocalAdminRequest(req);
            if (!actorIsAdmin && (!actorAccess.allowed || !principalMatchesLicense(record, actor))) {
                return res.status(403).json({ success: false, error: 'Current owner or admin required' });
            }

            const policy = record.ownershipPolicy || {};
            if (policy.requiresManualTransferApproval || policy.allowsTransfer !== true) {
                return res.status(409).json({
                    success: false,
                    error: 'This license cannot be automatically transferred',
                    ownershipPolicy: policy
                });
            }

            const targetPrincipal = await buildNormalizedLicenseIdentity(req, {
                identity: req.body?.identity || req.body?.email || req.body?.username || '',
                email: req.body?.email || '',
                username: req.body?.username || '',
                authProvider: req.body?.authProvider || ''
            });
            if (!targetPrincipal.identityKey || !targetPrincipal.email) {
                return res.status(400).json({ success: false, error: 'Target account email required for transfer' });
            }

            const cooldownDays = Number.isFinite(policy.transferCooldownDays) ? Number(policy.transferCooldownDays) : 30;
            const lastTransferAt = record.lastTransferAt ? new Date(record.lastTransferAt).getTime() : 0;
            if (cooldownDays > 0 && lastTransferAt > 0) {
                const nextAllowedAt = lastTransferAt + (cooldownDays * 24 * 60 * 60 * 1000);
                if (Date.now() < nextAllowedAt) {
                    return res.status(409).json({
                        success: false,
                        error: 'Transfer cooldown is still active',
                        nextAllowedAt: new Date(nextAllowedAt).toISOString()
                    });
                }
            }

            const oldIdentityKey = record.identityKey;
            record.primaryEmail = targetPrincipal.email;
            record.identityKey = targetPrincipal.identityKey;
            record.owners = [{
                identityKey: targetPrincipal.identityKey,
                id: targetPrincipal.id || null,
                email: targetPrincipal.email || null,
                username: targetPrincipal.username || null,
                displayName: targetPrincipal.displayName || null,
                role: 'owner',
                authProvider: targetPrincipal.authProvider || 'local'
            }];
            record.coOwners = [];
            record.lastTransferAt = new Date().toISOString();
            record.updatedAt = record.lastTransferAt;
            if (oldIdentityKey && this.licensingState.licenses[oldIdentityKey]) {
                delete this.licensingState.licenses[oldIdentityKey];
            }
            this.licensingState.licenses[targetPrincipal.identityKey] = record;
            persistLicensingState();
            return res.json({ success: true, ...publicLicenseRecord(record, targetPrincipal) });
        });

        this.app.post('/api/licensing/domains/bind', async (req, res) => {
            const principal = await buildNormalizedLicenseIdentity(req, req.body || {});
            if (!principal.identityKey) {
                return res.status(401).json({ success: false, error: 'Authenticated account required' });
            }

            const record = findLicenseRecordByIdentityKey(principal.identityKey)
                || await ensureLicenseRecordForPrincipal(principal, {});
            if (!record) {
                return res.status(500).json({ success: false, error: 'Unable to create license record' });
            }

            const accessCheck = enforceLicensePrincipalAccess(record, principal);
            if (!accessCheck.allowed) {
                return res.status(403).json({ success: false, error: accessCheck.error });
            }

            const domains = []
                .concat(req.body?.domain || [])
                .concat(req.body?.domains || [])
                .flatMap((value) => Array.isArray(value) ? value : [value])
                .map((value) => normalizeBoundDomain(value))
                .filter(Boolean);

            if (!domains.length) {
                return res.status(400).json({ success: false, error: 'At least one domain or subdomain is required' });
            }

            const serverId = String(req.body?.serverId || '').trim() || null;
            const nodeId = String(req.body?.nodeId || '').trim() || null;
            const nodeUrl = String(req.body?.nodeUrl || '').trim() || null;
            const ipAddress = normalizeBoundIp(req.body?.ipAddress || '');
            const privateIpAddress = normalizeBoundIp(req.body?.privateIpAddress || '');
            const installType = String(req.body?.installType || 'server').trim().toLowerCase() === 'desktop' ? 'desktop' : 'server';
            const source = String(req.body?.source || 'manual').trim().toLowerCase() || 'manual';
            const selfHosted = req.body?.selfHosted !== false;
            const federationEligible = req.body?.federationEligible !== false;
            const moduleRepoAccess = req.body?.moduleRepoAccess !== false;
            const nowIso = new Date().toISOString();

            mergeBoundDomainsIntoRecord(record, domains.map((domain) => ({
                domain,
                source,
                serverId,
                nodeId,
                nodeUrl,
                ipAddress: ipAddress || null,
                installType,
                lastSeen: nowIso
            })));

            mergeInstallEndpointsIntoRecord(record, [{
                serverId,
                nodeId,
                nodeUrl,
                domain: domains[0] || '',
                ipAddress,
                privateIpAddress,
                installType,
                selfHosted,
                federationEligible,
                moduleRepoAccess,
                lastSeen: nowIso
            }]);

            record.updatedAt = nowIso;
            persistLicensingState();
            return res.json({ success: true, ...publicLicenseRecord(record, principal) });
        });

        this.app.post('/api/admin/invites', async (req, res) => {
            if (this.isLocalAdminRequest && !this.isLocalAdminRequest(req)) {
                return res.status(403).json({ success: false, error: 'Admin access required' });
            }

            const email = normalizeEmail(req.body?.email);
            const requestedRole = String(req.body?.role || 'admin').toLowerCase();
            const role = ['admin', 'moderator', 'owner'].includes(requestedRole) ? requestedRole : 'admin';
            const expiresMinutes = Math.max(5, Math.min(Number(req.body?.expiresMinutes || 60), 1440));
            if (!email || !validateEmail(email)) {
                return res.status(400).json({ success: false, error: 'Valid email is required' });
            }

            const token = `vlinvite_${uuidv4()}_${Date.now().toString(36)}`;
            const expiresAt = new Date(Date.now() + expiresMinutes * 60 * 1000);
            const inviter = this.getAnyAuthUserFromRequest ? this.getAnyAuthUserFromRequest(req) : (this.getLocalAuthUserFromRequest ? this.getLocalAuthUserFromRequest(req) : null);
            this.adminInviteTokens.set(token, {
                email,
                role,
                invitedBy: inviter?.username || inviter?.email || 'admin',
                createdAt: new Date(),
                expiresAt
            });

            const host = req.get('host');
            const protocol = req.get('x-forwarded-proto') || req.protocol || 'https';
            const inviteUrl = `${protocol}://${host}/admin-invite.html?token=${encodeURIComponent(token)}`;
            const desktopUrl = `vcl://admin-invite?token=${encodeURIComponent(token)}&server=${encodeURIComponent(`${protocol}://${host}`)}`;

            try {
                if (this.mailer) {
                    const supportAddress = this.emailFrom || 'services@devine-creations.com';
                    await this.mailer.sendMail({
                        from: supportAddress,
                        to: email,
                        subject: `VoiceLink Admin Access Invite (${role})`,
                        text: `You were invited to VoiceLink as ${role}.\n\nWeb activation link:\n${inviteUrl}\n\nDesktop app deep link:\n${desktopUrl}\n\nInvited by: ${inviter?.username || inviter?.email || 'Server Admin'}\nExpires: ${expiresAt.toISOString()}\n\nIf you were not expecting this invite, ignore this email.\nSupport: ${supportAddress}`,
                        html: `
                            <div style="font-family: sans-serif; max-width: 520px; margin: 0 auto; padding: 20px;">
                                <h2 style="color: #6366f1;">VoiceLink Admin Invite</h2>
                                <p>You were invited as <strong>${role}</strong>.</p>
                                <p>Use this secure link to activate your admin profile and set your username/password:</p>
                                <p><a href="${inviteUrl}" style="display:inline-block;padding:12px 16px;background:#4f46e5;color:#fff;text-decoration:none;border-radius:8px;">Activate Admin Access</a></p>
                                <p style="word-break:break-all;color:#555;font-size:13px;">Web link: ${inviteUrl}</p>
                                <p style="word-break:break-all;color:#555;font-size:13px;">Desktop link: ${desktopUrl}</p>
                                <p style="color:#666;font-size:13px;">Invited by: ${inviter?.username || inviter?.email || 'Server Admin'}</p>
                                <p style="color:#666;font-size:13px;">Expires: ${expiresAt.toISOString()}</p>
                                <p style="color:#999;font-size:12px;">If you were not expecting this invite, ignore this email.</p>
                                <p style="color:#999;font-size:12px;">Support: ${supportAddress}</p>
                            </div>
                        `
                    });
                }
            } catch (error) {
                console.warn('[Auth] Failed to send admin invite email:', error.message);
            }

            return res.json({ success: true, email, role, inviteUrl, expiresAt });
        });

        this.app.get('/api/auth/local/admin-invite/:token', (req, res) => {
            const token = String(req.params.token || '').trim();
            const invite = this.adminInviteTokens.get(token);
            if (!invite || new Date() > new Date(invite.expiresAt)) {
                this.adminInviteTokens.delete(token);
                return res.status(404).json({ success: false, error: 'Invite link is invalid or expired' });
            }
            return res.json({
                success: true,
                email: invite.email,
                role: invite.role,
                invitedBy: invite.invitedBy,
                expiresAt: invite.expiresAt
            });
        });

        this.app.post('/api/auth/local/admin-invite/accept', (req, res) => {
            const token = String(req.body?.token || '').trim();
            const username = normalizeUsername(req.body?.username);
            const email = normalizeEmail(req.body?.email);
            const displayName = String(req.body?.displayName || username || '').trim();
            const password = String(req.body?.password || '');
            if (!token || !username || !password) {
                return res.status(400).json({ success: false, error: 'Token, username, and password are required' });
            }
            if (!validateUsername(username)) {
                return res.status(400).json({ success: false, error: 'Invalid username format' });
            }
            if (password.length < 8) {
                return res.status(400).json({ success: false, error: 'Password must be at least 8 characters' });
            }

            const invite = this.adminInviteTokens.get(token);
            if (!invite || new Date() > new Date(invite.expiresAt)) {
                this.adminInviteTokens.delete(token);
                return res.status(400).json({ success: false, error: 'Invite token is invalid or expired' });
            }
            if (email && invite.email && email !== invite.email) {
                return res.status(400).json({ success: false, error: 'Email does not match invite' });
            }

            const targetEmail = invite.email;
            let user = findLocalUserByIdentity(targetEmail) || findLocalUserByIdentity(username);
            if (!user) {
                const { salt, hash } = buildPasswordHash(password);
                user = {
                    id: `usr_${uuidv4()}`,
                    username,
                    displayName: displayName || username,
                    email: targetEmail,
                    passwordSalt: salt,
                    passwordHash: hash,
                    role: invite.role || 'admin',
                    isVerified: true,
                    createdAt: new Date().toISOString(),
                    updatedAt: new Date().toISOString()
                };
            } else {
                const { salt, hash } = buildPasswordHash(password);
                user.username = username;
                user.displayName = displayName || username;
                user.email = user.email || targetEmail;
                user.passwordSalt = salt;
                user.passwordHash = hash;
                user.role = invite.role || user.role || 'admin';
                user.isVerified = true;
                user.updatedAt = new Date().toISOString();
            }

            this.localAuthUsers.set(user.id, user);
            this.adminInviteTokens.delete(token);
            persistLocalAuthUsers();
            const accessToken = issueLocalAuthToken(user.id);

            return res.json({
                success: true,
                accessToken,
                user: publicLocalUser(user)
            });
        });

        this.app.get('/admin-invite', (req, res) => {
            const token = String(req.query?.token || '').trim();
            if (!token) {
                return res.status(400).send('<h2>Missing invite token</h2>');
            }
            return res.sendFile(path.join(__dirname, '../../client/admin-invite.html'));
        });
        this.app.get('/api/admin-invite', (req, res) => {
            const token = String(req.query?.token || '').trim();
            if (!token) {
                return res.status(400).json({ success: false, error: 'Missing invite token' });
            }
            return res.redirect(`/admin-invite.html?token=${encodeURIComponent(token)}`);
        });

        this.app.get('/api/auth/providers', (_req, res) => {
            const whmcsConfig = this.getWhmcsConfig();
            const adminBridge = this.getWhmcsAdminBridgeConfig();
            const whmcsEnabled = this.shouldDelegateWhmcsAuth()
                || Boolean(whmcsConfig.identifier && whmcsConfig.secret)
                || Boolean(adminBridge.enabled && adminBridge.configPath);
            res.json({
                passkey: {
                    supported: !!this.modules.twoFactorAuth,
                    recommendedAfterMinutes: 10
                },
                providers: [
                    { id: 'email', name: 'Sign In', enabled: true, default: true },
                    { id: 'mastodon', name: 'Mastodon', enabled: true, default: false },
                    { id: 'whmcs', name: 'Client Portal', enabled: whmcsEnabled, default: false }
                ]
            });
        });

        this.app.get('/api/auth/oauth/providers', (_req, res) => {
            res.json({
                providers: [
                    { id: 'mastodon', name: 'Mastodon', enabled: true }
                ]
            });
        });

        this.app.get('/api/admin/status', (req, res) => {
            const user = this.getAnyAuthUserFromRequest ? this.getAnyAuthUserFromRequest(req) : (this.getLocalAuthUserFromRequest ? this.getLocalAuthUserFromRequest(req) : null);
            const role = String(user?.role || 'none').toLowerCase();
            const isAdmin = role === 'owner' || role === 'admin';
            res.json({
                isAdmin,
                role,
                isModerator: role === 'staff',
                user: user ? publicLocalUser(user) : null
            });
        });

        // Store for linked devices and pending email verifications
        this.linkedDevices = new Map(); // deviceId -> LinkedDevice
        this.pairingCodes = new Map(); // code -> { expiresAt, serverInfo }
        this.emailVerificationCodes = new Map(); // email -> { code, expiresAt, clientId }

        // Generate pairing code for this server
        this.app.post('/api/pairing/generate', (req, res) => {
            const authToken = String(req.body?.authToken || '').trim();
            const authReq = authToken
                ? { ...req, body: { ...(req.body || {}), accessToken: authToken } }
                : req;
            const actingUser = this.getAnyAuthUserFromRequest ? this.getAnyAuthUserFromRequest(authReq) : null;
            const role = String(actingUser?.role || '').toLowerCase();
            if (!actingUser || (role !== 'owner' && role !== 'admin')) {
                return res.status(403).json({ success: false, error: 'Only authenticated server admins can generate pairing codes.' });
            }

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
                },
                generatedBy: {
                    id: actingUser.id || null,
                    username: actingUser.username || actingUser.fullHandle || actingUser.email || 'admin'
                },
                requireAuth: true
            });

            // Auto-cleanup after expiry
            setTimeout(() => {
                this.pairingCodes.delete(code);
            }, 60000);

            res.json({
                success: true,
                code,
                expiresAt: new Date(Date.now() + 60000),
                generatedBy: actingUser.username || actingUser.fullHandle || actingUser.email || 'admin'
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

            const authReq = authToken
                ? { ...req, body: { ...(req.body || {}), accessToken: authToken } }
                : req;
            const pairingUser = this.getAnyAuthUserFromRequest ? this.getAnyAuthUserFromRequest(authReq) : null;
            if (pairingData.requireAuth && !pairingUser) {
                return res.status(401).json({ error: 'You must sign in before pairing this client.' });
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
                pairedByUserId: pairingUser?.id || null,
                pairedByUsername: pairingUser?.username || pairingUser?.fullHandle || pairingUser?.email || null,
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

        // List devices for the authenticated account, or all server-linked devices for admins
        this.app.get('/api/devices', async (req, res) => {
            const principal = await buildNormalizedLicenseIdentity(req, {});
            if (principal.identityKey) {
                const record = findLicenseRecordByIdentityKey(principal.identityKey)
                    || await ensureLicenseRecordForPrincipal(principal, {});
                if (!record) {
                    return res.status(500).json({ error: 'Unable to load license devices' });
                }
                const accessCheck = enforceLicensePrincipalAccess(record, principal);
                if (!accessCheck.allowed) {
                    return res.status(403).json({ error: accessCheck.error });
                }

                const devices = (Array.isArray(record.devices) ? record.devices : []).map((device = {}) => {
                    const liveSocketId = this.deviceSessions.get(device.id) || this.deviceSessions.get(device.uuid);
                    const lastSeen = device.lastSeen || device.linkedAt || new Date().toISOString();
                    const reachable = !!liveSocketId || (Date.now() - new Date(lastSeen).getTime()) <= 300000;
                    return {
                        id: device.id || device.uuid || null,
                        clientId: device.uuid || device.id || null,
                        deviceName: device.name || 'Desktop Client',
                        authMethod: device.authMethod || null,
                        authUsername: principal.username || null,
                        authProvider: device.authProvider || null,
                        linkedAt: device.linkedAt || null,
                        lastSeen,
                        isRevoked: false,
                        isOnline: reachable,
                        source: 'license'
                    };
                });

                return res.json({
                    devices,
                    recentMachines: Array.isArray(record.machineHistory) ? record.machineHistory : [],
                    source: 'license'
                });
            }

            if (!this.isLocalAdminRequest(req)) {
                return res.status(401).json({ error: 'Authentication required' });
            }

            const devices = [];
            this.linkedDevices.forEach((device, id) => {
                devices.push({
                    id: device.id,
                    clientId: device.clientId || device.id,
                    deviceName: device.deviceName,
                    authMethod: device.authMethod,
                    authUsername: device.authUsername,
                    linkedAt: device.linkedAt,
                    lastSeen: device.lastSeen,
                    isRevoked: device.isRevoked,
                    isOnline: (Date.now() - new Date(device.lastSeen || 0).getTime()) <= 300000,
                    source: 'server'
                });
            });
            res.json({ devices, source: 'server' });
        });

        // Revoke device access (server-initiated)
        this.app.post('/api/devices/:deviceId/revoke', async (req, res) => {
            const { deviceId } = req.params;
            const principal = await buildNormalizedLicenseIdentity(req, {});

            if (principal.identityKey) {
                const record = findLicenseRecordByIdentityKey(principal.identityKey)
                    || await ensureLicenseRecordForPrincipal(principal, {});
                if (!record) {
                    return res.status(500).json({ success: false, error: 'Unable to load license record' });
                }
                const accessCheck = enforceLicensePrincipalAccess(record, principal);
                if (!accessCheck.allowed) {
                    return res.status(403).json({ success: false, error: accessCheck.error });
                }

                record.devices = (record.devices || []).filter((entry) => entry.id !== deviceId && entry.uuid !== deviceId);
                if (Array.isArray(record.machineHistory)) {
                    const machine = record.machineHistory.find((entry) => entry.id === deviceId || entry.uuid === deviceId);
                    if (machine) {
                        machine.state = 'deactivated';
                        machine.lastSeen = new Date().toISOString();
                    }
                }
                record.updatedAt = new Date().toISOString();
                persistLicensingState();

                const targetSocketId = this.deviceSessions.get(deviceId);
                if (this.io && targetSocketId) {
                    this.io.to(targetSocketId).emit('access-revoked', {
                        deviceId,
                        reason: req.body.reason || 'Access revoked by account owner'
                    });
                }

                return res.json({ success: true, message: 'Device access revoked', ...publicLicenseRecord(record, principal) });
            }

            if (!this.isLocalAdminRequest(req)) {
                return res.status(401).json({ success: false, error: 'Authentication required' });
            }

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
        this.app.delete('/api/devices/:deviceId', async (req, res) => {
            const { deviceId } = req.params;
            const principal = await buildNormalizedLicenseIdentity(req, {});

            if (principal.identityKey) {
                const record = findLicenseRecordByIdentityKey(principal.identityKey)
                    || await ensureLicenseRecordForPrincipal(principal, {});
                if (!record) {
                    return res.status(500).json({ success: false, error: 'Unable to load license record' });
                }
                const accessCheck = enforceLicensePrincipalAccess(record, principal);
                if (!accessCheck.allowed) {
                    return res.status(403).json({ success: false, error: accessCheck.error });
                }

                record.devices = (record.devices || []).filter((entry) => entry.id !== deviceId && entry.uuid !== deviceId);
                if (Array.isArray(record.machineHistory)) {
                    record.machineHistory = record.machineHistory.filter((entry) => entry.id !== deviceId && entry.uuid !== deviceId);
                }
                record.updatedAt = new Date().toISOString();
                persistLicensingState();

                const targetSocketId = this.deviceSessions.get(deviceId);
                if (this.io && targetSocketId) {
                    this.io.to(targetSocketId).emit('device-removed', { deviceId });
                }

                return res.json({ success: true, message: 'Device removed', ...publicLicenseRecord(record, principal) });
            }

            if (!this.isLocalAdminRequest(req)) {
                return res.status(401).json({ success: false, error: 'Authentication required' });
            }

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
                expiresAt: new Date(Date.now() + 15 * 60 * 1000), // 15 minutes
                attempts: 0
            });

            // Auto-cleanup after expiry
            setTimeout(() => {
                this.emailVerificationCodes.delete(email);
            }, 15 * 60 * 1000);

            // Try to send email if nodemailer is configured
            try {
                if (this.mailer) {
                    const supportAddress = this.emailFrom || 'services@devine-creations.com';
                    await this.mailer.sendMail({
                        from: supportAddress,
                        to: email,
                        subject: 'VoiceLink Sign-in Verification Code',
                        text: `VoiceLink verification code: ${code}\n\nThis code expires in 15 minutes.\n\nIf you did not request this code, you can safely ignore this message.\n\nNeed help? Contact ${supportAddress}`,
                        html: `
                            <div style="font-family: sans-serif; max-width: 400px; margin: 0 auto; padding: 20px;">
                                <h2 style="color: #6366f1;">VoiceLink Sign-in Verification</h2>
                                <p>Use this code to complete sign-in on VoiceLink:</p>
                                <div style="font-size: 32px; font-weight: bold; letter-spacing: 4px; padding: 20px; background: #f3f4f6; border-radius: 8px; text-align: center;">
                                    ${code}
                                </div>
                                <p style="color: #666; font-size: 14px;">This code expires in 15 minutes.</p>
                                <p style="color: #999; font-size: 12px;">If you did not request this code, you can ignore this message.</p>
                                <p style="color: #999; font-size: 12px;">Support: ${supportAddress}</p>
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

        this.app.get('/api/rooms/:roomId/jellyfin/access', (req, res) => {
            const room = this.rooms.get(req.params.roomId);
            if (!room) return res.status(404).json({ error: 'Room not found' });
            const requester = this.getRequesterContext(req);
            const canManage = this.canManageRoomJellyfin(room, requester);
            const effective = this.getRoomJellyfinPermission(room, requester);
            const access = this.ensureRoomJellyfinAccess(room);
            res.json({ success: true, roomId: room.id, canManage, access, effective });
        });

        this.app.put('/api/rooms/:roomId/jellyfin/access', (req, res) => {
            const room = this.rooms.get(req.params.roomId);
            if (!room) return res.status(404).json({ error: 'Room not found' });
            const requester = this.getRequesterContext(req);
            if (!this.canManageRoomJellyfin(room, requester)) {
                return res.status(403).json({ error: 'Only admins or room owner can update Jellyfin room access' });
            }
            const access = this.ensureRoomJellyfinAccess(room);
            const payload = req.body || {};
            if (typeof payload.enabled === 'boolean') access.enabled = payload.enabled;
            if (typeof payload.adminCanAccessAll === 'boolean') access.adminCanAccessAll = payload.adminCanAccessAll;
            if (typeof payload.allowRoomOwnerUploads === 'boolean') access.allowRoomOwnerUploads = payload.allowRoomOwnerUploads;
            if (typeof payload.allowAuthenticatedUploads === 'boolean') access.allowAuthenticatedUploads = payload.allowAuthenticatedUploads;
            if (Array.isArray(payload.allowedServerIds)) access.allowedServerIds = payload.allowedServerIds.map(String);
            if (payload.allowedLibraryIdsByServer && typeof payload.allowedLibraryIdsByServer === 'object') {
                const next = {};
                Object.entries(payload.allowedLibraryIdsByServer).forEach(([serverId, ids]) => {
                    next[String(serverId)] = Array.isArray(ids) ? ids.map(String) : [];
                });
                access.allowedLibraryIdsByServer = next;
            }
            res.json({ success: true, roomId: room.id, access });
        });

        this.app.put('/api/rooms/:roomId/jellyfin/access/users/:principal', (req, res) => {
            const room = this.rooms.get(req.params.roomId);
            if (!room) return res.status(404).json({ error: 'Room not found' });
            const requester = this.getRequesterContext(req);
            if (!this.canManageRoomJellyfin(room, requester)) {
                return res.status(403).json({ error: 'Only admins or room owner can manage room user Jellyfin access' });
            }
            const principal = String(req.params.principal || '').trim();
            if (!principal) return res.status(400).json({ error: 'principal is required (id:<id> or name:<name>)' });
            const access = this.ensureRoomJellyfinAccess(room);
            const payload = req.body || {};
            access.roomUserPermissions[principal] = {
                canUseLibraries: payload.canUseLibraries !== false,
                canUploadMedia: payload.canUploadMedia === true,
                canManageRoomLibraries: payload.canManageRoomLibraries === true,
                allowedServerIds: Array.isArray(payload.allowedServerIds) ? payload.allowedServerIds.map(String) : [],
                allowedLibraryIdsByServer: payload.allowedLibraryIdsByServer && typeof payload.allowedLibraryIdsByServer === 'object'
                    ? Object.fromEntries(
                        Object.entries(payload.allowedLibraryIdsByServer).map(([serverId, ids]) => [String(serverId), Array.isArray(ids) ? ids.map(String) : []])
                    )
                    : {}
            };
            res.json({ success: true, roomId: room.id, principal, permission: access.roomUserPermissions[principal] });
        });

        this.app.delete('/api/rooms/:roomId/jellyfin/access/users/:principal', (req, res) => {
            const room = this.rooms.get(req.params.roomId);
            if (!room) return res.status(404).json({ error: 'Room not found' });
            const requester = this.getRequesterContext(req);
            if (!this.canManageRoomJellyfin(room, requester)) {
                return res.status(403).json({ error: 'Only admins or room owner can manage room user Jellyfin access' });
            }
            const principal = String(req.params.principal || '').trim();
            const access = this.ensureRoomJellyfinAccess(room);
            delete access.roomUserPermissions[principal];
            res.json({ success: true, roomId: room.id, principal });
        });

        this.app.get('/api/rooms/:roomId/jellyfin/libraries', async (req, res) => {
            const room = this.rooms.get(req.params.roomId);
            if (!room) return res.status(404).json({ error: 'Room not found' });
            const requester = this.getRequesterContext(req);
            const permission = this.getRoomJellyfinPermission(room, requester);
            if (!permission.canUseLibraries) return res.status(403).json({ error: 'Library access disabled for this user' });
            const serverId = String(req.query.serverId || '');
            const server = this.jellyfinServers.get(serverId);
            if (!server) return res.status(404).json({ error: 'Jellyfin server not found' });
            if (!this.isServerAllowedForRoom(room, serverId, requester)) {
                return res.status(403).json({ error: 'This Jellyfin server is not allowed for this room' });
            }
            try {
                const response = await fetch(`${server.url}/Library/MediaFolders?api_key=${server.apiKey}`);
                const data = await response.json();
                const allowed = this.getRoomJellyfinPermission(room, requester).allowedLibraryIdsByServer?.[serverId]
                    || this.ensureRoomJellyfinAccess(room).allowedLibraryIdsByServer?.[serverId]
                    || [];
                const allLibraries = Array.isArray(data.Items) ? data.Items : [];
                const libraries = (!allowed.length || (requester.isAdmin && this.ensureRoomJellyfinAccess(room).adminCanAccessAll))
                    ? allLibraries
                    : allLibraries.filter((item) => allowed.includes(String(item.ItemId || item.Id)));
                res.json({
                    success: true,
                    roomId: room.id,
                    serverId,
                    canUpload: !!permission.canUploadMedia,
                    libraries: libraries.map((item) => ({
                        id: String(item.ItemId || item.Id),
                        name: item.Name,
                        collectionType: item.CollectionType || null
                    }))
                });
            } catch (error) {
                res.status(500).json({ error: 'Failed to fetch room libraries: ' + error.message });
            }
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

            // Common Jellyfin ports
            const jellyfinPorts = [8096, 8920];

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

            const roomId = req.query.roomId ? String(req.query.roomId) : null;
            if (roomId) {
                const room = this.rooms.get(roomId);
                if (!room) return res.status(404).json({ error: 'Room not found' });
                const requester = this.getRequesterContext(req);
                const permission = this.getRoomJellyfinPermission(room, requester);
                if (!permission.canUseLibraries) return res.status(403).json({ error: 'Library access disabled for this user' });
                if (!this.isServerAllowedForRoom(room, req.params.serverId, requester)) {
                    return res.status(403).json({ error: 'This Jellyfin server is not allowed for this room' });
                }
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
            const { serverId, itemId, roomId, libraryId = null, type = 'audio', startedBy = 'Jukebox' } = req.body;

            const server = this.jellyfinServers.get(serverId);
            if (!server) {
                return res.status(404).json({ error: 'Jellyfin server not found' });
            }

            const room = this.rooms.get(roomId);
            if (!room) {
                return res.status(404).json({ error: 'Room not found' });
            }

            const requester = this.getRequesterContext(req);
            const permission = this.getRoomJellyfinPermission(room, requester);
            if (!permission.canUseLibraries) {
                return res.status(403).json({ error: 'You are not allowed to stream media in this room' });
            }
            if (!this.isServerAllowedForRoom(room, serverId, requester)) {
                return res.status(403).json({ error: 'Selected Jellyfin server is not allowed in this room' });
            }
            if (!this.isLibraryAllowedForRoom(room, serverId, libraryId, requester)) {
                return res.status(403).json({ error: 'Selected library is not allowed in this room' });
            }
            if (this.modules.mediaRooms?.isRoomMediaEnabled && !this.modules.mediaRooms.isRoomMediaEnabled(roomId)) {
                this.modules.mediaRooms.setRoomMediaEnabled(roomId, true);
            }

            // Store active stream info
            this.roomMediaStreams.set(roomId, {
                serverId,
                itemId,
                libraryId,
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

        this.app.put('/api/rooms/:roomId/media-enabled', (req, res) => {
            const room = this.rooms.get(req.params.roomId);
            if (!room) return res.status(404).json({ error: 'Room not found' });
            if (!this.modules.mediaRooms) {
                return res.status(500).json({ error: 'Media module not loaded' });
            }
            const requester = this.getRequesterContext(req);
            if (!this.canManageRoomJellyfin(room, requester)) {
                return res.status(403).json({ error: 'Only admins or room owner can update room media playback' });
            }

            const enabled = req.body?.enabled !== false;
            const state = this.modules.mediaRooms.setRoomMediaEnabled(room.id, enabled);
            if (!enabled) {
                this.roomMediaStreams.delete(room.id);
                this.io.to(room.id).emit('media-stream-stopped', { roomId: room.id, disabled: true });
                this.io.to(room.id).emit('room-media-updated', {
                    roomId: room.id,
                    mediaEnabled: false,
                    updatedBy: requester.name || requester.username || 'administrator'
                });
            } else {
                this.io.to(room.id).emit('room-media-updated', {
                    roomId: room.id,
                    mediaEnabled: true,
                    updatedBy: requester.name || requester.username || 'administrator'
                });
            }

            res.json({
                success: true,
                roomId: room.id,
                mediaEnabled: state.mediaEnabled !== false
            });
        });

        // Get active stream for a room
        this.app.get('/api/jellyfin/room-stream/:roomId', (req, res) => {
            const mediaEnabled = this.modules.mediaRooms?.isRoomMediaEnabled
                ? this.modules.mediaRooms.isRoomMediaEnabled(req.params.roomId)
                : true;
            if (!mediaEnabled) {
                return res.json({ active: false, disabled: true, mediaEnabled: false, message: 'Room media is disabled' });
            }
            const stream = this.roomMediaStreams.get(req.params.roomId);
            if (!stream) {
                const room = this.rooms.get(req.params.roomId);
                const configuredBackgroundStream = room ? this.getConfiguredBackgroundStreamForRoom(room) : null;
                if (configuredBackgroundStream) {
                    return res.json({
                        active: true,
                        mediaEnabled: true,
                        type: 'audio',
                        streamUrl: configuredBackgroundStream.streamUrl,
                        startedAt: null,
                        startedBy: 'background-stream',
                        title: configuredBackgroundStream.name,
                        volume: configuredBackgroundStream.volume
                    });
                }
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
                mediaEnabled: true,
                type: stream.type,
                streamUrl,
                startedAt: stream.startedAt,
                startedBy: stream.startedBy
            });
        });

        // Add to room queue
        this.app.post('/api/jellyfin/queue', (req, res) => {
            const { roomId, serverId, itemId, libraryId = null, title, type, addedBy = 'Jukebox' } = req.body;
            const room = this.rooms.get(roomId);
            if (!room) return res.status(404).json({ error: 'Room not found' });
            const requester = this.getRequesterContext(req);
            const permission = this.getRoomJellyfinPermission(room, requester);
            if (!permission.canUseLibraries) {
                return res.status(403).json({ error: 'You are not allowed to queue media in this room' });
            }
            if (!this.isServerAllowedForRoom(room, serverId, requester)) {
                return res.status(403).json({ error: 'Selected Jellyfin server is not allowed in this room' });
            }
            if (!this.isLibraryAllowedForRoom(room, serverId, libraryId, requester)) {
                return res.status(403).json({ error: 'Selected library is not allowed in this room' });
            }

            if (!this.mediaQueues.has(roomId)) {
                this.mediaQueues.set(roomId, []);
            }

            const queue = this.mediaQueues.get(roomId);
            queue.push({
                serverId,
                itemId,
                libraryId,
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

        // Setup Federated Jellyfin routes
        if (this.federatedJellyfin) {
            this.federatedJellyfin.setupRoutes(this.app);
            this.jellyfinAutoManager.setupRoutes(this.app);
        }

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

        const normalizeVisibilityConfig = (value = {}) => {
            const fallback = { desktop: true, ios: true, web: true, frontendOpen: true };
            if (!value || typeof value !== 'object') return fallback;
            return {
                desktop: value.desktop !== false,
                ios: value.ios !== false,
                web: value.web !== false,
                frontendOpen: value.frontendOpen !== false
            };
        };

        const resolveDeploymentActor = (req) => {
            const authUser = req.authUser || req.user || {};
            const actorName = String(
                authUser.displayName
                || authUser.username
                || authUser.email
                || req.headers['x-user-email']
                || req.headers['x-forwarded-user']
                || 'admin'
            ).trim();
            return {
                actorName,
                actorId: String(authUser.id || authUser.userId || req.headers['x-client-id'] || '').trim() || null,
                actorEmail: String(authUser.email || req.headers['x-user-email'] || '').trim() || null,
                actorClientId: String(req.headers['x-client-id'] || '').trim() || null
            };
        };

        const getServerPolicyConfig = () => {
            const cfg = deployConfig.get('serverPolicies') || {};
            const ownerVisibility = normalizeVisibilityConfig(cfg.visibility);
            const override = cfg.visibilityOverride && typeof cfg.visibilityOverride === 'object'
                ? cfg.visibilityOverride
                : {};
            const now = Date.now();
            const expiresAtTs = override.expiresAt ? new Date(override.expiresAt).getTime() : null;
            const overrideExpired = Number.isFinite(expiresAtTs) && expiresAtTs <= now;
            if (override.active && overrideExpired) {
                const next = { ...cfg, visibilityOverride: { active: false, reason: '', setBy: '', setAt: null, expiresAt: null, visibility: null } };
                deployConfig.updateSection('serverPolicies', next);
            }
            const freshCfg = deployConfig.get('serverPolicies') || cfg;
            const freshOverride = freshCfg.visibilityOverride && typeof freshCfg.visibilityOverride === 'object'
                ? freshCfg.visibilityOverride
                : {};
            const overrideActive = !!freshOverride.active && !(freshOverride.expiresAt && new Date(freshOverride.expiresAt).getTime() <= Date.now());
            const effectiveVisibility = overrideActive && freshOverride.visibility
                ? normalizeVisibilityConfig(freshOverride.visibility)
                : ownerVisibility;
            return {
                primaryServerUrl: freshCfg.primaryServerUrl || 'https://voicelink.devinecreations.net',
                autoPairPrimaryServer: freshCfg.autoPairPrimaryServer !== false,
                autoPullUpdatesFromPrimary: freshCfg.autoPullUpdatesFromPrimary !== false,
                autoInstallRequiredModules: freshCfg.autoInstallRequiredModules !== false,
                autoInstallOptionalModules: !!freshCfg.autoInstallOptionalModules,
                updatePushMode: freshCfg.updatePushMode || 'manual',
                updateCheckIntervalMinutes: Number(freshCfg.updateCheckIntervalMinutes || 30),
                bootstrapFederationOnInstall: freshCfg.bootstrapFederationOnInstall !== false,
                bootstrapFederationMinutes: Number(freshCfg.bootstrapFederationMinutes || 15),
                deploymentAutomation: {
                    enabled: !!freshCfg.deploymentAutomation?.enabled,
                    allowManualServerConfig: freshCfg.deploymentAutomation?.allowManualServerConfig !== false,
                    allowAutoSetup: !!freshCfg.deploymentAutomation?.allowAutoSetup,
                    requireRemoteCredentials: freshCfg.deploymentAutomation?.requireRemoteCredentials !== false,
                    allowSshKeyAuth: freshCfg.deploymentAutomation?.allowSshKeyAuth !== false,
                    allowPasswordAuth: freshCfg.deploymentAutomation?.allowPasswordAuth !== false
                },
                moduleGovernance: {
                    required: Array.isArray(freshCfg.moduleGovernance?.required) ? freshCfg.moduleGovernance.required : [],
                    optional: Array.isArray(freshCfg.moduleGovernance?.optional) ? freshCfg.moduleGovernance.optional : [],
                    revoked: Array.isArray(freshCfg.moduleGovernance?.revoked) ? freshCfg.moduleGovernance.revoked : [],
                    allowedByServer: freshCfg.moduleGovernance?.allowedByServer && typeof freshCfg.moduleGovernance.allowedByServer === 'object'
                        ? freshCfg.moduleGovernance.allowedByServer
                        : {},
                    ownerAutoUpdateModules: !!freshCfg.moduleGovernance?.ownerAutoUpdateModules,
                    ownerUpdateChannel: freshCfg.moduleGovernance?.ownerUpdateChannel || 'manual'
                },
                networkTrust: {
                    level: Math.min(100, Math.max(1, Number(freshCfg.networkTrust?.level || 1))),
                    role: String(freshCfg.networkTrust?.role || 'visitor'),
                    isCommunityServer: !!freshCfg.networkTrust?.isCommunityServer,
                    isTrustedModerator: !!freshCfg.networkTrust?.isTrustedModerator,
                    isTrustedOwner: !!freshCfg.networkTrust?.isTrustedOwner
                },
                visibility: ownerVisibility,
                visibilityOverride: {
                    active: overrideActive,
                    reason: String(freshOverride.reason || ''),
                    setBy: String(freshOverride.setBy || ''),
                    setAt: freshOverride.setAt || null,
                    expiresAt: freshOverride.expiresAt || null,
                    visibility: freshOverride.visibility ? normalizeVisibilityConfig(freshOverride.visibility) : null
                },
                effectiveVisibility
            };
        };

        const networkTrustMeaning = (level = 1) => {
            const numeric = Math.min(100, Math.max(1, Number(level || 1)));
            if (numeric >= 90) return 'Network core authority';
            if (numeric >= 75) return 'Trusted owner tier';
            if (numeric >= 60) return 'Trusted moderator tier';
            if (numeric >= 40) return 'Community server tier';
            if (numeric >= 20) return 'Verified server tier';
            return 'Visitor / baseline tier';
        };

        // Get current server configuration
        this.app.get('/api/config', (req, res) => {
            const config = deployConfig.getConfig() || {};
            const serverPolicies = getServerPolicyConfig();
            const flattened = {
                serverName: config.server?.name || 'VoiceLink',
                serverDescription: config.server?.description || config.server?.tagline || '',
                maxUsers: Number(config.server?.maxUsers || config.rooms?.maxUsers || 500),
                maxRooms: Number(config.rooms?.maxRooms || config.server?.maxRooms || 100),
                maxUsersPerRoom: Number(config.rooms?.maxUsersPerRoom || config.server?.maxUsersPerRoom || 50),
                welcomeMessage: config.server?.welcomeMessage || null,
                lobbyWelcomeMessage: config.server?.lobbyWelcomeMessage || this.getDefaultLobbyWelcomeMessage(),
                motd: config.server?.motd || null,
                motdSettings: {
                    enabled: config.server?.motdSettings?.enabled !== false,
                    showBeforeJoin: config.server?.motdSettings?.showBeforeJoin !== false,
                    showInRoom: config.server?.motdSettings?.showInRoom !== false,
                    appendToWelcomeMessage: !!config.server?.motdSettings?.appendToWelcomeMessage
                },
                handoffPromptMode: config.server?.handoffPromptMode || 'serverRecommended',
                registrationEnabled: config.auth?.registrationEnabled ?? config.security?.registrationEnabled ?? true,
                requireAuth: config.security?.requireAuth ?? config.features?.requireAuth ?? false,
                allowGuests: config.security?.allowGuests ?? true,
                maxGuestDuration: config.security?.maxGuestDuration ?? null,
                enableRateLimiting: config.security?.enableRateLimiting ?? true,
                serverVisibility: serverPolicies.effectiveVisibility,
                ownerVisibility: serverPolicies.visibility,
                visibilityOverrideActive: serverPolicies.visibilityOverride.active,
                backgroundStreams: config.backgroundStreams || null,
                pushover: config.pushover || null,
                messageSettings: this.getMessageSettingsConfig()
            };
            res.json(flattened);
        });

        // Update server configuration
        this.app.put('/api/config', async (req, res) => {
            try {
                const updates = req.body || {};
                const hasKey = (key) => Object.prototype.hasOwnProperty.call(updates, key);
                if (typeof updates.serverName === 'string') {
                    const motdSettings = updates.motdSettings && typeof updates.motdSettings === 'object'
                        ? {
                            enabled: updates.motdSettings.enabled !== false,
                            showBeforeJoin: updates.motdSettings.showBeforeJoin !== false,
                            showInRoom: updates.motdSettings.showInRoom !== false,
                            appendToWelcomeMessage: !!updates.motdSettings.appendToWelcomeMessage
                        }
                        : (deployConfig.getConfig()?.server?.motdSettings || {
                            enabled: true,
                            showBeforeJoin: true,
                            showInRoom: true,
                            appendToWelcomeMessage: false
                        });
                    deployConfig.updateSection('server', {
                        name: updates.serverName,
                        description: updates.serverDescription || '',
                        welcomeMessage: updates.welcomeMessage || null,
                        lobbyWelcomeMessage: typeof updates.lobbyWelcomeMessage === 'string'
                            ? (updates.lobbyWelcomeMessage.trim() || this.getDefaultLobbyWelcomeMessage())
                            : (deployConfig.getConfig()?.server?.lobbyWelcomeMessage || this.getDefaultLobbyWelcomeMessage()),
                        motd: updates.motd || null,
                        motdSettings,
                        handoffPromptMode: typeof updates.handoffPromptMode === 'string' ? updates.handoffPromptMode : (deployConfig.getConfig()?.server?.handoffPromptMode || 'serverRecommended'),
                        maxUsers: Number(updates.maxUsers) || 500,
                        maxUsersPerRoom: Number(updates.maxUsersPerRoom) || 50
                    });
                }
                if (hasKey('maxRooms') || hasKey('maxUsersPerRoom')) {
                    const currentRooms = deployConfig.get('rooms') || {};
                    const nextRooms = { ...currentRooms };
                    if (hasKey('maxRooms')) {
                        const parsedMaxRooms = Number(updates.maxRooms);
                        nextRooms.maxRooms = Number.isFinite(parsedMaxRooms) && parsedMaxRooms > 0
                            ? parsedMaxRooms
                            : currentRooms.maxRooms;
                    }
                    if (hasKey('maxUsersPerRoom')) {
                        const parsedMaxUsersPerRoom = Number(updates.maxUsersPerRoom);
                        nextRooms.maxUsersPerRoom = Number.isFinite(parsedMaxUsersPerRoom) && parsedMaxUsersPerRoom > 0
                            ? parsedMaxUsersPerRoom
                            : currentRooms.maxUsersPerRoom;
                    }
                    deployConfig.updateSection('rooms', nextRooms);
                }
                if (hasKey('requireAuth')
                    || hasKey('registrationEnabled')
                    || hasKey('allowGuests')
                    || hasKey('maxGuestDuration')
                    || hasKey('enableRateLimiting')) {
                    const currentSecurity = deployConfig.get('security') || {};
                    const nextSecurity = { ...currentSecurity };
                    if (hasKey('requireAuth')) {
                        nextSecurity.requireAuth = !!updates.requireAuth;
                    }
                    if (hasKey('registrationEnabled')) {
                        nextSecurity.registrationEnabled = updates.registrationEnabled !== false;
                    }
                    if (hasKey('allowGuests')) {
                        nextSecurity.allowGuests = updates.allowGuests !== false;
                    }
                    if (hasKey('maxGuestDuration')) {
                        nextSecurity.maxGuestDuration = updates.maxGuestDuration ?? null;
                    }
                    if (hasKey('enableRateLimiting')) {
                        nextSecurity.enableRateLimiting = updates.enableRateLimiting !== false;
                    }
                    deployConfig.updateSection('security', nextSecurity);
                }
                if (updates.serverVisibility && typeof updates.serverVisibility === 'object') {
                    const currentPolicies = deployConfig.get('serverPolicies') || {};
                    deployConfig.updateSection('serverPolicies', {
                        ...currentPolicies,
                        visibility: normalizeVisibilityConfig(updates.serverVisibility)
                    });
                }
                if (updates.backgroundStreams && typeof updates.backgroundStreams === 'object') {
                    deployConfig.updateSection('backgroundStreams', updates.backgroundStreams);
                }
                if (updates.pushover && typeof updates.pushover === 'object') {
                    deployConfig.updateSection('pushover', updates.pushover);
                }
                if (updates.messageSettings && typeof updates.messageSettings === 'object') {
                    deployConfig.updateSection('messageSettings', {
                        ...this.getMessageSettingsConfig(),
                        ...updates.messageSettings
                    });
                }

                await deployConfig.save();
                res.json({ success: true, message: 'Configuration updated' });
            } catch (error) {
                res.status(500).json({ error: error.message });
            }
        });

        this.app.get('/api/admin/logs', (req, res) => {
            if (this.isLocalAdminRequest && !this.isLocalAdminRequest(req)) {
                return res.status(403).json({ success: false, error: 'Admin access required' });
            }
            try {
                const appRoot = path.join(__dirname, '../..');
                const pm2Home = process.env.PM2_HOME || path.join(os.homedir(), '.pm2');
                const candidatePaths = [
                    path.join(pm2Home, 'logs', 'voicelink-primary-error.log'),
                    path.join(pm2Home, 'logs', 'voicelink-primary-out.log'),
                    path.join(pm2Home, 'logs', 'voicelink-hubnode-gateway-error.log'),
                    path.join(pm2Home, 'logs', 'voicelink-hubnode-gateway-out.log'),
                    path.join(pm2Home, 'logs', 'voicelink-local-api-error.log'),
                    path.join(pm2Home, 'logs', 'voicelink-local-api-out.log'),
                    path.join(appRoot, 'logs', 'server.log'),
                    path.join(appRoot, 'server.log'),
                    path.join(appRoot, 'logs', 'combined.log')
                ];
                const existing = candidatePaths.filter(p => fs.existsSync(p));
                const lines = existing.flatMap((filePath) => {
                    const text = fs.readFileSync(filePath, 'utf8');
                    return text
                        .split(/\r?\n/)
                        .filter(Boolean)
                        .slice(-120)
                        .map((line) => `[${path.basename(filePath)}] ${line}`);
                });
                const bugFile = path.join(appRoot, 'data', 'bug-reports.json');
                const bugLines = fs.existsSync(bugFile)
                    ? (() => {
                        try {
                            const reports = JSON.parse(fs.readFileSync(bugFile, 'utf8') || '[]');
                            return (Array.isArray(reports) ? reports : [])
                                .slice(0, 25)
                                .map((report) => {
                                    const who = report.accountEmail || report.username || report.submittedBy || 'anonymous';
                                    const clientId = report.clientId || 'unknown-client';
                                    const room = report.currentRoom || 'no-room';
                                    const title = report.title || 'Untitled bug report';
                                    return `[bug-reports] ${report.submittedAt || new Date().toISOString()} ${who} ${clientId} room=${room} severity=${report.severity || 'normal'} category=${report.category || 'general'} title=${title}`;
                                });
                        } catch {
                            return [];
                        }
                    })()
                    : [];
                const combinedLines = [...bugLines, ...lines].slice(-300);
                if (existing.length === 0 && bugLines.length === 0) {
                    return res.json({ success: true, source: null, lines: [] });
                }
                res.json({
                    success: true,
                    source: [...existing.map((filePath) => path.basename(filePath)), bugLines.length > 0 ? 'bug-reports.json' : null].filter(Boolean).join(', '),
                    lines: combinedLines
                });
            } catch (error) {
                res.status(500).json({ success: false, error: error.message });
            }
        });

        this.app.post('/api/admin/background-streams/probe', async (req, res) => {
            if (this.isLocalAdminRequest && !this.isLocalAdminRequest(req)) {
                return res.status(403).json({ success: false, error: 'Admin access required' });
            }

            const rawInput = String(req.body?.input || '').trim();
            if (!rawInput) {
                return res.status(400).json({ success: false, error: 'input is required' });
            }

            const normalizeProbeBase = (value) => {
                const candidate = value.includes('://') ? value : `https://${value}`;
                try {
                    const url = new URL(candidate);
                    url.hash = '';
                    url.search = '';
                    if (!url.pathname || url.pathname === '/') {
                        url.pathname = '';
                    } else {
                        url.pathname = url.pathname.replace(/\/+$/, '');
                    }
                    return url.toString().replace(/\/$/, '');
                } catch {
                    return null;
                }
            };

            const buildCandidates = (value) => {
                const normalized = normalizeProbeBase(value);
                if (!normalized) return [];
                const baseUrl = new URL(normalized);
                const pathname = baseUrl.pathname || '';
                const directBase = `${baseUrl.protocol}//${baseUrl.host}${pathname}`.replace(/\/$/, '');
                const candidates = new Set([directBase]);

                if (!baseUrl.port && !pathname) {
                    ['http://', 'https://'].forEach((protocol) => {
                        ['8000', '8080'].forEach((port) => {
                            candidates.add(`${protocol}${baseUrl.hostname}:${port}`);
                        });
                    });
                }

                return Array.from(candidates);
            };

            const parseStatusJson = async (url) => {
                const response = await fetch(url, { method: 'GET' });
                if (!response.ok) return [];
                const payload = await response.json();
                const source = payload?.icestats?.source;
                const sources = Array.isArray(source) ? source : (source ? [source] : []);
                return sources.map((entry, index) => ({
                    id: `${url}#${index}`,
                    name: String(entry?.server_name || entry?.listenurl || entry?.stream || `Stream ${index + 1}`),
                    streamUrl: String(entry?.listenurl || '').trim() || url.replace(/\/status-json\.xsl$/, '/'),
                    type: 'icecast',
                    genre: entry?.genre || null,
                    bitrate: Number.isFinite(Number(entry?.bitrate)) ? Number(entry.bitrate) : null,
                    listeners: Number.isFinite(Number(entry?.listeners)) ? Number(entry.listeners) : null,
                    title: entry?.title || entry?.server_description || null,
                    artist: null,
                    sourceUrl: url
                })).filter((entry) => entry.streamUrl);
            };

            const parseShoutcastStats = async (url, base) => {
                const response = await fetch(url, { method: 'GET' });
                if (!response.ok) return [];
                const text = await response.text();
                const body = text.replace(/<[^>]+>/g, '').trim();
                const segments = body.split(',').map((part) => part.trim()).filter(Boolean);
                if (segments.length < 7) return [];
                return [{
                    id: `${url}#0`,
                    name: segments[6] || new URL(base).host,
                    streamUrl: `${base.replace(/\/$/, '')}/;`,
                    type: 'shoutcast',
                    genre: null,
                    bitrate: Number.isFinite(Number(segments[5])) ? Number(segments[5]) : null,
                    listeners: Number.isFinite(Number(segments[0])) ? Number(segments[0]) : null,
                    title: segments[6] || null,
                    artist: null,
                    sourceUrl: url
                }];
            };

            const seen = new Set();
            const streams = [];

            for (const base of buildCandidates(rawInput)) {
                const probes = [
                    { url: `${base}/status-json.xsl`, parse: parseStatusJson },
                    { url: `${base}/7.html`, parse: (url) => parseShoutcastStats(url, base) }
                ];

                for (const probe of probes) {
                    try {
                        const results = await probe.parse(probe.url);
                        for (const result of results) {
                            const key = `${result.streamUrl}|${result.name}`;
                            if (seen.has(key)) continue;
                            seen.add(key);
                            streams.push(result);
                        }
                    } catch (_error) {
                        continue;
                    }
                }

                if (!streams.length && /^https?:\/\//i.test(base)) {
                    const host = new URL(base).host;
                    const key = `${base}|${host}`;
                    if (!seen.has(key)) {
                        seen.add(key);
                        streams.push({
                            id: `${base}#direct`,
                            name: host,
                            streamUrl: base,
                            type: 'direct',
                            genre: null,
                            bitrate: null,
                            listeners: null,
                            title: null,
                            artist: null,
                            sourceUrl: base
                        });
                    }
                }
            }

            res.json({ success: true, streams });
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
                const { label, includeFederationSnapshot, includeLinkedServers } = req.body || {};
                const backupCfg = deployConfig.get('backup') || {};
                const includeFed = includeFederationSnapshot !== undefined
                    ? !!includeFederationSnapshot
                    : backupCfg.includeFederationSnapshot !== false;
                const includeLinks = includeLinkedServers !== undefined
                    ? !!includeLinkedServers
                    : backupCfg.includeLinkedServers !== false;

                const metadata = {};
                if (includeFed) {
                    metadata.federation = {
                        status: {
                            mode: this.federation?.mode || 'standalone',
                            peerServers: this.federation?.peerServers || [],
                            masterServer: this.federation?.masterServerUrl || null,
                            connectedServers: this.federation?.getConnectedServers?.() || []
                        },
                        config: deployConfig.get('federation') || {}
                    };
                }
                if (includeLinks) {
                    metadata.linkedServers = (deployConfig.get('federation', 'trustedServers') || []).map((url) => ({ url }));
                }

                const result = await deployConfig.createBackup(label, { metadata });
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
            const policy = getServerPolicyConfig();
            res.json({
                enabled: config?.enabled || false,
                mode: config?.mode || 'standalone',
                globalFederation: config?.globalFederation !== false, // default true
                allowIncoming: config?.allowIncoming !== false,
                allowOutgoing: config?.allowOutgoing !== false,
                trustedServers: config?.trustedServers || [],
                roomApprovalRequired: config?.roomApprovalRequired || false,
                approvalHoldTime: config?.approvalHoldTime || 3600000, // 1 hour default
                maintenanceModeEnabled: config?.maintenanceModeEnabled || false,
                autoHandoffEnabled: config?.autoHandoffEnabled || false,
                handoffTargetServer: config?.handoffTargetServer || null,
                pendingApprovals: this.roomApprovalQueue.size,
                connectedServers: this.federation.getConnectedServers().length,
                serverVisibility: policy.effectiveVisibility,
                networkTrust: {
                    level: policy.networkTrust.level,
                    role: policy.networkTrust.role,
                    meaning: networkTrustMeaning(policy.networkTrust.level)
                }
            });
        });

        // Update federation settings
        this.app.put('/api/federation/settings', async (req, res) => {
            try {
                const {
                    enabled,
                    mode,
                    globalFederation,
                    allowIncoming,
                    allowOutgoing,
                    roomApprovalRequired,
                    approvalHoldTime,
                    trustedServers,
                    maintenanceModeEnabled,
                    autoHandoffEnabled,
                    handoffTargetServer
                } = req.body;

                deployConfig.updateSection('federation', {
                    enabled: enabled !== undefined ? enabled : deployConfig.get('federation', 'enabled'),
                    mode: mode || deployConfig.get('federation', 'mode'),
                    globalFederation: globalFederation !== undefined ? globalFederation : true,
                    allowIncoming: allowIncoming !== undefined ? allowIncoming : deployConfig.get('federation', 'allowIncoming'),
                    allowOutgoing: allowOutgoing !== undefined ? allowOutgoing : deployConfig.get('federation', 'allowOutgoing'),
                    roomApprovalRequired: roomApprovalRequired || false,
                    approvalHoldTime: approvalHoldTime || 3600000,
                    trustedServers: trustedServers || deployConfig.get('federation', 'trustedServers'),
                    maintenanceModeEnabled: maintenanceModeEnabled !== undefined ? maintenanceModeEnabled : deployConfig.get('federation', 'maintenanceModeEnabled'),
                    autoHandoffEnabled: autoHandoffEnabled !== undefined ? autoHandoffEnabled : deployConfig.get('federation', 'autoHandoffEnabled'),
                    handoffTargetServer: handoffTargetServer !== undefined ? handoffTargetServer : deployConfig.get('federation', 'handoffTargetServer')
                });

                await deployConfig.save();
                res.json({ success: true, message: 'Federation settings updated' });
            } catch (error) {
                res.status(500).json({ error: error.message });
            }
        });

        this.app.post('/api/federation/prepare-transfer', (req, res) => {
            try {
                const sourceServerUrl = this.normalizeFederationServerUrl(req.body?.sourceServerUrl || '');
                if (!this.isAdminRequest(req) && !this.isTrustedFederationPeer(sourceServerUrl)) {
                    return res.status(403).json({ success: false, error: 'Trusted federation peer or admin access required' });
                }

                const sourceRoom = req.body?.sourceRoom;
                const targetRoomId = String(req.body?.targetRoomId || '').trim();
                const targetRoomName = String(req.body?.targetRoomName || '').trim();
                const incomingUserCount = Number(req.body?.incomingUserCount || 0);

                if (!sourceRoom || typeof sourceRoom !== 'object') {
                    return res.status(400).json({ success: false, error: 'sourceRoom is required' });
                }
                if (!targetRoomId) {
                    return res.status(400).json({ success: false, error: 'targetRoomId is required' });
                }

                const prepared = this.ensureTransferTargetRoom({
                    sourceRoom,
                    targetRoomId,
                    targetRoomName,
                    incomingUserCount,
                    hostedBy: sourceServerUrl || null,
                    targetServerUrl: this.getLocalServerOrigins()[0] || ''
                });

                void this.notifyAdminRoomTransfer({
                    sourceRoom,
                    targetRoom: prepared.room,
                    targetServerUrl: this.getLocalServerOrigins()[0] || '',
                    incomingUserCount,
                    expanded: prepared.expanded,
                    previousMaxUsers: prepared.previousMaxUsers,
                    requiredCapacity: prepared.requiredCapacity
                });

                res.json({
                    success: true,
                    targetRoom: {
                        id: prepared.room.id,
                        name: prepared.room.name,
                        maxUsers: prepared.room.maxUsers,
                        visibility: prepared.room.visibility,
                        accessType: prepared.room.accessType
                    },
                    created: prepared.created,
                    expanded: prepared.expanded,
                    previousMaxUsers: prepared.previousMaxUsers,
                    requiredCapacity: prepared.requiredCapacity
                });
            } catch (error) {
                res.status(500).json({ success: false, error: error.message });
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
        // UPDATER MODULE API
        // ============================================

        const requireUpdaterModule = (req, res, next) => {
            if (!this.modules.updater) {
                return res.status(503).json({ success: false, error: 'Updater module not available' });
            }
            if (!this.isAdminRequest(req)) {
                return res.status(403).json({ success: false, error: 'Admin access required' });
            }
            next();
        };

        this.app.get('/api/modules/updater/status', requireUpdaterModule, (req, res) => {
            res.json({ success: true, ...this.modules.updater.getStatus() });
        });

        this.app.get('/api/modules/updater/preferences', requireUpdaterModule, (req, res) => {
            res.json({ success: true, ...this.modules.updater.getPreferences() });
        });

        this.app.put('/api/modules/updater/preferences', requireUpdaterModule, (req, res) => {
            const result = this.modules.updater.setPreferences(req.body || {});
            res.json(result);
        });

        this.app.post('/api/modules/updater/check', requireUpdaterModule, async (req, res) => {
            try {
                const result = await this.modules.updater.checkForUpdates();
                res.json({ success: true, updates: result });
            } catch (error) {
                res.status(500).json({ success: false, error: error.message });
            }
        });

        this.app.post('/api/modules/updater/category/:categoryId', requireUpdaterModule, (req, res) => {
            const enabled = req.body?.enabled !== false;
            const result = this.modules.updater.setCategoryEnabled(req.params.categoryId, enabled);
            if (!result.success) {
                return res.status(400).json(result);
            }
            res.json(result);
        });

        this.app.post('/api/modules/updater/apply/:updateId', requireUpdaterModule, async (req, res) => {
            try {
                const result = await this.modules.updater.applyUpdate(req.params.updateId);
                res.json(result);
            } catch (error) {
                res.status(500).json({ success: false, error: error.message });
            }
        });

        this.app.get('/api/modules/updater/alerts', requireUpdaterModule, (req, res) => {
            const limit = Number(req.query.limit || 50);
            res.json({ success: true, alerts: this.modules.updater.getAdminAlerts(limit) });
        });

        this.app.delete('/api/modules/updater/alerts', requireUpdaterModule, (req, res) => {
            const result = this.modules.updater.clearAdminAlerts();
            res.json(result);
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

        // System action push notifications (desktop/iOS clients)
        this.app.post('/api/notifications/system-action', (req, res) => {
            if (!this.isAdminRequest(req)) {
                return res.status(403).json({ error: 'Admin access required' });
            }

            const body = req.body || {};
            const message = String(body.message || '').trim();
            if (!message) {
                return res.status(400).json({ error: 'message is required' });
            }

            this.emitSystemActionNotification({
                type: body.type || 'system_action',
                title: body.title || 'VoiceLink System',
                message,
                severity: body.severity || 'info',
                targetUserId: body.targetUserId || null,
                roomId: body.roomId || null,
                metadata: body.metadata && typeof body.metadata === 'object' ? body.metadata : {}
            });

            return res.json({ success: true });
        });

        this.app.post('/api/client/assets/synced', (req, res) => {
            const body = req.body || {};
            const assetName = String(body.assetName || '').trim();
            const assetType = String(body.assetType || 'asset').trim() || 'asset';
            const assetPath = String(body.assetPath || assetName || '').trim();
            if (!assetName || !assetPath) {
                return res.status(400).json({ error: 'assetName and assetPath are required' });
            }

            const username = String(body.username || 'User').trim() || 'User';
            const clientPlatform = String(body.clientPlatform || 'desktop-client').trim() || 'desktop-client';
            const roomName = String(body.roomName || '').trim();
            const serverName = String(body.serverName || deployConfig.get('server.name') || 'VoiceLink Server').trim() || 'VoiceLink Server';
            const dedupeKey = [
                assetType.toLowerCase(),
                assetPath.toLowerCase(),
                assetName.toLowerCase(),
                username.toLowerCase(),
                clientPlatform.toLowerCase()
            ].join('::');
            const now = Date.now();
            const lastSeenAt = this.clientAssetSyncNotifications.get(dedupeKey) || 0;
            if (now - lastSeenAt < 10 * 60 * 1000) {
                return res.json({ success: true, deduped: true });
            }
            this.clientAssetSyncNotifications.set(dedupeKey, now);

            const roomSuffix = roomName ? ` for ${roomName}` : '';
            const message = `${username}'s ${clientPlatform} synced missing ${assetType.replace(/_/g, ' ')} asset ${assetName}${roomSuffix} on ${serverName}.`;
            this.emitAdminScopedNotification({
                type: 'client_asset_sync',
                title: 'Client asset sync completed',
                message,
                severity: 'info',
                metadata: {
                    assetType,
                    assetName,
                    assetPath,
                    username,
                    clientPlatform,
                    roomId: body.roomId || null,
                    roomName: roomName || null,
                    serverName
                }
            });

            return res.json({ success: true });
        });

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
                    this.emitSystemActionNotification({
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
                    this.emitSystemActionNotification({
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
                this.emitSystemActionNotification({
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
                    this.emitSystemActionNotification({
                        type: 'docs-generation-complete',
                        message: 'Documentation generation completed successfully',
                        timestamp: this.docsConfig.lastGenerated
                    });
                }

            } catch (error) {
                console.error('[Docs] Generation failed:', error.message);

                if (this.io) {
                    this.emitSystemActionNotification({
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

        // Serve documentation files from the full docs tree so public policy/help pages resolve directly.
        this.app.use('/docs', express.static(path.join(__dirname, '../../docs')));
        this.app.use('/admin/docs', express.static(path.join(__dirname, '../../docs/authenticated')));

        // Serve release packages for installer downloads
        this.app.use('/releases', express.static(path.join(__dirname, '../../releases')));
        this.app.use('/exports', express.static(path.join(__dirname, '../../data/exports')));

        const handleClientUploadShareLink = (req, res) => {
            const requestPath = String(req.body?.path || req.body?.filePath || '').trim();
            const keepForever = this.parseBool(req.body?.keepForever, false);
            const expiresAt = req.body?.expiresAt ? new Date(req.body.expiresAt).toISOString() : null;
            if (!requestPath) {
                return res.status(400).json({ success: false, error: 'path is required' });
            }
            const link = this.createClientUploadShareLink(req, requestPath, keepForever, expiresAt);
            if (!link) {
                return res.status(404).json({ success: false, error: 'File not found for share link' });
            }
            return res.json(link);
        };

        this.app.put(/^\/uploads\/.+/, express.raw({ type: '*/*', limit: '250mb' }), (req, res) => {
            try {
                const requestPath = decodeURIComponent(req.path || '');
                const resolved = this.resolveClientUploadPath(requestPath);
                if (!resolved) {
                    return res.status(400).json({ error: 'Invalid upload path' });
                }
                if (!Buffer.isBuffer(req.body) || req.body.length === 0) {
                    return res.status(400).json({ error: 'Upload body is empty' });
                }
                fs.mkdirSync(path.dirname(resolved.absolutePath), { recursive: true });
                fs.writeFileSync(resolved.absolutePath, req.body);
                const stats = fs.statSync(resolved.absolutePath);
                return res.status(201).json({
                    success: true,
                    path: resolved.publicPath,
                    size: stats.size,
                    url: `${this.getRequestPublicBaseUrl(req)}${resolved.publicPath}`
                });
            } catch (error) {
                console.error('[Uploads] Failed to store client upload:', error.message);
                return res.status(500).json({ error: 'Failed to store uploaded file' });
            }
        });

        this.app.post('/api/files/upload', express.raw({ type: '*/*', limit: '250mb' }), (req, res) => {
            try {
                const requestPath = String(req.query?.path || req.headers['x-upload-path'] || req.body?.path || '').trim();
                const resolved = this.resolveClientUploadPath(requestPath);
                if (!resolved) {
                    return res.status(400).json({ error: 'Invalid upload path' });
                }
                if (!Buffer.isBuffer(req.body) || req.body.length === 0) {
                    return res.status(400).json({ error: 'Upload body is empty' });
                }
                fs.mkdirSync(path.dirname(resolved.absolutePath), { recursive: true });
                fs.writeFileSync(resolved.absolutePath, req.body);
                const stats = fs.statSync(resolved.absolutePath);
                return res.status(201).json({
                    success: true,
                    path: resolved.publicPath,
                    size: stats.size,
                    url: `${this.getRequestPublicBaseUrl(req)}/api/files/content?path=${encodeURIComponent(resolved.publicPath)}`
                });
            } catch (error) {
                console.error('[Uploads] Failed to store API upload:', error.message);
                return res.status(500).json({ error: 'Failed to store uploaded file' });
            }
        });

        this.app.get('/api/files/content', (req, res) => {
            try {
                const requestPath = String(req.query?.path || '').trim();
                const resolved = this.resolveClientUploadPath(requestPath);
                if (!resolved || !fs.existsSync(resolved.absolutePath)) {
                    return res.status(404).json({ error: 'File not found' });
                }
                return res.sendFile(resolved.absolutePath);
            } catch (error) {
                console.error('[Uploads] Failed to serve uploaded file:', error.message);
                return res.status(500).json({ error: 'Failed to serve uploaded file' });
            }
        });

        this.app.post([
            '/api/files/share-link',
            '/api/copyparty/share-link',
            '/api/share-link',
            '/api/share/create'
        ], handleClientUploadShareLink);

        // Generate a share link using OpenLink/CopyParty with automatic provider fallback.
        this.app.post('/api/links/generate', async (req, res) => {
            try {
                const prefer = String(req.body?.prefer || 'auto').trim().toLowerCase();
                const timeoutMs = Math.max(1000, Math.min(Number(req.body?.timeoutMs) || 6000, 15000));
                const tokenSeed = String(req.body?.token || req.body?.slug || req.body?.roomId || req.body?.fileName || '').trim();
                const directCopyPartyUrl = String(req.body?.copyPartyUrl || '').trim();
                const fileName = String(req.body?.fileName || '').trim();
                const skipProbe = this.parseBool(req.body?.skipProbe, false);

                const providers = [];
                const preferOpenLink = prefer === 'auto' || prefer === 'openlink';
                const preferCopyParty = prefer === 'auto' || prefer === 'copyparty';

                if (preferOpenLink) {
                    const openLink = await this.buildOpenLinkShareLink({
                        token: tokenSeed || this.createShareToken('openlink'),
                        timeoutMs
                    });
                    providers.push(openLink);
                    if (openLink.ok) {
                        return res.json({
                            success: true,
                            provider: 'openlink',
                            url: openLink.url,
                            token: openLink.token,
                            providers
                        });
                    }
                }

                if (preferCopyParty) {
                    const copyParty = this.buildCopyPartyLink({
                        fileName,
                        directUrl: directCopyPartyUrl
                    });
                    if (!copyParty.configured || !copyParty.url) {
                        providers.push({ ok: false, provider: 'copyparty', reason: 'CopyParty link input/config missing' });
                    } else if (skipProbe) {
                        providers.push({ ok: true, provider: 'copyparty', url: copyParty.url, skippedProbe: true });
                        return res.json({
                            success: true,
                            provider: 'copyparty',
                            url: copyParty.url,
                            providers
                        });
                    } else {
                        const check = await this.probeUrl(copyParty.url, timeoutMs);
                        if (check.ok) {
                            providers.push({ ok: true, provider: 'copyparty', url: copyParty.url, status: check.status });
                            return res.json({
                                success: true,
                                provider: 'copyparty',
                                url: copyParty.url,
                                providers
                            });
                        }
                        providers.push({
                            ok: false,
                            provider: 'copyparty',
                            url: copyParty.url,
                            reason: `CopyParty probe failed (${check.status || check.error || 'unknown'})`
                        });
                    }
                }

                return res.status(502).json({
                    success: false,
                    error: 'No share provider produced a working link',
                    providers
                });
            } catch (error) {
                console.error('[links] Failed to generate share link:', error.message);
                return res.status(500).json({ success: false, error: error.message });
            }
        });

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
                        roomTransfer = await this.startMigrationRoomTransfer({
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
        this.app.post('/api/admin/migration/room-transfer', async (req, res) => {
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

                const session = await this.startMigrationRoomTransfer({
                    sourceRoomId,
                    targetRoomId,
                    targetServerUrl,
                    targetRoomName: String(req.body?.targetRoomName || '').trim()
                });
                res.json({ success: true, session });
            } catch (error) {
                res.status(500).json({ success: false, error: error.message });
            }
        });

        // ============================================
        // MODULE INSTALLER API
        // ============================================

        this.app.get('/api/admin/module-governance', (req, res) => {
            if (!this.isAdminRequest(req)) {
                return res.status(403).json({ success: false, error: 'Admin access required' });
            }
            const policies = getServerPolicyConfig();
            const modules = this.moduleRegistry.getAvailableModules({ sortBy: 'recommended' });
            res.json({
                success: true,
                governance: policies.moduleGovernance,
                modules
            });
        });

        this.app.put('/api/admin/module-governance', async (req, res) => {
            if (!this.isAdminRequest(req)) {
                return res.status(403).json({ success: false, error: 'Admin access required' });
            }
            try {
                const body = req.body || {};
                const current = getServerPolicyConfig();
                const required = Array.isArray(body.required) ? body.required.filter(Boolean) : current.moduleGovernance.required;
                const optional = Array.isArray(body.optional) ? body.optional.filter(Boolean) : current.moduleGovernance.optional;
                const revoked = Array.isArray(body.revoked) ? body.revoked.filter(Boolean) : current.moduleGovernance.revoked;
                const allowedByServer = body.allowedByServer && typeof body.allowedByServer === 'object'
                    ? body.allowedByServer
                    : current.moduleGovernance.allowedByServer;

                deployConfig.updateSection('serverPolicies', {
                    ...current,
                    moduleGovernance: {
                        ...current.moduleGovernance,
                        required,
                        optional,
                        revoked,
                        allowedByServer,
                        ownerAutoUpdateModules: body.ownerAutoUpdateModules !== undefined
                            ? !!body.ownerAutoUpdateModules
                            : current.moduleGovernance.ownerAutoUpdateModules,
                        ownerUpdateChannel: typeof body.ownerUpdateChannel === 'string'
                            ? body.ownerUpdateChannel
                            : current.moduleGovernance.ownerUpdateChannel
                    }
                });
                await deployConfig.save();
                res.json({ success: true, governance: getServerPolicyConfig().moduleGovernance });
            } catch (error) {
                res.status(500).json({ success: false, error: error.message });
            }
        });

        this.app.post('/api/admin/module-governance/apply', async (req, res) => {
            if (!this.isAdminRequest(req)) {
                return res.status(403).json({ success: false, error: 'Admin access required' });
            }
            try {
                const policy = getServerPolicyConfig().moduleGovernance;
                const required = new Set(Array.isArray(policy.required) ? policy.required : []);
                const revoked = new Set(Array.isArray(policy.revoked) ? policy.revoked : []);
                const actions = [];

                for (const moduleId of required) {
                    if (revoked.has(moduleId)) continue;
                    const module = this.moduleRegistry.getModule(moduleId);
                    if (!module?.installed) {
                        actions.push({ moduleId, action: 'install', result: this.moduleRegistry.installModule(moduleId, { enabled: true }) });
                    }
                    actions.push({ moduleId, action: 'enable', result: this.moduleRegistry.setModuleEnabled(moduleId, true) });
                }

                for (const moduleId of revoked) {
                    const module = this.moduleRegistry.getModule(moduleId);
                    if (module?.installed) {
                        actions.push({ moduleId, action: 'disable', result: this.moduleRegistry.setModuleEnabled(moduleId, false) });
                    }
                }

                this.initializeModules();
                res.json({ success: true, actions });
            } catch (error) {
                res.status(500).json({ success: false, error: error.message });
            }
        });

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

        // Export module bundle for peer sync (required modules are public; others require admin auth)
        this.app.get('/api/modules/:moduleId/bundle', (req, res) => {
            const module = this.moduleRegistry.getModule(req.params.moduleId);
            if (!module) {
                return res.status(404).json({ success: false, error: 'Module not found' });
            }
            if (!module.required && !this.isAdminRequest(req)) {
                return res.status(403).json({ success: false, error: 'Admin access required for optional module bundles' });
            }

            const bundleResult = this.moduleRegistry.buildModuleBundle(req.params.moduleId);
            if (!bundleResult.success) {
                return res.status(404).json({ success: false, error: bundleResult.error });
            }
            return res.json({
                success: true,
                bundle: bundleResult.bundle
            });
        });

        // Trigger module sync from primary/trusted servers.
        this.app.post('/api/modules/:moduleId/sync', async (req, res) => {
            if (!this.isAdminRequest(req)) {
                return res.status(403).json({ success: false, error: 'Admin access required' });
            }
            const sources = Array.isArray(req.body?.sources) && req.body.sources.length
                ? req.body.sources
                : this.resolveModuleSyncSources();
            const timeoutMs = Number(req.body?.timeoutMs || 12000);
            const result = await this.moduleRegistry.syncModuleFromNetwork(req.params.moduleId, {
                sources,
                adminKey: process.env.VOICELINK_ADMIN_KEY || '',
                timeoutMs
            });
            if (!result.success) {
                return res.status(502).json(result);
            }

            if (req.params.moduleId === 'internal-scheduler') {
                await this.ensureInternalSchedulerModule();
                this.initializeInternalSchedulerInstance();
            } else {
                this.initializeModules();
            }
            return res.json(result);
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
            const policy = getServerPolicyConfig().moduleGovernance;
            if (Array.isArray(policy.revoked) && policy.revoked.includes(req.params.moduleId)) {
                return res.status(403).json({ success: false, error: 'Module is revoked by admin policy' });
            }
            const result = this.moduleRegistry.installModule(req.params.moduleId, req.body.config);
            if (result.success) {
                // Reinitialize modules after install
                this.initializeModules();
            }
            res.json(result);
        });

        // Uninstall module
        this.app.post('/api/modules/:moduleId/uninstall', (req, res) => {
            const policy = getServerPolicyConfig().moduleGovernance;
            if (Array.isArray(policy.required) && policy.required.includes(req.params.moduleId)) {
                return res.status(403).json({ success: false, error: 'Required modules cannot be removed by policy' });
            }
            const result = this.moduleRegistry.uninstallModule(req.params.moduleId);
            if (result.success) {
                // Clear module instance
                if (req.params.moduleId === 'two-factor-auth') {
                    this.modules.twoFactorAuth = null;
                } else if (req.params.moduleId === 'support-system') {
                    this.modules.supportSystem = null;
                } else if (req.params.moduleId === 'deployment-manager') {
                    this.modules.deploymentManager = null;
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
            const policy = getServerPolicyConfig().moduleGovernance;
            const enabled = req.body.enabled !== undefined ? req.body.enabled : !module.config.enabled;
            if (enabled && Array.isArray(policy.revoked) && policy.revoked.includes(req.params.moduleId)) {
                return res.status(403).json({ success: false, error: 'Module is revoked by admin policy' });
            }
            if (!enabled && Array.isArray(policy.required) && policy.required.includes(req.params.moduleId)) {
                return res.status(403).json({ success: false, error: 'Required modules cannot be disabled by policy' });
            }
            const result = this.moduleRegistry.setModuleEnabled(req.params.moduleId, enabled);
            if (result.success) {
                this.initializeModules();
            }
            res.json(result);
        });

        // ============================================
        // DEPLOYMENT MANAGER MODULE API
        // ============================================

        const requireDeploymentManager = (req, res, next) => {
            if (!this.modules.deploymentManager) {
                return res.status(503).json({ error: 'Deployment Manager module not installed or enabled' });
            }
            if (!this.isAdminRequest(req)) {
                return res.status(403).json({ error: 'Admin access required' });
            }
            next();
        };

        this.app.get('/api/modules/deployment-manager/status', requireDeploymentManager, (req, res) => {
            res.json(this.modules.deploymentManager.getStatus());
        });

        this.app.get('/api/modules/deployment-manager/transports', requireDeploymentManager, (req, res) => {
            res.json({ transports: this.modules.deploymentManager.getSupportedTransports() });
        });

        this.app.get('/api/modules/deployment-manager/history', requireDeploymentManager, (req, res) => {
            const limit = Math.min(200, Math.max(1, Number(req.query.limit || 50)));
            res.json({ actions: this.modules.deploymentManager.getActionHistory(limit) });
        });

        this.app.get('/api/modules/deployment-manager/watchdog', requireDeploymentManager, (req, res) => {
            res.json(this.modules.deploymentManager.getWatchdogStatus());
        });

        this.app.post('/api/modules/deployment-manager/watchdog/run', requireDeploymentManager, async (req, res) => {
            try {
                const result = await this.modules.deploymentManager.runWatchdogChecks(req.body || {});
                res.json(result);
            } catch (error) {
                res.status(500).json({ success: false, error: error.message });
            }
        });

        this.app.post('/api/modules/deployment-manager/package', requireDeploymentManager, async (req, res) => {
            try {
                const {
                    preset,
                    sanitize = true,
                    ownerEmail,
                    targetLabel,
                    targetServerUrl,
                    linkedToMain = true,
                    trustedServers = [],
                    extraConfig = {}
                } = req.body || {};

                const bundle = await this.modules.deploymentManager.buildDeploymentBundle({
                    preset,
                    sanitize,
                    ownerEmail,
                    targetLabel,
                    targetServerUrl,
                    linkedToMain,
                    trustedServers,
                    extraConfig
                });

                this.modules.deploymentManager.recordDeploymentAction({
                    type: 'package',
                    actor: resolveDeploymentActor(req),
                    target: {
                        label: targetLabel || null,
                        serverUrl: targetServerUrl || null
                    },
                    bundle: {
                        id: bundle.bundleId,
                        name: bundle.zipName
                    }
                });

                res.json({
                    success: true,
                    bundleId: bundle.bundleId,
                    bundleName: bundle.zipName,
                    zipPath: bundle.zipPath,
                    manifest: bundle.manifest
                });
            } catch (error) {
                res.status(500).json({ success: false, error: error.message });
            }
        });

        this.app.post('/api/modules/deployment-manager/deploy', requireDeploymentManager, async (req, res) => {
            try {
                const {
                    packageOptions = {},
                    target = {},
                    bootstrap = false
                } = req.body || {};
                const policy = getServerPolicyConfig();
                const automation = policy.deploymentAutomation || {};
                const wantsBootstrap = bootstrap === true;

                if (wantsBootstrap && (!automation.enabled || !automation.allowAutoSetup)) {
                    return res.status(403).json({
                        success: false,
                        error: 'Auto-setup is disabled by server policy. Enable Deployment Automation to allow remote bootstrap.'
                    });
                }

                const validation = this.modules.deploymentManager.validateDeploymentTarget(target, {
                    requireRemoteCredentials: automation.requireRemoteCredentials !== false,
                    requireBootstrapCredentials: wantsBootstrap
                });
                if (!validation.ok) {
                    return res.status(400).json({ success: false, error: validation.error });
                }

                const bundle = await this.modules.deploymentManager.buildDeploymentBundle(packageOptions);
                const uploadResult = await this.modules.deploymentManager.uploadBundle(bundle.zipPath, target);
                let bootstrapResult = null;
                let restartResult = null;

                if (wantsBootstrap) {
                    bootstrapResult = await this.modules.deploymentManager.bootstrapRemoteInstall(target, bundle.deployConfig);
                    if (target.restartAfterBootstrap === true) {
                        restartResult = await this.modules.deploymentManager.triggerRemoteRestart(target);
                    }
                }

                this.modules.deploymentManager.recordDeploymentAction({
                    type: 'deploy',
                    actor: resolveDeploymentActor(req),
                    target: {
                        transport: target.transport || null,
                        host: target.host || null,
                        uploadUrl: target.uploadUrl || null,
                        apiBaseUrl: target.apiBaseUrl || null
                    },
                    bundle: {
                        id: bundle.bundleId,
                        name: bundle.zipName
                    },
                    bootstrap: !!wantsBootstrap,
                    bootstrapSuccess: wantsBootstrap ? !!bootstrapResult?.success : null
                });

                res.json({
                    success: true,
                    bundleId: bundle.bundleId,
                    bundleName: bundle.zipName,
                    upload: uploadResult,
                    bootstrap: bootstrapResult,
                    restart: restartResult
                });
            } catch (error) {
                res.status(500).json({ success: false, error: error.message });
            }
        });

        this.app.post('/api/modules/deployment-manager/email-owner', requireDeploymentManager, async (req, res) => {
            try {
                const {
                    recipient,
                    subject,
                    bundleName,
                    remoteUrl,
                    apiBaseUrl
                } = req.body || {};

                const result = await this.modules.deploymentManager.emailDeploymentDetails({
                    recipient,
                    subject,
                    bundleName,
                    remoteUrl,
                    apiBaseUrl
                });

                this.modules.deploymentManager.recordDeploymentAction({
                    type: 'email-owner',
                    actor: resolveDeploymentActor(req),
                    target: {
                        recipient: recipient || null,
                        remoteUrl: remoteUrl || null,
                        apiBaseUrl: apiBaseUrl || null
                    },
                    subject: subject || null,
                    bundleName: bundleName || null
                });
                res.json(result);
            } catch (error) {
                res.status(500).json({ success: false, error: error.message });
            }
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
        const supportStaffRoles = new Set(['owner', 'admin', 'staff', 'support', 'moderator']);
        const getSupportActor = (req) => {
            const authUser = this.getAnyAuthUserFromRequest ? this.getAnyAuthUserFromRequest(req) : null;
            if (authUser) {
                const role = normalizeUserRole(authUser.role);
                return {
                    id: String(authUser.id || '').trim(),
                    name: authUser.displayName || authUser.username || authUser.email || 'User',
                    email: authUser.email || '',
                    role,
                    isAuthenticated: true,
                    isStaff: supportStaffRoles.has(role),
                    isAdmin: ['owner', 'admin'].includes(role),
                    source: authUser.authProvider || 'local'
                };
            }

            const token = this.extractTokenFromRequest(req);
            if (token) {
                const principalResult = this.resolvePrincipalFromToken(token, req);
                if (principalResult?.valid && principalResult.principal) {
                    const principal = principalResult.principal;
                    const roleContext = principal.roleContext || {};
                    const role = normalizeUserRole(roleContext.primaryRole || (principal.isAdmin ? 'admin' : 'user'));
                    return {
                        id: String(principal.userId || '').trim(),
                        name: principal.userName || principal.name || 'API User',
                        email: principal.metadata?.email || '',
                        role,
                        isAuthenticated: true,
                        isStaff: Boolean(principal.isAdmin || roleContext.isModerator || supportStaffRoles.has(role)),
                        isAdmin: Boolean(principal.isAdmin || ['owner', 'admin'].includes(role)),
                        source: principal.tokenType || 'token',
                        principal
                    };
                }
            }

            return null;
        };
        const requireSupportActor = (req, res, next) => {
            const actor = getSupportActor(req);
            if (!actor) {
                return res.status(401).json({ error: 'Authentication required for support access' });
            }
            req.supportActor = actor;
            next();
        };
        const requireSupportStaff = (req, res, next) => {
            const actor = getSupportActor(req);
            if (!actor || !actor.isStaff) {
                return res.status(403).json({ error: 'Support staff access required' });
            }
            req.supportActor = actor;
            next();
        };
        const supportActorOwnsTicket = (actor, ticket) => {
            if (!actor || !ticket) return false;
            const actorId = String(actor.id || '').trim().toLowerCase();
            const ticketUserId = String(ticket.userId || '').trim().toLowerCase();
            const actorEmail = String(actor.email || '').trim().toLowerCase();
            const ticketEmail = String(ticket.userEmail || '').trim().toLowerCase();
            return Boolean(
                (actorId && ticketUserId && actorId === ticketUserId) ||
                (actorEmail && ticketEmail && actorEmail === ticketEmail)
            );
        };
        const canGuestOpenSupportRequest = (req) => {
            const name = String(req.body?.userName || '').trim();
            const email = String(req.body?.userEmail || '').trim();
            const issue = String(req.body?.issue || req.body?.description || '').trim();
            return Boolean(name && email && issue);
        };
        const createHiddenSupportRoom = ({ sessionId, userName, issue, ownerName }) => {
            const roomId = `support-${sessionId}`;
            const trimmedUser = String(userName || 'User').trim() || 'User';
            const room = {
                id: roomId,
                name: `Support: ${trimmedUser}`,
                description: issue ? `Private support chat for ${trimmedUser}: ${String(issue).slice(0, 120)}` : `Private support chat for ${trimmedUser}`,
                roomType: 'support',
                password: null,
                hasPassword: false,
                maxUsers: 8,
                users: [],
                backgroundStream: null,
                visibility: 'private',
                visibleToGuests: false,
                accessType: 'hidden',
                allowEmbed: false,
                showInApp: false,
                privacyLevel: 'private',
                encrypted: false,
                creatorHandle: ownerName || 'support-system',
                createdBy: ownerName || 'support-system',
                isDefault: false,
                template: 'support-session',
                createdAt: new Date(),
                updatedAt: new Date(),
                updatedBy: ownerName || 'support-system',
                previousNames: [],
                expiresAt: null,
                locked: false,
                lockedAt: null,
                lockedBy: null,
                autoLock: null,
                autoLockScheduled: null,
                autoplayMusic: false,
                autoplayPlaylist: null,
                jellyfinAccess: {
                    enabled: false,
                    adminCanAccessAll: true,
                    allowRoomOwnerUploads: false,
                    allowAuthenticatedUploads: false,
                    allowedServerIds: [],
                    allowedLibraryIdsByServer: {},
                    roomUserPermissions: {}
                },
                supportSession: {
                    enabled: true,
                    sessionId
                }
            };
            this.rooms.set(roomId, room);
            this.saveRoomsToDisk();
            return room;
        };
        const postSupportRoomSystemMessage = (roomId, content, metadata = {}) => {
            if (!roomId || !content) return null;
            const message = {
                id: uuidv4(),
                userId: 'system:support',
                userName: 'System',
                message: content,
                timestamp: new Date(),
                isAuthenticated: true,
                metadata: {
                    type: 'support-session',
                    ...metadata
                }
            };
            this.storeRoomMessage(roomId, message);
            this.io.to(roomId).emit('chat-message', message);
            return message;
        };
        const closeSupportRoom = (roomId, reason = 'Support session closed', redirectUrl = null) => {
            if (!roomId) return false;
            const room = this.rooms.get(roomId);
            if (!room) return false;
            this.io.to(roomId).emit('room-deleted', { reason, roomId, redirectUrl });
            this.rooms.delete(roomId);
            this.federation.broadcastRoomChange('deleted', { id: roomId });
            this.saveRoomsToDisk();
            return true;
        };
        const resolveWhmcsSupportDepartmentId = (body = {}) => {
            return body.departmentId || this.moduleRegistry?.getModule('whmcs-integration')?.config?.supportDepartmentId || '';
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
            const actor = getSupportActor(req);
            if (!actor && !canGuestOpenSupportRequest(req)) {
                return res.status(401).json({ error: 'Authentication required or provide name, email, and description' });
            }
            const payload = {
                ...req.body,
                userId: req.body?.userId || actor?.id || `guest:${uuidv4()}`,
                userName: req.body?.userName || actor?.name || 'Guest',
                userEmail: req.body?.userEmail || actor?.email || '',
                channel: req.body?.channel || (actor ? 'voicelink' : 'web'),
                metadata: {
                    ...(req.body?.metadata && typeof req.body.metadata === 'object' ? req.body.metadata : {}),
                    createdBySource: actor?.source || 'guest',
                    createdByRole: actor?.role || 'guest'
                }
            };
            const result = await this.modules.supportSystem.tickets.createTicket(payload);
            res.json(result);
        });

        // Get user's tickets
        this.app.get('/api/support/tickets/user/:userId', requireSupportModule, requireSupportActor, (req, res) => {
            if (!req.supportActor.isStaff && String(req.supportActor.id || '') !== String(req.params.userId || '')) {
                return res.status(403).json({ error: 'You can only view your own tickets' });
            }
            const tickets = this.modules.supportSystem.tickets.getUserTickets(
                req.params.userId,
                req.query
            );
            res.json(tickets);
        });

        // Get ticket by ID
        this.app.get('/api/support/tickets/:ticketId', requireSupportModule, requireSupportActor, (req, res) => {
            const ticket = this.modules.supportSystem.tickets.getTicket(req.params.ticketId);
            if (!ticket) {
                return res.status(404).json({ error: 'Ticket not found' });
            }
            if (!req.supportActor.isStaff && !supportActorOwnsTicket(req.supportActor, ticket)) {
                return res.status(403).json({ error: 'You do not have access to this ticket' });
            }
            res.json(ticket);
        });

        // Add reply to ticket
        this.app.post('/api/support/tickets/:ticketId/reply', requireSupportModule, requireSupportActor, async (req, res) => {
            const ticket = this.modules.supportSystem.tickets.getTicket(req.params.ticketId);
            if (!ticket) {
                return res.status(404).json({ error: 'Ticket not found' });
            }
            if (!req.supportActor.isStaff && !supportActorOwnsTicket(req.supportActor, ticket)) {
                return res.status(403).json({ error: 'You do not have access to this ticket' });
            }
            const result = await this.modules.supportSystem.tickets.addReply(
                req.params.ticketId,
                {
                    ...req.body,
                    userId: req.body?.userId || req.supportActor.id,
                    userName: req.body?.userName || req.supportActor.name,
                    isAgent: req.body?.isAgent === true ? req.supportActor.isStaff : req.supportActor.isStaff
                }
            );
            res.json(result);
        });

        // Update ticket status
        this.app.put('/api/support/tickets/:ticketId/status', requireSupportModule, requireSupportStaff, (req, res) => {
            const result = this.modules.supportSystem.tickets.updateStatus(
                req.params.ticketId,
                req.body.status,
                req.body.note
            );
            res.json(result);
        });

        // Rate ticket
        this.app.post('/api/support/tickets/:ticketId/rate', requireSupportModule, requireSupportActor, (req, res) => {
            const ticket = this.modules.supportSystem.tickets.getTicket(req.params.ticketId);
            if (!ticket) {
                return res.status(404).json({ error: 'Ticket not found' });
            }
            if (!req.supportActor.isStaff && !supportActorOwnsTicket(req.supportActor, ticket)) {
                return res.status(403).json({ error: 'You do not have access to this ticket' });
            }
            const result = this.modules.supportSystem.tickets.addRating(
                req.params.ticketId,
                req.body.rating,
                req.body.feedback
            );
            res.json(result);
        });

        // Admin: Get all tickets
        this.app.get('/api/support/admin/tickets', requireSupportModule, requireSupportStaff, (req, res) => {
            const result = this.modules.supportSystem.tickets.getAllTickets(req.query);
            res.json(result);
        });

        // Admin: Assign ticket
        this.app.post('/api/support/admin/tickets/:ticketId/assign', requireSupportModule, requireSupportStaff, (req, res) => {
            const result = this.modules.supportSystem.tickets.assignTicket(
                req.params.ticketId,
                req.body.agentId,
                req.body.agentName
            );
            res.json(result);
        });

        // Admin: Get statistics
        this.app.get('/api/support/admin/stats', requireSupportModule, requireSupportStaff, (req, res) => {
            res.json(this.modules.supportSystem.getStatistics());
        });

        // Admin: Manage agents
        this.app.get('/api/support/admin/agents', requireSupportModule, requireSupportStaff, (req, res) => {
            res.json(this.modules.supportSystem.tickets.getAgents());
        });

        this.app.post('/api/support/admin/agents', requireSupportModule, requireSupportStaff, (req, res) => {
            const result = this.modules.supportSystem.tickets.addAgent(req.body);
            res.json(result);
        });

        this.app.delete('/api/support/admin/agents/:agentId', requireSupportModule, requireSupportStaff, (req, res) => {
            const result = this.modules.supportSystem.tickets.removeAgent(req.params.agentId);
            res.json(result);
        });

        // Live chat endpoints
        this.app.post('/api/support/chat/join', requireSupportModule, (req, res) => {
            const actor = getSupportActor(req);
            if (!actor && !canGuestOpenSupportRequest(req)) {
                return res.status(401).json({ error: 'Authentication required or provide name, email, and issue' });
            }
            const result = this.modules.supportSystem.liveChat.joinQueue(
                req.body.userId || actor?.id || `guest:${uuidv4()}`,
                req.body.userName || actor?.name || 'Guest',
                req.body.issue,
                {
                    userEmail: req.body.userEmail || actor?.email || '',
                    ticketId: req.body.ticketId || null,
                    whmcsTicketId: req.body.whmcsTicketId || null,
                    roomId: req.body.roomId || null,
                    roomName: req.body.roomName || null,
                    channel: req.body.channel || (actor ? 'voicelink' : 'web'),
                    hiddenRoomId: req.body.hiddenRoomId || null,
                    supportPinRequired: req.body.supportPinRequired === true,
                    supportPinValidated: req.body.supportPinValidated === true,
                    metadata: {
                        ...(req.body?.metadata && typeof req.body.metadata === 'object' ? req.body.metadata : {}),
                        requesterRole: actor?.role || 'guest'
                    }
                }
            );
            res.json(result);
        });

        this.app.post('/api/support/chat/leave', requireSupportModule, requireSupportActor, (req, res) => {
            this.modules.supportSystem.liveChat.leaveQueue(req.body.queueId);
            res.json({ success: true });
        });

        this.app.get('/api/support/chat/status', requireSupportModule, (req, res) => {
            res.json(this.modules.supportSystem.liveChat.getQueueStatus());
        });

        // Support session endpoints
        this.app.get('/api/support/sessions', requireSupportModule, requireSupportStaff, (req, res) => {
            const sessions = this.modules.supportSystem.listSupportSessions(req.query || {});
            res.json({ success: true, sessions });
        });

        this.app.get('/api/support/sessions/:sessionId', requireSupportModule, requireSupportActor, (req, res) => {
            const session = this.modules.supportSystem.getSupportSession(req.params.sessionId);
            if (!session) {
                return res.status(404).json({ error: 'Support session not found' });
            }
            const ownsSession = String(session.userId || '') === String(req.supportActor.id || '')
                || (req.supportActor.email && session.userEmail && String(req.supportActor.email).toLowerCase() === String(session.userEmail).toLowerCase());
            if (!req.supportActor.isStaff && !ownsSession) {
                return res.status(403).json({ error: 'You do not have access to this support session' });
            }
            res.json({ success: true, session });
        });

        this.app.post('/api/support/sessions', requireSupportModule, async (req, res) => {
            const actor = getSupportActor(req);
            if (!actor && !canGuestOpenSupportRequest(req)) {
                return res.status(401).json({ error: 'Authentication required or provide name, email, and issue' });
            }

            const supportPinRequired = req.body?.supportPinRequired === true;
            const room = createHiddenSupportRoom({
                sessionId: uuidv4(),
                userName: req.body?.userName || actor?.name || 'Guest',
                issue: req.body?.issue || req.body?.description || '',
                ownerName: actor?.name || 'support-system'
            });

            const existingInternalTicket = this.modules.supportSystem.tickets.findReusableTicket({
                userId: req.body?.userId || actor?.id || `guest:${uuidv4()}`,
                userEmail: req.body?.userEmail || actor?.email || '',
                subject: req.body?.subject || `Live support request: ${req.body?.issue || 'Support'}`,
                description: req.body?.description || req.body?.issue || 'Live support requested'
            });
            const builtInTicket = existingInternalTicket
                ? this.modules.supportSystem.tickets.getTicket(existingInternalTicket.id)
                : null;

            let whmcsTicketId = null;
            let whmcsTicketNumber = null;
            let thankYouUrl = '/docs/support-thank-you.html';
            if (this.modules.whmcsIntegration?.getStatistics().configured) {
                thankYouUrl = this.modules.whmcsIntegration.getSupportThankYouUrl?.() || thankYouUrl;
            }

            const created = this.modules.supportSystem.createSupportSession({
                userId: req.body?.userId || actor?.id || `guest:${uuidv4()}`,
                userName: req.body?.userName || actor?.name || 'Guest',
                userEmail: req.body?.userEmail || actor?.email || '',
                issue: req.body?.issue || req.body?.description || '',
                roomId: req.body?.roomId || null,
                roomName: req.body?.roomName || null,
                hiddenRoomId: room.id,
                hiddenRoomName: room.name,
                ticketId: builtInTicket?.ticketId || null,
                whmcsTicketId,
                whmcsTicketNumber,
                channel: req.body?.channel || (actor ? 'voicelink' : 'web'),
                supportPinRequired,
                pinDelivery: req.body?.pinDelivery || 'none',
                metadata: {
                    requestedByRole: actor?.role || 'guest',
                    requestedBySource: actor?.source || 'guest',
                    existingTicketAttached: Boolean(builtInTicket),
                    thankYouUrl
                }
            });

            room.supportSession = {
                enabled: true,
                sessionId: created.session.id,
                ticketId: builtInTicket?.ticketId || null,
                whmcsTicketId,
                whmcsTicketNumber
            };
            this.rooms.set(room.id, room);
            this.saveRoomsToDisk();

            postSupportRoomSystemMessage(
                room.id,
                `Private support session created for ${created.session.userName}.`,
                { sessionId: created.session.id, ticketId: builtInTicket?.ticketId || null, whmcsTicketId }
            );

            res.json({
                success: true,
                session: created.session,
                hiddenRoom: {
                    id: room.id,
                    name: room.name
                },
                supportPin: created.supportPin,
                ticketId: builtInTicket?.ticketId || null,
                whmcsTicketId,
                whmcsTicketNumber,
                thankYouUrl
            });
        });

        this.app.post('/api/support/sessions/:sessionId/pickup', requireSupportModule, requireSupportStaff, async (req, res) => {
            const result = this.modules.supportSystem.assignSupportSession(req.params.sessionId, {
                id: req.supportActor.id,
                name: req.supportActor.name
            });
            if (!result.success) {
                return res.status(404).json(result);
            }
            if (result.session.hiddenRoomId) {
                postSupportRoomSystemMessage(
                    result.session.hiddenRoomId,
                    `${req.supportActor.name} joined this support session.`,
                    { sessionId: result.session.id, event: 'pickup' }
                );
            }
            res.json(result);
        });

        this.app.post('/api/support/sessions/:sessionId/pin/verify', requireSupportModule, requireSupportActor, (req, res) => {
            const result = this.modules.supportSystem.validateSupportPin(req.params.sessionId, req.body?.pin || '');
            if (!result.success) {
                return res.status(400).json(result);
            }
            res.json(result);
        });

        this.app.post('/api/support/sessions/:sessionId/message', requireSupportModule, requireSupportActor, async (req, res) => {
            const session = this.modules.supportSystem.getSupportSession(req.params.sessionId);
            if (!session) {
                return res.status(404).json({ error: 'Support session not found' });
            }
            const ownsSession = String(session.userId || '') === String(req.supportActor.id || '')
                || (req.supportActor.email && session.userEmail && String(req.supportActor.email).toLowerCase() === String(session.userEmail).toLowerCase());
            if (!req.supportActor.isStaff && !ownsSession) {
                return res.status(403).json({ error: 'You do not have access to this support session' });
            }
            if (session.supportPinRequired && !session.supportPinValidated && !req.supportActor.isStaff) {
                return res.status(403).json({ error: 'Support PIN verification required before continuing' });
            }

            const content = String(req.body?.content || '').trim();
            if (!content) {
                return res.status(400).json({ error: 'Message content is required' });
            }

            const appended = this.modules.supportSystem.appendSupportSessionMessage(req.params.sessionId, {
                from: req.supportActor.isStaff ? 'agent' : 'user',
                userId: req.supportActor.id,
                userName: req.supportActor.name,
                content,
                metadata: req.body?.metadata || {}
            });
            if (!appended.success) {
                return res.status(400).json(appended);
            }

            if (session.hiddenRoomId) {
                const message = {
                    id: uuidv4(),
                    userId: req.supportActor.id || `support:${req.params.sessionId}`,
                    userName: req.supportActor.isStaff ? `Support: ${req.supportActor.name}` : req.supportActor.name,
                    message: content,
                    timestamp: new Date(),
                    isAuthenticated: true,
                    metadata: {
                        type: 'support-session-message',
                        sessionId: req.params.sessionId
                    }
                };
                this.storeRoomMessage(session.hiddenRoomId, message);
                this.io.to(session.hiddenRoomId).emit('chat-message', message);
            }

            if (session.whmcsTicketId && this.modules.whmcsIntegration?.getStatistics().configured) {
                try {
                    if (req.supportActor.isStaff) {
                        await this.modules.whmcsIntegration.addTicketNote(
                            session.whmcsTicketId,
                            `[VoiceLink Live Chat] ${req.supportActor.name}: ${content}`
                        );
                    }
                } catch (error) {
                    console.warn('[Support] Failed to append support ticket note from support session:', error.message);
                }
            }

            res.json(appended);
        });

        this.app.put('/api/support/sessions/:sessionId/status', requireSupportModule, requireSupportStaff, async (req, res) => {
            const session = this.modules.supportSystem.getSupportSession(req.params.sessionId);
            if (!session) {
                return res.status(404).json({ error: 'Support session not found' });
            }
            const nextStatus = String(req.body?.status || 'active').trim().toLowerCase();
            const updated = this.modules.supportSystem.updateSupportSession(req.params.sessionId, {
                status: nextStatus,
                metadata: {
                    updatedBy: req.supportActor.name
                }
            });
            if (!updated.success) {
                return res.status(400).json(updated);
            }

            if (session.ticketId) {
                this.modules.supportSystem.tickets.updateStatus(session.ticketId, nextStatus === 'closed' ? 'closed' : 'in_progress', req.body?.note || null);
            }
            if (session.whmcsTicketId && this.modules.whmcsIntegration?.getStatistics().configured && req.body?.whmcsStatus) {
                try {
                    await this.modules.whmcsIntegration.updateTicketStatus(session.whmcsTicketId, req.body.whmcsStatus);
                } catch (error) {
                    console.warn('[Support] Failed to update support ticket status from support session:', error.message);
                }
            }
            if (session.hiddenRoomId && req.body?.note) {
                postSupportRoomSystemMessage(session.hiddenRoomId, req.body.note, { sessionId: session.id, event: 'status-update' });
            }
            if (nextStatus === 'closed' && session.hiddenRoomId) {
                closeSupportRoom(session.hiddenRoomId, 'Support session closed', session.metadata?.thankYouUrl || '/docs/support-thank-you.html');
            }
            res.json(updated);
        });

        this.app.post('/api/support/sessions/:sessionId/attach-whmcs-ticket', requireSupportModule, requireSupportStaff, async (req, res) => {
            const session = this.modules.supportSystem.getSupportSession(req.params.sessionId);
            if (!session) {
                return res.status(404).json({ error: 'Support session not found' });
            }
            if (!this.modules.whmcsIntegration?.getStatistics().configured) {
                return res.status(503).json({ error: 'Support ticket integration is not configured' });
            }
            try {
                const whmcsTicket = await this.modules.whmcsIntegration.openSupportTicket({
                    clientId: req.body?.whmcsClientId || '',
                    departmentId: resolveWhmcsSupportDepartmentId(req.body || {}),
                    subject: req.body?.subject || `Support session for ${session.userName}`,
                    message: req.body?.message || session.issue || 'Live support session attached from Support',
                    priority: req.body?.priority || 'Medium',
                    name: session.userName,
                    email: session.userEmail
                });
                const updated = this.modules.supportSystem.updateSupportSession(req.params.sessionId, {
                    whmcsTicketId: whmcsTicket.ticketId || null,
                    whmcsTicketNumber: whmcsTicket.ticketNumber || null
                });
                res.json({
                    success: true,
                    session: updated.session,
                    whmcsTicketId: whmcsTicket.ticketId || null,
                    whmcsTicketNumber: whmcsTicket.ticketNumber || null
                });
            } catch (error) {
                res.status(500).json({ error: error.message || 'Failed to attach support ticket' });
            }
        });

        this.app.post('/api/support/sessions/:sessionId/end', requireSupportModule, requireSupportStaff, (req, res) => {
            const result = this.modules.supportSystem.endSupportSession(
                req.params.sessionId,
                req.body?.reason || 'completed',
                req.body?.status || 'closed'
            );
            if (!result.success) {
                return res.status(404).json(result);
            }
            if (result.session.hiddenRoomId) {
                postSupportRoomSystemMessage(
                    result.session.hiddenRoomId,
                    `Support session ended by ${req.supportActor.name}.`,
                    { sessionId: result.session.id, event: 'end' }
                );
                closeSupportRoom(
                    result.session.hiddenRoomId,
                    'Support session ended',
                    result.session.metadata?.thankYouUrl || '/docs/support-thank-you.html'
                );
            }
            res.json(result);
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

        const sharedSecretHeader = 'x-voicelink-shared-secret';
        const configuredAdminSharedSecret = String(
            process.env.VOICELINK_AUTH_SHARED_SECRET
            || process.env.VOICELINK_AUTHORITY_SHARED_SECRET
            || ''
        ).trim();
        const hasSharedSecretAccess = (req) => {
            if (!configuredAdminSharedSecret) return false;
            return String(req.get(sharedSecretHeader) || '').trim() === configuredAdminSharedSecret;
        };
        const getAdminRequestUser = (req) => this.getAnyAuthUserFromRequest ? this.getAnyAuthUserFromRequest(req) : null;
        const getAdminRequestRole = (req) => this.normalizeUserRole(getAdminRequestUser(req)?.role || 'user');
        const hasUserModerationAccess = (req) => {
            if (hasSharedSecretAccess(req)) return true;
            const role = getAdminRequestRole(req);
            return role === 'owner' || role === 'admin' || role === 'staff';
        };
        const hasRoleAssignmentAccess = (req) => {
            if (hasSharedSecretAccess(req)) return true;
            const role = getAdminRequestRole(req);
            return role === 'owner' || role === 'admin';
        };
        const localRoleValue = (role) => this.normalizeUserRole(role) === 'staff' ? 'staff' : this.normalizeUserRole(role);
        const buildIdentityMatchers = (identity = {}) => {
            const socketId = String(identity.socketId || identity.userId || '').trim();
            const accountId = String(identity.accountId || identity.id || '').trim().toLowerCase();
            const email = normalizeEmail(identity.email);
            const username = normalizeUsername(identity.username || identity.displayName || identity.name || '');
            return { socketId, accountId, email, username };
        };
        const resolveManagedIdentity = (payload = {}) => {
            const socketId = String(payload.socketId || payload.userId || payload.id || '').trim();
            const session = socketId ? (this.socketSessions.get(socketId) || null) : null;
            const authUser = socketId ? (this.authenticatedUsers.get(socketId) || null) : null;
            const liveUser = socketId ? (this.users.get(socketId) || null) : null;
            return {
                socketId: socketId || null,
                accountId: String(payload.accountId || authUser?.id || session?.userId || '').trim() || null,
                email: normalizeEmail(payload.email || authUser?.email || liveUser?.authInfo?.email || liveUser?.email || ''),
                username: normalizeUsername(payload.username || authUser?.username || liveUser?.authInfo?.username || liveUser?.username || liveUser?.name || ''),
                displayName: String(payload.displayName || authUser?.displayName || authUser?.name || liveUser?.authInfo?.displayName || liveUser?.displayName || liveUser?.name || '').trim() || null,
                authProvider: String(payload.authProvider || authUser?.authProvider || liveUser?.authInfo?.authProvider || liveUser?.authProvider || '').trim() || null
            };
        };
        const upsertManagedRoleRecord = (identity, role) => {
            const normalizedRole = localRoleValue(role);
            if (!identity?.email && !identity?.username) {
                throw new Error('Target email or username is required');
            }
            let user = (identity.email && findLocalUserByIdentity(identity.email))
                || (identity.username && findLocalUserByIdentity(identity.username))
                || null;
            if (!user) {
                user = {
                    id: `managed_${uuidv4()}`,
                    username: identity.username || (identity.email ? identity.email.split('@')[0] : `user_${Date.now()}`),
                    displayName: identity.displayName || identity.username || identity.email || 'Managed User',
                    email: identity.email || '',
                    role: normalizedRole,
                    permissions: buildPermissionsForRole(normalizedRole),
                    entitlements: buildDefaultEntitlements(normalizedRole),
                    managedRoleOverride: true,
                    isVerified: false,
                    createdAt: new Date().toISOString(),
                    updatedAt: new Date().toISOString()
                };
            } else {
                user.username = identity.username || user.username;
                user.displayName = identity.displayName || user.displayName || user.username;
                user.email = identity.email || user.email || '';
                user.role = normalizedRole;
                user.permissions = buildPermissionsForRole(normalizedRole);
                user.entitlements = buildDefaultEntitlements(normalizedRole, user.entitlements);
                user.managedRoleOverride = true;
                user.updatedAt = new Date().toISOString();
            }
            this.localAuthUsers.set(user.id, user);
            persistLocalAuthUsers();
            return user;
        };
        const removeManagedRoleOverride = (identity) => {
            const user = (identity.email && findLocalUserByIdentity(identity.email))
                || (identity.username && findLocalUserByIdentity(identity.username))
                || null;
            if (!user) return null;
            user.role = 'user';
            user.permissions = buildPermissionsForRole('user');
            user.entitlements = buildDefaultEntitlements('user', user.entitlements);
            user.managedRoleOverride = false;
            user.updatedAt = new Date().toISOString();
            this.localAuthUsers.set(user.id, user);
            persistLocalAuthUsers();
            return user;
        };
        const applyLiveRoleUpdate = (identity, role = null) => {
            const matchers = buildIdentityMatchers(identity);
            const nextRole = role ? localRoleValue(role) : null;
            const affectedRooms = new Set();
            for (const [socketId, authUser] of this.authenticatedUsers.entries()) {
                const authEmail = normalizeEmail(authUser?.email);
                const authUsername = normalizeUsername(authUser?.username || authUser?.displayName || '');
                const authAccountId = String(authUser?.id || this.socketSessions.get(socketId)?.userId || '').trim().toLowerCase();
                const matched = (!!matchers.accountId && authAccountId === matchers.accountId)
                    || (!!matchers.email && authEmail === matchers.email)
                    || (!!matchers.username && authUsername === matchers.username)
                    || (!!matchers.socketId && socketId === matchers.socketId);
                if (!matched) continue;
                if (nextRole) {
                    authUser.role = nextRole;
                    authUser.permissions = this.buildPermissionsForRole(nextRole);
                    authUser.isAdmin = nextRole === 'owner' || nextRole === 'admin';
                    authUser.isModerator = authUser.isAdmin || nextRole === 'staff';
                    this.authenticatedUsers.set(socketId, authUser);
                    this.io.to(socketId).emit('role-updated', {
                        role: this.clientFacingRole(nextRole),
                        permissions: authUser.permissions
                    });
                } else {
                    authUser.role = 'user';
                    authUser.permissions = this.buildPermissionsForRole('user');
                    authUser.isAdmin = false;
                    authUser.isModerator = false;
                    this.authenticatedUsers.set(socketId, authUser);
                    this.io.to(socketId).emit('role-updated', {
                        role: 'user',
                        permissions: authUser.permissions
                    });
                }
                const liveUser = this.users.get(socketId);
                if (liveUser) {
                    liveUser.authInfo = {
                        ...(liveUser.authInfo || {}),
                        role: nextRole || 'user',
                        permissions: nextRole ? this.buildPermissionsForRole(nextRole) : this.buildPermissionsForRole('user')
                    };
                    liveUser.role = nextRole || 'user';
                    this.users.set(socketId, liveUser);
                    if (liveUser.roomId) affectedRooms.add(liveUser.roomId);
                }
            }
            for (const roomId of affectedRooms) {
                this.emitRoomUsersSnapshot(roomId);
            }
        };
        const serializeAdminConnectedUser = (socketId) => {
            const session = this.socketSessions.get(socketId) || {};
            const liveUser = this.users.get(socketId) || null;
            const authUser = this.authenticatedUsers.get(socketId) || null;
            const role = this.clientFacingRole(authUser?.role || liveUser?.authInfo?.role || liveUser?.role || (authUser ? 'user' : 'visitor'));
            const roomName = liveUser?.roomId ? (this.rooms.get(liveUser.roomId)?.name || null) : null;
            return {
                id: socketId,
                odId: String(authUser?.id || session.userId || socketId),
                accountId: String(authUser?.id || session.userId || '') || null,
                username: authUser?.username || liveUser?.authInfo?.username || liveUser?.username || liveUser?.name || `user-${socketId.slice(0, 8)}`,
                displayName: authUser?.displayName || authUser?.name || liveUser?.authInfo?.displayName || liveUser?.displayName || liveUser?.name || null,
                currentRoom: roomName,
                connectedAt: session.connectedAt || liveUser?.joinedAt || null,
                role,
                isMuted: !!(liveUser?.audioSettings?.muted),
                isDeafened: !!(liveUser?.audioSettings?.deafened),
                ipAddress: session.ip || null,
                authMethod: authUser?.authMethod || liveUser?.authInfo?.authMethod || null,
                email: authUser?.email || liveUser?.authInfo?.email || liveUser?.email || null
            };
        };
        const getTrustedRoleSyncTargets = () => {
            const configured = deployConfig.get('federation')?.trustedServers;
            if (!Array.isArray(configured)) return [];
            return Array.from(new Set(configured
                .map((value) => String(value || '').trim())
                .filter(Boolean)
                .map((value) => value.startsWith('http://') || value.startsWith('https://') ? value : `https://${value}`)
                .map((value) => value.replace(/\/+$/, ''))));
        };
        const propagateRoleChangeToPeers = async (method, payload) => {
            if (!configuredAdminSharedSecret) return;
            const targets = getTrustedRoleSyncTargets();
            if (!targets.length) return;
            await Promise.allSettled(targets.map(async (baseUrl) => {
                const response = await fetch(`${baseUrl}/api/admin/users/sync-role`, {
                    method,
                    headers: {
                        'Content-Type': 'application/json',
                        [sharedSecretHeader]: configuredAdminSharedSecret
                    },
                    body: JSON.stringify(payload)
                });
                if (!response.ok) {
                    throw new Error(`Role sync failed for ${baseUrl} (${response.status})`);
                }
            }));
        };
        const ejectUserFromRoom = (socketId, reason = 'Removed from room by moderator') => {
            const liveUser = this.users.get(socketId);
            const roomId = liveUser?.roomId;
            if (!roomId) return false;
            const room = this.rooms.get(roomId);
            if (!room) return false;
            room.users = (room.users || []).filter((entry) => entry.id !== socketId);
            this.users.set(socketId, { ...liveUser, roomId: null });
            const targetSocket = this.io.sockets.sockets.get(socketId);
            if (targetSocket) {
                targetSocket.leave(roomId);
                targetSocket.emit('kicked-from-room', {
                    roomId,
                    roomName: room.name,
                    reason
                });
            }
            this.io.to(roomId).emit('user-left', {
                userId: socketId,
                userName: liveUser?.name || liveUser?.authInfo?.displayName || liveUser?.authInfo?.username || 'User'
            });
            this.emitRoomSystemMessage(
                roomId,
                `${liveUser?.name || liveUser?.authInfo?.displayName || liveUser?.authInfo?.username || 'User'} left the room.`
            );
            this.emitRoomUsersSnapshot(roomId);
            return true;
        };

        this.app.get('/api/admin/users', (req, res) => {
            if (!hasUserModerationAccess(req)) {
                return res.status(403).json({ success: false, error: 'Moderator or admin access required' });
            }
            const socketIds = new Set([
                ...this.socketSessions.keys(),
                ...this.users.keys(),
                ...this.authenticatedUsers.keys()
            ]);
            const connectedUsers = Array.from(socketIds).map(serializeAdminConnectedUser);
            return res.json(connectedUsers);
        });

        this.app.post('/api/admin/users/:userId/kick', (req, res) => {
            if (!hasUserModerationAccess(req)) {
                return res.status(403).json({ success: false, error: 'Moderator or admin access required' });
            }
            const userId = String(req.params.userId || '').trim();
            if (!userId) {
                return res.status(400).json({ success: false, error: 'User ID is required' });
            }
            const reason = String(req.body?.reason || 'Removed from room by moderator').trim();
            const ok = ejectUserFromRoom(userId, reason);
            if (!ok) {
                return res.status(404).json({ success: false, error: 'User is not currently in a room' });
            }
            return res.json({ success: true });
        });

        this.app.post('/api/admin/users/:userId/role', async (req, res) => {
            if (!hasRoleAssignmentAccess(req)) {
                return res.status(403).json({ success: false, error: 'Admin access required' });
            }
            const requestedRole = String(req.body?.role || '').trim().toLowerCase();
            const normalizedRole = localRoleValue(requestedRole);
            if (!['admin', 'staff'].includes(normalizedRole)) {
                return res.status(400).json({ success: false, error: 'Role must be admin or moderator' });
            }
            const identity = resolveManagedIdentity({ ...req.body, userId: req.params.userId });
            if (!identity.email && !identity.username && !identity.accountId) {
                return res.status(400).json({ success: false, error: 'Target user identity is required' });
            }
            const savedUser = upsertManagedRoleRecord(identity, normalizedRole);
            applyLiveRoleUpdate(identity, normalizedRole);
            if (req.body?.propagate !== false) {
                await propagateRoleChangeToPeers('POST', {
                    email: identity.email || null,
                    username: identity.username || null,
                    accountId: identity.accountId || null,
                    displayName: identity.displayName || null,
                    role: normalizedRole
                });
            }
            return res.json({
                success: true,
                role: this.clientFacingRole(normalizedRole),
                user: publicLocalUser(savedUser)
            });
        });

        this.app.delete('/api/admin/users/:userId/role', async (req, res) => {
            if (!hasRoleAssignmentAccess(req)) {
                return res.status(403).json({ success: false, error: 'Admin access required' });
            }
            const identity = resolveManagedIdentity({
                userId: req.params.userId,
                email: req.body?.email || req.query?.email,
                username: req.body?.username || req.query?.username,
                accountId: req.body?.accountId || req.query?.accountId
            });
            if (!identity.email && !identity.username && !identity.accountId) {
                return res.status(400).json({ success: false, error: 'Target user identity is required' });
            }
            const savedUser = removeManagedRoleOverride(identity);
            applyLiveRoleUpdate(identity, null);
            if (req.body?.propagate !== false) {
                await propagateRoleChangeToPeers('DELETE', {
                    email: identity.email || null,
                    username: identity.username || null,
                    accountId: identity.accountId || null
                });
            }
            return res.json({
                success: true,
                role: 'user',
                user: savedUser ? publicLocalUser(savedUser) : null
            });
        });

        this.app.post('/api/admin/users/sync-role', (req, res) => {
            if (!hasSharedSecretAccess(req)) {
                return res.status(403).json({ success: false, error: 'Shared-secret access required' });
            }
            const requestedRole = String(req.body?.role || '').trim().toLowerCase();
            const normalizedRole = localRoleValue(requestedRole);
            if (!['admin', 'staff'].includes(normalizedRole)) {
                return res.status(400).json({ success: false, error: 'Role must be admin or moderator' });
            }
            const identity = resolveManagedIdentity(req.body || {});
            if (!identity.email && !identity.username && !identity.accountId) {
                return res.status(400).json({ success: false, error: 'Target identity is required' });
            }
            upsertManagedRoleRecord(identity, normalizedRole);
            applyLiveRoleUpdate(identity, normalizedRole);
            return res.json({ success: true, role: this.clientFacingRole(normalizedRole) });
        });

        this.app.delete('/api/admin/users/sync-role', (req, res) => {
            if (!hasSharedSecretAccess(req)) {
                return res.status(403).json({ success: false, error: 'Shared-secret access required' });
            }
            const identity = resolveManagedIdentity(req.body || req.query || {});
            if (!identity.email && !identity.username && !identity.accountId) {
                return res.status(400).json({ success: false, error: 'Target identity is required' });
            }
            removeManagedRoleOverride(identity);
            applyLiveRoleUpdate(identity, null);
            return res.json({ success: true, role: 'user' });
        });

        // Admin settings (server + database)
        this.app.get('/api/admin/settings', (req, res) => {
            if (this.isLocalAdminRequest && !this.isLocalAdminRequest(req)) {
                return res.status(403).json({ success: false, error: 'Admin access required' });
            }
            const config = deployConfig.getConfig() || {};
            const serverPolicies = getServerPolicyConfig();
            const database = { ...(config.database || {}) };
            if (database?.postgres?.password) database.postgres.password = '********';
            if (database?.mysql?.password) database.mysql.password = '********';
            if (database?.mariadb?.password) database.mariadb.password = '********';

            res.json({
                maxRooms: config.rooms?.maxRooms ?? 100,
                requireAuth: config.security?.requireAuth ?? false,
                messageSettings: this.getMessageSettingsConfig(),
                serverPolicies,
                database
            });
        });

        this.app.get('/api/admin/stats', (req, res) => {
            if (this.isLocalAdminRequest && !this.isLocalAdminRequest(req)) {
                return res.status(403).json({ success: false, error: 'Admin access required' });
            }

            const roomSnapshot = this.getRoomMonitorSnapshot();
            const totalUsers = this.getConnectedUsersCount();
            const activeUsers = roomSnapshot.reduce((sum, room) => sum + room.userCount, 0);
            const totalRooms = this.rooms.size;
            const activeRooms = roomSnapshot.filter(room => room.userCount > 0).length;
            const uptime = Math.max(0, Math.floor((Date.now() - this.serverStartedAt) / 1000));
            const peakUsers = roomSnapshot.reduce((peak, room) => {
                const roomPeak = Number(room.peakUsers || room.userCount || 0);
                return Math.max(peak, roomPeak);
            }, totalUsers);

            const now = Date.now();
            const recentMessageWindowMs = 5 * 60 * 1000;
            let recentMessages = 0;
            for (const messages of this.roomMessages.values()) {
                for (const message of messages || []) {
                    const ts = new Date(
                        message?.timestamp ||
                        message?.createdAt ||
                        message?.sentAt ||
                        message?.time ||
                        0
                    ).getTime();
                    if (Number.isFinite(ts) && ts > 0 && now - ts <= recentMessageWindowMs) {
                        recentMessages++;
                    }
                }
            }
            for (const messages of this.directMessages.values()) {
                for (const message of messages || []) {
                    const ts = new Date(
                        message?.timestamp ||
                        message?.createdAt ||
                        message?.sentAt ||
                        message?.time ||
                        0
                    ).getTime();
                    if (Number.isFinite(ts) && ts > 0 && now - ts <= recentMessageWindowMs) {
                        recentMessages++;
                    }
                }
            }

            const minutes = recentMessageWindowMs / 60000;
            const messagesPerMinute = Number((recentMessages / minutes).toFixed(2));
            const bandwidthUsage = Number((this.relayStats.bytesRelayed / (1024 * 1024)).toFixed(2));

            res.json({
                totalUsers,
                activeUsers,
                totalRooms,
                activeRooms,
                uptime,
                peakUsers,
                messagesPerMinute,
                bandwidthUsage,
                visibility: getServerPolicyConfig().effectiveVisibility
            });
        });

        this.app.post('/api/admin/settings', async (req, res) => {
            if (this.isLocalAdminRequest && !this.isLocalAdminRequest(req)) {
                return res.status(403).json({ success: false, error: 'Admin access required' });
            }
            try {
                const maxRooms = Number(req.body?.maxRooms);
                const hasRequireAuth = Object.prototype.hasOwnProperty.call(req.body || {}, 'requireAuth');
                const requireAuth = !!req.body?.requireAuth;
                const incomingMessageSettings = req.body?.messageSettings && typeof req.body.messageSettings === 'object'
                    ? req.body.messageSettings
                    : null;
                const incomingDatabase = req.body?.database && typeof req.body.database === 'object'
                    ? req.body.database
                    : null;
                const incomingServerPolicies = req.body?.serverPolicies && typeof req.body.serverPolicies === 'object'
                    ? req.body.serverPolicies
                    : null;

                if (!Number.isNaN(maxRooms) && maxRooms > 0) {
                    deployConfig.updateSection('rooms', { maxRooms });
                }
                if (hasRequireAuth) {
                    const currentSecurity = deployConfig.get('security') || {};
                    deployConfig.updateSection('security', {
                        ...currentSecurity,
                        requireAuth
                    });
                }
                if (incomingMessageSettings) {
                    deployConfig.updateSection('messageSettings', {
                        ...this.getMessageSettingsConfig(),
                        ...incomingMessageSettings
                    });
                }

                if (incomingDatabase) {
                    const current = deployConfig.get('database') || {};
                    const preserveMaskedPassword = (incomingValue, existingValue) => {
                        if (typeof incomingValue === 'string' && incomingValue.trim() === '********') {
                            return existingValue || '';
                        }
                        return incomingValue;
                    };

                    const postgresPassword = preserveMaskedPassword(
                        incomingDatabase?.postgres?.password,
                        current?.postgres?.password
                    );
                    const mysqlPassword = preserveMaskedPassword(
                        incomingDatabase?.mysql?.password,
                        current?.mysql?.password
                    );
                    const mariadbPassword = preserveMaskedPassword(
                        incomingDatabase?.mariadb?.password,
                        current?.mariadb?.password
                    );
                    const merged = {
                        ...current,
                        ...incomingDatabase,
                        sqlite: { ...(current.sqlite || {}), ...(incomingDatabase.sqlite || {}) },
                        postgres: {
                            ...(current.postgres || {}),
                            ...(incomingDatabase.postgres || {}),
                            password: postgresPassword
                        },
                        mysql: {
                            ...(current.mysql || {}),
                            ...(incomingDatabase.mysql || {}),
                            password: mysqlPassword
                        },
                        mariadb: {
                            ...(current.mariadb || {}),
                            ...(incomingDatabase.mariadb || {}),
                            password: mariadbPassword
                        }
                    };
                    deployConfig.updateSection('database', merged);
                }
                if (incomingServerPolicies) {
                    const currentPolicies = getServerPolicyConfig();
                    deployConfig.updateSection('serverPolicies', {
                        ...currentPolicies,
                        ...incomingServerPolicies,
                        visibility: incomingServerPolicies.visibility
                            ? normalizeVisibilityConfig(incomingServerPolicies.visibility)
                            : currentPolicies.visibility,
                        visibilityOverride: incomingServerPolicies.visibilityOverride
                            ? {
                                ...currentPolicies.visibilityOverride,
                                ...incomingServerPolicies.visibilityOverride,
                                visibility: incomingServerPolicies.visibilityOverride.visibility
                                    ? normalizeVisibilityConfig(incomingServerPolicies.visibilityOverride.visibility)
                                    : currentPolicies.visibilityOverride.visibility
                            }
                            : currentPolicies.visibilityOverride
                    });
                }

                await deployConfig.save();
                res.json({ success: true });
            } catch (error) {
                res.status(500).json({ success: false, error: error.message });
            }
        });

        this.app.get('/api/admin/server-visibility', (req, res) => {
            if (this.isLocalAdminRequest && !this.isLocalAdminRequest(req)) {
                return res.status(403).json({ success: false, error: 'Admin access required' });
            }
            const policies = getServerPolicyConfig();
            res.json({
                success: true,
                ownerVisibility: policies.visibility,
                override: policies.visibilityOverride,
                effectiveVisibility: policies.effectiveVisibility,
                frontendStatus: policies.effectiveVisibility.frontendOpen ? 'open' : 'closed'
            });
        });

        this.app.put('/api/admin/server-visibility', async (req, res) => {
            if (this.isLocalAdminRequest && !this.isLocalAdminRequest(req)) {
                return res.status(403).json({ success: false, error: 'Admin access required' });
            }
            try {
                const current = getServerPolicyConfig();
                const nextVisibility = normalizeVisibilityConfig(req.body?.visibility || req.body || {});
                deployConfig.updateSection('serverPolicies', {
                    ...current,
                    visibility: nextVisibility
                });
                await deployConfig.save();
                const fresh = getServerPolicyConfig();
                res.json({ success: true, ownerVisibility: fresh.visibility, effectiveVisibility: fresh.effectiveVisibility });
            } catch (error) {
                res.status(500).json({ success: false, error: error.message });
            }
        });

        this.app.post('/api/admin/server-visibility/override', async (req, res) => {
            if (this.isLocalAdminRequest && !this.isLocalAdminRequest(req)) {
                return res.status(403).json({ success: false, error: 'Admin access required' });
            }
            try {
                const current = getServerPolicyConfig();
                const actor = resolveDeploymentActor(req);
                const reason = String(req.body?.reason || '').trim();
                const visibility = normalizeVisibilityConfig(req.body?.visibility || {});
                const permanent = req.body?.permanent === true;
                const durationMinutes = Math.max(1, Number(req.body?.durationMinutes || 0));
                const expiresAt = permanent ? null : new Date(Date.now() + durationMinutes * 60000).toISOString();
                deployConfig.updateSection('serverPolicies', {
                    ...current,
                    visibilityOverride: {
                        active: true,
                        reason,
                        setBy: actor.actorName,
                        setAt: new Date().toISOString(),
                        expiresAt,
                        visibility
                    }
                });
                await deployConfig.save();
                const fresh = getServerPolicyConfig();
                res.json({ success: true, override: fresh.visibilityOverride, effectiveVisibility: fresh.effectiveVisibility });
            } catch (error) {
                res.status(500).json({ success: false, error: error.message });
            }
        });

        this.app.delete('/api/admin/server-visibility/override', async (req, res) => {
            if (this.isLocalAdminRequest && !this.isLocalAdminRequest(req)) {
                return res.status(403).json({ success: false, error: 'Admin access required' });
            }
            try {
                const current = getServerPolicyConfig();
                deployConfig.updateSection('serverPolicies', {
                    ...current,
                    visibilityOverride: {
                        active: false,
                        reason: '',
                        setBy: '',
                        setAt: null,
                        expiresAt: null,
                        visibility: null
                    }
                });
                await deployConfig.save();
                const fresh = getServerPolicyConfig();
                res.json({ success: true, override: fresh.visibilityOverride, effectiveVisibility: fresh.effectiveVisibility });
            } catch (error) {
                res.status(500).json({ success: false, error: error.message });
            }
        });

        this.app.get('/api/admin/deployment-automation', (req, res) => {
            if (this.isLocalAdminRequest && !this.isLocalAdminRequest(req)) {
                return res.status(403).json({ success: false, error: 'Admin access required' });
            }
            const policy = getServerPolicyConfig();
            res.json({
                success: true,
                deploymentAutomation: policy.deploymentAutomation
            });
        });

        this.app.put('/api/admin/deployment-automation', async (req, res) => {
            if (this.isLocalAdminRequest && !this.isLocalAdminRequest(req)) {
                return res.status(403).json({ success: false, error: 'Admin access required' });
            }
            try {
                const current = getServerPolicyConfig();
                const incoming = req.body?.deploymentAutomation || req.body || {};
                const next = {
                    ...current,
                    deploymentAutomation: {
                        ...current.deploymentAutomation,
                        enabled: incoming.enabled !== undefined ? !!incoming.enabled : current.deploymentAutomation.enabled,
                        allowManualServerConfig: incoming.allowManualServerConfig !== undefined
                            ? !!incoming.allowManualServerConfig
                            : current.deploymentAutomation.allowManualServerConfig,
                        allowAutoSetup: incoming.allowAutoSetup !== undefined
                            ? !!incoming.allowAutoSetup
                            : current.deploymentAutomation.allowAutoSetup,
                        requireRemoteCredentials: incoming.requireRemoteCredentials !== undefined
                            ? !!incoming.requireRemoteCredentials
                            : current.deploymentAutomation.requireRemoteCredentials,
                        allowSshKeyAuth: incoming.allowSshKeyAuth !== undefined
                            ? !!incoming.allowSshKeyAuth
                            : current.deploymentAutomation.allowSshKeyAuth,
                        allowPasswordAuth: incoming.allowPasswordAuth !== undefined
                            ? !!incoming.allowPasswordAuth
                            : current.deploymentAutomation.allowPasswordAuth
                    }
                };
                deployConfig.updateSection('serverPolicies', next);
                await deployConfig.save();
                res.json({ success: true, deploymentAutomation: getServerPolicyConfig().deploymentAutomation });
            } catch (error) {
                res.status(500).json({ success: false, error: error.message });
            }
        });

        this.app.get('/api/admin/network-trust', (req, res) => {
            if (this.isLocalAdminRequest && !this.isLocalAdminRequest(req)) {
                return res.status(403).json({ success: false, error: 'Admin access required' });
            }
            const policy = getServerPolicyConfig();
            res.json({
                success: true,
                trust: {
                    ...policy.networkTrust,
                    meaning: networkTrustMeaning(policy.networkTrust.level)
                }
            });
        });

        this.app.put('/api/admin/network-trust', async (req, res) => {
            if (this.isLocalAdminRequest && !this.isLocalAdminRequest(req)) {
                return res.status(403).json({ success: false, error: 'Admin access required' });
            }
            try {
                const current = getServerPolicyConfig();
                const body = req.body || {};
                const nextTrust = {
                    level: Math.min(100, Math.max(1, Number(body.level || current.networkTrust.level || 1))),
                    role: String(body.role || current.networkTrust.role || 'visitor'),
                    isCommunityServer: body.isCommunityServer !== undefined ? !!body.isCommunityServer : current.networkTrust.isCommunityServer,
                    isTrustedModerator: body.isTrustedModerator !== undefined ? !!body.isTrustedModerator : current.networkTrust.isTrustedModerator,
                    isTrustedOwner: body.isTrustedOwner !== undefined ? !!body.isTrustedOwner : current.networkTrust.isTrustedOwner
                };
                deployConfig.updateSection('serverPolicies', {
                    ...current,
                    networkTrust: nextTrust
                });
                await deployConfig.save();
                res.json({ success: true, trust: { ...nextTrust, meaning: networkTrustMeaning(nextTrust.level) } });
            } catch (error) {
                res.status(500).json({ success: false, error: error.message });
            }
        });

        this.app.get('/api/network/trust', (req, res) => {
            const policy = getServerPolicyConfig();
            res.json({
                level: policy.networkTrust.level,
                role: policy.networkTrust.role,
                meaning: networkTrustMeaning(policy.networkTrust.level)
            });
        });

        this.app.get('/api/admin/api-sync', (req, res) => {
            if (this.isLocalAdminRequest && !this.isLocalAdminRequest(req)) {
                return res.status(403).json({ success: false, error: 'Admin access required' });
            }
            const config = deployConfig.getConfig() || {};
            res.json({
                enabled: config.apiSync?.enabled !== false,
                mode: config.apiSync?.mode || 'hybrid',
                syncInterval: Number(config.apiSync?.syncInterval || 60),
                autoSyncOnChange: config.apiSync?.autoSyncOnChange !== false,
                allowClientChoice: config.apiSync?.allowClientChoice !== false,
                autoReturnRecoveredUsers: !!config.apiSync?.autoReturnRecoveredUsers,
                snapshotIntervalSeconds: Number(config.apiSync?.snapshotIntervalSeconds || 180),
                routingProfiles: Array.isArray(config.apiSync?.routingProfiles) ? config.apiSync.routingProfiles : [],
                whmcsEnabled: this.shouldDelegateWhmcsAuth(),
                whmcsUrl: process.env.VOICELINK_WHMCS_AUTHORITY_URL || 'https://devine-creations.com',
                whmcsApiIdentifier: config.whmcs?.apiIdentifier || null,
                whmcsApiSecret: config.whmcs?.apiSecret || null
            });
        });

        this.app.put('/api/admin/api-sync', async (req, res) => {
            if (this.isLocalAdminRequest && !this.isLocalAdminRequest(req)) {
                return res.status(403).json({ success: false, error: 'Admin access required' });
            }
            try {
                const body = req.body || {};
                deployConfig.updateSection('apiSync', {
                    enabled: body.enabled !== false,
                    mode: body.mode || 'hybrid',
                    syncInterval: Number(body.syncInterval) || 60,
                    autoSyncOnChange: body.autoSyncOnChange !== false,
                    allowClientChoice: body.allowClientChoice !== false,
                    autoReturnRecoveredUsers: !!body.autoReturnRecoveredUsers,
                    snapshotIntervalSeconds: Number(body.snapshotIntervalSeconds) || 180,
                    routingProfiles: Array.isArray(body.routingProfiles) ? body.routingProfiles.slice(0, 32).map((profile) => ({
                        id: String(profile?.id || uuidv4()),
                        label: String(profile?.label || 'Routing Profile').trim() || 'Routing Profile',
                        targetServer: String(profile?.targetServer || '').trim(),
                        targetType: String(profile?.targetType || 'domain').trim() || 'domain',
                        installPath: profile?.installPath ? String(profile.installPath).trim() : null,
                        manualAddress: profile?.manualAddress ? String(profile.manualAddress).trim() : null,
                        actions: Array.isArray(profile?.actions)
                            ? profile.actions.slice(0, 4).map((action) => String(action || '').trim()).filter(Boolean)
                            : []
                    })) : []
                });
                deployConfig.updateSection('whmcs', {
                    apiIdentifier: body.whmcsApiIdentifier || null,
                    apiSecret: body.whmcsApiSecret || null
                });
                await deployConfig.save();
                res.json({ success: true, message: 'API sync settings updated' });
            } catch (error) {
                res.status(500).json({ success: false, error: error.message });
            }
        });

        this.app.post('/api/bugs/submit', (req, res) => {
            try {
                const report = req.body || {};
                const title = String(report.title || '').trim();
                const description = String(report.description || '').trim();
                if (!title || !description) {
                    return res.status(400).json({ success: false, error: 'Bug title and description are required' });
                }

                const bugReport = {
                    id: `bug_${uuidv4()}`,
                    title,
                    description,
                    category: String(report.category || 'general').trim() || 'general',
                    severity: String(report.severity || 'normal').trim() || 'normal',
                    anonymous: report.anonymous !== false,
                    submittedBy: report.submittedBy || null,
                    mastodonHandle: report.mastodonHandle || null,
                    appVersion: report.appVersion || null,
                    platform: report.platform || null,
                    accountEmail: report.accountEmail || null,
                    displayName: report.displayName || null,
                    username: report.username || null,
                    clientId: report.clientId || req.headers['x-client-id'] || null,
                    currentRoom: report.currentRoom || null,
                    diagnosticsSummary: report.diagnosticsSummary || null,
                    localMonitorDiagnostics: report.localMonitorDiagnostics || null,
                    recentCrashReports: Array.isArray(report.recentCrashReports) ? report.recentCrashReports : [],
                    submittedAt: report.submittedAt || new Date().toISOString(),
                    ip: req.ip
                };

                const bugDir = path.join(__dirname, '../../data');
                const bugFile = path.join(bugDir, 'bug-reports.json');
                fs.mkdirSync(bugDir, { recursive: true });
                const existing = fs.existsSync(bugFile)
                    ? JSON.parse(fs.readFileSync(bugFile, 'utf8') || '[]')
                    : [];
                const reports = Array.isArray(existing) ? existing : [];
                reports.unshift(bugReport);
                fs.writeFileSync(bugFile, JSON.stringify(reports.slice(0, 1000), null, 2));
                try {
                    databaseStorage.mirrorJsonFile('diagnostics', 'bug-reports', bugFile, reports.slice(0, 1000));
                } catch (mirrorError) {
                    console.warn('[BugReport] Database mirror skipped:', mirrorError.message);
                }
                console.log(
                    `[BugReport] id=${bugReport.id} account=${bugReport.accountEmail || bugReport.displayName || bugReport.username || bugReport.submittedBy || 'anonymous'} client=${bugReport.clientId || 'unknown'} room=${bugReport.currentRoom || 'none'} severity=${bugReport.severity} category=${bugReport.category} title=${bugReport.title}`
                );
                if (bugReport.localMonitorDiagnostics) {
                    console.log(`[BugReport][LocalMonitor] ${String(bugReport.localMonitorDiagnostics).replace(/\r?\n/g, ' | ')}`);
                }

                return res.json({
                    success: true,
                    bugId: bugReport.id,
                    message: 'Bug report submitted'
                });
            } catch (error) {
                return res.status(500).json({ success: false, error: error.message });
            }
        });

        this.app.post('/api/admin/database/test', async (req, res) => {
            if (this.isLocalAdminRequest && !this.isLocalAdminRequest(req)) {
                return res.status(403).json({ success: false, error: 'Admin access required' });
            }
            const provider = String(req.body?.provider || '').toLowerCase();
            const cfg = req.body?.config || {};
            if (!provider) {
                return res.status(400).json({ success: false, error: 'Database provider is required' });
            }

            if (provider === 'sqlite') {
                const dbPath = String(cfg.path || '').trim();
                if (!dbPath) {
                    return res.status(400).json({ success: false, error: 'SQLite path is required' });
                }
                try {
                    const dir = path.dirname(dbPath);
                    fs.mkdirSync(dir, { recursive: true });
                    fs.accessSync(dir, fs.constants.W_OK);
                    return res.json({
                        success: true,
                        provider,
                        message: 'SQLite path is writable'
                    });
                } catch (error) {
                    return res.status(400).json({ success: false, error: `SQLite path not writable: ${error.message}` });
                }
            }

            const expected = new Set(['postgres', 'mysql', 'mariadb']);
            if (!expected.has(provider)) {
                return res.status(400).json({ success: false, error: `Unsupported provider: ${provider}` });
            }

            const host = String(cfg.host || '').trim();
            const port = Number(cfg.port || (provider === 'postgres' ? 5432 : 3306));
            if (!host || Number.isNaN(port) || port <= 0) {
                return res.status(400).json({ success: false, error: 'Host and valid port are required' });
            }

            const socket = new net.Socket();
            let done = false;
            const finish = (ok, message) => {
                if (done) return;
                done = true;
                socket.destroy();
                if (ok) {
                    return res.json({ success: true, provider, message });
                }
                return res.status(400).json({ success: false, error: message });
            };

            socket.setTimeout(3000);
            socket.once('connect', () => finish(true, `Connected to ${host}:${port}`));
            socket.once('timeout', () => finish(false, `Connection timeout to ${host}:${port}`));
            socket.once('error', (error) => finish(false, `Connection failed: ${error.message}`));
            socket.connect(port, host);
        });

        this.app.get('/api/admin/database/status', async (req, res) => {
            if (this.isLocalAdminRequest && !this.isLocalAdminRequest(req)) {
                return res.status(403).json({ success: false, error: 'Admin access required' });
            }

            try {
                return res.json({
                    success: true,
                    status: databaseStorage.status()
                });
            } catch (error) {
                return res.status(500).json({ success: false, error: error.message });
            }
        });

        this.app.post('/api/admin/database/initialize', async (req, res) => {
            if (this.isLocalAdminRequest && !this.isLocalAdminRequest(req)) {
                return res.status(403).json({ success: false, error: 'Admin access required' });
            }

            try {
                const dbPath = databaseStorage.ensureSchema();
                return res.json({
                    success: true,
                    dbPath,
                    status: databaseStorage.status(),
                    message: 'Database initialized'
                });
            } catch (error) {
                return res.status(500).json({ success: false, error: error.message });
            }
        });

        this.app.post('/api/admin/database/migrate-defaults', async (req, res) => {
            if (this.isLocalAdminRequest && !this.isLocalAdminRequest(req)) {
                return res.status(403).json({ success: false, error: 'Admin access required' });
            }

            try {
                const result = databaseStorage.migrateDefaults();
                return res.json({
                    success: true,
                    result,
                    status: databaseStorage.status(),
                    message: 'Default data migrated into database snapshots'
                });
            } catch (error) {
                return res.status(500).json({ success: false, error: error.message });
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

            socket.on('register-session', (data = {}) => {
                try {
                    const {
                        token,
                        provider,
                        deviceId,
                        deviceName,
                        deviceType,
                        clientVersion,
                        appVersion,
                        timeZone,
                        locale,
                        locationHint
                    } = data;

                    let user = null;
                    if (provider === 'whmcs') {
                        const session = this.getAuthSession(this.whmcsAuthSessions, token);
                        if (!session) {
                            socket.emit('auth_failed', { message: 'Invalid or expired WHMCS session' });
                            return;
                        }
                        user = session.user;
                    } else if (provider === 'email' || provider === 'mastodon') {
                        if (data.user && data.user.id) {
                            user = data.user;
                        }
                    }

                    if (!user || !user.id) {
                        socket.emit('auth_failed', { message: 'Authentication required' });
                        return;
                    }

                    const sessionInfo = {
                        userId: user.id,
                        username: user.username || user.displayName || user.email || 'Unknown',
                        provider: provider || user.authProvider || 'unknown',
                        deviceId: deviceId || null,
                        deviceName: deviceName || 'Unknown Device',
                        deviceType: deviceType || 'unknown',
                        clientVersion: clientVersion || appVersion || null,
                        timeZone: timeZone || null,
                        locale: locale || null,
                        locationHint: locationHint || null,
                        ip: socket.handshake.address,
                        userAgent: socket.handshake.headers['user-agent'] || '',
                        connectedAt: new Date()
                    };

                    this.registerSocketSession(socket, sessionInfo);
                    this.authenticatedUsers.set(socket.id, user);

                    const otherSessions = this.getOtherUserSessions(user.id, socket.id);
                    if (otherSessions.length > 0) {
                        otherSessions.forEach((session) => {
                            this.io.to(session.socketId).emit('multi-device-login', {
                                userId: user.id,
                                newDevice: sessionInfo,
                                activeDevices: this.getUserSessions(user.id)
                            });
                        });
                        socket.emit('multi-device-active', {
                            userId: user.id,
                            activeDevices: this.getUserSessions(user.id)
                        });
                    }

                    socket.emit('auth_success', {
                        role: user.role || 'user',
                        permissions: user.permissions || []
                    });
                } catch (err) {
                    socket.emit('auth_failed', { message: err.message || 'Authentication failed' });
                }
            });

            socket.on('multi-device-command', (data = {}) => {
                const { targetDeviceId, action, payload } = data;
                if (!targetDeviceId || !action) return;
                const targetSocketId = this.deviceSessions.get(targetDeviceId);
                if (targetSocketId) {
                    this.io.to(targetSocketId).emit('multi-device-command', {
                        action,
                        fromDeviceId: this.socketSessions.get(socket.id)?.deviceId || null,
                        payload: payload || {}
                    });
                }
            });

            // Get room list for desktop/mobile apps
            socket.on('get-rooms', () => {
                const roomList = this.buildClientRoomListPayload();
                console.log('[Socket] Sending room-list with ' + roomList.length + ' rooms');
                socket.emit('room-list', roomList);
            });

            // User joins a room
            socket.on('join-room', (data) => {
                const { roomId, userName, username, password } = data;
                const resolvedUserName = userName || username;
                const room = this.rooms.get(roomId);

                if (!room) {
                    socket.emit('error', { message: 'Room not found' });
                    return;
                }

                if (room.password && room.password !== password) {
                    socket.emit('error', { message: 'Invalid password' });
                    return;
                }

                if (room.locked) {
                    const requesterAuth = this.authenticatedUsers.get(socket.id) || null;
                    const requestEntry = {
                        id: uuidv4(),
                        userId: socket.id,
                        userName: resolvedUserName || requesterAuth?.displayName || requesterAuth?.username || `User ${socket.id.slice(0, 8)}`,
                        requestedAt: new Date(),
                        authInfo: requesterAuth
                    };
                    room.pendingJoinRequests = Array.isArray(room.pendingJoinRequests) ? room.pendingJoinRequests : [];
                    room.pendingJoinRequests = room.pendingJoinRequests.filter((entry) => entry.userId !== socket.id);
                    room.pendingJoinRequests.unshift(requestEntry);
                    this.emitRoomJoinRequest(roomId, requestEntry);
                    socket.emit('join-room-error', {
                        message: 'Room is locked. Your join request has been sent to the room administrators.',
                        roomLocked: true,
                        requestPending: true,
                        requestId: requestEntry.id
                    });
                    return;
                }

                this.normalizeRoomUsers(roomId);

                if (room.users.length >= room.maxUsers) {
                    socket.emit('error', { message: 'Room is full' });
                    return;
                }

                // If this socket is already in another room, leave that room first.
                const existingSession = this.users.get(socket.id);
                if (existingSession?.roomId && existingSession.roomId !== roomId) {
                    const previousRoom = this.rooms.get(existingSession.roomId);
                    if (previousRoom) {
                        previousRoom.users = (previousRoom.users || []).filter(u => u.id !== socket.id);
                        socket.to(existingSession.roomId).emit('user-left', {
                            userId: socket.id,
                            userName: existingSession.name
                        });
                        this.emitRoomSystemMessage(
                            existingSession.roomId,
                            `${existingSession.name} left the room.`
                        );
                        this.emitRoomUsersSnapshot(existingSession.roomId);
                    }
                    socket.leave(existingSession.roomId);
                }

                // Check if user is authenticated (Mastodon/email) or guest
                const authUser = this.authenticatedUsers.get(socket.id);
                const isAuthenticated = !!authUser;

                // Add user to room
                const user = {
                    id: socket.id,
                    name: resolvedUserName || `User ${socket.id.slice(0, 8)}`,
                    joinedAt: new Date(),
                    lastActiveAt: new Date(),
                    isSpeaking: false,
                    isAuthenticated: isAuthenticated,
                    authInfo: authUser || null, // Mastodon user info if authenticated
                    audioSettings: {
                        muted: false,
                        deafened: false,
                        volume: 1.0,
                        spatialPosition: { x: 0, y: 0, z: 0 },
                        outputDevice: 'default'
                    }
                };

                room.users = (room.users || []).filter(u => u.id !== socket.id);
                room.users.push(user);

                const wasRecentUser = Array.isArray(room.recentUsers)
                    ? room.recentUsers.some((entry) => (entry?.name || '').trim().toLowerCase() === (user.name || '').trim().toLowerCase())
                    : false;

                // Track recent users (keep last 10)
                if (!room.recentUsers) room.recentUsers = [];
                const recentEntry = { name: user.name, joinedAt: user.joinedAt };
                room.recentUsers = room.recentUsers.filter(u => u.name !== user.name);
                room.recentUsers.unshift(recentEntry);
                if (room.recentUsers.length > 10) room.recentUsers = room.recentUsers.slice(0, 10);

                // Track peak users
                if (!room.peakUsers) room.peakUsers = 0;
                if (room.users.length > room.peakUsers) {
                    room.peakUsers = room.users.length;
                }
                this.users.set(socket.id, { ...user, roomId });

                socket.join(roomId);

                // Send full room state including all users to the joining user
                const configuredBackgroundStream = this.getConfiguredBackgroundStreamForRoom(room);
                const roomState = {
                    id: room.id,
                    name: room.name,
                    description: room.description || '',
                    welcomeMessage: room.welcomeMessage || null,
                    users: this.normalizeRoomUsers(roomId).map(u => this.serializeRoomUser(u, roomId)).filter(Boolean),
                    userCount: this.normalizeRoomUsers(roomId).length,
                    maxUsers: room.maxUsers || 50,
                    locked: room.locked || false,
                    createdAt: room.createdAt ? new Date(room.createdAt).toISOString() : null,
                    uptimeSeconds: room.createdAt ? Math.max(0, Math.floor((Date.now() - new Date(room.createdAt).getTime()) / 1000)) : null,
                    backgroundStream: configuredBackgroundStream?.streamUrl || null,
                    streamVolume: configuredBackgroundStream?.volume ?? null,
                    nowPlaying: configuredBackgroundStream ? {
                        playing: true,
                        title: configuredBackgroundStream.name,
                        source: 'background_stream'
                    } : null
                };

                socket.emit('joined-room', { room: roomState, user });
                socket.to(roomId).emit('user-joined', user);
                this.emitRoomSystemMessage(
                    roomId,
                    `${user.name} joined the room.`,
                    { joinedUserId: user.id }
                );

                // Broadcast updated user count to all in room
                this.emitRoomUsersSnapshot(roomId);
                this.emitRoomListToClients();

                const roomWelcome = this.buildRoomWelcomeMessage({ user, room });
                if (roomWelcome) {
                    const botMessage = {
                        id: uuidv4(),
                        userId: `bot:${roomId}`,
                        userName: 'VoiceLink Bot',
                        message: roomWelcome,
                        timestamp: new Date(),
                        isAuthenticated: true,
                        isBot: true,
                        authProvider: 'voicelink_bot',
                        reactions: []
                    };
                    this.storeRoomMessage(roomId, botMessage);
                    setTimeout(() => {
                        this.io.to(roomId).emit('chat-message', botMessage);
                    }, 150);
                }

                if (!this.restartNoticeSentAtByRoom.has(roomId)) {
                    const restartNotice = this.buildRecentRestartRoomNotice(room);
                    if (restartNotice) {
                        const systemMessage = {
                            id: uuidv4(),
                            userId: `system:${roomId}`,
                            userName: 'System',
                            message: restartNotice,
                            timestamp: new Date(),
                            isAuthenticated: true,
                            isBot: true,
                            type: 'system',
                            reactions: []
                        };
                        this.storeRoomMessage(roomId, systemMessage);
                        this.restartNoticeSentAtByRoom.set(roomId, Date.now());
                        setTimeout(() => {
                            this.io.to(roomId).emit('chat-message', systemMessage);
                        }, 220);
                    }
                }

                console.log(`User ${user.name} joined room ${room.name} (${this.normalizeRoomUsers(roomId).length} users now)`);
            });

            socket.on('room-join-request-response', (data = {}) => {
                const moderator = this.users.get(socket.id);
                const { roomId, requestId, action } = data;
                const room = this.rooms.get(roomId);
                if (!moderator || !room || !requestId) return;
                if (!this.canUserModerateRoom(moderator, room)) return;

                room.pendingJoinRequests = Array.isArray(room.pendingJoinRequests) ? room.pendingJoinRequests : [];
                const requestIndex = room.pendingJoinRequests.findIndex((entry) => entry.id === requestId);
                if (requestIndex === -1) return;

                const requestEntry = room.pendingJoinRequests[requestIndex];
                room.pendingJoinRequests.splice(requestIndex, 1);

                if (action === 'approve') {
                    this.io.to(requestEntry.userId).emit('room-join-request-approved', {
                        roomId,
                        roomName: room.name,
                        approvedBy: moderator.name || moderator.username || 'Moderator'
                    });
                } else if (action === 'decline') {
                    this.io.to(requestEntry.userId).emit('room-join-request-declined', {
                        roomId,
                        roomName: room.name,
                        declinedBy: moderator.name || moderator.username || 'Moderator'
                    });
                }
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
                    user.lastActiveAt = new Date();

                    socket.to(user.roomId).emit('user-audio-settings-changed', {
                        userId: socket.id,
                        settings: user.audioSettings
                    });
                    this.emitRoomUsersSnapshot(user.roomId);
                }
            });

            socket.on('audio-state', (data) => {
                const user = this.users.get(socket.id);
                if (!user) return;
                user.audioSettings = user.audioSettings || {};
                user.audioSettings.muted = !!data.muted;
                user.audioSettings.deafened = !!data.deafened;
                user.isSpeaking = false;
                user.lastActiveAt = new Date();

                this.io.to(user.roomId).emit('user-audio-state-changed', {
                    userId: socket.id,
                    muted: user.audioSettings.muted,
                    deafened: user.audioSettings.deafened,
                    speaking: user.isSpeaking
                });
                this.emitRoomUsersSnapshot(user.roomId);
            });

            // Chat messages
            socket.on('chat-message', async (data) => {
                const user = this.users.get(socket.id);
                if (!user?.roomId) {
                    console.warn(`[Chat] Ignored room message from ${socket.id}: no active room binding`);
                    socket.emit('error', { message: 'You are not currently joined to a room.' });
                    return;
                }
                const message = {
                    id: uuidv4(),
                    userId: socket.id,
                    userName: user.name,
                    message: data.message,
                    content: data.message,
                    timestamp: new Date(),
                    isAuthenticated: user.isAuthenticated || false,
                    type: data.type || 'text',
                    replyTo: data.replyTo || null,
                    attachmentId: data.attachmentId || null,
                    attachmentName: data.attachmentName || null,
                    attachmentURL: data.attachmentURL || data.attachmentUrl || null,
                    attachmentCaption: data.attachmentCaption || data.caption || null,
                    attachmentExpiresAt: data.attachmentExpiresAt || null,
                    attachmentRemoved: !!data.attachmentRemoved,
                    reactions: []
                };

                user.lastActiveAt = new Date();
                this.users.set(socket.id, user);

                const room = this.rooms.get(user.roomId);
                const sanitizedResult = await this.sanitizeMessageLinks(message, {
                    actorName: user.name,
                    roomName: room?.name || 'this room'
                });
                const sanitizedMessage = sanitizedResult.message;

                // Store message in room history
                this.storeRoomMessage(user.roomId, sanitizedMessage);

                this.io.to(user.roomId).emit('chat-message', sanitizedMessage);
                if (sanitizedResult.notice) {
                    this.storeRoomMessage(user.roomId, sanitizedResult.notice);
                    this.io.to(user.roomId).emit('chat-message', sanitizedResult.notice);
                }

                const source = (sanitizedMessage.message || '').trim();
                const lowered = source.toLowerCase();
                const botMentionPattern = /@voicelink(?:\s+bot)?\b/;
                const explicitBotAddress =
                    lowered.startsWith('/bot') ||
                    lowered.startsWith('/vb') ||
                    lowered.startsWith('/voicebot') ||
                    botMentionPattern.test(lowered) ||
                    lowered.includes('voicelink bot');
                const dismissesBot =
                    lowered.includes('dismiss bot') ||
                    lowered.includes('thanks bot') ||
                    lowered.includes('thank you bot') ||
                    lowered.includes('that is all bot') ||
                    lowered.includes('stop bot');
                    const addressedToBot =
                        explicitBotAddress ||
                        (this.isBotConversationActive(user.roomId, socket.id) && this.isLikelyBotFollowUp(source));

                    if (addressedToBot) {
                        if (dismissesBot) {
                            this.dismissBotConversation(user.roomId, socket.id);
                            return;
                        }
                        this.updateBotConversationState(user.roomId, socket.id, source);
                        this.rememberBotTurn(user.roomId, socket.id, 'user', source);
                        const commandResult = await this.executeRoomBotCommand(user, user.roomId, source);
                        let reply = commandResult.handled
                            ? commandResult.reply
                            : await this.buildBotTextReply(user, user.roomId, source);
                        if (!commandResult.handled) {
                            const generatedReply = await this.generateBotOllamaReply(user, user.roomId, source);
                            if (generatedReply) {
                                reply = generatedReply;
                            }
                        }
                        const attachmentReply = sanitizedMessage.attachmentName || sanitizedMessage.attachmentURL
                            ? await this.buildBotAttachmentReply(user, sanitizedMessage)
                            : null;
                        if (attachmentReply) {
                            reply = attachmentReply;
                        }
                        if (this.shouldSuppressBotReply(user.roomId, socket.id, source, reply, explicitBotAddress)) {
                            return;
                        }
                        const botThreadTarget = this.findBotReplyTarget(user.roomId, sanitizedMessage, reply);

                        const botMessage = {
                            id: uuidv4(),
                            userId: `bot:${user.roomId}`,
                            userName: 'VoiceLink Bot',
                            message: reply,
                            timestamp: new Date(),
                            isAuthenticated: true,
                            isBot: true,
                            authProvider: 'voicelink_bot',
                            replyTo: botThreadTarget.replyTo,
                            botTopic: botThreadTarget.botTopic,
                            attachmentName: commandResult.attachmentName || null,
                            attachmentURL: commandResult.attachmentURL || null,
                            reactions: []
                        };
                        this.rememberBotTurn(user.roomId, socket.id, 'assistant', reply);
                        this.storeRoomMessage(user.roomId, botMessage);
                        setTimeout(() => {
                            this.io.to(user.roomId).emit('chat-message', botMessage);
                        }, 250);
                    }
            });

            // Direct messages (DMs)
            socket.on('direct-message', async (data) => {
                const user = this.users.get(socket.id);
                const { targetUserId, message: msgContent, replyTo } = data;

                if (user && targetUserId) {
                    const outboundMessage = {
                        id: uuidv4(),
                        senderId: socket.id,
                        senderName: user.name,
                        receiverId: targetUserId,
                        message: msgContent,
                        content: msgContent,
                        timestamp: new Date(),
                        isAuthenticated: user.isAuthenticated || false,
                        type: data.type || 'text',
                        replyTo: replyTo || null,
                        attachmentId: data.attachmentId || null,
                        attachmentName: data.attachmentName || null,
                        attachmentURL: data.attachmentURL || data.attachmentUrl || null,
                        attachmentCaption: data.attachmentCaption || data.caption || null,
                        attachmentExpiresAt: data.attachmentExpiresAt || null,
                        attachmentRemoved: !!data.attachmentRemoved,
                        reactions: [],
                        read: false
                    };

                    const dmTargetLabel = targetUserId.startsWith('bot:') ? 'VoiceLink Bot' : 'this conversation';
                    const sanitizedResult = await this.sanitizeMessageLinks(outboundMessage, {
                        actorName: user.name,
                        roomName: dmTargetLabel
                    });
                    const message = sanitizedResult.message;

                    // Store DM
                    this.storeDirectMessage(socket.id, targetUserId, message);

                    // Send to both sender and receiver
                    socket.emit('direct-message', message);
                    if (sanitizedResult.notice) {
                        this.storeDirectMessage(socket.id, targetUserId, sanitizedResult.notice);
                        socket.emit('direct-message', sanitizedResult.notice);
                    }

                    if (targetUserId.startsWith('bot:')) {
                        const roomId = targetUserId.slice(4);
                        if (message.attachmentName || message.attachmentURL) {
                            console.log('[Bot Attachment] DM attachment received for bot', {
                                roomId,
                                sender: user.name,
                                attachmentName: message.attachmentName || null,
                                attachmentURL: message.attachmentURL || null
                            });
                        }
                        this.rememberBotTurn(roomId, socket.id, 'user', msgContent);
                        let reply = await this.buildBotTextReply(user, roomId, msgContent);
                        const generatedReply = await this.generateBotOllamaReply(user, roomId, msgContent);
                        if (generatedReply) {
                            reply = generatedReply;
                        }
                        const attachmentReply = message.attachmentName || message.attachmentURL
                            ? await this.buildBotAttachmentReply(user, message)
                            : null;
                        if (attachmentReply) {
                            reply = attachmentReply;
                        }

                        const botReply = {
                            id: uuidv4(),
                            senderId: targetUserId,
                            senderName: 'VoiceLink Bot',
                            receiverId: socket.id,
                            message: reply,
                            content: reply,
                            timestamp: new Date(),
                            isAuthenticated: true,
                            isBot: true,
                            authProvider: 'voicelink_bot',
                            type: 'text',
                            replyTo: message.id,
                            reactions: [],
                            read: false
                        };
                        this.rememberBotTurn(roomId, socket.id, 'assistant', reply);
                        this.storeDirectMessage(targetUserId, socket.id, botReply);
                        socket.emit('direct-message', botReply);
                    } else {
                        this.io.to(targetUserId).emit('direct-message', message);
                        if (sanitizedResult.notice) {
                            this.io.to(targetUserId).emit('direct-message', sanitizedResult.notice);
                        }
                    }
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

                const { audioData, timestamp, sampleRate, channels } = data;
                user.isSpeaking = !user.audioSettings?.muted;
                user.lastActiveAt = new Date();

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
                                sampleRate: sampleRate,
                                channels: channels || this.audioBuffers.get(socket.id)?.channels || 2
                            });
                        }
                    });
                    this.emitRoomUsersSnapshot(user.roomId);
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

            // Get users in a specific room
            socket.on('get-room-users', (data) => {
                const { roomId } = data;
                const room = this.rooms.get(roomId);
                if (room) {
                    const liveUsers = this.normalizeRoomUsers(roomId);
                    socket.emit('room-users', {
                        roomId,
                        users: liveUsers.map(u => this.serializeRoomUser(u, roomId)).filter(Boolean),
                        count: liveUsers.length
                    });
                }
            });

            // Disconnect handling
            socket.on('disconnect', () => {
                this.unregisterSocketSession(socket.id);
                const user = this.users.get(socket.id);
                if (user) {
                    const room = this.rooms.get(user.roomId);
                    if (room) {
                        const userName = user.name;
                        room.users = room.users.filter(u => u.id !== socket.id);
                        const liveUsers = this.normalizeRoomUsers(user.roomId);

                        // Notify others user left
                        socket.to(user.roomId).emit('user-left', {
                            userId: socket.id,
                            userName: userName
                        });
                        this.emitRoomSystemMessage(
                            user.roomId,
                            `${userName} left the room.`
                        );

                    // Broadcast updated user count
                    this.emitRoomUsersSnapshot(user.roomId);

                        console.log(`User ${userName} left room ${room.name} (${liveUsers.length} users remain)`);

                        if (liveUsers.length === 0) {
                            this.cleanupRoomMessagesIfEmpty(user.roomId);
                        }

                        // Clean up empty rooms (but keep default rooms)
                        if (liveUsers.length === 0 && !room.isDefault) {
                            this.rooms.delete(user.roomId);
                            console.log(`Room ${room.name} deleted (empty)`);
                        }

                        this.emitRoomListToClients();
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

    // ==================== Message Persistence Methods ====================

    /**
     * Store a room message
     * Messages from authenticated users persist forever
     * Messages from guests expire after 24 hours
     */
    storeRoomMessage(roomId, message) {
        const settings = this.getMessageSettingsConfig();
        if (!settings.keepRoomMessages) {
            return;
        }
        if (!this.roomMessages.has(roomId)) {
            this.roomMessages.set(roomId, []);
        }

        const messages = this.roomMessages.get(roomId);
        messages.push(message);
        this.trimMessagesToCap(messages, settings.roomMessageCap);
    }

    createRoomSystemMessage(roomId, message, overrides = {}) {
        return {
            id: uuidv4(),
            userId: `system:${roomId}`,
            userName: 'System',
            message,
            timestamp: new Date(),
            isAuthenticated: true,
            isBot: true,
            type: 'system',
            reactions: [],
            ...overrides
        };
    }

    emitRoomSystemMessage(roomId, message, overrides = {}) {
        if (!roomId || !message) return null;
        const systemMessage = this.createRoomSystemMessage(roomId, message, overrides);
        this.storeRoomMessage(roomId, systemMessage);
        this.io.to(roomId).emit('chat-message', systemMessage);
        return systemMessage;
    }

    /**
     * Store a direct message
     * Uses sorted user IDs as key for consistent lookup
     */
    storeDirectMessage(senderId, receiverId, message) {
        const settings = this.getMessageSettingsConfig();
        if (!settings.keepDirectMessages) {
            return;
        }
        const dmKey = [senderId, receiverId].sort().join('_');

        if (!this.directMessages.has(dmKey)) {
            this.directMessages.set(dmKey, []);
        }

        const messages = this.directMessages.get(dmKey);
        messages.push(message);
        this.trimMessagesToCap(messages, settings.directMessageCap);
    }

    getDirectMessageMeta(dmKey) {
        return {
            visibility: this.directMessageVisibility.get(dmKey) || {},
            purgeRequests: this.directMessagePurgeRequests.get(dmKey) || {}
        };
    }

    hideDirectMessagesForUser(userId1, userId2, viewerId, clearBefore = null) {
        const dmKey = [userId1, userId2].sort().join('_');
        const visibility = { ...(this.directMessageVisibility.get(dmKey) || {}) };
        visibility[String(viewerId || '').trim()] = clearBefore || new Date().toISOString();
        this.directMessageVisibility.set(dmKey, visibility);
        return visibility;
    }

    restoreDirectMessagesForUser(userId1, userId2, viewerId) {
        const dmKey = [userId1, userId2].sort().join('_');
        const visibility = { ...(this.directMessageVisibility.get(dmKey) || {}) };
        delete visibility[String(viewerId || '').trim()];
        if (Object.keys(visibility).length === 0) {
            this.directMessageVisibility.delete(dmKey);
            return {};
        }
        this.directMessageVisibility.set(dmKey, visibility);
        return visibility;
    }

    requestDirectMessagePurge(userId1, userId2, viewerId, clearBefore = null, options = {}) {
        const dmKey = [userId1, userId2].sort().join('_');
        const participants = [String(userId1 || '').trim(), String(userId2 || '').trim()].filter(Boolean);
        const requester = String(viewerId || '').trim();
        if (!participants.includes(requester)) {
            return { success: false, reason: 'invalid_requester' };
        }

        const purgeRequests = { ...(this.directMessagePurgeRequests.get(dmKey) || {}) };
        purgeRequests[requester] = {
            clearBefore: clearBefore || new Date().toISOString(),
            removeAttachments: options.removeAttachments === true
        };
        this.directMessagePurgeRequests.set(dmKey, purgeRequests);

        const approvals = participants.filter(participant => purgeRequests[participant]);
        if (approvals.length < participants.length) {
            return { success: true, pending: true, purgeRequests };
        }

        const cutoffMs = approvals
            .map(participant => new Date(purgeRequests[participant].clearBefore).getTime())
            .filter(Number.isFinite)
            .reduce((latest, value) => Math.max(latest, value), 0);
        const removeAttachments = approvals.every(participant => purgeRequests[participant].removeAttachments === true);
        const cutoffIso = new Date(cutoffMs || Date.now()).toISOString();
        const messages = this.directMessages.get(dmKey) || [];
        const retained = messages.reduce((acc, message) => {
            const timestamp = new Date(message.timestamp).getTime();
            const hasAttachment = !!(message.attachmentId || message.attachmentName || message.attachmentURL);
            const shouldPurge = Number.isFinite(timestamp) && timestamp <= cutoffMs;
            if (!shouldPurge) {
                acc.push(message);
                return acc;
            }
            if (!removeAttachments && hasAttachment) {
                acc.push({
                    ...message,
                    content: '[message history removed]',
                    message: '[message history removed]',
                    attachmentRemoved: false,
                    historyRedacted: true
                });
            }
            return acc;
        }, []);
        this.directMessages.set(dmKey, retained);
        this.directMessagePurgeRequests.delete(dmKey);
        this.directMessageVisibility.delete(dmKey);
        return {
            success: true,
            pending: false,
            purged: true,
            cutoff: cutoffIso,
            removeAttachments,
            removedCount: Math.max(0, messages.length - retained.length)
        };
    }

    /**
     * Get room messages with optional pagination
     */
    getRoomMessages(roomId, limit = 50, before = null) {
        const settings = this.getMessageSettingsConfig();
        const requestedLimit = Math.min(settings.scrollbackLimit, Math.max(1, Number(limit || settings.initialLoadCount)));
        const retentionMs = this.getMessageExpiryMs(true);
        const guestRetentionMs = this.getMessageExpiryMs(false);
        const now = Date.now();
        const messages = (this.roomMessages.get(roomId) || []).filter(message => {
            const timestamp = new Date(message.timestamp).getTime();
            if (!Number.isFinite(timestamp)) return true;
            const expiryMs = message.isAuthenticated ? retentionMs : guestRetentionMs;
            return (now - timestamp) < expiryMs;
        });

        let filtered = messages;
        if (before) {
            const beforeIdx = messages.findIndex(m => m.id === before);
            if (beforeIdx > 0) {
                filtered = messages.slice(0, beforeIdx);
            }
        }

        return filtered.slice(-requestedLimit);
    }

    /**
     * Get direct messages between two users
     */
    getDirectMessages(userId1, userId2, limit = 50, before = null, viewerId = null) {
        const settings = this.getMessageSettingsConfig();
        const requestedLimit = Math.min(settings.scrollbackLimit, Math.max(1, Number(limit || settings.initialLoadCount)));
        const dmKey = [userId1, userId2].sort().join('_');
        const retentionMs = this.getMessageExpiryMs(true);
        const guestRetentionMs = this.getMessageExpiryMs(false);
        const now = Date.now();
        const viewer = String(viewerId || userId1 || '').trim();
        const hiddenBeforeValue = this.getDirectMessageMeta(dmKey).visibility[viewer];
        const hiddenBeforeMs = hiddenBeforeValue ? new Date(hiddenBeforeValue).getTime() : 0;
        const messages = (this.directMessages.get(dmKey) || []).filter(message => {
            const timestamp = new Date(message.timestamp).getTime();
            if (!Number.isFinite(timestamp)) return true;
            const expiryMs = message.isAuthenticated ? retentionMs : guestRetentionMs;
            return (now - timestamp) < expiryMs && (!hiddenBeforeMs || timestamp > hiddenBeforeMs);
        });

        let filtered = messages;
        if (before) {
            const beforeIdx = messages.findIndex(m => m.id === before);
            if (beforeIdx > 0) {
                filtered = messages.slice(0, beforeIdx);
            }
        }

        return filtered.slice(-requestedLimit);
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
        const settings = this.getMessageSettingsConfig();
        const now = Date.now();
        let removedCount = 0;

        // Clean room messages
        for (const [roomId, messages] of this.roomMessages.entries()) {
            const originalLength = messages.length;
            const filtered = messages.filter(msg => {
                const msgTime = new Date(msg.timestamp).getTime();
                if (!Number.isFinite(msgTime)) return true;
                const expiryMs = msg.isAuthenticated
                    ? settings.authenticatedRetentionDays * 24 * 60 * 60 * 1000
                    : settings.guestRetentionHours * 60 * 60 * 1000;
                return (now - msgTime) < expiryMs;
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
                const msgTime = new Date(msg.timestamp).getTime();
                if (!Number.isFinite(msgTime)) return true;
                const expiryMs = msg.isAuthenticated
                    ? settings.authenticatedRetentionDays * 24 * 60 * 60 * 1000
                    : settings.guestRetentionHours * 60 * 60 * 1000;
                return (now - msgTime) < expiryMs;
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


    /**
     * Load rooms from persistent storage on startup
     */
    loadPersistedRooms() {
        try {
            const roomsFile = path.join(__dirname, '../../data/rooms.json');
            if (fs.existsSync(roomsFile)) {
                const roomsData = JSON.parse(fs.readFileSync(roomsFile, 'utf8'));
                let loaded = 0;
                for (const roomData of roomsData) {
                    roomData.users = []; // Reset users on load
                    this.rooms.set(roomData.id, roomData);
                    loaded++;
                }
                console.log(`[Rooms] Loaded ${loaded} rooms from storage`);
            } else {
                console.log('[Rooms] No saved rooms found, will generate defaults');
                this.generateDefaultRoomsInternal();
            }
        } catch (error) {
            console.error('[Rooms] Failed to load rooms:', error.message);
            this.generateDefaultRoomsInternal();
        }
    }

    /**
     * Save rooms to persistent storage
     */
    saveRoomsToDisk() {
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
            try {
                databaseStorage.mirrorJsonFile('rooms', 'rooms', path.join(dataDir, 'rooms.json'), roomsData);
            } catch (mirrorError) {
                console.warn('[Rooms] Database mirror skipped:', mirrorError.message);
            }
            console.log(`[Rooms] Saved ${roomsData.length} rooms to storage`);
        } catch (error) {
            console.error('[Rooms] Failed to save rooms:', error.message);
        }
    }

    /**
     * Internal method to generate default rooms
     */
    generateDefaultRoomsInternal() {
        const templates = [
            { template: 'social', name: 'General Chat', maxUsers: 50 },
            { template: 'social', name: 'Music Lounge', maxUsers: 20 },
            { template: 'workspace', name: 'Gaming Voice', maxUsers: 10 },
            { template: 'social', name: 'Chill Zone', maxUsers: 30 },
            { template: 'workspace', name: 'Tech Talk', maxUsers: 25 }
        ];

        for (const config of templates) {
            const exists = Array.from(this.rooms.values()).some(
                r => r.name.toLowerCase() === config.name.toLowerCase()
            );
            if (!exists) {
                const roomId = 'default_' + Date.now() + '_' + Math.random().toString(36).substr(2, 6);
                const room = {
                    id: roomId,
                    name: config.name,
                    description: '',
                    password: null,
                    maxUsers: config.maxUsers,
                    users: [],
                    visibility: 'public',
                    accessType: 'hybrid',
                    allowEmbed: true,
                    visibleToGuests: true,
                    isDefault: true,
                    template: config.template,
                    serverSource: 'local',
                    locked: false,
                    lockedAt: null,
                    createdAt: new Date().toISOString()
                };
                this.rooms.set(roomId, room);
            }
        }
        console.log('[Rooms] Generated default rooms');
        this.saveRoomsToDisk();
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
