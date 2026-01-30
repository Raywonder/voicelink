#!/usr/bin/env node
/**
 * VoiceLink Documentation Sync Module
 *
 * For installations without Ollama:
 * - Pulls documentation from main VoiceLink server
 * - Places docs in correct local directories
 * - Checks for updates periodically
 *
 * For installations with Ollama:
 * - Generates docs locally
 * - Falls back to sync if generation fails
 */

const fs = require('fs');
const path = require('path');
const https = require('https');
const http = require('http');
const { execFileSync } = require('child_process');

// Configuration
const MAIN_SERVER = process.env.VOICELINK_MAIN_SERVER || 'https://voicelink.devinecreations.net';
const DOCS_DIR = path.join(__dirname, '../../docs');
const PUBLIC_DOCS_DIR = path.join(DOCS_DIR, 'public');
const AUTH_DOCS_DIR = path.join(DOCS_DIR, 'authenticated');
const SYNC_CONFIG_FILE = path.join(__dirname, '../../data/docs-sync.json');

class DocsSyncModule {
    constructor(options = {}) {
        this.mainServer = options.mainServer || MAIN_SERVER;
        this.docsDir = options.docsDir || DOCS_DIR;
        this.publicDir = options.publicDir || PUBLIC_DOCS_DIR;
        this.authDir = options.authDir || AUTH_DOCS_DIR;
        this.ollamaAvailable = false;
        this.syncConfig = this.loadSyncConfig();
    }

    loadSyncConfig() {
        const defaults = {
            lastSync: null,
            lastCheck: null,
            syncedVersion: null,
            autoSync: true,
            syncInterval: 86400000, // Daily
            preferLocal: true // Prefer local Ollama generation
        };

        try {
            if (fs.existsSync(SYNC_CONFIG_FILE)) {
                return { ...defaults, ...JSON.parse(fs.readFileSync(SYNC_CONFIG_FILE, 'utf8')) };
            }
        } catch (e) { /* use defaults */ }

        return defaults;
    }

    saveSyncConfig() {
        const dataDir = path.dirname(SYNC_CONFIG_FILE);
        if (!fs.existsSync(dataDir)) {
            fs.mkdirSync(dataDir, { recursive: true });
        }
        fs.writeFileSync(SYNC_CONFIG_FILE, JSON.stringify(this.syncConfig, null, 2), 'utf8');
    }

    /**
     * Check if Ollama is available locally
     */
    async checkOllama() {
        return new Promise((resolve) => {
            const req = http.request({
                hostname: 'localhost',
                port: 11434,
                path: '/api/tags',
                method: 'GET',
                timeout: 3000
            }, (res) => {
                this.ollamaAvailable = res.statusCode === 200;
                resolve(this.ollamaAvailable);
            });

            req.on('error', () => {
                this.ollamaAvailable = false;
                resolve(false);
            });

            req.on('timeout', () => {
                req.destroy();
                this.ollamaAvailable = false;
                resolve(false);
            });

            req.end();
        });
    }

    /**
     * Fetch JSON from URL
     */
    async fetchJson(url) {
        return new Promise((resolve, reject) => {
            const client = url.startsWith('https') ? https : http;

            client.get(url, (res) => {
                let data = '';
                res.on('data', chunk => data += chunk);
                res.on('end', () => {
                    try {
                        resolve(JSON.parse(data));
                    } catch (e) {
                        reject(new Error('Invalid JSON response'));
                    }
                });
            }).on('error', reject);
        });
    }

    /**
     * Download file from URL
     */
    async downloadFile(url, destPath) {
        return new Promise((resolve, reject) => {
            const client = url.startsWith('https') ? https : http;
            const dir = path.dirname(destPath);

            if (!fs.existsSync(dir)) {
                fs.mkdirSync(dir, { recursive: true });
            }

            const file = fs.createWriteStream(destPath);

            client.get(url, (res) => {
                if (res.statusCode === 301 || res.statusCode === 302) {
                    this.downloadFile(res.headers.location, destPath)
                        .then(resolve)
                        .catch(reject);
                    return;
                }

                if (res.statusCode !== 200) {
                    reject(new Error(`HTTP ${res.statusCode}`));
                    return;
                }

                res.pipe(file);
                file.on('finish', () => {
                    file.close();
                    resolve(destPath);
                });
            }).on('error', (err) => {
                fs.unlink(destPath, () => {});
                reject(err);
            });
        });
    }

    /**
     * Check for documentation updates from main server
     */
    async checkForUpdates() {
        console.log('[DocsSync] Checking for updates from', this.mainServer);

        try {
            const remoteStatus = await this.fetchJson(`${this.mainServer}/api/docs/status`);
            const remoteList = await this.fetchJson(`${this.mainServer}/api/docs/list`);

            const localPublicCount = fs.existsSync(this.publicDir)
                ? fs.readdirSync(this.publicDir).filter(f => f.endsWith('.html')).length
                : 0;
            const localAuthCount = fs.existsSync(this.authDir)
                ? fs.readdirSync(this.authDir).filter(f => f.endsWith('.html')).length
                : 0;

            const needsUpdate =
                remoteStatus.publicDocs > localPublicCount ||
                remoteStatus.authenticatedDocs > localAuthCount ||
                (remoteStatus.lastGenerated &&
                 this.syncConfig.lastSync &&
                 new Date(remoteStatus.lastGenerated) > new Date(this.syncConfig.lastSync));

            this.syncConfig.lastCheck = new Date().toISOString();
            this.saveSyncConfig();

            return {
                needsUpdate,
                local: { public: localPublicCount, authenticated: localAuthCount },
                remote: {
                    public: remoteStatus.publicDocs,
                    authenticated: remoteStatus.authenticatedDocs,
                    lastGenerated: remoteStatus.lastGenerated
                },
                files: remoteList
            };

        } catch (error) {
            console.error('[DocsSync] Failed to check updates:', error.message);
            return { needsUpdate: false, error: error.message };
        }
    }

    /**
     * Sync documentation from main server
     */
    async syncFromServer() {
        console.log('[DocsSync] Syncing documentation from', this.mainServer);

        try {
            const remoteList = await this.fetchJson(`${this.mainServer}/api/docs/list`);
            let synced = 0;

            [this.docsDir, this.publicDir, this.authDir].forEach(dir => {
                if (!fs.existsSync(dir)) {
                    fs.mkdirSync(dir, { recursive: true });
                }
            });

            if (remoteList.public && remoteList.public.length > 0) {
                console.log(`[DocsSync] Downloading ${remoteList.public.length} public docs...`);
                for (const doc of remoteList.public) {
                    try {
                        const url = `${this.mainServer}/docs/${doc.file}`;
                        const destPath = path.join(this.publicDir, doc.file);
                        await this.downloadFile(url, destPath);
                        console.log(`  Downloaded: ${doc.file}`);
                        synced++;
                    } catch (err) {
                        console.error(`  Failed: ${doc.file} - ${err.message}`);
                    }
                }
            }

            if (remoteList.authenticated && remoteList.authenticated.length > 0) {
                console.log(`[DocsSync] Downloading ${remoteList.authenticated.length} admin docs...`);
                for (const doc of remoteList.authenticated) {
                    try {
                        const url = `${this.mainServer}/admin/docs/${doc.file}`;
                        const destPath = path.join(this.authDir, doc.file);
                        await this.downloadFile(url, destPath);
                        console.log(`  Downloaded: ${doc.file}`);
                        synced++;
                    } catch (err) {
                        console.error(`  Failed: ${doc.file} - ${err.message}`);
                    }
                }
            }

            this.syncConfig.lastSync = new Date().toISOString();
            this.syncConfig.syncedVersion = 'remote';
            this.saveSyncConfig();

            console.log(`[DocsSync] Sync complete. Downloaded ${synced} files.`);
            return { success: true, synced };

        } catch (error) {
            console.error('[DocsSync] Sync failed:', error.message);
            return { success: false, error: error.message };
        }
    }

    /**
     * Initialize documentation - check Ollama, sync if needed
     */
    async initialize() {
        console.log('[DocsSync] Initializing documentation module...');

        const hasOllama = await this.checkOllama();
        console.log(`[DocsSync] Ollama available: ${hasOllama}`);

        const hasLocalDocs = fs.existsSync(this.publicDir) &&
            fs.readdirSync(this.publicDir).filter(f => f.endsWith('.html')).length > 0;

        if (!hasLocalDocs) {
            console.log('[DocsSync] No local docs found, syncing from main server...');
            await this.syncFromServer();
        } else if (this.syncConfig.autoSync) {
            const timeSinceSync = this.syncConfig.lastSync
                ? Date.now() - new Date(this.syncConfig.lastSync).getTime()
                : Infinity;

            if (timeSinceSync > this.syncConfig.syncInterval) {
                console.log('[DocsSync] Auto-sync interval reached, checking for updates...');
                const updates = await this.checkForUpdates();
                if (updates.needsUpdate) {
                    await this.syncFromServer();
                }
            }
        }

        return {
            ollamaAvailable: hasOllama,
            hasLocalDocs: fs.existsSync(this.publicDir),
            lastSync: this.syncConfig.lastSync,
            docsDir: this.docsDir
        };
    }

    /**
     * Generate locally or sync from server
     */
    async ensureDocs() {
        const hasOllama = await this.checkOllama();

        if (hasOllama && this.syncConfig.preferLocal) {
            console.log('[DocsSync] Ollama available, generating docs locally...');
            try {
                const generatorPath = path.join(__dirname, 'generate-docs.js');

                if (fs.existsSync(generatorPath)) {
                    // Use execFileSync for safety - no shell interpolation
                    execFileSync('node', [generatorPath], {
                        cwd: __dirname,
                        timeout: 600000,
                        stdio: 'inherit'
                    });

                    this.syncConfig.lastSync = new Date().toISOString();
                    this.syncConfig.syncedVersion = 'local';
                    this.saveSyncConfig();

                    return { source: 'local', success: true };
                }
            } catch (error) {
                console.error('[DocsSync] Local generation failed, falling back to sync:', error.message);
            }
        }

        const result = await this.syncFromServer();
        return { source: 'remote', ...result };
    }

    /**
     * Get local documentation URLs
     */
    getDocsUrls(baseUrl = '') {
        const publicDocs = [];
        const authDocs = [];

        if (fs.existsSync(this.publicDir)) {
            fs.readdirSync(this.publicDir)
                .filter(f => f.endsWith('.html'))
                .forEach(f => {
                    publicDocs.push({
                        name: f.replace('.html', '').replace(/-/g, ' '),
                        file: f,
                        url: `${baseUrl}/docs/${f}`
                    });
                });
        }

        if (fs.existsSync(this.authDir)) {
            fs.readdirSync(this.authDir)
                .filter(f => f.endsWith('.html'))
                .forEach(f => {
                    authDocs.push({
                        name: f.replace('.html', '').replace(/-/g, ' '),
                        file: f,
                        url: `${baseUrl}/admin/docs/${f}`
                    });
                });
        }

        return { public: publicDocs, authenticated: authDocs };
    }
}

// CLI usage
if (require.main === module) {
    const args = process.argv.slice(2);
    const command = args[0] || 'sync';
    const sync = new DocsSyncModule();

    switch (command) {
        case 'init':
            sync.initialize().then(r => console.log('\nResult:', r));
            break;
        case 'check':
            sync.checkForUpdates().then(r => console.log('\nResult:', r));
            break;
        case 'sync':
            sync.syncFromServer().then(r => console.log('\nResult:', r));
            break;
        case 'ensure':
            sync.ensureDocs().then(r => console.log('\nResult:', r));
            break;
        default:
            console.log('Usage: node docs-sync.js [init|check|sync|ensure]');
    }
}

module.exports = DocsSyncModule;
