/**
 * VoiceLink Deployment Configuration System
 *
 * Manages server configuration, presets, and deployment settings.
 * Supports quick deployment to new servers with pre-configured templates.
 */

const fs = require('fs');
const path = require('path');
const crypto = require('crypto');

// Configuration paths
const CONFIG_DIR = process.env.VOICELINK_CONFIG_DIR || path.join(__dirname, '../../data');
const DEPLOY_CONFIG_FILE = path.join(CONFIG_DIR, 'deploy.json');
const BACKUP_DIR = path.join(CONFIG_DIR, 'backups');
const PRESETS_DIR = path.join(__dirname, '../presets');

// Default configuration
const DEFAULT_CONFIG = {
    version: '1.0.0',
    server: {
        name: 'VoiceLink Server',
        description: 'A VoiceLink voice chat server',
        port: 3010,
        host: '0.0.0.0',
        publicUrl: null, // Auto-detected or set manually
        maxConnections: 500,
        rateLimit: {
            windowMs: 60000,
            maxRequests: 100
        }
    },
    rooms: {
        maxRooms: 100,
        maxUsersPerRoom: 50,
        defaultMaxUsers: 20,
        allowUserCreatedRooms: true,
        autoCleanupEnabled: true,
        cleanupIntervalMs: 3600000, // 1 hour
        emptyRoomTimeoutMs: 1800000, // 30 minutes
        defaultRoomsEnabled: true,
        defaultRoomsCount: 8
    },
    audio: {
        sampleRate: 48000,
        channels: 2,
        bitDepth: 16,
        codec: 'opus',
        spatialAudioEnabled: true,
        maxBitrate: 128000,
        minBitrate: 16000
    },
    security: {
        requireAuth: false,
        allowGuests: true,
        maxGuestDuration: null, // null = unlimited
        enableRateLimiting: true,
        corsOrigins: ['*'],
        enableHttps: false,
        sslCertPath: null,
        sslKeyPath: null
    },
    federation: {
        enabled: false,
        mode: 'standalone', // 'standalone', 'hub', 'spoke', 'mesh'
        hubUrl: null,
        trustedServers: [],
        syncInterval: 300000, // 5 minutes
        // Per-room federation control
        globalFederation: true, // Default: all public rooms federated
        roomApprovalRequired: false, // Require admin approval before federation
        approvalHoldTime: 3600000, // Hold time before auto-approve (1 hour)
        autoApproveAfterHold: true, // Auto-approve after hold time
        // Federation tiers
        tiers: {
            none: { visible: false, syncInterval: 0 },
            standard: { visible: true, syncInterval: 300000 },
            promoted: { visible: true, syncInterval: 60000, priority: 'high' }
        },
        // Ecripto node operator priority
        nodeOperatorPriority: {
            enabled: true, // Give priority to servers running Ecripto nodes
            priorityBoost: 100, // Score boost for node operators (higher = more visible)
            verificationInterval: 3600000, // Re-verify node status every hour
            trustedNodes: [] // Manually verified node operator wallet addresses
        }
    },
    mastodon: {
        enabled: false,
        botEnabled: false,
        instances: [],
        defaultInstance: null
    },
    admin: {
        enabled: true,
        requireAuth: true,
        adminEmails: [],
        adminMastodonHandles: []
    },
    features: {
        peekIntoRoom: true,
        jukebox: true,
        screenShare: false,
        recording: false,
        transcription: false,
        whisperMode: true
    },
    // Jellyfin Media Server Integration
    jellyfin: {
        // Bundled installation settings (for full installer)
        bundled: {
            enabled: false, // True when Jellyfin is bundled with VoiceLink installer
            version: null, // Bundled Jellyfin version
            installPath: null, // e.g., /home/{user}/apps/jellyfin
            dataPath: null, // e.g., /home/{user}/apps/jellyfin/data
            mediaPath: null, // e.g., /home/{user}/apps/media
            port: 8096,
            autoStart: true
        },
        // Connection settings
        connection: {
            serverUrl: null, // http://localhost:8096 or external
            apiKey: null, // Auto-generated or manual
            userId: null, // Jellyfin user ID for bot
            autoSetup: true // Auto-configure API key on first run
        },
        // Media Player Bot settings
        bot: {
            enabled: false,
            status: 'disabled', // 'enabled', 'disabled', 'suspended'
            suspendedUntil: null, // ISO timestamp for auto-re-enable
            suspendReason: null,
            // Default rooms for music playback
            defaultRooms: [], // Room IDs where bot auto-plays
            globalPlayback: false, // Play in all rooms by default
            // Per-room overrides
            roomOverrides: {}, // { roomId: { enabled: true/false, library: 'Music' } }
            // Default music library
            defaultLibrary: 'Music',
            // Ambient music settings
            ambientOnJoin: true, // Auto-play when users join
            ambientVolume: 0.3
        },
        // Suspension options
        suspension: {
            allowedDurations: [
                { id: '24h', label: '24 Hours', ms: 86400000 },
                { id: '36h', label: '36 Hours', ms: 129600000 },
                { id: 'week', label: '1 Week', ms: 604800000 },
                { id: 'month', label: '1 Month', ms: 2592000000 }
            ],
            autoReEnable: true // Re-enable after suspension period
        },
        // Library management
        libraries: {
            // Remote import settings
            remoteImport: {
                enabled: true,
                allowedExtensions: ['.zip', '.tar', '.tar.gz', '.mp3', '.m3u', '.m3u8', '.flac', '.ogg', '.wav'],
                maxDownloadSize: 5368709120, // 5GB default
                downloadPath: null, // Temp download path
                autoExtract: true,
                autoCleanup: true, // Remove archive after extraction
                autoScan: true // Trigger Jellyfin library scan after import
            },
            // Upload settings
            upload: {
                enabled: true,
                maxFileSize: 5368709120, // 5GB default
                allowedExtensions: ['.zip', '.tar', '.tar.gz', '.mp3', '.m3u', '.m3u8', '.flac', '.ogg', '.wav', '.mp4', '.mkv'],
                uploadPath: null // Where uploads are saved
            },
            // Storage limits
            storage: {
                maxTotalSize: null, // null = unlimited, or bytes
                currentUsage: 0,
                purchasedExtra: 0, // Extra storage purchased
                purchaseEnabled: false // Allow purchasing more space
            }
        },
        // Backup settings
        backup: {
            enabled: true,
            autoBackup: true,
            backupInterval: 86400000, // Daily
            backupPath: null, // e.g., /home/{user}/apps/backups/jellyfin
            maxBackups: 7,
            includeMedia: false, // Usually too large
            includeConfig: true,
            includeDatabase: true,
            lastBackup: null,
            lastBackupSize: null
        },
        // Removal settings
        removal: {
            requireConfirmation: true,
            requireBackupCheck: true, // Show backup status before removal
            removeMedia: false, // Default: don't remove media
            removeConfig: true,
            removeDatabase: true
        },
        // Admin panel settings (which Jellyfin settings to expose)
        adminPanel: {
            showApiKey: false, // Hide API key in UI for security
            editableSettings: [
                'bot.enabled',
                'bot.defaultRooms',
                'bot.globalPlayback',
                'bot.defaultLibrary',
                'bot.ambientOnJoin',
                'bot.ambientVolume',
                'libraries.remoteImport.enabled',
                'libraries.upload.enabled',
                'backup.autoBackup'
            ],
            // Settings that would break configuration (hidden/locked)
            lockedSettings: [
                'connection.serverUrl',
                'connection.apiKey',
                'bundled.installPath',
                'bundled.port'
            ]
        }
    },
    branding: {
        appName: 'VoiceLink',
        logoUrl: null,
        primaryColor: '#6364FF',
        secondaryColor: '#563ACC'
    },
    whmcs: {
        portalUrl: 'https://devine-creations.com/clientarea.php',
        roles: {
            adminGroups: [],
            staffGroups: [],
            adminAddons: [],
            staffAddons: []
        }
    },
    ecripto: {
        enabled: false,
        apiUrl: 'https://api.ecripto.app',
        networkId: null, // Ecripto network ID
        // Node operator configuration (for federation priority)
        nodeOperator: {
            isNode: false, // Is this server running an Ecripto node?
            nodeWalletAddress: null, // Wallet address of the node
            nodeId: null, // Ecripto node ID
            nodeType: null, // 'validator', 'relay', 'archive'
            verifiedAt: null, // Last verification timestamp
            verificationProof: null // Signed proof of node operation
        },
        // Room minting/access control
        mintingEnabled: false,
        shopTabEnabled: false,
        // Wallet-based access
        walletAccessEnabled: false,
        requiredTokens: [], // Token contracts required for access
        // Access tiers (day, week, monthly passes)
        accessTiers: {
            enabled: false,
            tiers: [
                { id: 'day', name: 'Day Pass', duration: 86400000, price: null },
                { id: 'week', name: 'Weekly Pass', duration: 604800000, price: null },
                { id: 'month', name: 'Monthly Pass', duration: 2592000000, price: null }
            ]
        },
        // Filtering by wallet/domain/status
        filterOptions: {
            byUser: true,
            byDomain: true,
            byMintStatus: true
        }
    },
    mastodonDiscovery: {
        enabled: false,
        // Show servers on user's Mastodon domain
        showDomainServers: true,
        // Show servers tied to user's Mastodon profile
        showProfileServers: true,
        // Federated timeline style discovery
        federatedDiscovery: true
    },
    backup: {
        enabled: true,
        intervalMs: 3600000, // 1 hour
        maxBackups: 24,
        includeRooms: true,
        includeUsers: false // Privacy consideration
    },
    logging: {
        level: 'info', // 'debug', 'info', 'warn', 'error'
        file: null,
        maxFileSize: 10485760, // 10MB
        maxFiles: 5
    },
    // Multi-Payment Provider Configuration
    payments: {
        enabled: false,
        defaultProvider: null, // 'stripe', 'paypal', 'crypto', 'manual'
        currency: 'usd',
        // Provider-specific configurations
        providers: {
            stripe: {
                enabled: false,
                displayName: 'Credit/Debit Card',
                publishableKey: null, // pk_live_... or pk_test_...
                secretKey: null, // sk_live_... or sk_test_... (KEEP SECRET)
                webhookSecret: null, // whsec_... for webhook verification
                supportedMethods: ['card'], // 'card', 'apple_pay', 'google_pay'
                priority: 1 // Display order
            },
            paypal: {
                enabled: false,
                displayName: 'PayPal',
                clientId: null, // PayPal client ID
                clientSecret: null, // PayPal secret (KEEP SECRET)
                mode: 'sandbox', // 'sandbox' or 'live'
                webhookId: null,
                priority: 2
            },
            crypto: {
                enabled: false,
                displayName: 'Cryptocurrency',
                // Ecripto wallet payments
                ecriptoEnabled: true,
                // Direct crypto addresses
                addresses: {
                    btc: null,
                    eth: null,
                    sol: null
                },
                // Coinbase Commerce / BTCPay Server
                coinbaseCommerceKey: null,
                btcPayServerUrl: null,
                btcPayServerApiKey: null,
                priority: 3
            },
            cashapp: {
                enabled: false,
                displayName: 'Cash App',
                cashtag: null, // $cashtag
                // Note: Cash App doesn't have a direct API for non-business
                // This is for manual verification or Cash App Pay for Business
                businessId: null,
                priority: 4
            },
            manual: {
                enabled: false,
                displayName: 'Manual Payment',
                instructions: 'Contact admin for payment details',
                contactEmail: null,
                contactMastodon: null,
                priority: 99
            }
        },
        // Pricing configuration
        pricing: {
            // Room access tiers
            roomAccess: {
                enabled: false,
                tiers: [
                    { id: 'day', name: 'Day Pass', duration: 86400000, price: 1.00 },
                    { id: 'week', name: 'Weekly Pass', duration: 604800000, price: 5.00 },
                    { id: 'month', name: 'Monthly Pass', duration: 2592000000, price: 15.00 }
                ]
            },
            // Server donations/support
            donations: {
                enabled: false,
                suggestedAmounts: [5, 10, 25, 50],
                allowCustomAmount: true,
                minimumAmount: 1.00
            },
            // Premium features
            premiumFeatures: {
                enabled: false,
                features: [
                    { id: 'recording', name: 'Recording Access', price: 5.00, duration: 2592000000 },
                    { id: 'transcription', name: 'Transcription', price: 10.00, duration: 2592000000 },
                    { id: 'priority_federation', name: 'Priority Federation', price: 20.00, duration: 2592000000 }
                ]
            }
        },
        // Payment processing options
        options: {
            requireEmailReceipt: true,
            allowRefunds: true,
            refundWindowDays: 7,
            taxRate: 0, // Percentage, e.g., 0.08 for 8%
            taxInclusive: false
        }
    },
    // Legacy stripe config (for backwards compatibility, use payments.providers.stripe)
    stripe: {
        enabled: false,
        publishableKey: null,
        secretKey: null,
        webhookSecret: null,
        currency: 'usd'
    },
    escort: {
        enabled: true,
        sessionTimeout: 300000, // 5 minutes
        maxFollowers: 100,
        sounds: {
            leave: 'whoosh_leave.mp3',
            arrive: 'whoosh_arrive.mp3'
        }
    }
};

// Deployment presets
const PRESETS = {
    // Small personal server
    personal: {
        name: 'Personal Server',
        description: 'Small server for friends and family',
        config: {
            server: { maxConnections: 50 },
            rooms: { maxRooms: 10, maxUsersPerRoom: 10, defaultRoomsCount: 4 },
            security: { allowGuests: true, requireAuth: false },
            features: { jukebox: true, peekIntoRoom: true }
        }
    },

    // Community server
    community: {
        name: 'Community Server',
        description: 'Medium-sized community server',
        config: {
            server: { maxConnections: 200 },
            rooms: { maxRooms: 50, maxUsersPerRoom: 30, defaultRoomsCount: 8 },
            security: { allowGuests: true, requireAuth: false },
            features: { jukebox: true, peekIntoRoom: true, whisperMode: true }
        }
    },

    // Public server
    public: {
        name: 'Public Server',
        description: 'Large public server with moderation',
        config: {
            server: { maxConnections: 500 },
            rooms: { maxRooms: 100, maxUsersPerRoom: 50 },
            security: { allowGuests: true, enableRateLimiting: true },
            admin: { enabled: true, requireAuth: true },
            features: { jukebox: true, peekIntoRoom: true }
        }
    },

    // Enterprise/private server
    enterprise: {
        name: 'Enterprise Server',
        description: 'Private server with authentication required',
        config: {
            server: { maxConnections: 1000 },
            rooms: { allowUserCreatedRooms: true },
            security: { requireAuth: true, allowGuests: false, enableHttps: true },
            admin: { enabled: true, requireAuth: true },
            features: { recording: true, transcription: true }
        }
    },

    // Federated hub server
    federation_hub: {
        name: 'Federation Hub',
        description: 'Central hub for federated network',
        config: {
            federation: { enabled: true, mode: 'hub' },
            server: { maxConnections: 1000 },
            security: { enableRateLimiting: true }
        }
    },

    // Federated spoke server
    federation_spoke: {
        name: 'Federation Spoke',
        description: 'Spoke server connecting to a hub',
        config: {
            federation: { enabled: true, mode: 'spoke' },
            server: { maxConnections: 200 }
        }
    },

    // Development/testing server
    development: {
        name: 'Development Server',
        description: 'Local development and testing',
        config: {
            server: { port: 3010, maxConnections: 20 },
            rooms: { maxRooms: 5, defaultRoomsCount: 3 },
            security: { allowGuests: true, corsOrigins: ['*'] },
            logging: { level: 'debug' }
        }
    },

    // Minimal/embedded server
    minimal: {
        name: 'Minimal Server',
        description: 'Minimal footprint for embedding',
        config: {
            server: { maxConnections: 10 },
            rooms: { maxRooms: 3, defaultRoomsEnabled: false, autoCleanupEnabled: false },
            features: { jukebox: false, peekIntoRoom: false },
            backup: { enabled: false }
        }
    }
};

class DeploymentConfig {
    constructor() {
        this.config = null;
        this.configPath = DEPLOY_CONFIG_FILE;
        this.loaded = false;
    }

    /**
     * Initialize configuration - load from file or create default
     */
    async init() {
        await this.ensureDirectories();
        await this.load();
        return this.config;
    }

    /**
     * Ensure required directories exist
     */
    async ensureDirectories() {
        const dirs = [CONFIG_DIR, BACKUP_DIR, PRESETS_DIR];
        for (const dir of dirs) {
            if (!fs.existsSync(dir)) {
                fs.mkdirSync(dir, { recursive: true });
            }
        }
    }

    /**
     * Load configuration from file
     */
    async load() {
        try {
            if (fs.existsSync(this.configPath)) {
                const data = fs.readFileSync(this.configPath, 'utf8');
                const loaded = JSON.parse(data);
                // Merge with defaults to ensure all fields exist
                this.config = this.deepMerge(DEFAULT_CONFIG, loaded);
                console.log('[DeployConfig] Loaded configuration from', this.configPath);
            } else {
                this.config = { ...DEFAULT_CONFIG };
                await this.save();
                console.log('[DeployConfig] Created default configuration');
            }
            this.loaded = true;
        } catch (error) {
            console.error('[DeployConfig] Error loading config:', error.message);
            this.config = { ...DEFAULT_CONFIG };
        }
        return this.config;
    }

    /**
     * Save configuration to file
     */
    async save() {
        try {
            this.config.lastModified = new Date().toISOString();
            const data = JSON.stringify(this.config, null, 2);
            fs.writeFileSync(this.configPath, data, 'utf8');
            console.log('[DeployConfig] Saved configuration');
            return true;
        } catch (error) {
            console.error('[DeployConfig] Error saving config:', error.message);
            return false;
        }
    }

    /**
     * Get current configuration
     */
    getConfig() {
        return this.config;
    }

    /**
     * Get a specific config section
     */
    get(section, key = null) {
        if (!this.config) return null;
        if (key) {
            return this.config[section]?.[key];
        }
        return this.config[section];
    }

    /**
     * Set a configuration value
     */
    set(section, key, value) {
        if (!this.config[section]) {
            this.config[section] = {};
        }
        this.config[section][key] = value;
        return this;
    }

    /**
     * Update entire section
     */
    updateSection(section, values) {
        this.config[section] = { ...this.config[section], ...values };
        return this;
    }

    /**
     * Apply a preset configuration
     */
    applyPreset(presetName) {
        const preset = PRESETS[presetName];
        if (!preset) {
            throw new Error(`Unknown preset: ${presetName}`);
        }

        // Start with defaults and apply preset
        this.config = this.deepMerge(DEFAULT_CONFIG, preset.config);
        this.config._preset = presetName;
        this.config._presetName = preset.name;

        console.log(`[DeployConfig] Applied preset: ${preset.name}`);
        return this.config;
    }

    /**
     * Get available presets
     */
    getPresets() {
        return Object.entries(PRESETS).map(([key, preset]) => ({
            id: key,
            name: preset.name,
            description: preset.description
        }));
    }

    /**
     * Export configuration for deployment
     */
    exportConfig(options = {}) {
        const exported = {
            exportedAt: new Date().toISOString(),
            version: this.config.version,
            config: { ...this.config }
        };

        // Remove sensitive data if requested
        if (options.sanitize) {
            delete exported.config.security?.sslKeyPath;
            delete exported.config.admin?.adminEmails;
            if (exported.config.mastodon?.instances) {
                exported.config.mastodon.instances = exported.config.mastodon.instances.map(i => ({
                    ...i,
                    accessToken: '***REDACTED***'
                }));
            }
        }

        // Add checksum for integrity verification
        const configString = JSON.stringify(exported.config);
        exported.checksum = crypto.createHash('sha256').update(configString).digest('hex');

        return exported;
    }

    /**
     * Import configuration from export
     */
    importConfig(exported, options = {}) {
        // Verify checksum if present
        if (exported.checksum && !options.skipVerification) {
            const configString = JSON.stringify(exported.config);
            const checksum = crypto.createHash('sha256').update(configString).digest('hex');
            if (checksum !== exported.checksum) {
                throw new Error('Configuration checksum mismatch - file may be corrupted');
            }
        }

        // Merge with defaults to ensure completeness
        this.config = this.deepMerge(DEFAULT_CONFIG, exported.config);
        this.config._importedAt = new Date().toISOString();
        this.config._importedFrom = exported.exportedAt;

        return this.config;
    }

    /**
     * Create a backup of current configuration
     */
    async createBackup(label = null) {
        const timestamp = new Date().toISOString().replace(/[:.]/g, '-');
        const filename = label
            ? `backup-${label}-${timestamp}.json`
            : `backup-${timestamp}.json`;
        const backupPath = path.join(BACKUP_DIR, filename);

        const backup = {
            createdAt: new Date().toISOString(),
            label: label,
            config: this.config
        };

        fs.writeFileSync(backupPath, JSON.stringify(backup, null, 2), 'utf8');
        console.log(`[DeployConfig] Created backup: ${filename}`);

        // Cleanup old backups
        await this.cleanupBackups();

        return { path: backupPath, filename };
    }

    /**
     * List available backups
     */
    listBackups() {
        if (!fs.existsSync(BACKUP_DIR)) return [];

        const files = fs.readdirSync(BACKUP_DIR)
            .filter(f => f.startsWith('backup-') && f.endsWith('.json'))
            .map(filename => {
                const filepath = path.join(BACKUP_DIR, filename);
                const stats = fs.statSync(filepath);
                try {
                    const data = JSON.parse(fs.readFileSync(filepath, 'utf8'));
                    return {
                        filename,
                        path: filepath,
                        createdAt: data.createdAt,
                        label: data.label,
                        size: stats.size
                    };
                } catch (e) {
                    return { filename, path: filepath, error: true };
                }
            })
            .sort((a, b) => new Date(b.createdAt) - new Date(a.createdAt));

        return files;
    }

    /**
     * Restore from backup
     */
    async restoreBackup(filename) {
        const backupPath = path.join(BACKUP_DIR, filename);
        if (!fs.existsSync(backupPath)) {
            throw new Error(`Backup not found: ${filename}`);
        }

        // Create a backup of current config before restoring
        await this.createBackup('pre-restore');

        const backup = JSON.parse(fs.readFileSync(backupPath, 'utf8'));
        this.config = this.deepMerge(DEFAULT_CONFIG, backup.config);
        this.config._restoredAt = new Date().toISOString();
        this.config._restoredFrom = filename;

        await this.save();
        console.log(`[DeployConfig] Restored from backup: ${filename}`);

        return this.config;
    }

    /**
     * Cleanup old backups (keep maxBackups most recent)
     */
    async cleanupBackups() {
        const maxBackups = this.config?.backup?.maxBackups || 24;
        const backups = this.listBackups().filter(b => !b.label); // Only auto backups

        if (backups.length > maxBackups) {
            const toDelete = backups.slice(maxBackups);
            for (const backup of toDelete) {
                try {
                    fs.unlinkSync(backup.path);
                    console.log(`[DeployConfig] Deleted old backup: ${backup.filename}`);
                } catch (e) {
                    console.error(`[DeployConfig] Error deleting backup: ${e.message}`);
                }
            }
        }
    }

    /**
     * Generate deployment package (config + instructions)
     */
    generateDeploymentPackage(targetPreset = null) {
        const config = targetPreset
            ? this.deepMerge(DEFAULT_CONFIG, PRESETS[targetPreset]?.config || {})
            : this.config;

        return {
            name: 'VoiceLink Deployment Package',
            generatedAt: new Date().toISOString(),
            preset: targetPreset,
            config: config,
            instructions: {
                steps: [
                    '1. Copy deploy.json to server/data/ directory',
                    '2. Set environment variables (see below)',
                    '3. Run: npm install',
                    '4. Run: pm2 start server/routes/local-server.js --name voicelink',
                    '5. Configure nginx/reverse proxy (optional)',
                    '6. Generate default rooms: POST /api/rooms/generate-defaults'
                ],
                envVars: {
                    VOICELINK_PORT: config.server?.port || 3010,
                    VOICELINK_HOST: config.server?.host || '0.0.0.0',
                    VOICELINK_CONFIG_DIR: '/path/to/data',
                    NODE_ENV: 'production'
                },
                nginx: this.generateNginxConfig(config),
                systemd: this.generateSystemdConfig(config)
            }
        };
    }

    /**
     * Generate nginx configuration snippet
     */
    generateNginxConfig(config) {
        const port = config.server?.port || 3010;
        return `
# VoiceLink Nginx Configuration
server {
    listen 80;
    server_name your-domain.com;

    location / {
        proxy_pass http://127.0.0.1:${port};
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;

        # WebSocket timeout
        proxy_read_timeout 86400;
    }
}
`.trim();
    }

    /**
     * Generate systemd service configuration
     */
    generateSystemdConfig(config) {
        return `
# VoiceLink Systemd Service
# Save as /etc/systemd/system/voicelink.service
[Unit]
Description=VoiceLink Voice Chat Server
After=network.target

[Service]
Type=simple
User=voicelink
WorkingDirectory=/opt/voicelink
ExecStart=/usr/bin/node server/routes/local-server.js
Restart=always
RestartSec=10
Environment=NODE_ENV=production
Environment=VOICELINK_PORT=${config.server?.port || 3010}

[Install]
WantedBy=multi-user.target
`.trim();
    }

    /**
     * Deep merge objects
     */
    deepMerge(target, source) {
        const result = { ...target };
        for (const key in source) {
            if (source[key] && typeof source[key] === 'object' && !Array.isArray(source[key])) {
                result[key] = this.deepMerge(target[key] || {}, source[key]);
            } else {
                result[key] = source[key];
            }
        }
        return result;
    }
}

// Singleton instance
const deployConfig = new DeploymentConfig();

module.exports = {
    DeploymentConfig,
    deployConfig,
    DEFAULT_CONFIG,
    PRESETS
};
