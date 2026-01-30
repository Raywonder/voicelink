/**
 * VoiceLink VM Manager Module
 *
 * Integrates with existing VM Manager API for:
 * - Auto-detecting VoiceLink VMs
 * - Managing VMs from VoiceLink admin panel
 * - Auto-assigning VMs to modules/users
 * - WHMCS integration for VM provisioning
 */

const https = require('https');
const http = require('http');
const fs = require('fs');
const path = require('path');

class VMManagerModule {
    constructor(options = {}) {
        this.config = options.config || {};
        this.dataDir = options.dataDir || path.join(__dirname, '../../../data/vm-manager');

        // VM Manager API settings - connects to existing VM Manager at /home/dom/apps/vm-manager
        // Default configuration from systemd service: port 8083, key dc-vm-manager-2024
        this.apiUrl = this.config.apiUrl || process.env.VM_MANAGER_URL || 'http://localhost:8083';
        this.apiKey = this.config.apiKey || process.env.VM_MANAGER_API_KEY || 'dc-vm-manager-2024';

        // Auto-detection settings
        this.autoDetectInterval = this.config.autoDetectInterval || 300000; // 5 minutes
        this.autoAssignEnabled = this.config.autoAssign?.enabled || true;

        // Tracked VMs
        this.trackedVMs = new Map();
        this.vmAssignments = new Map(); // vmId -> { userId, moduleId, serviceId }

        // Initialize
        if (!fs.existsSync(this.dataDir)) {
            fs.mkdirSync(this.dataDir, { recursive: true });
        }
        this.loadState();

        // Start auto-detection if enabled
        if (this.config.autoDetect?.enabled) {
            this.startAutoDetection();
        }
    }

    loadState() {
        const stateFile = path.join(this.dataDir, 'vm-state.json');
        try {
            if (fs.existsSync(stateFile)) {
                const data = JSON.parse(fs.readFileSync(stateFile, 'utf8'));
                data.trackedVMs?.forEach(vm => this.trackedVMs.set(vm.name, vm));
                data.assignments?.forEach(a => this.vmAssignments.set(a.vmId, a));
            }
        } catch (e) {
            console.error('[VM Manager] Error loading state:', e.message);
        }
    }

    saveState() {
        const stateFile = path.join(this.dataDir, 'vm-state.json');
        const data = {
            lastUpdated: Date.now(),
            trackedVMs: Array.from(this.trackedVMs.values()),
            assignments: Array.from(this.vmAssignments.values())
        };
        fs.writeFileSync(stateFile, JSON.stringify(data, null, 2));
    }

    /**
     * Make API request to VM Manager
     */
    async apiRequest(method, endpoint, data = null) {
        return new Promise((resolve, reject) => {
            const url = new URL(endpoint, this.apiUrl);
            const isHttps = url.protocol === 'https:';
            const client = isHttps ? https : http;

            const options = {
                hostname: url.hostname,
                port: url.port || (isHttps ? 443 : 80),
                path: url.pathname + url.search,
                method,
                headers: {
                    'Content-Type': 'application/json',
                    'Authorization': `Bearer ${this.apiKey}`
                }
            };

            const req = client.request(options, (res) => {
                let responseData = '';
                res.on('data', chunk => responseData += chunk);
                res.on('end', () => {
                    try {
                        const json = JSON.parse(responseData);
                        if (json.success === false) {
                            reject(new Error(json.error || 'API request failed'));
                        } else {
                            resolve(json);
                        }
                    } catch (e) {
                        reject(new Error('Invalid JSON response'));
                    }
                });
            });

            req.on('error', reject);
            req.setTimeout(30000, () => {
                req.destroy();
                reject(new Error('Request timeout'));
            });

            if (data) {
                req.write(JSON.stringify(data));
            }
            req.end();
        });
    }

    /**
     * List all VMs from VM Manager
     */
    async listVMs() {
        try {
            const result = await this.apiRequest('GET', '/api/vms');
            return result.vms || [];
        } catch (error) {
            console.error('[VM Manager] List VMs error:', error.message);
            return [];
        }
    }

    /**
     * Get VM status
     */
    async getVMStatus(vmId) {
        try {
            return await this.apiRequest('GET', `/api/vm/${vmId}/status`);
        } catch (error) {
            return { success: false, error: error.message };
        }
    }

    /**
     * Create a new VM
     */
    async createVM(options) {
        const {
            name,
            cpu = 2,
            ram = 2048,
            disk = 40,
            os_image = 'ubuntu-24.04',
            root_password,
            install_cockpit = true,
            client_email,
            service_id,
            user_id,
            module_id
        } = options;

        try {
            const result = await this.apiRequest('POST', '/api/vm/create', {
                name,
                cpu,
                ram,
                disk,
                os_image,
                root_password,
                install_cockpit,
                client_email,
                service_id
            });

            if (result.success) {
                // Track the VM
                const vmData = {
                    name,
                    vm_id: result.vm_id,
                    ip_address: result.ip_address,
                    vnc_port: result.vnc_port,
                    created_at: Date.now(),
                    os_image,
                    cpu,
                    ram,
                    disk
                };
                this.trackedVMs.set(name, vmData);

                // Auto-assign if specified
                if (user_id || module_id || service_id) {
                    this.assignVM(name, { userId: user_id, moduleId: module_id, serviceId: service_id });
                }

                this.saveState();
            }

            return result;
        } catch (error) {
            return { success: false, error: error.message };
        }
    }

    /**
     * Delete a VM
     */
    async deleteVM(vmId) {
        try {
            const result = await this.apiRequest('DELETE', `/api/vm/${vmId}`);
            if (result.success) {
                this.trackedVMs.delete(vmId);
                this.vmAssignments.delete(vmId);
                this.saveState();
            }
            return result;
        } catch (error) {
            return { success: false, error: error.message };
        }
    }

    /**
     * Start a VM
     */
    async startVM(vmId) {
        try {
            return await this.apiRequest('POST', `/api/vm/${vmId}/start`);
        } catch (error) {
            return { success: false, error: error.message };
        }
    }

    /**
     * Stop a VM
     */
    async stopVM(vmId) {
        try {
            return await this.apiRequest('POST', `/api/vm/${vmId}/stop`);
        } catch (error) {
            return { success: false, error: error.message };
        }
    }

    /**
     * Force stop a VM
     */
    async forceStopVM(vmId) {
        try {
            return await this.apiRequest('POST', `/api/vm/${vmId}/force-stop`);
        } catch (error) {
            return { success: false, error: error.message };
        }
    }

    /**
     * Restart a VM
     */
    async restartVM(vmId) {
        try {
            return await this.apiRequest('POST', `/api/vm/${vmId}/restart`);
        } catch (error) {
            return { success: false, error: error.message };
        }
    }

    /**
     * Suspend a VM
     */
    async suspendVM(vmId) {
        try {
            return await this.apiRequest('POST', `/api/vm/${vmId}/suspend`);
        } catch (error) {
            return { success: false, error: error.message };
        }
    }

    /**
     * Resume a VM
     */
    async resumeVM(vmId) {
        try {
            return await this.apiRequest('POST', `/api/vm/${vmId}/resume`);
        } catch (error) {
            return { success: false, error: error.message };
        }
    }

    /**
     * Resize a VM
     */
    async resizeVM(vmId, options) {
        try {
            return await this.apiRequest('PUT', `/api/vm/${vmId}/resize`, options);
        } catch (error) {
            return { success: false, error: error.message };
        }
    }

    /**
     * Get VNC console info
     */
    async getConsole(vmId) {
        try {
            return await this.apiRequest('GET', `/api/vm/${vmId}/console`);
        } catch (error) {
            return { success: false, error: error.message };
        }
    }

    /**
     * Create snapshot
     */
    async createSnapshot(vmId, name) {
        try {
            return await this.apiRequest('POST', `/api/vm/${vmId}/snapshot`, { name });
        } catch (error) {
            return { success: false, error: error.message };
        }
    }

    /**
     * List snapshots
     */
    async listSnapshots(vmId) {
        try {
            return await this.apiRequest('GET', `/api/vm/${vmId}/snapshots`);
        } catch (error) {
            return { success: false, error: error.message };
        }
    }

    /**
     * Restore snapshot
     */
    async restoreSnapshot(vmId, snapshotName) {
        try {
            return await this.apiRequest('POST', `/api/vm/${vmId}/snapshot/${snapshotName}/restore`);
        } catch (error) {
            return { success: false, error: error.message };
        }
    }

    /**
     * Get available OS images
     */
    async getOSImages() {
        try {
            return await this.apiRequest('GET', '/api/images');
        } catch (error) {
            return { success: false, error: error.message };
        }
    }

    // ==========================================
    // Auto-Detection & Assignment
    // ==========================================

    /**
     * Start auto-detection of VMs
     */
    startAutoDetection() {
        console.log('[VM Manager] Starting auto-detection...');
        this.detectAndAssignVMs();
        this.autoDetectTimer = setInterval(
            () => this.detectAndAssignVMs(),
            this.autoDetectInterval
        );
    }

    /**
     * Stop auto-detection
     */
    stopAutoDetection() {
        if (this.autoDetectTimer) {
            clearInterval(this.autoDetectTimer);
            this.autoDetectTimer = null;
        }
    }

    /**
     * Detect VMs and auto-assign unassigned ones
     */
    async detectAndAssignVMs() {
        console.log('[VM Manager] Running VM detection...');

        try {
            const vms = await this.listVMs();

            for (const vm of vms) {
                // Check if VM is already tracked
                if (!this.trackedVMs.has(vm.name)) {
                    console.log(`[VM Manager] Detected new VM: ${vm.name}`);

                    // Get full status
                    const status = await this.getVMStatus(vm.name);

                    const vmData = {
                        name: vm.name,
                        state: vm.state,
                        ip_address: status.ip_address,
                        detected_at: Date.now(),
                        auto_detected: true
                    };

                    this.trackedVMs.set(vm.name, vmData);
                }

                // Update state
                const tracked = this.trackedVMs.get(vm.name);
                if (tracked) {
                    tracked.state = vm.state;
                    tracked.last_checked = Date.now();
                }
            }

            // Auto-assign unassigned VMs if enabled
            if (this.autoAssignEnabled) {
                await this.autoAssignUnassignedVMs();
            }

            this.saveState();

            return { success: true, detected: vms.length, tracked: this.trackedVMs.size };
        } catch (error) {
            console.error('[VM Manager] Detection error:', error.message);
            return { success: false, error: error.message };
        }
    }

    /**
     * Auto-assign unassigned VMs
     */
    async autoAssignUnassignedVMs() {
        const unassigned = [];

        for (const [vmId, vm] of this.trackedVMs) {
            if (!this.vmAssignments.has(vmId)) {
                unassigned.push(vm);
            }
        }

        if (unassigned.length === 0) return;

        console.log(`[VM Manager] ${unassigned.length} unassigned VMs found`);

        // Try to match VMs with WHMCS services or assign to default owner
        for (const vm of unassigned) {
            const assignment = await this.findAssignmentForVM(vm);
            if (assignment) {
                this.assignVM(vm.name, assignment);
                console.log(`[VM Manager] Auto-assigned VM ${vm.name} to ${assignment.userId || assignment.moduleId || 'owner'}`);
            } else if (this.config.autoAssign?.defaultOwner) {
                // Assign to default owner (account owner)
                this.assignVM(vm.name, {
                    userId: this.config.autoAssign.defaultOwner,
                    assignedBy: 'auto',
                    reason: 'default_owner'
                });
                console.log(`[VM Manager] Auto-assigned VM ${vm.name} to default owner`);
            }
        }
    }

    /**
     * Find assignment for a VM by checking WHMCS or naming patterns
     */
    async findAssignmentForVM(vm) {
        // Check if VM name matches a pattern like "whmcs-{serviceId}" or "user-{userId}"
        const serviceMatch = vm.name.match(/^(?:whmcs|service)-(\d+)/i);
        if (serviceMatch) {
            return { serviceId: serviceMatch[1], assignedBy: 'pattern' };
        }

        const userMatch = vm.name.match(/^(?:user|client)-(\d+)/i);
        if (userMatch) {
            return { userId: userMatch[1], assignedBy: 'pattern' };
        }

        // Check WHMCS for matching service if WHMCS module is available
        if (this.whmcsModule) {
            const whmcsService = await this.whmcsModule.findServiceByVMName(vm.name);
            if (whmcsService) {
                return {
                    userId: whmcsService.client_id,
                    serviceId: whmcsService.id,
                    assignedBy: 'whmcs'
                };
            }
        }

        return null;
    }

    /**
     * Assign a VM to a user/module/service
     */
    assignVM(vmId, assignment) {
        const existingAssignment = this.vmAssignments.get(vmId);

        this.vmAssignments.set(vmId, {
            vmId,
            ...assignment,
            assignedAt: Date.now(),
            previousAssignment: existingAssignment
        });

        this.saveState();
        return { success: true };
    }

    /**
     * Unassign a VM
     */
    unassignVM(vmId) {
        this.vmAssignments.delete(vmId);
        this.saveState();
        return { success: true };
    }

    /**
     * Get VM assignment
     */
    getVMAssignment(vmId) {
        return this.vmAssignments.get(vmId);
    }

    /**
     * Get VMs assigned to a user
     */
    getVMsForUser(userId) {
        const vms = [];
        for (const [vmId, assignment] of this.vmAssignments) {
            if (assignment.userId === userId) {
                const vmData = this.trackedVMs.get(vmId);
                if (vmData) {
                    vms.push({ ...vmData, assignment });
                }
            }
        }
        return vms;
    }

    /**
     * Get VMs by service ID (WHMCS)
     */
    getVMsForService(serviceId) {
        const vms = [];
        for (const [vmId, assignment] of this.vmAssignments) {
            if (assignment.serviceId === serviceId) {
                const vmData = this.trackedVMs.get(vmId);
                if (vmData) {
                    vms.push({ ...vmData, assignment });
                }
            }
        }
        return vms;
    }

    /**
     * Get all tracked VMs with assignments
     */
    getAllTrackedVMs() {
        const vms = [];
        for (const [vmId, vmData] of this.trackedVMs) {
            vms.push({
                ...vmData,
                assignment: this.vmAssignments.get(vmId) || null
            });
        }
        return vms;
    }

    /**
     * Get statistics
     */
    getStatistics() {
        const vms = Array.from(this.trackedVMs.values());

        return {
            total: vms.length,
            running: vms.filter(v => v.state === 'running').length,
            stopped: vms.filter(v => v.state === 'shut off').length,
            paused: vms.filter(v => v.state === 'paused').length,
            assigned: this.vmAssignments.size,
            unassigned: vms.length - this.vmAssignments.size,
            autoDetected: vms.filter(v => v.auto_detected).length
        };
    }

    /**
     * Set WHMCS module reference for integration
     */
    setWHMCSModule(whmcsModule) {
        this.whmcsModule = whmcsModule;
    }
}

module.exports = { VMManagerModule };
