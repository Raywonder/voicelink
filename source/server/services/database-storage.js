const fs = require('fs');
const path = require('path');
const { execFileSync } = require('child_process');

class DatabaseStorageManager {
    constructor({ deployConfig, appRoot }) {
        this.deployConfig = deployConfig;
        this.appRoot = appRoot;
    }

    getDatabaseConfig() {
        return this.deployConfig.get('database') || {};
    }

    getSqlitePath() {
        const config = this.getDatabaseConfig();
        const configured = config?.sqlite?.path || path.join(this.appRoot, 'data', 'voicelink.db');
        return path.isAbsolute(configured) ? configured : path.join(this.appRoot, configured);
    }

    sqliteAvailable() {
        try {
            execFileSync('sqlite3', ['-version'], { stdio: 'ignore' });
            return true;
        } catch {
            return false;
        }
    }

    runSql(sql) {
        const dbPath = this.getSqlitePath();
        fs.mkdirSync(path.dirname(dbPath), { recursive: true });
        execFileSync('sqlite3', [dbPath, sql], { stdio: 'pipe' });
        return dbPath;
    }

    ensureSchema() {
        if (!this.sqliteAvailable()) {
            throw new Error('sqlite3 is not installed on this server');
        }

        const sql = `
PRAGMA journal_mode=WAL;
CREATE TABLE IF NOT EXISTS voicelink_meta (
  key TEXT PRIMARY KEY,
  value TEXT,
  updated_at TEXT DEFAULT CURRENT_TIMESTAMP
);
CREATE TABLE IF NOT EXISTS voicelink_snapshots (
  kind TEXT NOT NULL,
  entry_key TEXT NOT NULL,
  payload TEXT NOT NULL,
  source_file TEXT,
  updated_at TEXT DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (kind, entry_key)
);
`;
        const dbPath = this.runSql(sql);
        this.runSql("INSERT INTO voicelink_meta(key, value, updated_at) VALUES('schema_version', '1', CURRENT_TIMESTAMP) ON CONFLICT(key) DO UPDATE SET value='1', updated_at=CURRENT_TIMESTAMP;");
        return dbPath;
    }

    readJson(filePath) {
        if (!fs.existsSync(filePath)) return null;
        try {
            return JSON.parse(fs.readFileSync(filePath, 'utf8'));
        } catch {
            return null;
        }
    }

    sqlEscape(value) {
        return String(value ?? '').replace(/'/g, "''");
    }

    upsertSnapshot(kind, entryKey, payload, sourceFile = null) {
        const payloadJson = this.sqlEscape(JSON.stringify(payload));
        const source = sourceFile ? `'${this.sqlEscape(sourceFile)}'` : 'NULL';
        this.runSql(`
INSERT INTO voicelink_snapshots(kind, entry_key, payload, source_file, updated_at)
VALUES('${this.sqlEscape(kind)}', '${this.sqlEscape(entryKey)}', '${payloadJson}', ${source}, CURRENT_TIMESTAMP)
ON CONFLICT(kind, entry_key) DO UPDATE SET
  payload=excluded.payload,
  source_file=excluded.source_file,
  updated_at=CURRENT_TIMESTAMP;
`);
    }

    migrateDefaults() {
        const dbPath = this.ensureSchema();
        const dataDir = path.join(this.appRoot, 'data');
        const serverDataDir = path.join(this.appRoot, 'server', 'data');

        this.upsertSnapshot('diagnostics', 'bug-reports', this.readJson(path.join(dataDir, 'bug-reports.json')) || [], path.join(dataDir, 'bug-reports.json'));
        this.upsertSnapshot('modules', 'modules-config', this.readJson(path.join(dataDir, 'modules.json')) || {}, path.join(dataDir, 'modules.json'));
        this.upsertSnapshot('rooms', 'rooms', this.readJson(path.join(serverDataDir, 'rooms.json')) || [], path.join(serverDataDir, 'rooms.json'));

        const schedulerDir = path.join(dataDir, 'scheduler');
        const schedulerPayload = {
            path: schedulerDir,
            files: fs.existsSync(schedulerDir) ? fs.readdirSync(schedulerDir).sort() : []
        };
        this.upsertSnapshot('scheduler', 'scheduler-dir', schedulerPayload, schedulerDir);
        this.upsertSnapshot('serverConfig', 'deploy-config', this.deployConfig.getConfig() || {}, 'deploy-config');

        this.runSql("INSERT INTO voicelink_meta(key, value, updated_at) VALUES('last_migration', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP) ON CONFLICT(key) DO UPDATE SET value=CURRENT_TIMESTAMP, updated_at=CURRENT_TIMESTAMP;");
        return { dbPath, migrated: ['diagnostics', 'modules', 'rooms', 'scheduler', 'serverConfig'] };
    }

    status() {
        const dbPath = this.getSqlitePath();
        const exists = fs.existsSync(dbPath);
        const sizeBytes = exists ? fs.statSync(dbPath).size : 0;
        let lastMigration = null;
        let snapshotCounts = {};

        if (exists && this.sqliteAvailable()) {
            try {
                lastMigration = execFileSync('sqlite3', [dbPath, "SELECT value FROM voicelink_meta WHERE key='last_migration' LIMIT 1;"], { encoding: 'utf8' }).trim() || null;
                const raw = execFileSync('sqlite3', [dbPath, "SELECT kind || ':' || COUNT(*) FROM voicelink_snapshots GROUP BY kind ORDER BY kind;"], { encoding: 'utf8' }).trim();
                snapshotCounts = (raw ? raw.split('\n') : []).reduce((acc, line) => {
                    const [kind, count] = line.split(':');
                    if (kind) acc[kind] = Number(count || 0);
                    return acc;
                }, {});
            } catch {
            }
        }

        return {
            provider: this.getDatabaseConfig().provider || 'sqlite',
            sqliteAvailable: this.sqliteAvailable(),
            dbPath,
            exists,
            sizeBytes,
            lastMigration,
            snapshotCounts
        };
    }
}

module.exports = { DatabaseStorageManager };
