/**
 * VoiceLink WHMCS Integration Module
 *
 * Integrates with WHMCS for:
 * - VM provisioning and management
 * - Service/license validation
 * - Client account sync
 * - Auto-assign VMs to WHMCS services
 */

const https = require('https');
const http = require('http');
const crypto = require('crypto');
const fs = require('fs');
const path = require('path');

class WHMCSIntegrationModule {
    constructor(options = {}) {
        this.config = options.config || {};
        this.dataDir = options.dataDir || path.join(__dirname, '../../../data/whmcs');

        // WHMCS API settings
        this.whmcsUrl = this.config.whmcsUrl || '';
        this.apiIdentifier = this.config.apiIdentifier || '';
        this.apiSecret = this.config.apiSecret || '';

        // VM Manager reference
        this.vmManager = options.vmManager;

        // Cached data
        this.clientsCache = new Map();
        this.servicesCache = new Map();
        this.cacheTTL = this.config.cacheTTL || 300000; // 5 minutes

        // VM provisioning settings
        this.vmProvisioningEnabled = this.config.vmProvisioning?.enabled || false;
        this.vmProductIds = this.config.vmProvisioning?.productIds || [];

        // Initialize
        if (!fs.existsSync(this.dataDir)) {
            fs.mkdirSync(this.dataDir, { recursive: true });
        }
        this.loadState();
    }

    loadState() {
        const stateFile = path.join(this.dataDir, 'whmcs-state.json');
        try {
            if (fs.existsSync(stateFile)) {
                const data = JSON.parse(fs.readFileSync(stateFile, 'utf8'));
                this.vmMappings = new Map(Object.entries(data.vmMappings || {}));
                this.lastSync = data.lastSync;
            } else {
                this.vmMappings = new Map();
            }
        } catch (e) {
            console.error('[WHMCS] Error loading state:', e.message);
            this.vmMappings = new Map();
        }
    }

    saveState() {
        const stateFile = path.join(this.dataDir, 'whmcs-state.json');
        const data = {
            lastUpdated: Date.now(),
            lastSync: this.lastSync,
            vmMappings: Object.fromEntries(this.vmMappings)
        };
        fs.writeFileSync(stateFile, JSON.stringify(data, null, 2));
    }

    /**
     * Make WHMCS API request
     */
    async apiRequest(action, params = {}) {
        return new Promise((resolve, reject) => {
            if (!this.whmcsUrl || !this.apiIdentifier || !this.apiSecret) {
                return reject(new Error('WHMCS API not configured'));
            }

            const postData = new URLSearchParams({
                identifier: this.apiIdentifier,
                secret: this.apiSecret,
                action,
                responsetype: 'json',
                ...params
            }).toString();

            const url = new URL('/includes/api.php', this.whmcsUrl);
            const isHttps = url.protocol === 'https:';
            const client = isHttps ? https : http;

            const options = {
                hostname: url.hostname,
                port: url.port || (isHttps ? 443 : 80),
                path: url.pathname,
                method: 'POST',
                headers: {
                    'Content-Type': 'application/x-www-form-urlencoded',
                    'Content-Length': Buffer.byteLength(postData)
                }
            };

            const req = client.request(options, (res) => {
                let responseData = '';
                res.on('data', chunk => responseData += chunk);
                res.on('end', () => {
                    try {
                        const json = JSON.parse(responseData);
                        if (json.result === 'error') {
                            reject(new Error(json.message || 'WHMCS API error'));
                        } else {
                            resolve(json);
                        }
                    } catch (e) {
                        reject(new Error('Invalid JSON response from WHMCS'));
                    }
                });
            });

            req.on('error', reject);
            req.setTimeout(30000, () => {
                req.destroy();
                reject(new Error('Request timeout'));
            });

            req.write(postData);
            req.end();
        });
    }

    // ==========================================
    // Client Management
    // ==========================================

    /**
     * Get WHMCS client by ID
     */
    async getClient(clientId) {
        // Check cache
        const cached = this.clientsCache.get(clientId);
        if (cached && Date.now() - cached.timestamp < this.cacheTTL) {
            return cached.data;
        }

        try {
            const result = await this.apiRequest('GetClientsDetails', { clientid: clientId });
            const clientData = {
                id: result.client.id,
                email: result.client.email,
                firstname: result.client.firstname,
                lastname: result.client.lastname,
                companyname: result.client.companyname,
                status: result.client.status
            };

            this.clientsCache.set(clientId, { data: clientData, timestamp: Date.now() });
            return clientData;
        } catch (error) {
            console.error('[WHMCS] Get client error:', error.message);
            return null;
        }
    }

    /**
     * Search clients by email
     */
    async searchClientByEmail(email) {
        try {
            const result = await this.apiRequest('GetClients', { email });
            if (result.clients?.client?.length > 0) {
                return result.clients.client[0];
            }
            return null;
        } catch (error) {
            console.error('[WHMCS] Search client error:', error.message);
            return null;
        }
    }

    // ==========================================
    // Service/Product Management
    // ==========================================

    /**
     * Get client services
     */
    async getClientServices(clientId) {
        try {
            const result = await this.apiRequest('GetClientsProducts', { clientid: clientId });
            return result.products?.product || [];
        } catch (error) {
            console.error('[WHMCS] Get services error:', error.message);
            return [];
        }
    }

    /**
     * Get service details
     */
    async getService(serviceId) {
        // Check cache
        const cached = this.servicesCache.get(serviceId);
        if (cached && Date.now() - cached.timestamp < this.cacheTTL) {
            return cached.data;
        }

        try {
            const result = await this.apiRequest('GetClientsProducts', { serviceid: serviceId });
            if (result.products?.product?.length > 0) {
                const service = result.products.product[0];
                this.servicesCache.set(serviceId, { data: service, timestamp: Date.now() });
                return service;
            }
            return null;
        } catch (error) {
            console.error('[WHMCS] Get service error:', error.message);
            return null;
        }
    }

    /**
     * Find WHMCS service by VM name
     */
    async findServiceByVMName(vmName) {
        // Check our mappings first
        for (const [serviceId, mapping] of this.vmMappings) {
            if (mapping.vmName === vmName) {
                const service = await this.getService(serviceId);
                if (service) {
                    return { ...service, mapping };
                }
            }
        }

        // Search by custom field or dedicated IP
        // This would need to query WHMCS custom fields
        return null;
    }

    /**
     * Update service custom field (e.g., VM IP address)
     */
    async updateServiceField(serviceId, fieldName, value) {
        try {
            // Get current custom fields to find the field ID
            const service = await this.getService(serviceId);
            if (!service) {
                return { success: false, error: 'Service not found' };
            }

            // Update the field
            await this.apiRequest('UpdateClientProduct', {
                serviceid: serviceId,
                customfields: `${fieldName}|${value}`
            });

            // Clear cache
            this.servicesCache.delete(serviceId);

            return { success: true };
        } catch (error) {
            return { success: false, error: error.message };
        }
    }

    // ==========================================
    // VM Provisioning Integration
    // ==========================================

    /**
     * Provision VM for WHMCS service
     */
    async provisionVMForService(serviceId, options = {}) {
        if (!this.vmManager) {
            return { success: false, error: 'VM Manager not configured' };
        }

        const service = await this.getService(serviceId);
        if (!service) {
            return { success: false, error: 'Service not found' };
        }

        // Check if VM already exists for this service
        const existingMapping = this.vmMappings.get(serviceId.toString());
        if (existingMapping) {
            return { success: false, error: 'VM already provisioned for this service', vmName: existingMapping.vmName };
        }

        // Get client info
        const client = await this.getClient(service.clientid);
        if (!client) {
            return { success: false, error: 'Client not found' };
        }

        // Generate VM name
        const vmName = options.vmName || `whmcs-${serviceId}-${crypto.randomBytes(4).toString('hex')}`;

        // Create VM
        const vmResult = await this.vmManager.createVM({
            name: vmName,
            cpu: options.cpu || this.getProductOption(service, 'cpu') || 2,
            ram: options.ram || this.getProductOption(service, 'ram') || 2048,
            disk: options.disk || this.getProductOption(service, 'disk') || 40,
            os_image: options.os_image || this.getProductOption(service, 'os') || 'ubuntu-24.04',
            root_password: options.root_password || crypto.randomBytes(16).toString('hex'),
            install_cockpit: true,
            client_email: client.email,
            service_id: serviceId,
            user_id: service.clientid
        });

        if (!vmResult.success) {
            return { success: false, error: vmResult.error };
        }

        // Store mapping
        this.vmMappings.set(serviceId.toString(), {
            vmName,
            vmId: vmResult.vm_id,
            ipAddress: vmResult.ip_address,
            clientId: service.clientid,
            provisionedAt: Date.now()
        });
        this.saveState();

        // Update WHMCS service with VM details
        if (vmResult.ip_address) {
            await this.updateServiceField(serviceId, 'IP Address', vmResult.ip_address);
        }

        // Assign VM in VM Manager
        this.vmManager.assignVM(vmName, {
            userId: service.clientid,
            serviceId,
            assignedBy: 'whmcs-provisioning'
        });

        return {
            success: true,
            vmName,
            ipAddress: vmResult.ip_address,
            vncPort: vmResult.vnc_port
        };
    }

    /**
     * Terminate VM for WHMCS service
     */
    async terminateVMForService(serviceId) {
        if (!this.vmManager) {
            return { success: false, error: 'VM Manager not configured' };
        }

        const mapping = this.vmMappings.get(serviceId.toString());
        if (!mapping) {
            return { success: false, error: 'No VM mapped to this service' };
        }

        // Delete VM
        const result = await this.vmManager.deleteVM(mapping.vmName);
        if (result.success) {
            this.vmMappings.delete(serviceId.toString());
            this.saveState();
        }

        return result;
    }

    /**
     * Suspend VM for WHMCS service
     */
    async suspendVMForService(serviceId) {
        if (!this.vmManager) {
            return { success: false, error: 'VM Manager not configured' };
        }

        const mapping = this.vmMappings.get(serviceId.toString());
        if (!mapping) {
            return { success: false, error: 'No VM mapped to this service' };
        }

        return await this.vmManager.suspendVM(mapping.vmName);
    }

    /**
     * Unsuspend VM for WHMCS service
     */
    async unsuspendVMForService(serviceId) {
        if (!this.vmManager) {
            return { success: false, error: 'VM Manager not configured' };
        }

        const mapping = this.vmMappings.get(serviceId.toString());
        if (!mapping) {
            return { success: false, error: 'No VM mapped to this service' };
        }

        return await this.vmManager.resumeVM(mapping.vmName);
    }

    /**
     * Get product configurable option value
     */
    getProductOption(service, optionName) {
        // Parse from service configoptions or package options
        if (service.configoptions) {
            const option = service.configoptions.find(o =>
                o.optionname?.toLowerCase().includes(optionName.toLowerCase())
            );
            if (option) {
                return parseInt(option.value) || option.value;
            }
        }
        return null;
    }

    // ==========================================
    // Sync & Auto-Assignment
    // ==========================================

    /**
     * Sync VMs with WHMCS services
     */
    async syncVMsWithServices() {
        if (!this.vmManager) {
            return { success: false, error: 'VM Manager not configured' };
        }

        console.log('[WHMCS] Starting VM-Service sync...');

        const vms = this.vmManager.getAllTrackedVMs();
        const unassignedVMs = vms.filter(vm => !vm.assignment);
        let matched = 0;

        for (const vm of unassignedVMs) {
            // Try to match VM with WHMCS service
            const service = await this.findServiceByVMName(vm.name);
            if (service) {
                this.vmManager.assignVM(vm.name, {
                    userId: service.clientid,
                    serviceId: service.id,
                    assignedBy: 'whmcs-sync'
                });
                matched++;
                console.log(`[WHMCS] Matched VM ${vm.name} to service ${service.id}`);
            }
        }

        this.lastSync = Date.now();
        this.saveState();

        return {
            success: true,
            totalVMs: vms.length,
            unassigned: unassignedVMs.length,
            matched
        };
    }

    /**
     * Get VM mapping for a service
     */
    getVMForService(serviceId) {
        return this.vmMappings.get(serviceId.toString());
    }

    /**
     * Get all VM mappings
     */
    getAllVMMappings() {
        return Array.from(this.vmMappings.entries()).map(([serviceId, mapping]) => ({
            serviceId,
            ...mapping
        }));
    }

    /**
     * Set VM Manager reference
     */
    setVMManager(vmManager) {
        this.vmManager = vmManager;
        if (vmManager) {
            vmManager.setWHMCSModule(this);
        }
    }

    // ==========================================
    // WHMCS Webhook Handlers
    // ==========================================

    /**
     * Handle WHMCS webhook for service actions
     */
    async handleWebhook(action, data) {
        switch (action) {
            case 'ServiceCreate':
            case 'AfterModuleCreate':
                // Check if this is a VM product
                if (this.vmProductIds.includes(data.productid) && this.vmProvisioningEnabled) {
                    return await this.provisionVMForService(data.serviceid, {
                        root_password: data.password
                    });
                }
                break;

            case 'ServiceSuspend':
            case 'AfterModuleSuspend':
                return await this.suspendVMForService(data.serviceid);

            case 'ServiceUnsuspend':
            case 'AfterModuleUnsuspend':
                return await this.unsuspendVMForService(data.serviceid);

            case 'ServiceTerminate':
            case 'AfterModuleTerminate':
                return await this.terminateVMForService(data.serviceid);

            default:
                return { success: true, message: 'No action required' };
        }
    }

    /**
     * Get module statistics
     */
    getStatistics() {
        return {
            configured: !!(this.whmcsUrl && this.apiIdentifier && this.apiSecret),
            vmProvisioningEnabled: this.vmProvisioningEnabled,
            totalMappings: this.vmMappings.size,
            lastSync: this.lastSync,
            cachedClients: this.clientsCache.size,
            cachedServices: this.servicesCache.size
        };
    }
}

module.exports = { WHMCSIntegrationModule };
