const fs = require('fs');
const path = require('path');
const { deployConfig } = require('../../config/deploy-config');
const { DatabaseStorageManager } = require('../../services/database-storage');
const databaseStorage = new DatabaseStorageManager({ deployConfig, appRoot: path.join(__dirname, '../..') });

class InternalScheduler {
    constructor(options = {}) {
        this.io = options.io || null;
        this.logger = options.logger || console;
        this.dataDir = options.dataDir || path.join(__dirname, '../../../data/scheduler');
        this.jobs = new Map();
        this.startedAt = null;
        this.ensureDataDir();
        this.start();
    }

    ensureDataDir() {
        if (!fs.existsSync(this.dataDir)) {
            fs.mkdirSync(this.dataDir, { recursive: true });
        }
    }

    start() {
        if (this.startedAt) return;
        this.startedAt = new Date().toISOString();

        // Lightweight housekeeping and health ping.
        this.schedule('cleanup-stale-files', 5 * 60 * 1000, () => this.cleanupStaleExports());
        this.schedule('scheduler-heartbeat', 60 * 1000, () => this.emitHeartbeat());
    }

    stop() {
        for (const job of this.jobs.values()) {
            clearInterval(job.timer);
        }
        this.jobs.clear();
    }

    schedule(name, intervalMs, handler) {
        if (this.jobs.has(name)) {
            clearInterval(this.jobs.get(name).timer);
        }
        const wrapped = async () => {
            try {
                await Promise.resolve(handler());
                const current = this.jobs.get(name);
                if (current) current.lastRunAt = new Date().toISOString();
            } catch (error) {
                this.logger.warn?.(`[InternalScheduler] Job "${name}" failed: ${error.message}`);
            }
        };
        const timer = setInterval(wrapped, intervalMs);
        this.jobs.set(name, {
            name,
            intervalMs,
            timer,
            createdAt: new Date().toISOString(),
            lastRunAt: null
        });
    }

    cleanupStaleExports() {
        const exportsDir = path.join(this.dataDir, '..', '..', 'exports');
        if (!fs.existsSync(exportsDir)) return;
        const cutoff = Date.now() - (24 * 60 * 60 * 1000);
        for (const entry of fs.readdirSync(exportsDir, { withFileTypes: true })) {
            if (!entry.isFile()) continue;
            const fullPath = path.join(exportsDir, entry.name);
            try {
                const stat = fs.statSync(fullPath);
                if (stat.mtimeMs < cutoff) {
                    fs.unlinkSync(fullPath);
                }
            } catch (error) {
                this.logger.warn?.(`[InternalScheduler] cleanup skip "${entry.name}": ${error.message}`);
            }
        }
    }

    emitHeartbeat() {
        try {
            databaseStorage.mirrorSnapshot('scheduler', 'scheduler-status', this.getStatus(), this.dataDir);
            databaseStorage.mirrorDirectoryListing('scheduler', 'scheduler-dir', this.dataDir);
        } catch (mirrorError) {
            this.logger.warn?.(`[InternalScheduler] database mirror skipped: ${mirrorError.message}`);
        }
        if (!this.io) return;
        this.io.emit('scheduler-heartbeat', {
            at: new Date().toISOString(),
            jobs: this.getStatus().jobs
        });
    }

    getStatus() {
        return {
            startedAt: this.startedAt,
            jobs: Array.from(this.jobs.values()).map((job) => ({
                name: job.name,
                intervalMs: job.intervalMs,
                createdAt: job.createdAt,
                lastRunAt: job.lastRunAt
            }))
        };
    }
}

module.exports = { InternalScheduler };
