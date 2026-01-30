/**
 * VoiceLink Licensing API Routes
 *
 * Handles node registration, license validation, and device management.
 * Syncs with hubnode API and api_monitor for centralized management.
 */

const express = require('express');
const { VoiceLinkLicensing } = require('../services/licensing');

class LicensingRoutes {
    constructor(options = {}) {
        this.router = express.Router();
        this.licensing = new VoiceLinkLicensing(options);

        // HubNode API sync configuration
        this.hubNodeConfig = {
            enabled: options.hubNodeSync !== false,
            apiUrl: options.hubNodeApiUrl || process.env.HUBNODE_API_URL || 'https://api.devinecreations.net',
            apiKey: options.hubNodeApiKey || process.env.HUBNODE_API_KEY,
            syncInterval: options.hubNodeSyncInterval || 300000 // 5 minutes
        };

        // API Monitor configuration
        this.apiMonitorConfig = {
            enabled: options.apiMonitor !== false,
            apiUrl: options.apiMonitorUrl || process.env.API_MONITOR_URL || 'https://api.devinecreations.net/monitor',
            apiKey: options.apiMonitorKey || process.env.API_MONITOR_KEY
        };

        this.setupRoutes();
        this.startHubNodeSync();
    }

    setupRoutes() {
        // Register a node (starts delay timer)
        this.router.post('/register', express.json(), (req, res) => {
            try {
                const { nodeId, serverId, nodeUrl, version, deviceInfo } = req.body;

                if (!nodeId || !serverId) {
                    return res.status(400).json({
                        success: false,
                        error: 'nodeId and serverId are required'
                    });
                }

                const result = this.licensing.registerNode({
                    nodeId,
                    serverId,
                    nodeUrl,
                    version,
                    deviceInfo
                });

                // Sync to hubnode
                this.syncToHubNode('register', { nodeId, serverId, result });

                res.json(result);
            } catch (e) {
                console.error('[Licensing] Register error:', e);
                res.status(500).json({ success: false, error: e.message });
            }
        });

        // Check license status
        this.router.get('/status/:serverId/:nodeId', (req, res) => {
            try {
                const { serverId, nodeId } = req.params;
                const result = this.licensing.checkStatus(serverId, nodeId);
                res.json(result);
            } catch (e) {
                console.error('[Licensing] Status error:', e);
                res.status(500).json({ success: false, error: e.message });
            }
        });

        // Validate license and device
        this.router.post('/validate', express.json(), (req, res) => {
            try {
                const { licenseKey, deviceInfo } = req.body;

                if (!licenseKey) {
                    return res.status(400).json({
                        success: false,
                        error: 'licenseKey is required'
                    });
                }

                const result = this.licensing.validateLicense(licenseKey, deviceInfo);
                res.json(result);
            } catch (e) {
                console.error('[Licensing] Validate error:', e);
                res.status(500).json({ success: false, error: e.message });
            }
        });

        // Activate a device
        this.router.post('/activate', express.json(), (req, res) => {
            try {
                const { licenseKey, deviceInfo } = req.body;

                if (!licenseKey || !deviceInfo) {
                    return res.status(400).json({
                        success: false,
                        error: 'licenseKey and deviceInfo are required'
                    });
                }

                const result = this.licensing.activateDevice(licenseKey, deviceInfo);

                // Sync to hubnode
                this.syncToHubNode('activate', { licenseKey, deviceInfo, result });

                res.json(result);
            } catch (e) {
                console.error('[Licensing] Activate error:', e);
                res.status(500).json({ success: false, error: e.message });
            }
        });

        // Deactivate a device
        this.router.post('/deactivate', express.json(), (req, res) => {
            try {
                const { licenseKey, deviceId } = req.body;

                if (!licenseKey || !deviceId) {
                    return res.status(400).json({
                        success: false,
                        error: 'licenseKey and deviceId are required'
                    });
                }

                const result = this.licensing.deactivateDevice(licenseKey, deviceId);

                // Sync to hubnode
                this.syncToHubNode('deactivate', { licenseKey, deviceId, result });

                res.json(result);
            } catch (e) {
                console.error('[Licensing] Deactivate error:', e);
                res.status(500).json({ success: false, error: e.message });
            }
        });

        // Heartbeat
        this.router.post('/heartbeat', express.json(), (req, res) => {
            try {
                const { licenseKey, deviceInfo } = req.body;

                if (!licenseKey) {
                    return res.status(400).json({
                        success: false,
                        error: 'licenseKey is required'
                    });
                }

                const result = this.licensing.heartbeat(licenseKey, deviceInfo);
                res.json(result);
            } catch (e) {
                console.error('[Licensing] Heartbeat error:', e);
                res.status(500).json({ success: false, error: e.message });
            }
        });

        // Get all licenses (admin)
        this.router.get('/all', this.adminAuth.bind(this), (req, res) => {
            try {
                const licenses = this.licensing.getAllLicenses();
                res.json({ success: true, licenses, count: licenses.length });
            } catch (e) {
                console.error('[Licensing] GetAll error:', e);
                res.status(500).json({ success: false, error: e.message });
            }
        });

        // Revoke license (admin)
        this.router.post('/revoke', this.adminAuth.bind(this), express.json(), (req, res) => {
            try {
                const { licenseKey, reason } = req.body;

                if (!licenseKey) {
                    return res.status(400).json({
                        success: false,
                        error: 'licenseKey is required'
                    });
                }

                const result = this.licensing.revokeLicense(licenseKey, reason);

                // Sync to hubnode
                this.syncToHubNode('revoke', { licenseKey, reason, result });

                res.json(result);
            } catch (e) {
                console.error('[Licensing] Revoke error:', e);
                res.status(500).json({ success: false, error: e.message });
            }
        });

        // Add purchased devices (admin/payment webhook)
        this.router.post('/purchase-devices', this.adminAuth.bind(this), express.json(), (req, res) => {
            try {
                const { licenseKey, quantity } = req.body;

                if (!licenseKey) {
                    return res.status(400).json({
                        success: false,
                        error: 'licenseKey is required'
                    });
                }

                const result = this.licensing.addPurchasedDevices(licenseKey, quantity || 1);

                // Sync to hubnode
                this.syncToHubNode('purchase', { licenseKey, quantity, result });

                res.json(result);
            } catch (e) {
                console.error('[Licensing] Purchase error:', e);
                res.status(500).json({ success: false, error: e.message });
            }
        });

        // API Monitor endpoints
        this.router.get('/monitor/health', (req, res) => {
            res.json({
                success: true,
                service: 'voicelink-licensing',
                status: 'healthy',
                timestamp: new Date().toISOString(),
                stats: {
                    totalLicenses: this.licensing.licenses.size,
                    totalDevices: this.licensing.devices.size,
                    pendingRegistrations: this.licensing.pendingNodes.size,
                    hubNodeSyncEnabled: this.hubNodeConfig.enabled,
                    apiMonitorEnabled: this.apiMonitorConfig.enabled
                }
            });
        });

        this.router.get('/monitor/stats', (req, res) => {
            const licenses = this.licensing.getAllLicenses();
            const activeLicenses = licenses.filter(l => l.status === 'active').length;
            const totalDevices = licenses.reduce((sum, l) => sum + l.activatedDevices, 0);

            res.json({
                success: true,
                stats: {
                    totalLicenses: licenses.length,
                    activeLicenses,
                    revokedLicenses: licenses.length - activeLicenses,
                    totalDevices,
                    pendingRegistrations: this.licensing.pendingNodes.size,
                    averageDevicesPerLicense: licenses.length > 0 ? (totalDevices / licenses.length).toFixed(2) : 0
                }
            });
        });

        // API Monitor - check specific key
        this.router.get('/monitor/key/:licenseKey', this.adminAuth.bind(this), (req, res) => {
            const license = this.licensing.findLicenseByKey(req.params.licenseKey);
            if (!license) {
                return res.status(404).json({ success: false, error: 'License not found' });
            }

            const devices = license.activatedDevices.map(deviceId => {
                const device = this.licensing.devices.get(deviceId);
                return device || { id: deviceId, status: 'unknown' };
            });

            res.json({
                success: true,
                license: {
                    id: license.id,
                    licenseKey: license.licenseKey,
                    nodeId: license.nodeId,
                    serverId: license.serverId,
                    status: license.status,
                    issuedAt: license.issuedAt,
                    lastSeen: license.lastSeen,
                    maxDevices: license.maxDevices + (license.purchasedDevices || 0),
                    purchasedDevices: license.purchasedDevices || 0
                },
                devices
            });
        });
    }

    adminAuth(req, res, next) {
        const authHeader = req.headers.authorization;
        if (!authHeader || !authHeader.startsWith('Bearer ')) {
            return res.status(401).json({ success: false, error: 'Authorization required' });
        }

        const token = authHeader.split(' ')[1];

        // Check against admin tokens (from env or config)
        const adminTokens = (process.env.ADMIN_TOKENS || 'admin-dev-token').split(',');
        if (!adminTokens.includes(token)) {
            return res.status(403).json({ success: false, error: 'Invalid admin token' });
        }

        next();
    }

    async syncToHubNode(action, data) {
        if (!this.hubNodeConfig.enabled || !this.hubNodeConfig.apiKey) {
            return;
        }

        try {
            const response = await fetch(`${this.hubNodeConfig.apiUrl}/voicelink-nodes/sync`, {
                method: 'POST',
                headers: {
                    'Content-Type': 'application/json',
                    'Authorization': `Bearer ${this.hubNodeConfig.apiKey}`
                },
                body: JSON.stringify({
                    action,
                    data,
                    timestamp: new Date().toISOString(),
                    source: 'voicelink-server'
                })
            });

            if (!response.ok) {
                console.warn(`[Licensing] HubNode sync failed: ${response.status}`);
            }
        } catch (e) {
            console.warn('[Licensing] HubNode sync error:', e.message);
        }
    }

    async reportToApiMonitor(status, data) {
        if (!this.apiMonitorConfig.enabled || !this.apiMonitorConfig.apiKey) {
            return;
        }

        try {
            const response = await fetch(`${this.apiMonitorConfig.apiUrl}/report`, {
                method: 'POST',
                headers: {
                    'Content-Type': 'application/json',
                    'Authorization': `Bearer ${this.apiMonitorConfig.apiKey}`
                },
                body: JSON.stringify({
                    service: 'voicelink-licensing',
                    status,
                    data,
                    timestamp: new Date().toISOString()
                })
            });

            if (!response.ok) {
                console.warn(`[Licensing] API Monitor report failed: ${response.status}`);
            }
        } catch (e) {
            console.warn('[Licensing] API Monitor report error:', e.message);
        }
    }

    startHubNodeSync() {
        if (!this.hubNodeConfig.enabled) return;

        // Periodic sync of all licenses to hubnode
        setInterval(async () => {
            const licenses = this.licensing.getAllLicenses();
            await this.syncToHubNode('bulk_sync', { licenses, count: licenses.length });
            await this.reportToApiMonitor('healthy', {
                totalLicenses: licenses.length,
                activeDevices: this.licensing.devices.size
            });
        }, this.hubNodeConfig.syncInterval);

        console.log(`[Licensing] HubNode sync enabled, interval: ${this.hubNodeConfig.syncInterval}ms`);
    }

    getRouter() {
        return this.router;
    }
}

module.exports = { LicensingRoutes };
