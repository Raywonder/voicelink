const fs = require('fs');
const os = require('os');
const path = require('path');
const http = require('http');
const https = require('https');
const net = require('net');
const { execFile } = require('child_process');
const { promisify } = require('util');

const execFileAsync = promisify(execFile);

class DeploymentManagerModule {
    constructor(options = {}) {
        this.config = options.config || {};
        this.server = options.server;
        this.dataDir = options.dataDir || path.join(__dirname, '../../../data/deployment-manager');
        this.mailer = options.mailer || null;
        this.emailFrom = options.emailFrom || 'services@devine-creations.com';
        this.deployConfig = options.deployConfig;

        if (!fs.existsSync(this.dataDir)) {
            fs.mkdirSync(this.dataDir, { recursive: true });
        }

        this.watchdogStateFile = path.join(this.dataDir, 'watchdog-state.json');
    }

    getStatus() {
        const watchdog = this.getWatchdogStatus();
        return {
            enabled: this.config.enabled !== false,
            supportsFreshInstall: true,
            supportsExistingInstallUpdate: true,
            supportsRemoteBootstrap: true,
            supportedTransports: this.getSupportedTransports(),
            mailConfigured: !!this.mailer,
            defaultOwnerEmailTemplateEnabled: this.config.emailOwner?.enabled !== false,
            watchdog
        };
    }

    loadWatchdogState() {
        try {
            if (fs.existsSync(this.watchdogStateFile)) {
                const parsed = JSON.parse(fs.readFileSync(this.watchdogStateFile, 'utf8'));
                if (parsed && typeof parsed === 'object') {
                    return parsed;
                }
            }
        } catch (error) {
            return { error: error.message };
        }
        return {};
    }

    saveWatchdogState(state) {
        fs.writeFileSync(this.watchdogStateFile, JSON.stringify(state, null, 2), 'utf8');
    }

    getWatchdogConfig() {
        return {
            enabled: this.config.watchdog?.enabled === true,
            intervalMinutes: Number(this.config.watchdog?.intervalMinutes || 5),
            adminEmails: Array.isArray(this.config.watchdog?.adminEmails) ? this.config.watchdog.adminEmails : [],
            notifications: {
                email: this.config.watchdog?.notifications?.email !== false,
                pushover: this.config.watchdog?.notifications?.pushover === true
            },
            targets: Array.isArray(this.config.watchdog?.targets) ? this.config.watchdog.targets : []
        };
    }

    getWatchdogStatus() {
        const config = this.getWatchdogConfig();
        const state = this.loadWatchdogState();
        return {
            ...config,
            lastRunAt: state.lastRunAt || null,
            lastSummary: state.lastSummary || null,
            lastResults: Array.isArray(state.lastResults) ? state.lastResults : []
        };
    }

    async runWatchdogChecks(options = {}) {
        const config = this.getWatchdogConfig();
        const targets = Array.isArray(options.targets) && options.targets.length ? options.targets : config.targets;
        const results = [];

        for (const target of targets) {
            results.push(await this.runWatchdogTarget(target));
        }

        const failed = results.filter((result) => result.ok === false);
        const summary = {
            ok: failed.length === 0,
            total: results.length,
            failed: failed.length,
            healthy: results.length - failed.length
        };

        const state = {
            lastRunAt: new Date().toISOString(),
            lastSummary: summary,
            lastResults: results
        };
        this.saveWatchdogState(state);

        if (failed.length) {
            await this.notifyWatchdogFailures(failed, config).catch(() => null);
        }

        return {
            success: true,
            summary,
            results
        };
    }

    async runWatchdogTarget(target = {}) {
        const type = String(target.type || 'http').trim().toLowerCase();
        const label = String(target.label || target.url || target.host || target.name || 'Unnamed target');
        try {
            if (type === 'tcp') {
                return await this.runTcpTarget(label, target);
            }
            return await this.runHttpTarget(label, target);
        } catch (error) {
            const recovery = await this.tryWatchdogRecovery(target, error.message).catch((recoveryError) => ({
                attempted: true,
                success: false,
                error: recoveryError.message
            }));
            return {
                ok: false,
                type,
                label,
                checkedAt: new Date().toISOString(),
                error: error.message,
                recovery
            };
        }
    }

    async runHttpTarget(label, target = {}) {
        const url = String(target.url || '').trim();
        if (!url) {
            throw new Error('Missing watchdog target URL');
        }
        const response = await this.httpProbe(url, Number(target.timeoutMs || 5000));
        if (!response.ok) {
            throw new Error(`HTTP probe failed (${response.status || 'error'})`);
        }
        return {
            ok: true,
            type: 'http',
            label,
            checkedAt: new Date().toISOString(),
            status: response.status,
            url
        };
    }

    async runTcpTarget(label, target = {}) {
        const host = String(target.host || '').trim();
        const port = Number(target.port || 0);
        if (!host || !port) {
            throw new Error('Missing TCP host or port');
        }
        await this.tcpProbe(host, port, Number(target.timeoutMs || 5000));
        return {
            ok: true,
            type: 'tcp',
            label,
            checkedAt: new Date().toISOString(),
            host,
            port
        };
    }

    httpProbe(url, timeoutMs = 5000) {
        return new Promise((resolve) => {
            const parsed = new URL(url);
            const client = parsed.protocol === 'https:' ? https : http;
            const req = client.request({
                hostname: parsed.hostname,
                port: parsed.port || (parsed.protocol === 'https:' ? 443 : 80),
                path: `${parsed.pathname}${parsed.search}`,
                method: 'GET',
                timeout: timeoutMs
            }, (res) => {
                res.resume();
                resolve({
                    ok: res.statusCode >= 200 && res.statusCode < 400,
                    status: res.statusCode
                });
            });
            req.on('timeout', () => {
                req.destroy(new Error('Probe timeout'));
            });
            req.on('error', (error) => resolve({ ok: false, error: error.message }));
            req.end();
        });
    }

    tcpProbe(host, port, timeoutMs = 5000) {
        return new Promise((resolve, reject) => {
            const socket = net.createConnection({ host, port });
            const done = (error) => {
                socket.removeAllListeners();
                socket.destroy();
                if (error) {
                    reject(error);
                    return;
                }
                resolve();
            };
            socket.setTimeout(timeoutMs);
            socket.once('connect', () => done());
            socket.once('timeout', () => done(new Error('TCP probe timeout')));
            socket.once('error', done);
        });
    }

    async tryWatchdogRecovery(target = {}, reason = '') {
        const recovery = target.recovery || {};
        if (!recovery.enabled) {
            return { attempted: false };
        }

        const result = {
            attempted: true,
            action: recovery.action || null,
            reason
        };

        if (recovery.action === 'restart-url' && recovery.url) {
            const response = await this.jsonRequest(String(recovery.url), {
                method: String(recovery.method || 'POST').toUpperCase(),
                body: recovery.body || {},
                headers: this.buildBootstrapHeaders(recovery)
            });
            result.success = true;
            result.response = response;
            return result;
        }

        result.success = false;
        result.error = 'Unsupported recovery action';
        return result;
    }

    async notifyWatchdogFailures(failures = [], config = this.getWatchdogConfig()) {
        if (!failures.length || !this.mailer || config.notifications?.email === false) {
            return { success: false, skipped: true };
        }

        const recipients = Array.isArray(config.adminEmails) ? config.adminEmails.filter(Boolean) : [];
        if (!recipients.length) {
            return { success: false, skipped: true };
        }

        const body = [
            'VoiceLink watchdog detected failed targets.',
            '',
            ...failures.map((failure) => `- ${failure.label}: ${failure.error || 'failed'}`)
        ].join('\n');

        await this.mailer.sendMail({
            from: this.emailFrom,
            to: recipients.join(','),
            subject: 'VoiceLink Watchdog Alert',
            text: body
        });

        return { success: true };
    }

    getSupportedTransports() {
        return [
            {
                id: 'sftp',
                name: 'SFTP',
                description: 'Upload deployment archives over SFTP using server credentials.'
            },
            {
                id: 'smb',
                name: 'SMB',
                description: 'Upload deployment archives to SMB shares for hosted installs.'
            },
            {
                id: 'http',
                name: 'HTTP',
                description: 'Push deployment archives or config payloads to HTTP endpoints.'
            },
            {
                id: 'https',
                name: 'HTTPS',
                description: 'Push deployment archives or config payloads to HTTPS endpoints.'
            }
        ];
    }

    sanitizeSlug(value, fallback = 'voicelink-deploy') {
        const cleaned = String(value || '')
            .trim()
            .toLowerCase()
            .replace(/[^a-z0-9._-]+/g, '-')
            .replace(/-+/g, '-')
            .replace(/^-|-$/g, '');
        return cleaned || fallback;
    }

    async buildDeploymentBundle(options = {}) {
        const {
            preset = null,
            sanitize = true,
            ownerEmail = '',
            targetLabel = '',
            targetServerUrl = '',
            linkedToMain = true,
            trustedServers = [],
            extraConfig = {}
        } = options;

        const packageData = this.deployConfig.generateDeploymentPackage(preset || null);
        const exported = this.deployConfig.exportConfig({ sanitize });
        const now = new Date();
        const bundleId = `deploy_${now.getTime()}`;
        const label = this.sanitizeSlug(targetLabel || targetServerUrl || 'voicelink-server');

        const mergedConfig = {
            ...exported,
            server: {
                ...(exported.server || {}),
                ...(extraConfig.server || {})
            },
            federation: {
                ...(exported.federation || {}),
                ...(extraConfig.federation || {})
            }
        };

        if (linkedToMain) {
            const currentTrusted = Array.isArray(mergedConfig.federation?.trustedServers)
                ? mergedConfig.federation.trustedServers
                : [];
            mergedConfig.federation = {
                ...(mergedConfig.federation || {}),
                enabled: true,
                trustedServers: Array.from(new Set([
                    ...currentTrusted,
                    ...trustedServers
                ].filter(Boolean)))
            };
        }

        const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'voicelink-deploy-'));
        const manifest = {
            id: bundleId,
            createdAt: now.toISOString(),
            targetLabel: targetLabel || null,
            targetServerUrl: targetServerUrl || null,
            ownerEmail: ownerEmail || null,
            package: packageData,
            config: mergedConfig
        };

        const installGuide = [
            'VoiceLink Deployment Bundle',
            '',
            `Bundle ID: ${bundleId}`,
            `Created: ${now.toISOString()}`,
            '',
            'Contents:',
            '- deploy.json: VoiceLink deployment config',
            '- deployment-package.json: generated deployment package metadata',
            '- manifest.json: bundle metadata',
            '',
            'Suggested install flow:',
            '1. Upload this bundle to the target server.',
            '2. Extract files into the VoiceLink install root or staging directory.',
            '3. Place deploy.json into server/data/deploy.json for a fresh install.',
            '4. If the target already runs VoiceLink, call /api/config/import with deploy.json.',
            '5. Restart the target VoiceLink API service.',
            '',
            'If the target server API is reachable, the deployment manager can bootstrap config automatically.'
        ].join('\n');

        fs.writeFileSync(path.join(tmpDir, 'deploy.json'), JSON.stringify(mergedConfig, null, 2), 'utf8');
        fs.writeFileSync(path.join(tmpDir, 'deployment-package.json'), JSON.stringify(packageData, null, 2), 'utf8');
        fs.writeFileSync(path.join(tmpDir, 'manifest.json'), JSON.stringify(manifest, null, 2), 'utf8');
        fs.writeFileSync(path.join(tmpDir, 'README.txt'), installGuide, 'utf8');

        const zipName = `${label}-${bundleId}.zip`;
        const zipPath = path.join(this.dataDir, zipName);
        await execFileAsync('zip', ['-rq', zipPath, '.'], { cwd: tmpDir });

        return {
            bundleId,
            zipPath,
            zipName,
            manifest,
            deployConfig: mergedConfig,
            packageData
        };
    }

    async uploadBundle(zipPath, target = {}) {
        const transport = String(target.transport || '').trim().toLowerCase();
        if (!['sftp', 'smb', 'http', 'https'].includes(transport)) {
            throw new Error('Unsupported transport');
        }
        if (!fs.existsSync(zipPath)) {
            throw new Error('Deployment bundle not found');
        }

        const remoteUrl = this.buildTransportUrl(target);
        const args = ['--fail', '--silent', '--show-error', '--upload-file', zipPath];
        if (target.username) args.push('--user', `${target.username}:${target.password || ''}`);
        if (target.method && ['POST', 'PUT'].includes(String(target.method).toUpperCase())) {
            args.push('-X', String(target.method).toUpperCase());
        }
        if (target.insecure === true) args.push('--insecure');
        args.push(remoteUrl);

        await execFileAsync('curl', args);
        return {
            success: true,
            transport,
            remoteUrl
        };
    }

    buildTransportUrl(target = {}) {
        const transport = String(target.transport || '').trim().toLowerCase();
        const host = String(target.host || '').trim();
        const remotePath = String(target.remotePath || '').trim().replace(/^\/+/, '');
        const uploadUrl = String(target.uploadUrl || '').trim();

        if ((transport === 'http' || transport === 'https') && uploadUrl) {
            return uploadUrl;
        }
        if (!host) {
            throw new Error('Target host is required');
        }

        const scheme = transport === 'smb' ? 'smb' : transport;
        const portPart = target.port ? `:${Number(target.port)}` : '';
        const pathPart = remotePath ? `/${remotePath}` : '';
        return `${scheme}://${host}${portPart}${pathPart}`;
    }

    async bootstrapRemoteInstall(target = {}, deployConfigPayload = {}) {
        const apiBaseUrl = String(target.apiBaseUrl || '').trim().replace(/\/+$/, '');
        if (!apiBaseUrl) {
            return { success: false, skipped: true, reason: 'No apiBaseUrl provided' };
        }

        const configResult = await this.jsonRequest(`${apiBaseUrl}/api/config/import`, {
            method: 'POST',
            body: {
                config: deployConfigPayload,
                skipVerification: true
            },
            headers: this.buildBootstrapHeaders(target)
        });

        const federationBody = {
            enabled: true,
            trustedServers: Array.from(new Set([
                ...(deployConfigPayload.federation?.trustedServers || []),
                ...(target.trustedServers || [])
            ].filter(Boolean))),
            allowIncoming: true,
            allowOutgoing: true
        };

        const federationResult = await this.jsonRequest(`${apiBaseUrl}/api/federation/settings`, {
            method: 'PUT',
            body: federationBody,
            headers: this.buildBootstrapHeaders(target)
        }).catch((error) => ({ success: false, error: error.message }));

        return {
            success: !!configResult?.success,
            configImport: configResult,
            federationSync: federationResult
        };
    }

    async triggerRemoteRestart(target = {}) {
        const restartUrl = String(target.restartUrl || '').trim();
        if (!restartUrl) {
            return { success: false, skipped: true, reason: 'No restartUrl provided' };
        }

        try {
            const response = await this.jsonRequest(restartUrl, {
                method: String(target.restartMethod || 'POST').toUpperCase(),
                body: target.restartBody || {},
                headers: this.buildBootstrapHeaders(target)
            });
            return { success: true, response };
        } catch (error) {
            return { success: false, error: error.message };
        }
    }

    buildBootstrapHeaders(target = {}) {
        const headers = { 'Content-Type': 'application/json' };
        if (target.apiToken) headers['x-voicelink-token'] = String(target.apiToken);
        if (target.sharedSecret) headers['x-voicelink-shared-secret'] = String(target.sharedSecret);
        return headers;
    }

    jsonRequest(url, options = {}) {
        return new Promise((resolve, reject) => {
            const parsed = new URL(url);
            const isHttps = parsed.protocol === 'https:';
            const client = isHttps ? https : http;
            const bodyString = JSON.stringify(options.body || {});
            const req = client.request({
                hostname: parsed.hostname,
                port: parsed.port || (isHttps ? 443 : 80),
                path: `${parsed.pathname}${parsed.search}`,
                method: options.method || 'POST',
                headers: {
                    'Content-Type': 'application/json',
                    'Content-Length': Buffer.byteLength(bodyString),
                    ...(options.headers || {})
                }
            }, (res) => {
                let data = '';
                res.on('data', (chunk) => data += chunk);
                res.on('end', () => {
                    let parsedBody = {};
                    try {
                        parsedBody = data ? JSON.parse(data) : {};
                    } catch (error) {
                        parsedBody = { raw: data };
                    }
                    if (res.statusCode >= 400) {
                        reject(new Error(parsedBody.error || `Request failed (${res.statusCode})`));
                        return;
                    }
                    resolve(parsedBody);
                });
            });
            req.on('error', reject);
            req.write(bodyString);
            req.end();
        });
    }

    async emailDeploymentDetails(options = {}) {
        const recipient = String(options.recipient || '').trim();
        if (!recipient) {
            throw new Error('Recipient email is required');
        }
        if (!this.mailer) {
            throw new Error('Mailer not configured');
        }

        const subject = options.subject || 'VoiceLink Server Deployment Details';
        const body = [
            `VoiceLink deployment package: ${options.bundleName || 'Generated'}`,
            options.remoteUrl ? `Upload target: ${options.remoteUrl}` : null,
            options.apiBaseUrl ? `API bootstrap target: ${options.apiBaseUrl}` : null,
            '',
            'Getting started:',
            '1. Extract or place the deployment package on the target server.',
            '2. Confirm deploy.json is loaded by the target VoiceLink install.',
            '3. Restart the VoiceLink API service on the target.',
            '4. Sign in and verify federation/API connectivity from Server Administration.',
            '',
            'If this target is linked to the main VoiceLink install, the deployment package already includes federation linkage and API defaults.'
        ].filter(Boolean).join('\n');

        await this.mailer.sendMail({
            from: this.emailFrom,
            to: recipient,
            subject,
            text: body
        });

        return { success: true };
    }
}

module.exports = { DeploymentManagerModule };
