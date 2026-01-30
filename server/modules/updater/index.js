/**
 * VoiceLink Updater Module
 *
 * Features:
 * - Selective feature updates for federated installs
 * - Admin chooses what updates get pushed
 * - Force push only for API-incompatible changes
 * - Connection/reconnection alerts
 */

const fs = require('fs');
const path = require('path');
const https = require('https');
const http = require('http');

class UpdaterModule {
    constructor(options = {}) {
        this.config = options.config || {};
        this.dataDir = options.dataDir || path.join(__dirname, '../../../data/updater');
        this.server = options.server;

        // Main hub URL for updates
        this.hubUrl = this.config.hubUrl || 'https://voicelink.devinecreations.net';

        // Current version
        this.currentVersion = this.config.version || '1.0.1';

        // Update categories that can be selectively enabled/disabled
        this.updateCategories = {
            'core': {
                name: 'Core Updates',
                description: 'Essential server functionality and security fixes',
                forceEnabled: true, // Always enabled, cannot be disabled
                includes: ['security', 'api-compatibility', 'critical-fixes']
            },
            'rooms': {
                name: 'Room Features',
                description: 'Room management, creation, and configuration updates',
                forceEnabled: false,
                includes: ['room-types', 'room-settings', 'room-permissions']
            },
            'media': {
                name: 'Media Features',
                description: 'Media playback, streaming, and Jellyfin integration',
                forceEnabled: false,
                includes: ['media-player', 'jellyfin', 'audio-description', 'intros-trailers']
            },
            'audio': {
                name: 'Audio Features',
                description: 'Spatial audio, voice effects, audio routing',
                forceEnabled: false,
                includes: ['spatial-audio', 'voice-effects', 'audio-routing', 'noise-reduction']
            },
            'federation': {
                name: 'Federation Features',
                description: 'Server federation and room sharing',
                forceEnabled: false,
                includes: ['federation-sync', 'room-discovery', 'cross-server']
            },
            'ui': {
                name: 'UI/Theme Updates',
                description: 'Visual updates, themes, and interface changes',
                forceEnabled: false,
                includes: ['themes', 'layouts', 'accessibility']
            },
            'integrations': {
                name: 'Third-Party Integrations',
                description: 'Mastodon, WHMCS, Ecripto, and other integrations',
                forceEnabled: false,
                includes: ['mastodon', 'whmcs', 'ecripto', 'jellyfin-integration']
            },
            'admin': {
                name: 'Admin Panel Updates',
                description: 'Admin dashboard and management features',
                forceEnabled: false,
                includes: ['admin-dashboard', 'user-management', 'analytics']
            }
        };

        // User preferences for updates
        this.updatePreferences = {
            autoUpdate: false,
            enabledCategories: ['core', 'rooms', 'audio'], // Default enabled
            notifyOnUpdate: true,
            updateChannel: 'stable' // 'stable', 'beta', 'dev'
        };

        // Connection tracking for admin alerts
        this.connections = new Map(); // connectionId -> { userId, status, lastSeen, reconnecting }
        this.adminAlerts = [];

        // Initialize
        if (!fs.existsSync(this.dataDir)) {
            fs.mkdirSync(this.dataDir, { recursive: true });
        }
        this.loadPreferences();
    }

    loadPreferences() {
        const prefsFile = path.join(this.dataDir, 'update-preferences.json');
        try {
            if (fs.existsSync(prefsFile)) {
                const data = JSON.parse(fs.readFileSync(prefsFile, 'utf8'));
                Object.assign(this.updatePreferences, data);
            }
        } catch (e) {
            console.error('[Updater] Error loading preferences:', e.message);
        }
    }

    savePreferences() {
        const prefsFile = path.join(this.dataDir, 'update-preferences.json');
        fs.writeFileSync(prefsFile, JSON.stringify(this.updatePreferences, null, 2));
    }

    /**
     * Get all update categories with current status
     */
    getCategories() {
        return Object.entries(this.updateCategories).map(([id, category]) => ({
            id,
            ...category,
            enabled: category.forceEnabled || this.updatePreferences.enabledCategories.includes(id)
        }));
    }

    /**
     * Enable/disable an update category
     */
    setCategoryEnabled(categoryId, enabled) {
        const category = this.updateCategories[categoryId];
        if (!category) {
            return { success: false, error: 'Unknown category' };
        }

        if (category.forceEnabled && !enabled) {
            return { success: false, error: 'This category cannot be disabled' };
        }

        if (enabled) {
            if (!this.updatePreferences.enabledCategories.includes(categoryId)) {
                this.updatePreferences.enabledCategories.push(categoryId);
            }
        } else {
            this.updatePreferences.enabledCategories = this.updatePreferences.enabledCategories.filter(c => c !== categoryId);
        }

        this.savePreferences();
        return { success: true };
    }

    /**
     * Check for available updates from hub
     */
    async checkForUpdates() {
        return new Promise((resolve, reject) => {
            const url = `${this.hubUrl}/api/updates/check`;
            const client = url.startsWith('https') ? https : http;

            const req = client.request(url, {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' }
            }, (res) => {
                let data = '';
                res.on('data', chunk => data += chunk);
                res.on('end', () => {
                    try {
                        const result = JSON.parse(data);
                        resolve(this.filterUpdates(result));
                    } catch (e) {
                        reject(new Error('Invalid response'));
                    }
                });
            });

            req.on('error', reject);
            req.write(JSON.stringify({
                currentVersion: this.currentVersion,
                enabledCategories: this.updatePreferences.enabledCategories,
                channel: this.updatePreferences.updateChannel
            }));
            req.end();
        });
    }

    /**
     * Filter updates based on user preferences
     */
    filterUpdates(updates) {
        if (!updates || !updates.available) return updates;

        const enabledCategories = new Set(this.updatePreferences.enabledCategories);

        // Always include force-enabled categories
        Object.entries(this.updateCategories).forEach(([id, cat]) => {
            if (cat.forceEnabled) enabledCategories.add(id);
        });

        // Filter updates
        const filteredUpdates = updates.available.filter(update => {
            // Always include critical/security updates
            if (update.critical || update.security) return true;

            // Check if update category is enabled
            return update.categories?.some(cat => enabledCategories.has(cat));
        });

        return {
            ...updates,
            available: filteredUpdates,
            filtered: updates.available.length - filteredUpdates.length
        };
    }

    /**
     * Apply an update
     */
    async applyUpdate(updateId) {
        // Implementation would download and apply specific update
        return { success: true, message: 'Update applied' };
    }

    /**
     * Check if update is compatible with current API
     */
    isApiCompatible(update) {
        if (!update.minApiVersion) return true;
        // Compare API versions
        return this.compareVersions(this.currentVersion, update.minApiVersion) >= 0;
    }

    /**
     * Compare version strings
     */
    compareVersions(v1, v2) {
        const parts1 = v1.split('.').map(Number);
        const parts2 = v2.split('.').map(Number);

        for (let i = 0; i < Math.max(parts1.length, parts2.length); i++) {
            const p1 = parts1[i] || 0;
            const p2 = parts2[i] || 0;
            if (p1 > p2) return 1;
            if (p1 < p2) return -1;
        }
        return 0;
    }

    // ==========================================
    // Connection Alerts for Admin
    // ==========================================

    /**
     * Track connection status
     */
    trackConnection(connectionId, userId, status) {
        const existing = this.connections.get(connectionId);

        if (status === 'reconnecting' && existing) {
            // Alert admin about reconnection
            this.addAdminAlert({
                type: 'connection_reconnecting',
                connectionId,
                userId,
                message: `User ${userId || 'Anonymous'} is reconnecting...`,
                timestamp: Date.now()
            });
        }

        this.connections.set(connectionId, {
            userId,
            status,
            lastSeen: Date.now(),
            reconnecting: status === 'reconnecting'
        });
    }

    /**
     * Handle connection restored
     */
    connectionRestored(connectionId) {
        const conn = this.connections.get(connectionId);
        if (conn && conn.reconnecting) {
            conn.reconnecting = false;
            conn.status = 'connected';
            conn.lastSeen = Date.now();

            this.addAdminAlert({
                type: 'connection_restored',
                connectionId,
                userId: conn.userId,
                message: `User ${conn.userId || 'Anonymous'} reconnected successfully`,
                timestamp: Date.now()
            });
        }
    }

    /**
     * Handle connection lost
     */
    connectionLost(connectionId, reason) {
        const conn = this.connections.get(connectionId);
        if (conn) {
            this.addAdminAlert({
                type: 'connection_lost',
                connectionId,
                userId: conn.userId,
                reason,
                message: `User ${conn.userId || 'Anonymous'} disconnected: ${reason}`,
                timestamp: Date.now()
            });
        }
        this.connections.delete(connectionId);
    }

    /**
     * Add admin alert
     */
    addAdminAlert(alert) {
        this.adminAlerts.unshift(alert);

        // Keep only last 100 alerts
        if (this.adminAlerts.length > 100) {
            this.adminAlerts = this.adminAlerts.slice(0, 100);
        }

        // Emit to admin sockets if server available
        if (this.server && this.server.io) {
            this.server.io.to('admin-room').emit('admin-alert', alert);
        }
    }

    /**
     * Get admin alerts
     */
    getAdminAlerts(limit = 50) {
        return this.adminAlerts.slice(0, limit);
    }

    /**
     * Clear admin alerts
     */
    clearAdminAlerts() {
        this.adminAlerts = [];
        return { success: true };
    }

    /**
     * Get update preferences (for admin panel)
     */
    getPreferences() {
        return {
            ...this.updatePreferences,
            categories: this.getCategories()
        };
    }

    /**
     * Update preferences
     */
    setPreferences(updates) {
        if (updates.autoUpdate !== undefined) {
            this.updatePreferences.autoUpdate = updates.autoUpdate;
        }
        if (updates.notifyOnUpdate !== undefined) {
            this.updatePreferences.notifyOnUpdate = updates.notifyOnUpdate;
        }
        if (updates.updateChannel) {
            this.updatePreferences.updateChannel = updates.updateChannel;
        }
        if (updates.enabledCategories) {
            // Ensure core is always included
            const categories = new Set(updates.enabledCategories);
            categories.add('core');
            this.updatePreferences.enabledCategories = Array.from(categories);
        }

        this.savePreferences();
        return { success: true, preferences: this.updatePreferences };
    }

    /**
     * Get current status
     */
    getStatus() {
        return {
            version: this.currentVersion,
            channel: this.updatePreferences.updateChannel,
            autoUpdate: this.updatePreferences.autoUpdate,
            enabledCategories: this.updatePreferences.enabledCategories,
            activeConnections: this.connections.size,
            pendingAlerts: this.adminAlerts.filter(a => !a.acknowledged).length
        };
    }
}

module.exports = { UpdaterModule };
