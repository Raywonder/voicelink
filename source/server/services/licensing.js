/**
 * VoiceLink Node Licensing Service
 *
 * Handles node registration, license key generation, and device activation limits.
 * - Nodes get licensed after 10-15 minutes of being online
 * - Each license allows 3 device activations (1 auto + 2 on request)
 * - Devices can be deactivated to free up slots
 * - Additional activations can be purchased
 */

const fs = require('fs');
const path = require('path');
const crypto = require('crypto');

class VoiceLinkLicensing {
    constructor(options = {}) {
        this.dataDir = options.dataDir || path.join(__dirname, '../../../data/licensing');
        this.registrationDelayMs = (options.registrationDelayMinutes || 15) * 60 * 1000;
        this.maxFreeDevices = options.maxFreeDevices || 3;
        this.autoActivateFirst = options.autoActivateFirst !== false;

        // In-memory pending registrations (nodes waiting for license)
        this.pendingNodes = new Map();

        // License data storage
        this.licenses = new Map();
        this.devices = new Map();

        this.ensureDataDir();
        this.loadData();

        // Cleanup expired pending registrations periodically
        setInterval(() => this.cleanupPending(), 60000);
    }

    ensureDataDir() {
        if (!fs.existsSync(this.dataDir)) {
            fs.mkdirSync(this.dataDir, { recursive: true });
        }
    }

    loadData() {
        try {
            const licensesFile = path.join(this.dataDir, 'licenses.json');
            const devicesFile = path.join(this.dataDir, 'devices.json');

            if (fs.existsSync(licensesFile)) {
                const data = JSON.parse(fs.readFileSync(licensesFile, 'utf8'));
                Object.entries(data).forEach(([k, v]) => this.licenses.set(k, v));
            }

            if (fs.existsSync(devicesFile)) {
                const data = JSON.parse(fs.readFileSync(devicesFile, 'utf8'));
                Object.entries(data).forEach(([k, v]) => this.devices.set(k, v));
            }
        } catch (e) {
            console.error('[Licensing] Error loading data:', e.message);
        }
    }

    saveData() {
        try {
            const licensesFile = path.join(this.dataDir, 'licenses.json');
            const devicesFile = path.join(this.dataDir, 'devices.json');

            fs.writeFileSync(licensesFile, JSON.stringify(Object.fromEntries(this.licenses), null, 2));
            fs.writeFileSync(devicesFile, JSON.stringify(Object.fromEntries(this.devices), null, 2));
        } catch (e) {
            console.error('[Licensing] Error saving data:', e.message);
        }
    }

    /**
     * Generate a license key
     * Format: VL-XXXX-XXXX-XXXX-XXXX
     */
    generateLicenseKey() {
        const segments = [];
        for (let i = 0; i < 4; i++) {
            segments.push(crypto.randomBytes(2).toString('hex').toUpperCase());
        }
        return 'VL-' + segments.join('-');
    }

    /**
     * Generate a device ID from device info
     */
    generateDeviceId(deviceInfo) {
        const data = JSON.stringify({
            name: deviceInfo.name,
            platform: deviceInfo.platform,
            uuid: deviceInfo.uuid || deviceInfo.machineId || Date.now()
        });
        return crypto.createHash('sha256').update(data).digest('hex').substring(0, 16);
    }

    /**
     * Register a node for licensing (starts delay timer)
     */
    registerNode(nodeInfo) {
        const { nodeId, serverId, nodeUrl, version, deviceInfo } = nodeInfo;

        const registrationId = `${serverId}_${nodeId}`;

        // Check if already has a license
        const existingLicense = this.findLicenseByNode(serverId, nodeId);
        if (existingLicense) {
            return {
                success: true,
                status: 'already_licensed',
                licenseKey: existingLicense.licenseKey,
                activatedDevices: existingLicense.activatedDevices?.length || 0,
                maxDevices: existingLicense.maxDevices
            };
        }

        // Check if registration already pending
        if (this.pendingNodes.has(registrationId)) {
            const pending = this.pendingNodes.get(registrationId);
            const elapsed = Date.now() - pending.startedAt;
            const remaining = this.registrationDelayMs - elapsed;

            if (remaining <= 0) {
                // Ready to issue license
                return this.issueLicense(nodeInfo);
            }

            return {
                success: true,
                status: 'pending',
                remainingMs: remaining,
                remainingMinutes: Math.ceil(remaining / 60000),
                message: `License will be issued in ${Math.ceil(remaining / 60000)} minutes`
            };
        }

        // Start new registration
        this.pendingNodes.set(registrationId, {
            nodeId,
            serverId,
            nodeUrl,
            version,
            deviceInfo,
            startedAt: Date.now(),
            expiresAt: Date.now() + this.registrationDelayMs + 3600000 // 1hr grace
        });

        console.log(`[Licensing] Node ${nodeId} registered, license in ${this.registrationDelayMs / 60000} minutes`);

        return {
            success: true,
            status: 'registered',
            remainingMs: this.registrationDelayMs,
            remainingMinutes: Math.ceil(this.registrationDelayMs / 60000),
            message: `Registration started. License will be issued in ${Math.ceil(this.registrationDelayMs / 60000)} minutes.`
        };
    }

    /**
     * Issue a license to a node
     */
    issueLicense(nodeInfo) {
        const { nodeId, serverId, nodeUrl, version, deviceInfo } = nodeInfo;
        const registrationId = `${serverId}_${nodeId}`;

        // Generate license
        const licenseKey = this.generateLicenseKey();
        const license = {
            id: registrationId,
            licenseKey,
            nodeId,
            serverId,
            nodeUrl,
            version,
            issuedAt: new Date().toISOString(),
            lastSeen: new Date().toISOString(),
            status: 'active',
            maxDevices: this.maxFreeDevices,
            purchasedDevices: 0,
            activatedDevices: []
        };

        // Auto-activate first device if enabled
        if (this.autoActivateFirst && deviceInfo) {
            const deviceId = this.generateDeviceId(deviceInfo);
            const device = {
                id: deviceId,
                licenseKey,
                name: deviceInfo.name || 'Primary Device',
                platform: deviceInfo.platform || 'unknown',
                activatedAt: new Date().toISOString(),
                lastSeen: new Date().toISOString(),
                status: 'active',
                autoActivated: true
            };

            license.activatedDevices.push(deviceId);
            this.devices.set(deviceId, device);
        }

        this.licenses.set(registrationId, license);
        this.pendingNodes.delete(registrationId);
        this.saveData();

        console.log(`[Licensing] License issued: ${licenseKey} to node ${nodeId}`);

        return {
            success: true,
            status: 'licensed',
            licenseKey,
            activatedDevices: license.activatedDevices.length,
            maxDevices: license.maxDevices,
            remainingSlots: license.maxDevices - license.activatedDevices.length
        };
    }

    /**
     * Check license status
     */
    checkStatus(serverId, nodeId) {
        const registrationId = `${serverId}_${nodeId}`;

        // Check for issued license
        const license = this.licenses.get(registrationId);
        if (license) {
            return {
                success: true,
                status: 'licensed',
                licenseKey: license.licenseKey,
                activatedDevices: license.activatedDevices.length,
                maxDevices: license.maxDevices + license.purchasedDevices,
                remainingSlots: (license.maxDevices + license.purchasedDevices) - license.activatedDevices.length,
                devices: license.activatedDevices.map(deviceId => {
                    const device = this.devices.get(deviceId);
                    return device ? {
                        id: device.id,
                        name: device.name,
                        platform: device.platform,
                        activatedAt: device.activatedAt,
                        lastSeen: device.lastSeen
                    } : null;
                }).filter(Boolean)
            };
        }

        // Check pending registration
        const pending = this.pendingNodes.get(registrationId);
        if (pending) {
            const elapsed = Date.now() - pending.startedAt;
            const remaining = this.registrationDelayMs - elapsed;

            if (remaining <= 0) {
                // Ready - issue license now
                return this.issueLicense(pending);
            }

            return {
                success: true,
                status: 'pending',
                remainingMs: remaining,
                remainingMinutes: Math.ceil(remaining / 60000)
            };
        }

        return {
            success: false,
            status: 'not_registered',
            message: 'Node is not registered. Call /register first.'
        };
    }

    /**
     * Activate a new device on a license
     */
    activateDevice(licenseKey, deviceInfo) {
        const license = this.findLicenseByKey(licenseKey);
        if (!license) {
            return { success: false, error: 'Invalid license key' };
        }

        const maxAllowed = license.maxDevices + license.purchasedDevices;
        if (license.activatedDevices.length >= maxAllowed) {
            return {
                success: false,
                error: 'Device limit reached',
                maxDevices: maxAllowed,
                activatedDevices: license.activatedDevices.length,
                message: 'Deactivate a device or purchase additional activations.'
            };
        }

        const deviceId = this.generateDeviceId(deviceInfo);

        // Check if device already activated
        if (license.activatedDevices.includes(deviceId)) {
            const device = this.devices.get(deviceId);
            if (device) {
                device.lastSeen = new Date().toISOString();
                this.saveData();
            }
            return {
                success: true,
                status: 'already_activated',
                deviceId,
                message: 'Device is already activated.'
            };
        }

        // Activate new device
        const device = {
            id: deviceId,
            licenseKey,
            name: deviceInfo.name || `Device ${license.activatedDevices.length + 1}`,
            platform: deviceInfo.platform || 'unknown',
            activatedAt: new Date().toISOString(),
            lastSeen: new Date().toISOString(),
            status: 'active',
            autoActivated: false
        };

        license.activatedDevices.push(deviceId);
        this.devices.set(deviceId, device);
        this.saveData();

        console.log(`[Licensing] Device activated: ${deviceId} on ${licenseKey}`);

        return {
            success: true,
            status: 'activated',
            deviceId,
            activatedDevices: license.activatedDevices.length,
            remainingSlots: maxAllowed - license.activatedDevices.length
        };
    }

    /**
     * Deactivate a device to free up a slot
     */
    deactivateDevice(licenseKey, deviceId) {
        const license = this.findLicenseByKey(licenseKey);
        if (!license) {
            return { success: false, error: 'Invalid license key' };
        }

        const deviceIndex = license.activatedDevices.indexOf(deviceId);
        if (deviceIndex === -1) {
            return { success: false, error: 'Device not found on this license' };
        }

        // Remove device
        license.activatedDevices.splice(deviceIndex, 1);

        const device = this.devices.get(deviceId);
        if (device) {
            device.status = 'deactivated';
            device.deactivatedAt = new Date().toISOString();
        }

        this.saveData();

        console.log(`[Licensing] Device deactivated: ${deviceId}`);

        return {
            success: true,
            status: 'deactivated',
            deviceId,
            activatedDevices: license.activatedDevices.length,
            remainingSlots: (license.maxDevices + license.purchasedDevices) - license.activatedDevices.length
        };
    }

    /**
     * Add purchased device slots to a license
     */
    addPurchasedDevices(licenseKey, quantity = 1) {
        const license = this.findLicenseByKey(licenseKey);
        if (!license) {
            return { success: false, error: 'Invalid license key' };
        }

        license.purchasedDevices = (license.purchasedDevices || 0) + quantity;
        this.saveData();

        console.log(`[Licensing] Added ${quantity} device slots to ${licenseKey}`);

        return {
            success: true,
            newMaxDevices: license.maxDevices + license.purchasedDevices,
            purchasedTotal: license.purchasedDevices
        };
    }

    /**
     * Validate a license key for a device
     */
    validateLicense(licenseKey, deviceInfo) {
        const license = this.findLicenseByKey(licenseKey);
        if (!license) {
            return { success: false, valid: false, error: 'Invalid license key' };
        }

        if (license.status !== 'active') {
            return { success: false, valid: false, error: `License is ${license.status}` };
        }

        // Check if device is activated
        if (deviceInfo) {
            const deviceId = this.generateDeviceId(deviceInfo);
            const isActivated = license.activatedDevices.includes(deviceId);

            if (!isActivated) {
                // Try to auto-activate if slots available
                const maxAllowed = license.maxDevices + license.purchasedDevices;
                if (license.activatedDevices.length < maxAllowed) {
                    return this.activateDevice(licenseKey, deviceInfo);
                }

                return {
                    success: false,
                    valid: true,
                    deviceActivated: false,
                    error: 'Device not activated. No slots available.',
                    message: 'Deactivate another device or purchase more activations.'
                };
            }

            // Update device last seen
            const device = this.devices.get(deviceId);
            if (device) {
                device.lastSeen = new Date().toISOString();
                this.saveData();
            }
        }

        // Update license last seen
        license.lastSeen = new Date().toISOString();
        this.saveData();

        return {
            success: true,
            valid: true,
            deviceActivated: true,
            nodeId: license.nodeId,
            serverId: license.serverId,
            features: this.getLicenseFeatures(license)
        };
    }

    /**
     * Get features available for a license tier
     */
    getLicenseFeatures(license) {
        return {
            federation: true,
            hosting: true,
            customBranding: license.purchasedDevices > 0,
            prioritySupport: license.purchasedDevices >= 3
        };
    }

    /**
     * Node heartbeat - update last seen
     */
    heartbeat(licenseKey, deviceInfo) {
        const license = this.findLicenseByKey(licenseKey);
        if (!license) {
            return { success: false, error: 'Invalid license key' };
        }

        license.lastSeen = new Date().toISOString();

        if (deviceInfo) {
            const deviceId = this.generateDeviceId(deviceInfo);
            const device = this.devices.get(deviceId);
            if (device) {
                device.lastSeen = new Date().toISOString();
            }
        }

        this.saveData();

        return { success: true, status: 'ok' };
    }

    /**
     * Get all licenses (admin)
     */
    getAllLicenses() {
        return Array.from(this.licenses.values()).map(license => ({
            id: license.id,
            licenseKey: license.licenseKey,
            nodeId: license.nodeId,
            serverId: license.serverId,
            nodeUrl: license.nodeUrl,
            issuedAt: license.issuedAt,
            lastSeen: license.lastSeen,
            status: license.status,
            activatedDevices: license.activatedDevices.length,
            maxDevices: license.maxDevices + license.purchasedDevices
        }));
    }

    /**
     * Revoke a license
     */
    revokeLicense(licenseKey, reason) {
        const license = this.findLicenseByKey(licenseKey);
        if (!license) {
            return { success: false, error: 'Invalid license key' };
        }

        license.status = 'revoked';
        license.revokedAt = new Date().toISOString();
        license.revokeReason = reason;

        // Deactivate all devices
        license.activatedDevices.forEach(deviceId => {
            const device = this.devices.get(deviceId);
            if (device) {
                device.status = 'revoked';
                device.revokedAt = new Date().toISOString();
            }
        });

        this.saveData();

        console.log(`[Licensing] License revoked: ${licenseKey}`);

        return { success: true, status: 'revoked' };
    }

    // Helper methods
    findLicenseByKey(licenseKey) {
        for (const license of this.licenses.values()) {
            if (license.licenseKey === licenseKey) {
                return license;
            }
        }
        return null;
    }

    findLicenseByNode(serverId, nodeId) {
        const registrationId = `${serverId}_${nodeId}`;
        return this.licenses.get(registrationId);
    }

    cleanupPending() {
        const now = Date.now();
        for (const [id, pending] of this.pendingNodes.entries()) {
            if (pending.expiresAt < now) {
                this.pendingNodes.delete(id);
                console.log(`[Licensing] Expired pending registration: ${id}`);
            }
        }
    }
}

module.exports = { VoiceLinkLicensing };
