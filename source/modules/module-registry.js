/**
 * VoiceLink Module Registry
 *
 * Manages installable modules for VoiceLink servers.
 * Modules can be installed/uninstalled via admin settings.
 */

const fs = require('fs');
const path = require('path');

// Module categories
const CATEGORIES = {
    SECURITY: 'security',
    COMMUNICATION: 'communication',
    INTEGRATION: 'integration',
    SUPPORT: 'support',
    MEDIA: 'media',
    ANALYTICS: 'analytics'
};

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
            },
            externalSync: {
                provider: 'auto',
                mode: 'builtin-first',
                syncDevineCreationsDomains: true,
                syncDomains: [
                    'devine-creations.com',
                    'devinecreations.net',
                    'voicelinkapp.app',
                    'community.voicelinkapp.app'
                ],
                whmcsDepartmentId: '',
                supportedProviders: ['builtin', 'whmcs']
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
            hostedBasePath: '/api/webhooks/incoming',
            outboundWebhooks: [],
            hostedEndpoints: [
                {
                    id: 'general-chat',
                    name: 'General Chat Hosted Webhook',
                    slug: 'general-chat',
                    enabled: true,
                    allowAnonymous: false,
                    eventType: 'general_chat_message',
                    deliveryMode: 'room-message',
                    roomName: 'General Chat',
                    secret: ''
                }
            ],
            delivery: {
                timeoutMs: 8000,
                retries: 2,
                maxLogEntries: 200
            }
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

    'openlink-bridge': {
        id: 'openlink-bridge',
        name: 'OpenLink Bridge',
        description: 'Install, connect, and govern OpenLink from VoiceLink while keeping OpenLink itself as a separate linked module',
        version: '1.1.0',
        category: CATEGORIES.INTEGRATION,
        author: 'VoiceLink',
        recommended: true,
        popular: true,
        dependencies: [],
        configurable: true,
        features: [
            'OpenLink install and link settings from the Modules Center',
            'Voice fallback room bridge policy',
            'Admin approval and override workflow for linked OpenLink sessions',
            'Auto-detect local OpenLink installs and service endpoints',
            'Linked domain, admin UI, API, and signaling endpoint controls',
            'Supports external OpenLink installs without bundling OpenLink into VoiceLink'
        ],
        defaultConfig: {
            enabled: false,
            moduleMode: 'external-linked',
            autoDetectInstalled: true,
            installState: 'not-installed',
            installSource: 'repo',
            installPath: '',
            installerPath: '',
            repoPath: '',
            appBundlePath: '',
            adminUIUrl: 'https://openlink.tappedin.fm',
            apiBaseUrl: 'https://openlink.tappedin.fm/api',
            signalingUrl: 'wss://openlink.tappedin.fm',
            defaultDomain: 'openlink.tappedin.fm',
            sharedSecret: '',
            linkedVoiceLinkServerId: '',
            allowAdminControl: true,
            allowRemoteInstall: true,
            voiceFallbackRoomsEnabled: true,
            requireAdminApprovalForEntry: true,
            allowAdminOverride: true,
            notifyBeforeAdminOverride: true,
            showActiveRoomsInAdminOverview: true,
            roomDurationMinutes: 1440,
            overrideWindowSeconds: 180
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

    'voicelink-flexpbx': {
        id: 'voicelink-flexpbx',
        name: 'VoiceLink FlexPBX Bridge',
        description: 'Room-aware telephony helpers, voice OTP delivery, and PBX-aware call actions for VoiceLink',
        version: '1.0.0',
        category: CATEGORIES.INTEGRATION,
        author: 'VoiceLink',
        recommended: true,
        popular: false,
        dependencies: [],
        configurable: true,
        features: [
            'US voice OTP fallback when email is unavailable',
            'Room telephony capability checks for admins and moderators',
            'FlexPBX API call initiation helpers',
            'Per-room or per-server outbound policy controls',
            'Call audit trail for verification and support flows',
            'Optional VoiceLink-managed hold media assignment and PBX MOH sync'
        ],
        defaultConfig: {
            enabled: true,
            pbxApiUrl: 'https://pbx.devinecreations.net/api',
            apiKey: '',
            defaultExtension: '2000',
            allowedRoomRoles: ['admin', 'moderator'],
            holdMedia: {
                enabled: true,
                optionalSource: true,
                autoReload: true,
                allowedSourceTypes: ['server-stream', 'room-background', 'room-stream', 'room-mix'],
                globalAssignment: {
                    enabled: false,
                    sourceType: 'server-stream',
                    sourceId: 'server-default',
                    mohClass: 'voicelink-global',
                    targetIds: ['community-pbx']
                },
                roomAssignments: {},
                pbxTargets: [
                    {
                        id: 'community-pbx',
                        name: 'Community PBX',
                        apiUrl: 'https://pbx.devinecreations.net/api',
                        enabled: true
                    },
                    {
                        id: 'dev-pbx',
                        name: 'Development PBX',
                        apiUrl: 'https://flexpbx.devinecreations.net/api',
                        enabled: true
                    }
                ]
            },
            otpVoice: {
                enabled: true,
                usOnly: true,
                expiryMinutes: 10,
                maxAttemptsPerHour: 5,
                fromExtension: '2000',
                endpoint: 'textnow-calling.php',
                messageTemplate: 'Hello from VoiceLink. Your verification code is {code}. This code expires in {expiryMinutes} minutes.'
            },
            voiceEngine: {
                provider: 'piper',
                defaultVoice: 'piper-female',
                allowClonedVoice: true,
                allowRecordedName: true,
                selectionMode: 'prefer-recorded-name'
            },
            promptTextOverrides: {
                otpMessageTemplate: 'Hello from VoiceLink. Your verification code is {code}. This code expires in {expiryMinutes} minutes.',
                verificationIntro: 'This is your VoiceLink verification call.',
                callIsFor: 'This call is for.',
                personNameUnavailable: 'This call is for the intended VoiceLink user.',
                codeIntro: 'Your verification code is.',
                codeValidForMinutes: 'You have this many minutes to enter the code before it expires.',
                stayOnTheLine: 'Stay on the line while we wait for your code to be entered.',
                waitingForCode: 'We are still waiting for your code to be entered.',
                repeatOptions: 'Press 1 to repeat the code, press 2 to hear it more slowly, or press 3 if you are not the intended person.',
                wrongPersonPrompt: 'If you are not the intended person, press 3 and we will stop calling this number for verification.',
                codeAccepted: 'Your code was accepted. You may hang up now.',
                codeExpired: 'This code has expired. Please request a new code.',
                wrongPersonReported: 'We will stop using this number for verification and notify support if needed.'
            }
        }
    }
};

class ModuleRegistry {
    constructor(configDir) {
        this.configDir = configDir || path.join(__dirname, '../../data');
        this.modulesConfigFile = path.join(this.configDir, 'modules.json');
        this.installedModules = this.loadInstalledModules();
        this.ensureDefaultInstalledModules();
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

    ensureDefaultInstalledModules() {
        const skipped = new Set(
            String(process.env.VOICELINK_SKIP_DEFAULT_MODULES || '')
                .split(',')
                .map((entry) => entry.trim())
                .filter(Boolean)
        );
        const defaultModuleIds = ['support-system'];
        let changed = false;

        for (const moduleId of defaultModuleIds) {
            if (skipped.has(moduleId)) continue;
            const module = AVAILABLE_MODULES[moduleId];
            if (!module || this.installedModules.installed[moduleId]) continue;
            this.installedModules.installed[moduleId] = {
                installedAt: Date.now(),
                config: { ...module.defaultConfig, enabled: true }
            };
            this.installedModules.installOrder.push(moduleId);
            changed = true;
            console.log(`[ModuleRegistry] Auto-installed default module: ${module.name}`);
        }

        if (changed) {
            this.installedModules.installOrder = Array.from(new Set(this.installedModules.installOrder));
            this.saveInstalledModules();
        }
    }

    saveInstalledModules() {
        try {
            if (!fs.existsSync(this.configDir)) {
                fs.mkdirSync(this.configDir, { recursive: true });
            }
            fs.writeFileSync(this.modulesConfigFile, JSON.stringify(this.installedModules, null, 2));
        } catch (e) {
            console.error('[ModuleRegistry] Error saving modules config:', e.message);
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
            installed: !!this.installedModules.installed[m.id],
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
        return this.installedModules.installOrder.map(id => ({
            ...AVAILABLE_MODULES[id],
            ...this.installedModules.installed[id],
            installed: true
        })).filter(Boolean);
    }

    /**
     * Get module by ID
     */
    getModule(moduleId) {
        const module = AVAILABLE_MODULES[moduleId];
        if (!module) return null;

        return {
            ...module,
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
     * Install every available module that is not currently installed.
     * Dependencies are resolved locally before dependents are attempted.
     */
    installMissingModules(options = {}) {
        const policy = options.policy || {};
        const revoked = new Set(Array.isArray(policy.revoked) ? policy.revoked : []);
        const customConfigById = options.customConfigById && typeof options.customConfigById === 'object'
            ? options.customConfigById
            : {};
        const pending = Object.keys(AVAILABLE_MODULES)
            .filter(id => !this.installedModules.installed[id])
            .filter(id => !revoked.has(id));
        const actions = [];
        const failed = [];
        const skipped = Object.keys(AVAILABLE_MODULES)
            .filter(id => revoked.has(id))
            .map(id => ({ moduleId: id, reason: 'revoked-by-policy' }));

        let madeProgress = true;
        while (pending.length && madeProgress) {
            madeProgress = false;
            for (let index = pending.length - 1; index >= 0; index -= 1) {
                const moduleId = pending[index];
                const module = AVAILABLE_MODULES[moduleId];
                const dependencies = Array.isArray(module.dependencies) ? module.dependencies : [];
                const unresolved = dependencies.filter(dep => !this.installedModules.installed[dep]);
                if (unresolved.length) continue;

                const result = this.installModule(moduleId, customConfigById[moduleId] || {});
                actions.push({
                    moduleId,
                    action: 'install',
                    success: !!result.success,
                    error: result.error || null
                });
                if (!result.success) {
                    failed.push({ moduleId, error: result.error || 'Install failed' });
                }
                pending.splice(index, 1);
                madeProgress = true;
            }
        }

        for (const moduleId of pending) {
            const module = AVAILABLE_MODULES[moduleId];
            const dependencies = Array.isArray(module.dependencies) ? module.dependencies : [];
            failed.push({
                moduleId,
                error: `Missing dependency: ${dependencies.filter(dep => !this.installedModules.installed[dep]).join(', ') || 'unknown'}`
            });
        }

        return {
            success: failed.length === 0,
            installed: actions.filter(entry => entry.success).map(entry => entry.moduleId),
            actions,
            skipped,
            failed
        };
    }

    /**
     * Uninstall a module
     */
    uninstallModule(moduleId) {
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
     * Reconcile installed module records with the current module catalog defaults.
     * This preserves admin customizations while adding new default keys and cleaning install order.
     */
    updateInstalledModules(options = {}) {
        const policy = options.policy || {};
        const revoked = new Set(Array.isArray(policy.revoked) ? policy.revoked : []);
        const actions = [];
        const skipped = [];
        let changed = false;

        for (const moduleId of Object.keys(this.installedModules.installed)) {
            const module = AVAILABLE_MODULES[moduleId];
            if (!module) {
                skipped.push({ moduleId, reason: 'not-in-current-catalog' });
                continue;
            }

            const installed = this.installedModules.installed[moduleId];
            const currentConfig = installed.config && typeof installed.config === 'object' ? installed.config : {};
            const nextConfig = {
                ...module.defaultConfig,
                ...currentConfig
            };
            if (revoked.has(moduleId)) {
                nextConfig.enabled = false;
            }

            const before = JSON.stringify(currentConfig);
            const after = JSON.stringify(nextConfig);
            if (before !== after) {
                installed.config = nextConfig;
                installed.updatedAt = Date.now();
                changed = true;
                actions.push({ moduleId, action: 'reconcile', success: true });
            } else {
                actions.push({ moduleId, action: 'check', success: true, changed: false });
            }
        }

        const dedupedOrder = Array.from(new Set(this.installedModules.installOrder))
            .filter(id => this.installedModules.installed[id]);
        if (dedupedOrder.length !== this.installedModules.installOrder.length) {
            this.installedModules.installOrder = dedupedOrder;
            changed = true;
        }

        if (changed) {
            this.saveInstalledModules();
        }

        return {
            success: true,
            updated: actions.filter(entry => entry.action === 'reconcile').map(entry => entry.moduleId),
            actions,
            skipped
        };
    }

    /**
     * Enable/disable a module
     */
    setModuleEnabled(moduleId, enabled) {
        return this.updateModuleConfig(moduleId, { enabled });
    }

    /**
     * Check if a module is enabled
     */
    isModuleEnabled(moduleId) {
        const installed = this.installedModules.installed[moduleId];
        return installed?.config?.enabled || false;
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
