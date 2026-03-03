const fs = require('fs');
const os = require('os');
const path = require('path');
const http = require('http');
const https = require('https');
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
    }

    getStatus() {
        return {
            enabled: this.config.enabled !== false,
            supportsFreshInstall: true,
            supportsExistingInstallUpdate: true,
            supportsRemoteBootstrap: true,
            supportedTransports: this.getSupportedTransports(),
            mailConfigured: !!this.mailer,
            defaultOwnerEmailTemplateEnabled: this.config.emailOwner?.enabled !== false
        };
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
