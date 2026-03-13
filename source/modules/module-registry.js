/**
 * VoiceLink Module Registry
 *
 * Manages installable modules for VoiceLink servers.
 * Modules can be installed/uninstalled via admin settings.
 */

const fs = require('fs');
const path = require('path');
const { URL } = require('url');
const { deployConfig } = require('../config/deploy-config');
const { DatabaseStorageManager } = require('../services/database-storage');

const MODULE_BUNDLE_API_PATH = '/api/modules';
const MODULE_SYNC_TIMEOUT_MS = 10000;
const MODULE_FILE_SIZE_LIMIT_BYTES = 2 * 1024 * 1024;
const databaseStorage = new DatabaseStorageManager({ deployConfig, appRoot: path.join(__dirname, '../..') });

// Module categories
const CATEGORIES = {
    SECURITY: 'security',
    COMMUNICATION: 'communication',
    INTEGRATION: 'integration',
    SUPPORT: 'support',
    MEDIA: 'media',
    ANALYTICS: 'analytics'
};

const CORE_MODULE_IDS = new Set([
    'updater',
    'internal-scheduler'
]);

const REQUIRED_MODULE_IDS = new Set([
    'updater',
    'internal-scheduler',
    'copyparty-file-transfer',
    'deployment-manager',
    'two-factor-auth',
    'support-system',
    'vm-manager',
    'whmcs-integration'
]);

const DEFAULT_INSTALL_MODULE_IDS = new Set([
    'copyparty-file-transfer',
    'deployment-manager',
    'media-rooms',
    'two-factor-auth',
    'support-system',
    'vm-manager',
    'whmcs-integration'
]);

// Available modules registry
const AVAILABLE_MODULES = {
    'two-factor-auth': {
        id: 'two-factor-auth',
        name: 'Two-Factor Authentication',
        description: 'Secure login with TOTP, Passkeys, SMS, or Email verification',
        version: '1.0.0',
        category: CATEGORIES.SECURITY,
        author: 'VoiceLink',
        recommended: true,
        popular: true,
        dependencies: [],
        configurable: true,
        features: [
            'TOTP Authenticator (Google Auth, Authy, etc.)',
            'Passkey/WebAuthn support',
            'SMS verification via FlexPBX',
            'Email code verification',
            'Admin enforcement controls',
            'International fallback options'
        ],
        defaultConfig: {
            enabled: false,
            methods: {
                totp: { enabled: true, issuer: 'VoiceLink' },
                passkey: { enabled: true },
                sms: { enabled: false, provider: 'flexpbx' },
                email: { enabled: true }
            },
            enforcement: {
                requireForAdmins: false,
                requireForUsers: false,
                allowUserChoice: true
            },
            codeSettings: {
                totpWindow: 1,        // Accept codes 30s before/after
                smsCodeLength: 6,
                emailCodeLength: 6,
                codeExpiryMinutes: 10, // Extended for Ollama delays
                maxAttempts: 5
            }
        }
    },

    'support-system': {
        id: 'support-system',
        name: 'Support System',
        description: 'Built-in support tickets, live chat, and help desk features',
        version: '1.0.0',
        category: CATEGORIES.SUPPORT,
        author: 'VoiceLink',
        recommended: true,
        popular: true,
        dependencies: [],
        configurable: true,
        features: [
            'Support ticket system',
            'Live chat support queue',
            'Knowledge base integration',
            'Support agent assignment',
            'Ticket priority levels',
            'Email notifications',
            'Support analytics'
        ],
        defaultConfig: {
            enabled: false,
            tickets: {
                enabled: true,
                autoAssign: true,
                priorities: ['low', 'medium', 'high', 'urgent'],
                categories: ['technical', 'billing', 'feature-request', 'bug-report', 'general']
            },
            liveChat: {
                enabled: true,
                maxQueueSize: 10,
                offlineMessage: true
            },
            notifications: {
                emailOnNewTicket: true,
                emailOnReply: true,
                emailOnClose: true
            }
        }
    },

    'voice-moderation': {
        id: 'voice-moderation',
        name: 'Voice Moderation',
        description: 'AI-powered voice moderation and content filtering',
        version: '1.0.0',
        category: CATEGORIES.SECURITY,
        author: 'VoiceLink',
        recommended: false,
        popular: false,
        dependencies: [],
        configurable: true,
        features: [
            'Profanity detection',
            'Volume level monitoring',
            'Automatic muting',
            'Warning system',
            'Moderation logs'
        ],
        defaultConfig: {
            enabled: false,
            profanityFilter: false,
            volumeLimit: { enabled: false, maxDb: -10 },
            autoMute: { enabled: false, duration: 60 }
        }
    },

    'room-scheduling': {
        id: 'room-scheduling',
        name: 'Room Scheduling',
        description: 'Schedule rooms for meetings and events',
        version: '1.0.0',
        category: CATEGORIES.COMMUNICATION,
        author: 'VoiceLink',
        recommended: true,
        popular: false,
        dependencies: [],
        configurable: true,
        features: [
            'Calendar integration',
            'Recurring events',
            'Room reservations',
            'Email reminders',
            'iCal export'
        ],
        defaultConfig: {
            enabled: false,
            calendarSync: false,
            reminders: { enabled: true, minutesBefore: [15, 60] }
        }
    },

    'analytics-dashboard': {
        id: 'analytics-dashboard',
        name: 'Analytics Dashboard',
        description: 'Usage analytics and server statistics',
        version: '1.0.0',
        category: CATEGORIES.ANALYTICS,
        author: 'VoiceLink',
        recommended: true,
        popular: true,
        dependencies: [],
        configurable: true,
        features: [
            'User activity tracking',
            'Room usage statistics',
            'Peak hours analysis',
            'Bandwidth monitoring',
            'Export reports'
        ],
        defaultConfig: {
            enabled: false,
            trackUsers: true,
            trackRooms: true,
            retentionDays: 30
        }
    },

    'webhook-integrations': {
        id: 'webhook-integrations',
        name: 'Webhook Integrations',
        description: 'Connect VoiceLink to external services via webhooks',
        version: '1.0.0',
        category: CATEGORIES.INTEGRATION,
        author: 'VoiceLink',
        recommended: false,
        popular: false,
        dependencies: [],
        configurable: true,
        features: [
            'Discord webhooks',
            'Slack notifications',
            'Custom webhook endpoints',
            'Event filtering',
            'Retry logic'
        ],
        defaultConfig: {
            enabled: false,
            webhooks: []
        }
    },

    'recording-module': {
        id: 'recording-module',
        name: 'Room Recording',
        description: 'Record voice chat sessions (requires consent)',
        version: '1.0.0',
        category: CATEGORIES.MEDIA,
        author: 'VoiceLink',
        recommended: false,
        popular: false,
        dependencies: [],
        configurable: true,
        features: [
            'Room recording',
            'Consent management',
            'Recording storage',
            'Playback interface',
            'Export options'
        ],
        defaultConfig: {
            enabled: false,
            requireConsent: true,
            storageDir: 'recordings',
            maxDurationMinutes: 120,
            autoDelete: { enabled: true, afterDays: 30 }
        }
    },

    'backup-manager': {
        id: 'backup-manager',
        name: 'Backup Manager',
        description: 'Automated backups and disaster recovery',
        version: '1.0.0',
        category: CATEGORIES.SECURITY,
        author: 'VoiceLink',
        recommended: true,
        popular: false,
        dependencies: [],
        configurable: true,
        features: [
            'Scheduled backups',
            'Remote backup storage',
            'One-click restore',
            'Backup verification',
            'Retention policies'
        ],
        defaultConfig: {
            enabled: false,
            schedule: 'daily',
            retention: 7,
            includeMedia: false,
            remoteStorage: null
        }
    },

    'vm-manager': {
        id: 'vm-manager',
        name: 'VM Manager',
        description: 'Manage libvirt/QEMU virtual machines with auto-detection and assignment',
        version: '1.0.0',
        category: CATEGORIES.INTEGRATION,
        author: 'VoiceLink',
        recommended: true,
        popular: true,
        dependencies: [],
        configurable: true,
        features: [
            'VM creation and management',
            'Auto-detect running VMs',
            'Auto-assign to users/modules',
            'VNC console access',
            'Snapshots and backups',
            'Resource monitoring',
            'WHMCS integration'
        ],
        defaultConfig: {
            enabled: false,
            apiUrl: 'http://localhost:8080',
            apiKey: '',
            autoDetect: {
                enabled: true,
                interval: 300000
            },
            autoAssign: {
                enabled: true,
                defaultOwner: null
            }
        }
    },

    'jellyfin': {
        id: 'jellyfin',
        name: 'Jellyfin Media Streaming',
        description: 'Enable Jellyfin integration for shared media libraries, streaming, queueing, and room playback controls',
        version: '1.0.0',
        category: CATEGORIES.MEDIA,
        author: 'VoiceLink',
        recommended: true,
        popular: true,
        dependencies: [],
        configurable: true,
        features: [
            'Remote Jellyfin server registration',
            'Room streaming and playback queue',
            'Library sync and discovery',
            'Per-room bot controls',
            'Backup and restore helpers',
            'Multi-node media federation support'
        ],
        defaultConfig: {
            enabled: false,
            allowRemoteServers: true,
            allowLocalBundled: true,
            defaultRooms: [],
            requireAdminForServerChanges: true
        }
    },

    'ecripto': {
        id: 'ecripto',
        name: 'eCrypto Wallet Integration',
        description: 'Enable eCrypto wallet account linking, wallet-auth, and wallet actions from VoiceLink accounts',
        version: '1.0.0',
        category: CATEGORIES.INTEGRATION,
        author: 'VoiceLink',
        recommended: true,
        popular: true,
        dependencies: [],
        configurable: true,
        features: [
            'Wallet link and unlink per account',
            'Wallet-based sign-in helpers',
            'User wallet metadata sync',
            'Admin policy control for wallet features',
            'Cross-instance wallet identity support'
        ],
        defaultConfig: {
            enabled: false,
            allowWalletLink: true,
            allowWalletAuth: true,
            requireVerifiedAccount: false,
            allowedProviders: ['ecripto']
        }
    },

    'whmcs-integration': {
        id: 'whmcs-integration',
        name: 'WHMCS Integration',
        description: 'Connect with WHMCS for VM provisioning and service management',
        version: '1.0.0',
        category: CATEGORIES.INTEGRATION,
        author: 'VoiceLink',
        recommended: true,
        popular: true,
        dependencies: ['vm-manager'],
        configurable: true,
        features: [
            'Auto-provision VMs for WHMCS services',
            'Sync VM assignments with clients',
            'Webhook handlers for service actions',
            'Client account lookup',
            'Service status updates',
            'IP address assignment to services'
        ],
        defaultConfig: {
            enabled: false,
            whmcsUrl: '',
            apiIdentifier: '',
            apiSecret: '',
            vmProvisioning: {
                enabled: false,
                productIds: []
            },
            cacheTTL: 300000
        }
    },

    'copyparty-file-transfer': {
        id: 'copyparty-file-transfer',
        name: 'CopyParty File Transfers',
        description: 'Default HTTPS file transfer provider with resumable link sharing, pause/resume controls, and transfer reminders',
        version: '1.0.0',
        category: CATEGORIES.COMMUNICATION,
        author: 'VoiceLink',
        recommended: true,
        popular: true,
        dependencies: [],
        configurable: true,
        features: [
            'CopyParty-backed HTTPS file share links',
            'Pause and resume transfer workflows',
            'Pending transfer reminders',
            'Protected links for direct and room sharing'
        ],
        defaultConfig: {
            enabled: true,
            provider: 'copyparty',
            allowFallbackProviders: true,
            resumableTransfers: true,
            reminders: {
                enabled: true,
                firstReminderMinutes: 45,
                repeatEveryMinutes: 120
            }
        }
    },

    'deployment-manager': {
        id: 'deployment-manager',
        name: 'Deployment Manager',
        description: 'Deploy fresh VoiceLink installs or update existing ones over SFTP, SMB, HTTP, or HTTPS and bootstrap API/federation settings',
        version: '1.0.0',
        category: CATEGORIES.INTEGRATION,
        author: 'VoiceLink',
        recommended: true,
        popular: true,
        dependencies: [],
        configurable: true,
        features: [
            'Build deployment bundles from live server config',
            'Upload bundles by SFTP, SMB, HTTP, or HTTPS',
            'Bootstrap existing VoiceLink installs through the remote API',
            'Email owners with deployment and getting-started details',
            'Keep linked server API and federation settings aligned'
        ],
        defaultConfig: {
            enabled: true,
            allowFreshInstallBundles: true,
            allowExistingInstallBootstrap: true,
            defaultTransports: ['sftp', 'smb', 'http', 'https'],
            emailOwner: {
                enabled: true,
                includeGettingStarted: true
            }
        }
    },

    'media-rooms': {
        id: 'media-rooms',
        name: 'Media Rooms',
        description: 'Optional room media state, now-playing metadata, and playback coordination when server-side streaming is enabled',
        version: '1.0.0',
        category: CATEGORIES.MEDIA,
        author: 'VoiceLink',
        recommended: true,
        popular: true,
        dependencies: [],
        configurable: true,
        features: [
            'Per-room now playing state',
            'Background media routing',
            'Playback metadata reporting',
            'Room media coordination'
        ],
        defaultConfig: {
            enabled: false,
            watchdog: {
                enabled: false,
                intervalMinutes: 5,
                adminEmails: [],
                targets: [],
                notifications: {
                    email: true,
                    pushover: false
                }
            }
        }
    },

    updater: {
        id: 'updater',
        name: 'Updater',
        description: 'Core update delivery, manifest handling, and installer coordination',
        version: '1.0.0',
        category: CATEGORIES.INTEGRATION,
        author: 'VoiceLink',
        recommended: true,
        popular: true,
        dependencies: [],
        configurable: true,
        core: true,
        features: [
            'Update manifest publishing',
            'Client update coordination',
            'Release metadata reporting'
        ],
        defaultConfig: {
            enabled: true
        }
    },

    'internal-scheduler': {
        id: 'internal-scheduler',
        name: 'Internal Scheduler',
        description: 'Core scheduled jobs for maintenance, cleanup, and timed automation',
        version: '1.0.0',
        category: CATEGORIES.COMMUNICATION,
        author: 'VoiceLink',
        recommended: true,
        popular: false,
        dependencies: [],
        configurable: true,
        core: true,
        features: [
            'Scheduled maintenance jobs',
            'Timed room automation',
            'Recurring server tasks'
        ],
        defaultConfig: {
            enabled: true
        }
    }
};

class ModuleRegistry {
    constructor(configDir) {
        this.configDir = configDir || path.join(__dirname, '../../data');
        this.modulesConfigFile = path.join(this.configDir, 'modules.json');
        this.installedModules = this.loadInstalledModules();
        this.ensureCoreModulesRegistered();
        this.ensureDefaultModulesInstalled();
    }

    loadInstalledModules() {
        try {
            if (fs.existsSync(this.modulesConfigFile)) {
                const loaded = JSON.parse(fs.readFileSync(this.modulesConfigFile, 'utf8'));
                if (!loaded || typeof loaded !== 'object') {
                    return { installed: {}, installOrder: [] };
                }
                if (!loaded.installed || typeof loaded.installed !== 'object') {
                    loaded.installed = {};
                }
                if (!Array.isArray(loaded.installOrder)) {
                    loaded.installOrder = [];
                }
                return loaded;
            }
        } catch (e) {
            console.error('[ModuleRegistry] Error loading modules config:', e.message);
        }
        return { installed: {}, installOrder: [] };
    }

    saveInstalledModules() {
        try {
            if (!fs.existsSync(this.configDir)) {
                fs.mkdirSync(this.configDir, { recursive: true });
            }
            fs.writeFileSync(this.modulesConfigFile, JSON.stringify(this.installedModules, null, 2));
            try {
                databaseStorage.mirrorJsonFile('modules', 'modules-config', this.modulesConfigFile, this.installedModules);
            } catch (mirrorError) {
                console.warn('[ModuleRegistry] Database mirror skipped:', mirrorError.message);
            }
        } catch (e) {
            console.error('[ModuleRegistry] Error saving modules config:', e.message);
        }
    }

    ensureCoreModulesRegistered() {
        let changed = false;

        for (const moduleId of CORE_MODULE_IDS) {
            const module = AVAILABLE_MODULES[moduleId];
            if (!module) continue;

            if (!this.installedModules.installed[moduleId]) {
                this.installedModules.installed[moduleId] = {
                    installedAt: new Date('2026-01-01T00:00:00.000Z').toISOString(),
                    config: { ...module.defaultConfig, enabled: true }
                };
                changed = true;
            } else if (this.installedModules.installed[moduleId]?.config?.enabled !== true) {
                this.installedModules.installed[moduleId].config = {
                    ...module.defaultConfig,
                    ...this.installedModules.installed[moduleId].config,
                    enabled: true
                };
                changed = true;
            }

            if (!this.installedModules.installOrder.includes(moduleId)) {
                this.installedModules.installOrder.unshift(moduleId);
                changed = true;
            }
        }

        if (changed) {
            this.saveInstalledModules();
        }
    }

    ensureDefaultModulesInstalled() {
        let changed = false;

        for (const moduleId of DEFAULT_INSTALL_MODULE_IDS) {
            const module = AVAILABLE_MODULES[moduleId];
            if (!module) continue;
            const required = REQUIRED_MODULE_IDS.has(moduleId);

            if (!this.installedModules.installed[moduleId]) {
                this.installedModules.installed[moduleId] = {
                    installedAt: new Date().toISOString(),
                    config: { ...module.defaultConfig, enabled: required ? true : (module.defaultConfig?.enabled ?? false) }
                };
                this.installedModules.installOrder.push(moduleId);
                changed = true;
                continue;
            }

            if (required && this.installedModules.installed[moduleId]?.config?.enabled !== true) {
                this.installedModules.installed[moduleId].config = {
                    ...module.defaultConfig,
                    ...this.installedModules.installed[moduleId].config,
                    enabled: true
                };
                changed = true;
            }

            if (!this.installedModules.installOrder.includes(moduleId)) {
                this.installedModules.installOrder.push(moduleId);
                changed = true;
            }
        }

        if (changed) {
            this.saveInstalledModules();
        }
    }

    /**
     * Get all available modules
     */
    getAvailableModules(options = {}) {
        const { sortBy = 'recommended', category = null } = options;

        let modules = Object.values(AVAILABLE_MODULES);

        // Filter by category
        if (category) {
            modules = modules.filter(m => m.category === category);
        }

        // Add installed status
        modules = modules.map(m => ({
            ...m,
            required: REQUIRED_MODULE_IDS.has(m.id),
            installed: CORE_MODULE_IDS.has(m.id) || !!this.installedModules.installed[m.id],
            config: this.installedModules.installed[m.id]?.config || m.defaultConfig
        }));

        // Sort
        switch (sortBy) {
            case 'recommended':
                modules.sort((a, b) => (b.recommended ? 1 : 0) - (a.recommended ? 1 : 0));
                break;
            case 'popular':
                modules.sort((a, b) => (b.popular ? 1 : 0) - (a.popular ? 1 : 0));
                break;
            case 'recent':
                // Sort by install date if installed, otherwise alphabetically
                modules.sort((a, b) => {
                    const aDate = this.installedModules.installed[a.id]?.installedAt || 0;
                    const bDate = this.installedModules.installed[b.id]?.installedAt || 0;
                    return bDate - aDate;
                });
                break;
            case 'name':
                modules.sort((a, b) => a.name.localeCompare(b.name));
                break;
            case 'category':
                modules.sort((a, b) => a.category.localeCompare(b.category));
                break;
        }

        return modules;
    }

    /**
     * Get installed modules
     */
    getInstalledModules() {
        const seen = new Set();

        return this.installedModules.installOrder
            .filter(id => {
                if (seen.has(id)) return false;
                seen.add(id);
                return true;
            })
            .map(id => {
                const module = AVAILABLE_MODULES[id];
                const installed = this.installedModules.installed[id];
                if (!module || !installed) return null;

                return {
                    ...module,
                    ...installed,
                    required: REQUIRED_MODULE_IDS.has(id),
                    enabled: installed?.config?.enabled ?? module.defaultConfig?.enabled ?? false,
                    installed: true
                };
            })
            .filter(Boolean);
    }

    /**
     * Get module by ID
     */
    getModule(moduleId) {
        const module = AVAILABLE_MODULES[moduleId];
        if (!module) return null;

        return {
            ...module,
            required: REQUIRED_MODULE_IDS.has(moduleId),
            installed: !!this.installedModules.installed[moduleId],
            config: this.installedModules.installed[moduleId]?.config || module.defaultConfig
        };
    }

    /**
     * Install a module
     */
    installModule(moduleId, customConfig = {}) {
        const module = AVAILABLE_MODULES[moduleId];
        if (!module) {
            return { success: false, error: 'Module not found' };
        }

        if (this.installedModules.installed[moduleId]) {
            return { success: false, error: 'Module already installed' };
        }

        // Check dependencies
        for (const dep of module.dependencies) {
            if (!this.installedModules.installed[dep]) {
                return { success: false, error: `Missing dependency: ${dep}` };
            }
        }

        // Install module
        this.installedModules.installed[moduleId] = {
            installedAt: Date.now(),
            config: { ...module.defaultConfig, ...customConfig, enabled: true }
        };
        this.installedModules.installOrder.push(moduleId);
        this.saveInstalledModules();

        console.log(`[ModuleRegistry] Installed module: ${module.name}`);
        return { success: true, module: this.getModule(moduleId) };
    }

    /**
     * Uninstall a module
     */
    uninstallModule(moduleId) {
        if (REQUIRED_MODULE_IDS.has(moduleId)) {
            return { success: false, error: 'Required modules cannot be removed' };
        }

        if (!this.installedModules.installed[moduleId]) {
            return { success: false, error: 'Module not installed' };
        }

        // Check if other modules depend on this one
        for (const [id, mod] of Object.entries(AVAILABLE_MODULES)) {
            if (this.installedModules.installed[id] && mod.dependencies.includes(moduleId)) {
                return { success: false, error: `Cannot uninstall: ${mod.name} depends on this module` };
            }
        }

        delete this.installedModules.installed[moduleId];
        this.installedModules.installOrder = this.installedModules.installOrder.filter(id => id !== moduleId);
        this.saveInstalledModules();

        console.log(`[ModuleRegistry] Uninstalled module: ${moduleId}`);
        return { success: true };
    }

    /**
     * Update module configuration
     */
    updateModuleConfig(moduleId, config) {
        if (!this.installedModules.installed[moduleId]) {
            return { success: false, error: 'Module not installed' };
        }

        this.installedModules.installed[moduleId].config = {
            ...this.installedModules.installed[moduleId].config,
            ...config
        };
        this.saveInstalledModules();

        return { success: true, config: this.installedModules.installed[moduleId].config };
    }

    /**
     * Enable/disable a module
     */
    setModuleEnabled(moduleId, enabled) {
        if (REQUIRED_MODULE_IDS.has(moduleId) && !enabled) {
            return { success: false, error: 'Required modules cannot be disabled' };
        }
        return this.updateModuleConfig(moduleId, { enabled });
    }

    /**
     * Check if a module is enabled
     */
    isModuleEnabled(moduleId) {
        const installed = this.installedModules.installed[moduleId];
        return installed?.config?.enabled || false;
    }

    getModuleDirectory(moduleId) {
        if (!moduleId) return null;
        const moduleDir = path.join(__dirname, moduleId);
        if (!fs.existsSync(moduleDir)) return null;
        if (!fs.statSync(moduleDir).isDirectory()) return null;
        return moduleDir;
    }

    buildModuleBundle(moduleId) {
        const moduleDir = this.getModuleDirectory(moduleId);
        if (!moduleDir) {
            return { success: false, error: `Module files not found for ${moduleId}` };
        }

        const files = [];
        const walk = (dir, relativeBase = '') => {
            const entries = fs.readdirSync(dir, { withFileTypes: true });
            for (const entry of entries) {
                if (entry.name === '.git' || entry.name === 'node_modules' || entry.name === '.DS_Store') {
                    continue;
                }
                const absolutePath = path.join(dir, entry.name);
                const relativePath = path.posix.join(relativeBase, entry.name);
                if (entry.isDirectory()) {
                    walk(absolutePath, relativePath);
                    continue;
                }
                if (!entry.isFile()) {
                    continue;
                }
                const stat = fs.statSync(absolutePath);
                if (stat.size > MODULE_FILE_SIZE_LIMIT_BYTES) {
                    continue;
                }
                const raw = fs.readFileSync(absolutePath);
                files.push({
                    path: relativePath,
                    encoding: 'base64',
                    content: raw.toString('base64'),
                    size: stat.size
                });
            }
        };
        walk(moduleDir);

        if (!files.length) {
            return { success: false, error: `No module files found for ${moduleId}` };
        }

        return {
            success: true,
            bundle: {
                moduleId,
                generatedAt: new Date().toISOString(),
                files
            }
        };
    }

    installModuleBundle(moduleId, bundle, metadata = {}) {
        if (!bundle || typeof bundle !== 'object') {
            return { success: false, error: 'Invalid module bundle payload' };
        }
        const files = Array.isArray(bundle.files) ? bundle.files : [];
        if (!files.length) {
            return { success: false, error: 'Module bundle is empty' };
        }

        const moduleDir = path.join(__dirname, moduleId);
        fs.mkdirSync(moduleDir, { recursive: true });

        let written = 0;
        for (const file of files) {
            if (!file || typeof file !== 'object' || typeof file.path !== 'string') {
                continue;
            }
            const cleanPath = file.path.replace(/\\/g, '/').replace(/^\/+/, '');
            if (!cleanPath || cleanPath.includes('..')) {
                continue;
            }
            const absolutePath = path.join(moduleDir, cleanPath);
            const insideModuleDir = absolutePath.startsWith(moduleDir + path.sep) || absolutePath === moduleDir;
            if (!insideModuleDir) {
                continue;
            }
            fs.mkdirSync(path.dirname(absolutePath), { recursive: true });
            const encoding = String(file.encoding || '').toLowerCase();
            if (encoding === 'base64') {
                fs.writeFileSync(absolutePath, Buffer.from(String(file.content || ''), 'base64'));
            } else {
                fs.writeFileSync(absolutePath, String(file.content || ''), 'utf8');
            }
            written += 1;
        }

        if (!written) {
            return { success: false, error: 'No valid files written from module bundle' };
        }

        const knownModule = AVAILABLE_MODULES[moduleId];
        if (knownModule && !this.installedModules.installed[moduleId]) {
            this.installedModules.installed[moduleId] = {
                installedAt: new Date().toISOString(),
                config: { ...knownModule.defaultConfig, enabled: true },
                syncedFrom: metadata.sourceUrl || null,
                syncedAt: new Date().toISOString()
            };
        } else if (this.installedModules.installed[moduleId]) {
            this.installedModules.installed[moduleId].syncedFrom = metadata.sourceUrl || this.installedModules.installed[moduleId].syncedFrom || null;
            this.installedModules.installed[moduleId].syncedAt = new Date().toISOString();
        }

        if (!this.installedModules.installOrder.includes(moduleId)) {
            this.installedModules.installOrder.push(moduleId);
        }
        this.saveInstalledModules();

        return { success: true, moduleId, filesWritten: written, sourceUrl: metadata.sourceUrl || null };
    }

    static normalizeSourceUrls(sources = []) {
        const out = [];
        const seen = new Set();
        for (const source of sources) {
            const raw = typeof source === 'string'
                ? source
                : (source && typeof source.url === 'string' ? source.url : '');
            if (!raw) continue;
            const candidate = raw.trim();
            if (!candidate) continue;
            const withProtocol = candidate.startsWith('http://') || candidate.startsWith('https://')
                ? candidate
                : `https://${candidate}`;
            try {
                const normalized = new URL(withProtocol).toString().replace(/\/+$/, '');
                if (seen.has(normalized)) continue;
                seen.add(normalized);
                out.push(normalized);
            } catch {
                continue;
            }
        }
        return out;
    }

    async syncModuleFromNetwork(moduleId, options = {}) {
        const sources = ModuleRegistry.normalizeSourceUrls(options.sources || []);
        const timeoutMs = Number(options.timeoutMs || MODULE_SYNC_TIMEOUT_MS);
        const adminKey = typeof options.adminKey === 'string' ? options.adminKey.trim() : '';
        if (!sources.length) {
            return { success: false, error: 'No module sources provided' };
        }

        const failures = [];
        for (const baseUrl of sources) {
            const requestUrl = `${baseUrl}${MODULE_BUNDLE_API_PATH}/${encodeURIComponent(moduleId)}/bundle`;
            const controller = new AbortController();
            const timeout = setTimeout(() => controller.abort(), timeoutMs);
            try {
                const response = await fetch(requestUrl, {
                    method: 'GET',
                    headers: adminKey ? { 'x-admin-key': adminKey } : undefined,
                    signal: controller.signal
                });
                if (!response.ok) {
                    failures.push(`${requestUrl} -> HTTP ${response.status}`);
                    continue;
                }
                const payload = await response.json().catch(() => null);
                const bundle = payload?.bundle || (payload?.files ? payload : null);
                if (!bundle || !Array.isArray(bundle.files)) {
                    failures.push(`${requestUrl} -> invalid bundle payload`);
                    continue;
                }
                const installResult = this.installModuleBundle(moduleId, bundle, { sourceUrl: baseUrl });
                if (installResult.success) {
                    console.log(`[ModuleRegistry] Synced module "${moduleId}" from ${baseUrl}`);
                    return {
                        success: true,
                        moduleId,
                        sourceUrl: baseUrl,
                        filesWritten: installResult.filesWritten
                    };
                }
                failures.push(`${requestUrl} -> ${installResult.error || 'install failed'}`);
            } catch (error) {
                failures.push(`${requestUrl} -> ${error.message}`);
            } finally {
                clearTimeout(timeout);
            }
        }

        return {
            success: false,
            error: `Unable to sync module "${moduleId}" from configured sources`,
            failures
        };
    }

    /**
     * Get categories
     */
    getCategories() {
        return Object.entries(CATEGORIES).map(([key, value]) => ({
            id: value,
            name: key.charAt(0) + key.slice(1).toLowerCase()
        }));
    }
}

module.exports = { ModuleRegistry, AVAILABLE_MODULES, CATEGORIES };
