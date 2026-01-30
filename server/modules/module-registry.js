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
    }
};

class ModuleRegistry {
    constructor(configDir) {
        this.configDir = configDir || path.join(__dirname, '../../data');
        this.modulesConfigFile = path.join(this.configDir, 'modules.json');
        this.installedModules = this.loadInstalledModules();
    }

    loadInstalledModules() {
        try {
            if (fs.existsSync(this.modulesConfigFile)) {
                return JSON.parse(fs.readFileSync(this.modulesConfigFile, 'utf8'));
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
