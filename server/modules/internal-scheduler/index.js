const fs = require('fs');
const path = require('path');

class InternalScheduler {
    constructor(options = {}) {
        this.io = options.io || null;
        this.dataDir = options.dataDir || path.join(process.cwd(), 'data', 'scheduler');
        this.logger = options.logger || console;
        this.server = options.server || null;
        this.deployConfig = options.deployConfig || null;
        this.tasks = new Map();
        this.logs = [];
        this.maxLogs = 250;
        this.service = 'internal-scheduler';
        this.healthPath = path.join(this.dataDir, 'health.json');

        fs.mkdirSync(this.dataDir, { recursive: true });
        this.taskStatePath = path.join(this.dataDir, 'tasks.json');
        this.logPath = path.join(this.dataDir, 'logs.json');
        this.persistedTaskState = this.loadJSON(this.taskStatePath, {});
        this.logs = this.loadJSON(this.logPath, []);
        this.health = this.loadJSON(this.healthPath, {
            runners: {
                native: { status: 'unknown', lastCheckedAt: null, message: null },
                system: { status: 'unknown', lastCheckedAt: null, message: null },
                internal: { status: 'ok', lastCheckedAt: new Date().toISOString(), message: 'VoiceLink internal scheduler available' }
            }
        });

        this.registerBuiltInTasks();
    }

    loadJSON(filePath, fallback) {
        try {
            if (!fs.existsSync(filePath)) return fallback;
            return JSON.parse(fs.readFileSync(filePath, 'utf8'));
        } catch (error) {
            this.logger.warn('[InternalScheduler] Failed to read', filePath, error.message);
            return fallback;
        }
    }

    saveJSON(filePath, value) {
        try {
            fs.writeFileSync(filePath, JSON.stringify(value, null, 2), 'utf8');
        } catch (error) {
            this.logger.warn('[InternalScheduler] Failed to write', filePath, error.message);
        }
    }

    persistTaskState() {
        const state = {};
        for (const [id, task] of this.tasks.entries()) {
            state[id] = {
                enabled: task.enabled,
                intervalSeconds: task.intervalSeconds,
                preferredRunners: task.preferredRunners,
                retryLimit: task.retryLimit,
                retryBackoffSeconds: task.retryBackoffSeconds,
                timeoutSeconds: task.timeoutSeconds,
                jitterSeconds: task.jitterSeconds
            };
        }
        this.saveJSON(this.taskStatePath, state);
    }

    persistLogs() {
        this.saveJSON(this.logPath, this.logs.slice(-this.maxLogs));
    }

    registerBuiltInTasks() {
        this.schedule(
            'community-config-sync',
            30 * 60 * 1000,
            async () => this.runCommunityConfigSync(),
            {
                name: 'Community Config Sync',
                description: 'Pulls approved server configuration from the primary VoiceLink server for trusted community nodes.',
                visibility: 'admin',
                allowUserRun: false,
                action: 'sync',
                tags: ['self-management', 'config'],
                preferredRunners: ['system', 'internal'],
                retryLimit: 2,
                retryBackoffSeconds: 60,
                timeoutSeconds: 120,
                jitterSeconds: 15
            }
        );

        this.schedule(
            'module-governance-reconcile',
            15 * 60 * 1000,
            async () => this.runModuleGovernanceReconcile(),
            {
                name: 'Module Governance Reconcile',
                description: 'Installs or repairs required approved modules when server policy allows.',
                visibility: 'admin',
                allowUserRun: false,
                action: 'repair',
                tags: ['self-management', 'modules'],
                preferredRunners: ['internal', 'system'],
                retryLimit: 1,
                retryBackoffSeconds: 120,
                timeoutSeconds: 180,
                jitterSeconds: 10
            }
        );

        this.schedule(
            'site-integration-reconcile',
            20 * 60 * 1000,
            async () => this.runSiteIntegrationReconcile(),
            {
                name: 'Site Integration Reconcile',
                description: 'Detects linked CMS, billing-portal, or hosting-account scheduler and firewall hints for WordPress, Composr, WHMCS, or cPanel-backed installs.',
                visibility: 'admin',
                allowUserRun: false,
                action: 'sync',
                tags: ['self-management', 'site-integrations'],
                preferredRunners: ['native', 'system', 'internal'],
                retryLimit: 2,
                retryBackoffSeconds: 90,
                timeoutSeconds: 120,
                jitterSeconds: 20
            }
        );

        this.schedule(
            'license-state-sync',
            30 * 60 * 1000,
            async () => this.runLicenseStateSync(),
            {
                name: 'License State Sync',
                description: 'Reconciles VoiceLink license state against WHMCS-linked entitlements and falls back to local VoiceLink license state when upstream managers are unavailable.',
                visibility: 'admin',
                allowUserRun: false,
                action: 'sync',
                tags: ['self-management', 'licensing'],
                preferredRunners: ['native', 'system', 'internal'],
                retryLimit: 2,
                retryBackoffSeconds: 120,
                timeoutSeconds: 180,
                jitterSeconds: 20
            }
        );

        this.schedule(
            'deployment-file-sync',
            25 * 60 * 1000,
            async () => this.runDeploymentFileSync(),
            {
                name: 'Deployment File Sync',
                description: 'Automatically reconciles release artifacts and linked install file sync state so manual sync is only needed for real blockers.',
                visibility: 'admin',
                allowUserRun: false,
                action: 'sync',
                tags: ['self-management', 'deployments', 'files'],
                preferredRunners: ['native', 'system', 'internal'],
                retryLimit: 2,
                retryBackoffSeconds: 90,
                timeoutSeconds: 180,
                jitterSeconds: 20
            }
        );
    }

    schedule(id, intervalMs, callback, options = {}) {
        if (!id || typeof callback !== 'function') {
            throw new Error('Task id and callback are required');
        }

        const persisted = this.persistedTaskState[id] || {};
        const intervalSeconds = Math.max(
            5,
            Number.isFinite(Number(persisted.intervalSeconds))
                ? Number(persisted.intervalSeconds)
                : Math.max(5, Math.round(Number(intervalMs || 60000) / 1000))
        );

        const existing = this.tasks.get(id);
        const task = existing || {
            id,
            name: options.name || id,
            description: options.description || '',
            visibility: options.visibility || 'admin',
            allowUserRun: options.allowUserRun === true,
            enabled: persisted.enabled !== undefined ? !!persisted.enabled : (options.enabled !== false),
            running: false,
            intervalSeconds,
            callback,
            timer: null,
            timerType: 'interval',
            lastRunAt: null,
            lastStatus: 'idle',
            lastDurationMs: 0,
            lastMessage: null,
            nextRunAt: null,
            action: options.action || null,
            tags: Array.isArray(options.tags) ? options.tags : [],
            preferredRunners: Array.isArray(persisted.preferredRunners) && persisted.preferredRunners.length
                ? persisted.preferredRunners
                : (Array.isArray(options.preferredRunners) && options.preferredRunners.length ? options.preferredRunners : ['internal']),
            retryLimit: Number.isFinite(Number(persisted.retryLimit))
                ? Math.max(0, Number(persisted.retryLimit))
                : Math.max(0, Number(options.retryLimit || 0)),
            retryBackoffSeconds: Number.isFinite(Number(persisted.retryBackoffSeconds))
                ? Math.max(5, Number(persisted.retryBackoffSeconds))
                : Math.max(5, Number(options.retryBackoffSeconds || 30)),
            timeoutSeconds: Number.isFinite(Number(persisted.timeoutSeconds))
                ? Math.max(5, Number(persisted.timeoutSeconds))
                : Math.max(5, Number(options.timeoutSeconds || 60)),
            jitterSeconds: Number.isFinite(Number(persisted.jitterSeconds))
                ? Math.max(0, Number(persisted.jitterSeconds))
                : Math.max(0, Number(options.jitterSeconds || 0)),
            consecutiveFailures: 0,
            lastRunner: null
        };

        task.name = options.name || task.name;
        task.description = options.description || task.description;
        task.visibility = options.visibility || task.visibility || 'admin';
        task.allowUserRun = options.allowUserRun === true || task.allowUserRun === true;
        task.callback = callback;
        task.action = options.action || task.action || null;
        task.tags = Array.isArray(options.tags) ? options.tags : task.tags;
        task.preferredRunners = Array.isArray(options.preferredRunners) && options.preferredRunners.length
            ? options.preferredRunners
            : task.preferredRunners;
        task.retryLimit = options.retryLimit !== undefined ? Math.max(0, Number(options.retryLimit || 0)) : task.retryLimit;
        task.retryBackoffSeconds = options.retryBackoffSeconds !== undefined ? Math.max(5, Number(options.retryBackoffSeconds || 30)) : task.retryBackoffSeconds;
        task.timeoutSeconds = options.timeoutSeconds !== undefined ? Math.max(5, Number(options.timeoutSeconds || 60)) : task.timeoutSeconds;
        task.jitterSeconds = options.jitterSeconds !== undefined ? Math.max(0, Number(options.jitterSeconds || 0)) : task.jitterSeconds;

        this.tasks.set(id, task);
        this.rescheduleTask(id);
        this.persistTaskState();
        return task;
    }

    computeNextDelayMs(task, mode = 'normal') {
        const baseSeconds = mode === 'retry'
            ? task.retryBackoffSeconds
            : task.intervalSeconds;
        const jitterSeconds = Math.max(0, Number(task.jitterSeconds || 0));
        const jitter = jitterSeconds > 0 ? Math.floor(Math.random() * ((jitterSeconds * 1000) + 1)) : 0;
        return Math.max(5000, (baseSeconds * 1000) + jitter);
    }

    rescheduleTask(id) {
        const task = this.tasks.get(id);
        if (!task) return;
        if (task.timer) {
            clearTimeout(task.timer);
            task.timer = null;
        }
        task.nextRunAt = null;
        if (!task.enabled) return;
        const delayMs = this.computeNextDelayMs(task);
        task.timerType = 'timeout';
        task.nextRunAt = new Date(Date.now() + delayMs).toISOString();
        task.timer = setTimeout(() => {
            this.runTask(id, { actor: 'scheduler', trigger: 'interval' }).catch((error) => {
                this.logger.warn('[InternalScheduler] Task run failed:', id, error.message);
            });
        }, delayMs);
    }

    scheduleRetry(task, meta = {}) {
        if (task.timer) {
            clearTimeout(task.timer);
            task.timer = null;
        }
        if (!task.enabled) return;
        const delayMs = this.computeNextDelayMs(task, 'retry');
        task.timerType = 'retry-timeout';
        task.nextRunAt = new Date(Date.now() + delayMs).toISOString();
        task.timer = setTimeout(() => {
            this.runTask(task.id, {
                actor: meta.actor || 'scheduler',
                trigger: 'retry'
            }).catch((error) => {
                this.logger.warn('[InternalScheduler] Retry task run failed:', task.id, error.message);
            });
        }, delayMs);
    }

    withTimeout(promise, timeoutSeconds) {
        const normalized = Math.max(5, Number(timeoutSeconds || 60)) * 1000;
        return Promise.race([
            promise,
            new Promise((_, reject) => {
                setTimeout(() => reject(new Error(`Task timed out after ${Math.round(normalized / 1000)}s`)), normalized);
            })
        ]);
    }

    updateRunnerHealth(runner, patch = {}) {
        this.health.runners[runner] = {
            ...(this.health.runners[runner] || {}),
            ...patch,
            lastCheckedAt: new Date().toISOString()
        };
        this.saveJSON(this.healthPath, this.health);
    }

    resolveRunnerHealth(runner) {
        if (runner === 'internal') {
            this.updateRunnerHealth('internal', {
                status: 'ok',
                message: 'VoiceLink internal scheduler available'
            });
            return this.health.runners.internal;
        }

        const config = this.deployConfig?.getConfig?.() || {};
        const detectedSites = Array.isArray(config.siteIntegration?.detectedSites)
            ? config.siteIntegration.detectedSites
            : [];

        if (runner === 'native') {
            const schedulerModes = detectedSites.map((site) => String(site.schedulerMode || '').trim()).filter(Boolean);
            const hasNative = schedulerModes.some((mode) => mode.includes('wordpress') || mode.includes('composr') || mode.includes('whmcs') || mode.includes('cpanel'));
            this.updateRunnerHealth('native', {
                status: hasNative ? 'ok' : 'degraded',
                message: hasNative ? `Native scheduler bridge available: ${schedulerModes.join(', ')}` : 'No native scheduler bridge detected'
            });
            return this.health.runners.native;
        }

        if (runner === 'system') {
            const allowSystem = config.siteIntegration?.preferSystemCronFallback !== false;
            this.updateRunnerHealth('system', {
                status: allowSystem ? 'ok' : 'degraded',
                message: allowSystem ? 'System cron fallback allowed' : 'System cron fallback disabled'
            });
            return this.health.runners.system;
        }

        return { status: 'unknown', lastCheckedAt: new Date().toISOString(), message: 'Unknown runner' };
    }

    chooseRunner(task) {
        const order = Array.isArray(task.preferredRunners) && task.preferredRunners.length
            ? task.preferredRunners
            : ['internal'];
        for (const runner of order) {
            const health = this.resolveRunnerHealth(runner);
            if (health.status === 'ok') {
                return { runner, health };
            }
        }
        const fallback = order[order.length - 1] || 'internal';
        return { runner: fallback, health: this.resolveRunnerHealth(fallback) };
    }

    getStatus(role = 'admin') {
        const tasks = this.listTasks(role);
        return {
            service: this.service,
            role,
            totalVisibleTasks: tasks.length,
            enabledTasks: tasks.filter((task) => task.enabled).length,
            runningTasks: tasks.filter((task) => task.running).length,
            runners: this.health.runners,
            serverTime: new Date().toISOString()
        };
    }

    listTasks(role = 'admin') {
        return Array.from(this.tasks.values())
            .filter((task) => role === 'admin' || task.visibility !== 'admin')
            .map((task) => this.serializeTask(task));
    }

    listLogs(role = 'admin', limit = 50) {
        const normalizedLimit = Math.max(1, Math.min(500, Number(limit || 50)));
        return this.logs
            .filter((entry) => role === 'admin' || entry.visibility !== 'admin')
            .slice(-normalizedLimit)
            .reverse();
    }

    serializeTask(task) {
        return {
            id: task.id,
            name: task.name,
            description: task.description,
            visibility: task.visibility,
            allowUserRun: task.allowUserRun,
            enabled: task.enabled,
            running: task.running,
            intervalSeconds: task.intervalSeconds,
            lastRunAt: task.lastRunAt,
            lastStatus: task.lastStatus,
            lastDurationMs: task.lastDurationMs,
            lastMessage: task.lastMessage,
            nextRunAt: task.nextRunAt,
            action: task.action,
            preferredRunners: task.preferredRunners,
            retryLimit: task.retryLimit,
            retryBackoffSeconds: task.retryBackoffSeconds,
            timeoutSeconds: task.timeoutSeconds,
            jitterSeconds: task.jitterSeconds,
            consecutiveFailures: task.consecutiveFailures,
            lastRunner: task.lastRunner
        };
    }

    appendLog(task, meta) {
        this.logs.push({
            id: `${Date.now()}-${Math.random().toString(36).slice(2, 8)}`,
            taskId: task.id,
            taskName: task.name,
            actor: meta.actor || 'scheduler',
            trigger: meta.trigger || 'interval',
            runner: meta.runner || task.lastRunner || 'internal',
            status: meta.status || 'ok',
            message: meta.message || null,
            durationMs: Number(meta.durationMs || 0),
            timestamp: new Date().toISOString(),
            visibility: task.visibility || 'admin'
        });
        if (this.logs.length > this.maxLogs) {
            this.logs = this.logs.slice(-this.maxLogs);
        }
        this.persistLogs();
    }

    async runTask(taskId, meta = {}) {
        const task = this.tasks.get(taskId);
        if (!task) {
            return { success: false, error: 'Task not found' };
        }
        if (task.running) {
            return { success: false, error: 'Task already running' };
        }

        task.running = true;
        const startedAt = Date.now();
        task.lastRunAt = new Date().toISOString();
        task.lastStatus = 'running';
        const selectedRunner = this.chooseRunner(task);
        task.lastRunner = selectedRunner.runner;

        try {
            const result = await this.withTimeout(
                Promise.resolve(task.callback({
                    taskId,
                    actor: meta.actor || 'scheduler',
                    trigger: meta.trigger || 'manual',
                    runner: selectedRunner.runner,
                    runnerHealth: selectedRunner.health,
                    preferredRunners: task.preferredRunners
                })),
                task.timeoutSeconds
            );
            const durationMs = Date.now() - startedAt;
            task.lastDurationMs = durationMs;
            task.lastStatus = result?.success === false ? 'error' : 'ok';
            task.lastMessage = result?.message || null;
            task.running = false;
            task.consecutiveFailures = task.lastStatus === 'ok' ? 0 : (task.consecutiveFailures + 1);
            if (task.enabled) {
                if (task.lastStatus === 'error' && task.consecutiveFailures <= task.retryLimit) {
                    this.scheduleRetry(task, meta);
                } else {
                    this.rescheduleTask(task.id);
                }
            }
            this.appendLog(task, {
                actor: meta.actor,
                trigger: meta.trigger,
                runner: selectedRunner.runner,
                status: task.lastStatus,
                message: task.lastMessage,
                durationMs
            });
            return {
                success: task.lastStatus === 'ok',
                message: task.lastMessage,
                durationMs
            };
        } catch (error) {
            const durationMs = Date.now() - startedAt;
            task.lastDurationMs = durationMs;
            task.lastStatus = 'error';
            task.lastMessage = error.message || 'Task failed';
            task.running = false;
            task.consecutiveFailures += 1;
            if (task.enabled) {
                if (task.consecutiveFailures <= task.retryLimit) {
                    this.scheduleRetry(task, meta);
                } else {
                    this.rescheduleTask(task.id);
                }
            }
            this.appendLog(task, {
                actor: meta.actor,
                trigger: meta.trigger,
                runner: selectedRunner.runner,
                status: 'error',
                message: task.lastMessage,
                durationMs
            });
            return { success: false, error: task.lastMessage, durationMs };
        }
    }

    updateTask(taskId, patch = {}, actor = 'admin') {
        const task = this.tasks.get(taskId);
        if (!task) {
            return { success: false, error: 'Task not found' };
        }
        if (patch.enabled !== undefined) {
            task.enabled = !!patch.enabled;
        }
        if (patch.intervalSeconds !== undefined && Number.isFinite(Number(patch.intervalSeconds))) {
            task.intervalSeconds = Math.max(5, Number(patch.intervalSeconds));
        }
        if (Array.isArray(patch.preferredRunners) && patch.preferredRunners.length) {
            task.preferredRunners = patch.preferredRunners.map((item) => String(item || '').trim()).filter(Boolean);
        }
        if (patch.retryLimit !== undefined && Number.isFinite(Number(patch.retryLimit))) {
            task.retryLimit = Math.max(0, Number(patch.retryLimit));
        }
        if (patch.retryBackoffSeconds !== undefined && Number.isFinite(Number(patch.retryBackoffSeconds))) {
            task.retryBackoffSeconds = Math.max(5, Number(patch.retryBackoffSeconds));
        }
        if (patch.timeoutSeconds !== undefined && Number.isFinite(Number(patch.timeoutSeconds))) {
            task.timeoutSeconds = Math.max(5, Number(patch.timeoutSeconds));
        }
        if (patch.jitterSeconds !== undefined && Number.isFinite(Number(patch.jitterSeconds))) {
            task.jitterSeconds = Math.max(0, Number(patch.jitterSeconds));
        }
        this.rescheduleTask(taskId);
        this.persistTaskState();
        this.appendLog(task, {
            actor,
            trigger: 'config',
            status: 'ok',
            message: 'Task settings updated',
            durationMs: 0
        });
        return { success: true, task: this.serializeTask(task) };
    }

    async runCommunityConfigSync() {
        if (!this.server || !this.deployConfig) {
            return { success: false, message: 'Scheduler server context unavailable' };
        }
        const config = this.deployConfig.getConfig() || {};
        const policies = config.serverPolicies || {};
        const primaryServerUrl = String(
            policies.primaryServerUrl
            || process.env.VOICELINK_MAIN_SERVER_URL
            || process.env.VOICELINK_PRIMARY_SERVER_URL
            || ''
        ).trim();

        if (!primaryServerUrl || policies.autoPullUpdatesFromPrimary === false) {
            return { success: true, message: 'Primary config sync is disabled' };
        }

        const requestHeaders = {};
        const adminKey = process.env.VOICELINK_ADMIN_KEY || '';
        if (adminKey) {
            requestHeaders['X-Admin-Key'] = adminKey;
        }

        const response = await fetch(`${primaryServerUrl.replace(/\/+$/, '')}/api/config`, {
            method: 'GET',
            headers: requestHeaders
        });
        if (!response.ok) {
            return { success: false, message: `Primary config fetch failed (${response.status})` };
        }

        const remote = await response.json();
        const currentServer = this.deployConfig.get('server') || {};
        const currentRooms = this.deployConfig.get('rooms') || {};
        const currentSecurity = this.deployConfig.get('security') || {};
        const currentMessageSettings = this.server.getMessageSettingsConfig
            ? this.server.getMessageSettingsConfig()
            : {};

        this.deployConfig.updateSection('server', {
            ...currentServer,
            name: remote.serverName || currentServer.name,
            description: remote.serverDescription || currentServer.description || '',
            welcomeMessage: remote.welcomeMessage || null,
            lobbyWelcomeMessage: remote.lobbyWelcomeMessage || currentServer.lobbyWelcomeMessage || null,
            motd: remote.motd || null,
            motdSettings: remote.motdSettings || currentServer.motdSettings || {},
            handoffPromptMode: remote.handoffPromptMode || currentServer.handoffPromptMode || 'serverRecommended',
            maxUsers: Number(remote.maxUsers || currentServer.maxUsers || 500),
            maxUsersPerRoom: Number(remote.maxUsersPerRoom || currentServer.maxUsersPerRoom || 50)
        });
        this.deployConfig.updateSection('rooms', {
            ...currentRooms,
            maxRooms: Number(remote.maxRooms || currentRooms.maxRooms || 100),
            maxUsersPerRoom: Number(remote.maxUsersPerRoom || currentRooms.maxUsersPerRoom || 50)
        });
        this.deployConfig.updateSection('security', {
            ...currentSecurity,
            requireAuth: remote.requireAuth ?? currentSecurity.requireAuth ?? false,
            allowGuests: remote.allowGuests ?? currentSecurity.allowGuests ?? true,
            maxGuestDuration: remote.maxGuestDuration ?? currentSecurity.maxGuestDuration ?? null,
            enableRateLimiting: remote.enableRateLimiting ?? currentSecurity.enableRateLimiting ?? true
        });
        this.deployConfig.updateSection('messageSettings', {
            ...currentMessageSettings,
            ...(remote.messageSettings || {})
        });
        await this.deployConfig.save();

        return { success: true, message: 'Community config synced from primary server' };
    }

    async runModuleGovernanceReconcile() {
        if (!this.server) {
            return { success: false, message: 'Scheduler server context unavailable' };
        }
        const policy = typeof this.server.getServerPolicyConfig === 'function'
            ? this.server.getServerPolicyConfig().moduleGovernance
            : ((this.deployConfig?.get('serverPolicies') || {}).moduleGovernance || {});
        const required = Array.isArray(policy.required) ? policy.required.filter(Boolean) : [];
        if (!required.length) {
            return { success: true, message: 'No required modules to reconcile' };
        }

        const actions = [];
        for (const moduleId of required) {
            const module = this.server.moduleRegistry?.getModule?.(moduleId);
            if (!module?.installed) {
                const result = this.server.moduleRegistry.installModule(moduleId, { enabled: true });
                actions.push({ moduleId, action: 'install', success: !!result?.success });
            }
        }

        if (actions.some((entry) => entry.success)) {
            await this.server.initializeModules?.();
        }

        return {
            success: true,
            message: actions.length
                ? `Reconciled ${actions.length} required module change(s)`
                : 'Required modules already satisfied'
        };
    }

    async runSiteIntegrationReconcile() {
        const config = this.deployConfig?.getConfig?.() || {};
        const integration = config.siteIntegration || {};
        const detectedSites = Array.isArray(integration.detectedSites) ? integration.detectedSites : [];
        if (!detectedSites.length) {
            return { success: true, message: 'No linked site integrations detected yet' };
        }

        const wordpressSites = detectedSites.filter((site) => site.type === 'wordpress').length;
        const composrSites = detectedSites.filter((site) => site.type === 'composr').length;
        const whmcsSites = detectedSites.filter((site) => site.type === 'whmcs').length;
        const cpanelSites = detectedSites.filter((site) => site.type === 'cpanel').length;
        const schedulerModes = Array.from(new Set(detectedSites.map((site) => site.schedulerMode).filter(Boolean)));
        const firewallHints = Array.from(new Set(detectedSites.flatMap((site) => Array.isArray(site.firewalls) ? site.firewalls : [])));

        return {
            success: true,
            message: `Checked ${detectedSites.length} linked site integration${detectedSites.length === 1 ? '' : 's'} (${wordpressSites} WordPress, ${composrSites} Composr, ${whmcsSites} WHMCS, ${cpanelSites} cPanel). Scheduler hints: ${schedulerModes.length ? schedulerModes.join(', ') : 'system'}. Firewalls: ${firewallHints.length ? firewallHints.join(', ') : 'none detected'}.`
        };
    }

    async runLicenseStateSync() {
        if (!this.server) {
            return { success: false, message: 'Scheduler server context unavailable' };
        }

        const licensingState = this.server.licensingState || {};
        const licenses = licensingState.licenses && typeof licensingState.licenses === 'object'
            ? licensingState.licenses
            : {};
        const entries = Object.values(licenses);
        if (!entries.length) {
            return { success: true, message: 'No local license records to reconcile' };
        }

        let whmcsSynced = 0;
        let localFallback = 0;
        let updated = 0;

        for (const record of entries) {
            if (!record || typeof record !== 'object') continue;
            record.entitlements = record.entitlements && typeof record.entitlements === 'object'
                ? record.entitlements
                : {};

            const email = String(record.primaryEmail || '').trim().toLowerCase();
            if (!email || typeof this.server.whmcsRequest !== 'function' || typeof this.server.deriveWhmcsEntitlements !== 'function') {
                record.entitlements.licenseAuthority = record.entitlements.licenseAuthority || 'voicelink_local';
                record.entitlements.lastSyncSource = record.entitlements.lastSyncSource || 'local_fallback';
                record.entitlements.lastSyncAt = new Date().toISOString();
                localFallback += 1;
                continue;
            }

            try {
                const clientResponse = await this.server.whmcsRequest('GetClientsDetails', { email });
                const clientDetails = clientResponse?.client || clientResponse?.clientdetails || null;
                if (!clientDetails) {
                    record.entitlements.licenseAuthority = record.entitlements.licenseAuthority || 'voicelink_local';
                    record.entitlements.lastSyncSource = 'local_fallback';
                    record.entitlements.lastSyncAt = new Date().toISOString();
                    localFallback += 1;
                    continue;
                }

                let services = [];
                try {
                    const servicesResponse = await this.server.whmcsRequest('GetClientsProducts', { clientid: clientDetails.id });
                    services = servicesResponse?.products?.product || [];
                } catch (_) {
                    services = [];
                }

                const derived = this.server.deriveWhmcsEntitlements(clientDetails, services) || {};
                record.entitlements = {
                    ...record.entitlements,
                    ...derived,
                    licenseAuthority: 'whmcs',
                    lastSyncSource: 'whmcs',
                    lastSyncAt: new Date().toISOString(),
                    whmcsClientId: clientDetails.id || record.entitlements.whmcsClientId || null
                };
                if (Number.isFinite(derived.maxDevices)) record.maxDevices = Number(derived.maxDevices);
                if (Number.isFinite(derived.installSlots)) record.installSlots = Number(derived.installSlots);
                if (Number.isFinite(derived.serverSlots)) record.serverSlots = Number(derived.serverSlots);
                record.ownershipPolicy = {
                    ...(record.ownershipPolicy || {}),
                    billingModel: derived.billingModel || record.ownershipPolicy?.billingModel || 'whmcs'
                };
                record.updatedAt = new Date().toISOString();
                whmcsSynced += 1;
                updated += 1;
            } catch (_) {
                record.entitlements.licenseAuthority = record.entitlements.licenseAuthority || 'voicelink_local';
                record.entitlements.lastSyncSource = 'local_fallback';
                record.entitlements.lastSyncAt = new Date().toISOString();
                localFallback += 1;
            }
        }

        if (typeof this.server.persistLicensingState === 'function') {
            this.server.persistLicensingState();
        }

        return {
            success: true,
            message: `Reconciled ${entries.length} license record${entries.length === 1 ? '' : 's'} (${whmcsSynced} synced from WHMCS, ${localFallback} using local VoiceLink fallback).`,
            updated,
            whmcsSynced,
            localFallback
        };
    }

    async runDeploymentFileSync() {
        const config = this.deployConfig?.getConfig?.() || {};
        const integration = config.siteIntegration || {};
        const detectedSites = Array.isArray(integration.detectedSites) ? integration.detectedSites : [];
        const releaseArtifacts = typeof this.server?.deploymentManager?.getReleaseArtifacts === 'function'
            ? this.server.deploymentManager.getReleaseArtifacts()
            : [];

        const syncReport = {
            lastRunAt: new Date().toISOString(),
            automatic: true,
            manualRequired: false,
            schedulerPreferred: true,
            schedulerHealth: this.health?.runners || {},
            linkedInstallCount: detectedSites.length,
            releaseArtifactCount: releaseArtifacts.length,
            releaseArtifacts: releaseArtifacts.map((artifact) => ({
                name: artifact.name,
                type: artifact.type,
                modifiedAt: artifact.modifiedAt,
                path: artifact.path
            })),
            linkedInstalls: detectedSites.map((site) => ({
                type: site.type || 'unknown',
                siteRoot: site.siteRoot || null,
                schedulerMode: site.schedulerMode || 'system',
                firewalls: Array.isArray(site.firewalls) ? site.firewalls : [],
                autoSyncFiles: site.autoSyncFiles !== false
            }))
        };

        try {
            this.saveJSON(path.join(this.dataDir, 'deployment-file-sync.json'), syncReport);
        } catch (_) {
            // Best effort only; the task result is still returned.
        }

        if (!releaseArtifacts.length && !detectedSites.length) {
            return { success: true, message: 'No linked installs or release artifacts detected for file sync yet.' };
        }

        const manualRequired = detectedSites.some((site) => site?.manualSyncRequired === true);
        syncReport.manualRequired = manualRequired;

        return {
            success: true,
            message: `Checked ${releaseArtifacts.length} release artifact${releaseArtifacts.length === 1 ? '' : 's'} and ${detectedSites.length} linked install${detectedSites.length === 1 ? '' : 's'}. Automatic scheduler-backed file sync remains preferred${manualRequired ? ', but at least one install still flags manual intervention.' : '.'}`,
            releaseArtifactCount: releaseArtifacts.length,
            linkedInstallCount: detectedSites.length,
            manualRequired
        };
    }
}

module.exports = { InternalScheduler };
