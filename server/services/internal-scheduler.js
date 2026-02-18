const fs = require('fs');
const path = require('path');
const { execFile } = require('child_process');

class InternalScheduler {
    constructor(options = {}) {
        this.io = options.io || null;
        this.logger = options.logger || console;
        this.dataDir = options.dataDir || path.join(process.cwd(), 'data');
        this.statePath = path.join(this.dataDir, 'internal-scheduler.json');
        this.logsPath = path.join(this.dataDir, 'internal-scheduler-logs.json');
        this.timers = new Map();
        this.tasks = new Map();
        this.logs = [];
        this.maxLogEntries = 400;

        this.defaultTasks = [
            {
                id: 'refresh_update_manifest',
                name: 'Refresh Desktop Update Manifest',
                description: 'Rebuild latest-mac.yml/latest.yml using the current VoiceLink-macOS.zip build.',
                visibility: 'admin',
                allowUserRun: false,
                enabled: true,
                intervalSeconds: 60,
                timeoutMs: 45000,
                action: 'refresh_update_manifest'
            },
            {
                id: 'api_health_probe',
                name: 'API Health Probe',
                description: 'Quick internal check that API health endpoint is responding.',
                visibility: 'user',
                allowUserRun: true,
                enabled: true,
                intervalSeconds: 120,
                timeoutMs: 15000,
                action: 'api_health_probe'
            },
            {
                id: 'sync_update_policy',
                name: 'Sync Update Policy From Hub',
                description: 'Pull update compatibility/required-version policy from upstream hub.',
                visibility: 'admin',
                allowUserRun: false,
                enabled: true,
                intervalSeconds: 300,
                timeoutMs: 20000,
                action: 'sync_update_policy'
            }
        ];

        this.ensureState();
        this.start();
    }

    ensureState() {
        fs.mkdirSync(this.dataDir, { recursive: true });

        const persisted = this.readJson(this.statePath, { tasks: [] });
        const persistedById = new Map((persisted.tasks || []).map((t) => [t.id, t]));

        for (const def of this.defaultTasks) {
            const merged = {
                ...def,
                ...(persistedById.get(def.id) || {}),
                running: false,
                lastRunAt: persistedById.get(def.id)?.lastRunAt || null,
                lastStatus: persistedById.get(def.id)?.lastStatus || 'never',
                lastDurationMs: persistedById.get(def.id)?.lastDurationMs || 0,
                lastMessage: persistedById.get(def.id)?.lastMessage || null,
                nextRunAt: null
            };
            merged.intervalSeconds = Math.max(30, Number(merged.intervalSeconds) || def.intervalSeconds);
            this.tasks.set(merged.id, merged);
        }

        this.logs = this.readJson(this.logsPath, { logs: [] }).logs || [];
        this.saveState();
    }

    readJson(filePath, fallback) {
        try {
            if (!fs.existsSync(filePath)) return fallback;
            return JSON.parse(fs.readFileSync(filePath, 'utf8'));
        } catch (err) {
            this.logger.warn('[InternalScheduler] Failed to read JSON:', filePath, err.message);
            return fallback;
        }
    }

    saveState() {
        const tasks = Array.from(this.tasks.values()).map((t) => ({
            id: t.id,
            name: t.name,
            description: t.description,
            visibility: t.visibility,
            allowUserRun: t.allowUserRun,
            enabled: t.enabled,
            intervalSeconds: t.intervalSeconds,
            timeoutMs: t.timeoutMs,
            action: t.action,
            lastRunAt: t.lastRunAt,
            lastStatus: t.lastStatus,
            lastDurationMs: t.lastDurationMs,
            lastMessage: t.lastMessage
        }));

        fs.writeFileSync(this.statePath, JSON.stringify({ updatedAt: new Date().toISOString(), tasks }, null, 2));
        fs.writeFileSync(this.logsPath, JSON.stringify({ updatedAt: new Date().toISOString(), logs: this.logs }, null, 2));
    }

    start() {
        for (const task of this.tasks.values()) {
            this.scheduleNext(task.id);
        }
        this.logger.log('[InternalScheduler] Started with', this.tasks.size, 'tasks');
    }

    stop() {
        for (const timer of this.timers.values()) {
            clearTimeout(timer);
        }
        this.timers.clear();
    }

    scheduleNext(taskId) {
        const task = this.tasks.get(taskId);
        if (!task) return;

        const existing = this.timers.get(taskId);
        if (existing) clearTimeout(existing);

        if (!task.enabled) {
            task.nextRunAt = null;
            this.timers.delete(taskId);
            this.saveState();
            return;
        }

        const delayMs = Math.max(1000, task.intervalSeconds * 1000);
        task.nextRunAt = new Date(Date.now() + delayMs).toISOString();

        const timer = setTimeout(async () => {
            await this.runTask(taskId, { actor: 'system', trigger: 'scheduled' });
            this.scheduleNext(taskId);
        }, delayMs);

        this.timers.set(taskId, timer);
        this.saveState();
    }

    async runTask(taskId, context = {}) {
        const task = this.tasks.get(taskId);
        if (!task) {
            return { success: false, error: 'Task not found' };
        }

        if (task.running) {
            return { success: false, error: 'Task already running' };
        }

        task.running = true;
        const startedAt = Date.now();
        const actor = context.actor || 'unknown';
        const trigger = context.trigger || 'manual';

        let result;
        try {
            result = await this.executeAction(task.action, task.timeoutMs);
            task.lastStatus = 'ok';
            task.lastMessage = result.message;
        } catch (err) {
            result = { success: false, message: err.message || 'Task failed' };
            task.lastStatus = 'error';
            task.lastMessage = result.message;
        } finally {
            task.running = false;
            task.lastRunAt = new Date().toISOString();
            task.lastDurationMs = Date.now() - startedAt;

            this.logs.unshift({
                id: `${task.id}:${Date.now()}`,
                taskId: task.id,
                taskName: task.name,
                actor,
                trigger,
                status: task.lastStatus,
                message: task.lastMessage,
                durationMs: task.lastDurationMs,
                timestamp: task.lastRunAt
            });
            this.logs = this.logs.slice(0, this.maxLogEntries);
            this.saveState();
            this.notifyUpdate();
        }

        return {
            success: task.lastStatus === 'ok',
            taskId: task.id,
            status: task.lastStatus,
            message: task.lastMessage,
            durationMs: task.lastDurationMs
        };
    }

    executeAction(action, timeoutMs) {
        switch (action) {
        case 'refresh_update_manifest':
            return this.execScript('/home/devinecr/scripts/refresh-voicelink-update-meta.sh', timeoutMs);
        case 'api_health_probe':
            return this.execInline('curl -fsS --max-time 8 http://127.0.0.1:3010/api/health > /dev/null', timeoutMs);
        case 'sync_update_policy':
            return this.execInline('curl -fsS --max-time 12 -X POST http://127.0.0.1:3010/api/updates/policy/sync > /dev/null', timeoutMs);
        default:
            return Promise.reject(new Error(`Unsupported scheduler action: ${action}`));
        }
    }

    execScript(scriptPath, timeoutMs = 30000) {
        if (!fs.existsSync(scriptPath)) {
            return Promise.reject(new Error(`Script not found: ${scriptPath}`));
        }
        return this.execInline(`bash ${scriptPath}`, timeoutMs);
    }

    execInline(command, timeoutMs = 30000) {
        return new Promise((resolve, reject) => {
            execFile('bash', ['-lc', command], { timeout: timeoutMs }, (error, stdout, stderr) => {
                if (error) {
                    reject(new Error((stderr || error.message || 'command failed').trim()));
                    return;
                }
                const output = [stdout, stderr].filter(Boolean).join('\n').trim();
                resolve({ success: true, message: output || 'ok' });
            });
        });
    }

    listTasks(role = 'user') {
        const isAdmin = role === 'admin';
        return Array.from(this.tasks.values())
            .filter((task) => isAdmin || task.visibility !== 'admin')
            .map((task) => ({
                id: task.id,
                name: task.name,
                description: task.description,
                visibility: task.visibility,
                allowUserRun: task.allowUserRun,
                enabled: task.enabled,
                intervalSeconds: task.intervalSeconds,
                running: task.running,
                lastRunAt: task.lastRunAt,
                lastStatus: task.lastStatus,
                lastDurationMs: task.lastDurationMs,
                lastMessage: task.lastMessage,
                nextRunAt: task.nextRunAt,
                action: isAdmin ? task.action : undefined
            }));
    }

    getStatus(role = 'user') {
        const visibleTasks = this.listTasks(role);
        const totalEnabled = visibleTasks.filter((t) => t.enabled).length;
        const running = visibleTasks.filter((t) => t.running).length;
        return {
            service: 'internal-scheduler',
            role,
            totalVisibleTasks: visibleTasks.length,
            enabledTasks: totalEnabled,
            runningTasks: running,
            serverTime: new Date().toISOString()
        };
    }

    updateTask(taskId, patch = {}, role = 'user') {
        const task = this.tasks.get(taskId);
        if (!task) return { success: false, error: 'Task not found' };
        if (role !== 'admin') return { success: false, error: 'Admin access required' };

        if (patch.enabled !== undefined) task.enabled = !!patch.enabled;
        if (patch.intervalSeconds !== undefined) {
            task.intervalSeconds = Math.max(30, Number(patch.intervalSeconds) || task.intervalSeconds);
        }

        this.scheduleNext(taskId);
        this.notifyUpdate();

        return { success: true, task: this.listTasks('admin').find((t) => t.id === taskId) };
    }

    listLogs(role = 'user', limit = 50) {
        const allowedTaskIds = new Set(this.listTasks(role).map((t) => t.id));
        return this.logs
            .filter((entry) => allowedTaskIds.has(entry.taskId))
            .slice(0, Math.max(1, Math.min(200, Number(limit) || 50)));
    }

    notifyUpdate() {
        if (!this.io) return;
        this.io.emit('scheduler:update', {
            status: this.getStatus('admin'),
            updatedAt: new Date().toISOString()
        });
    }
}

module.exports = InternalScheduler;
