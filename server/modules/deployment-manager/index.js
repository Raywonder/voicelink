const fs = require('fs');
const path = require('path');
const os = require('os');
const crypto = require('crypto');
const http = require('http');
const https = require('https');
const { execFile } = require('child_process');

function ensureDir(dirPath) {
    fs.mkdirSync(dirPath, { recursive: true });
    return dirPath;
}

function readJson(filePath, fallback) {
    try {
        if (!fs.existsSync(filePath)) return fallback;
        return JSON.parse(fs.readFileSync(filePath, 'utf8'));
    } catch (_) {
        return fallback;
    }
}

function writeJson(filePath, value) {
    fs.writeFileSync(filePath, JSON.stringify(value, null, 2), 'utf8');
}

function copyRecursive(source, destination) {
    fs.cpSync(source, destination, { recursive: true });
}

function execFileAsync(command, args, options = {}) {
    return new Promise((resolve, reject) => {
        execFile(command, args, options, (error, stdout, stderr) => {
            if (error) {
                error.stdout = stdout;
                error.stderr = stderr;
                reject(error);
                return;
            }
            resolve({ stdout, stderr });
        });
    });
}

function extractHostname(value) {
    if (!value || typeof value !== 'string') return null;
    try {
        if (/^https?:\/\//i.test(value)) {
            return new URL(value).hostname;
        }
        return value.replace(/^\/*/, '').split('/')[0].split(':')[0] || null;
    } catch (_) {
        return null;
    }
}

function normalizePublicUrl(value) {
    if (!value || typeof value !== 'string') return null;
    const trimmed = value.trim();
    if (!trimmed) return null;
    try {
        const parsed = new URL(/^https?:\/\//i.test(trimmed) ? trimmed : `https://${trimmed}`);
        parsed.hash = '';
        parsed.search = '';
        return parsed.toString().replace(/\/+$/, '');
    } catch (_) {
        return trimmed.replace(/\/+$/, '');
    }
}

function extractBasePath(value) {
    if (!value || typeof value !== 'string') return '';
    try {
        const parsed = new URL(/^https?:\/\//i.test(value) ? value : `https://${value}`);
        return parsed.pathname === '/' ? '' : parsed.pathname.replace(/\/+$/, '');
    } catch (_) {
        return '';
    }
}

function uniqueList(values = []) {
    const seen = new Set();
    const result = [];
    for (const value of values) {
        const normalized = normalizePublicUrl(value);
        if (!normalized || seen.has(normalized)) continue;
        seen.add(normalized);
        result.push(normalized);
    }
    return result;
}

function sanitizeFileToken(value, fallback = 'server') {
    const normalized = String(value || fallback)
        .trim()
        .replace(/[^a-z0-9._-]+/gi, '-')
        .replace(/^-+|-+$/g, '');
    return normalized || fallback;
}

function sanitizeDomainToken(value, fallback = 'server') {
    const token = sanitizeFileToken(value, fallback).toLowerCase();
    return token.includes('.') ? token : fallback;
}

function inferDeploymentRole({ role, siteType, deploymentMode, domain } = {}) {
    const explicit = String(role || '').trim().toLowerCase();
    if (['main', 'community', 'dev', 'cms', 'remote'].includes(explicit)) return explicit;

    const mode = String(deploymentMode || '').trim().toLowerCase();
    if (['main', 'community', 'dev', 'cms', 'remote'].includes(mode)) return mode;

    const normalizedSiteType = String(siteType || '').trim().toLowerCase();
    if (['wordpress', 'whmcs', 'composr', 'cpanel', 'installatron', 'cms'].includes(normalizedSiteType)) {
        return 'cms';
    }

    const host = String(domain || '').trim().toLowerCase();
    if (host.startsWith('community.') || host.includes('.community.')) return 'community';
    if (host.startsWith('dev.') || host.includes('.dev.') || host.includes('staging')) return 'dev';
    return 'main';
}

function buildDeploymentLayout({ target = {}, deployPayload = {}, serverConfig = {}, ownerConfig = {} } = {}) {
    const targetInfo = deployPayload.deploymentLink?.target || {};
    const deploymentMode = serverConfig.deploymentMode || deployPayload.deploymentLink?.deploymentMode || target.deploymentMode;
    const siteType = serverConfig.siteType || target.siteType || targetInfo.siteType;
    const domain = sanitizeDomainToken(
        serverConfig.domain
        || target.domain
        || targetInfo.domain
        || extractHostname(target.publicUrl || target.targetServerUrl || target.apiBaseUrl || deployPayload.targetServerUrl)
        || target.host
    );
    const role = inferDeploymentRole({
        role: serverConfig.role || target.role || targetInfo.role,
        siteType,
        deploymentMode,
        domain
    });
    const accountOwner = String(
        ownerConfig.accountOwner
        || serverConfig.accountOwner
        || serverConfig.targetUser
        || target.accountOwner
        || target.username
        || targetInfo.accountOwner
        || 'voicelink'
    ).trim() || 'voicelink';
    const accountHome = accountOwner.startsWith('/') ? accountOwner : path.posix.join('/home', accountOwner);
    const installRoot = String(
        serverConfig.installRoot
        || serverConfig.remotePath
        || target.remotePath
        || targetInfo.installRoot
        || path.posix.join(accountHome, 'apps', 'voicelink', role, domain)
    ).trim();
    const processName = sanitizeFileToken(
        serverConfig.processName
        || target.processName
        || `${domain}-${role}`,
        `${domain}-${role}`
    );
    const serviceId = sanitizeFileToken(
        serverConfig.serviceId
        || target.serviceId
        || processName,
        processName
    );
    const appPort = String(serverConfig.appPort || serverConfig.port || target.appPort || target.servicePort || '').trim();
    const displayName = String(
        serverConfig.displayName
        || serverConfig.name
        || target.displayName
        || target.label
        || `${domain} VoiceLink ${role}`
    ).trim();

    return {
        accountOwner,
        accountHome,
        domain,
        role,
        siteType: siteType || null,
        installRoot,
        processName,
        serviceId,
        displayName,
        appPort: appPort || null,
        pm2: {
            enabled: serverConfig.pm2Enabled !== false && target.pm2Enabled !== false,
            processName,
            serviceId,
            appPort: appPort || null
        }
    };
}

function createRequestPromise(urlString, options = {}, body = null) {
    return new Promise((resolve, reject) => {
        const client = urlString.startsWith('https://') ? https : http;
        const request = client.request(urlString, options, (response) => {
            let data = '';
            response.on('data', (chunk) => { data += chunk; });
            response.on('end', () => {
                resolve({
                    statusCode: response.statusCode || 0,
                    headers: response.headers,
                    body: data
                });
            });
        });
        request.on('error', reject);
        if (body) request.write(body);
        request.end();
    });
}

function shellQuote(value) {
    return `'${String(value).replace(/'/g, `'\\''`)}'`;
}

class DeploymentManagerModule {
    constructor(options = {}) {
        this.config = options.config || {};
        this.dataDir = ensureDir(options.dataDir || path.join(process.cwd(), 'data', 'deployment-manager'));
        this.deployConfig = options.deployConfig || null;
        this.server = options.server || null;
        this.mailer = options.mailer || null;
        this.emailFrom = options.emailFrom || null;
        this.appRoot = path.join(__dirname, '../../..');
        this.packageDir = ensureDir(path.join(this.dataDir, 'packages'));
        this.historyPath = path.join(this.dataDir, 'history.json');
        this.watchdogPath = path.join(this.dataDir, 'watchdog.json');
        this.targetsManifestPath = path.join(this.appRoot, 'wordpress', 'deployment-targets.json');
        this.history = readJson(this.historyPath, []);
        this.watchdog = readJson(this.watchdogPath, {
            lastRunAt: null,
            status: 'idle',
            checks: []
        });
        this.maxHistory = 250;
    }

    getSupportedTransports() {
        const transportConfig = this.config.transports || {};
        const transports = [];
        if (transportConfig.sftp !== false) {
            transports.push({
                id: 'sftp',
                name: 'SFTP / SCP',
                description: 'Copy the VoiceLink deployment bundle over SSH to an owned server.'
            });
        }
        if (transportConfig.http !== false) {
            transports.push({
                id: 'http',
                name: 'HTTP Upload',
                description: 'Upload the deployment bundle to a plain HTTP deployment endpoint.'
            });
        }
        if (transportConfig.https !== false) {
            transports.push({
                id: 'https',
                name: 'HTTPS Upload',
                description: 'Upload the deployment bundle to a secure deployment endpoint.'
            });
        }
        if (transportConfig.smb === true) {
            transports.push({
                id: 'smb',
                name: 'SMB Share',
                description: 'Copy the deployment bundle to a mounted SMB share or compatible fileshare.'
            });
        }
        return transports;
    }

    getSupportedTargets() {
        const manifest = readJson(this.targetsManifestPath, { supportedSites: [] });
        const targets = Array.isArray(manifest.targets)
            ? manifest.targets
            : (Array.isArray(manifest.supportedSites) ? manifest.supportedSites : []);
        return {
            ...manifest,
            targets
        };
    }

    getReleaseArtifacts() {
        const knownFiles = [
            'VoiceLink-1.0.0-macos.pkg',
            'VoiceLink-1.0.0-macos-intel.pkg',
            'VoiceLink-1.0.0-macos-apple-silicon.pkg',
            'VoiceLinkMacOS.zip',
            'VoiceLink-macOS.zip',
            'latest-mac.yml',
            'latest-mac.server.yml',
            'VoiceLink-1.0.0-windows-portable.exe',
            'VoiceLink-1.0.0-windows-setup.exe',
            'VoiceLink-windows.zip',
            'VoiceLink-linux.AppImage',
            'voicelink-local_1.0.0_amd64.deb'
        ];
        const homeDir = process.env.HOME || '';
        const configuredDownloadsRoot = process.env.VOICELINK_DOWNLOADS_DIR
            || (homeDir ? path.join(homeDir, 'downloads', 'voicelink') : null);
        const roots = [
            path.join(this.appRoot, 'swift-native', 'VoiceLinkNative'),
            configuredDownloadsRoot
        ].filter(Boolean);
        const artifacts = [];
        const seen = new Set();

        for (const root of roots) {
            if (!fs.existsSync(root)) continue;
            for (const fileName of knownFiles) {
                const artifactPath = path.join(root, fileName);
                if (!fs.existsSync(artifactPath)) continue;
                const key = `${root}::${fileName}`;
                if (seen.has(key)) continue;
                seen.add(key);
                const stats = fs.statSync(artifactPath);
                const checksumPath = `${artifactPath}.sha256`;
                artifacts.push({
                    name: fileName,
                    path: artifactPath,
                    root,
                    size: stats.size,
                    modifiedAt: stats.mtime.toISOString(),
                    checksumPath: fs.existsSync(checksumPath) ? checksumPath : null,
                    type: this.classifyReleaseArtifact(fileName)
                });
            }
        }

        return artifacts;
    }

    classifyReleaseArtifact(fileName = '') {
        const lowered = String(fileName).toLowerCase();
        if (lowered.endsWith('.pkg')) return 'macos-installer';
        if (lowered.endsWith('.zip')) return lowered.includes('macos') ? 'macos-zip' : 'archive';
        if (lowered.endsWith('.exe')) return 'windows-installer';
        if (lowered.endsWith('.appimage')) return 'linux-appimage';
        if (lowered.endsWith('.deb')) return 'linux-deb';
        if (lowered.endsWith('.yml')) return 'update-manifest';
        return 'artifact';
    }

    getStatus() {
        return {
            enabled: true,
            supportsFreshInstall: true,
            supportsExistingInstallUpdate: true,
            supportsRemoteBootstrap: true,
            supportedTransports: this.getSupportedTransports(),
            mailConfigured: !!(this.mailer && this.emailFrom),
            defaultOwnerEmailTemplateEnabled: this.config.autoEmailOwner !== false,
            supportedTargets: this.getSupportedTargets().targets || [],
            releaseArtifacts: this.getReleaseArtifacts(),
            lastWatchdogRunAt: this.watchdog.lastRunAt || null
        };
    }

    getActionHistory(limit = 50) {
        const normalized = Math.max(1, Math.min(500, Number(limit || 50)));
        return this.history.slice(-normalized).reverse();
    }

    recordDeploymentAction(action = {}) {
        this.history.push({
            id: `${Date.now()}-${Math.random().toString(36).slice(2, 8)}`,
            timestamp: new Date().toISOString(),
            ...action
        });
        if (this.history.length > this.maxHistory) {
            this.history = this.history.slice(-this.maxHistory);
        }
        writeJson(this.historyPath, this.history);
    }

    getWatchdogStatus() {
        return {
            enabled: this.config.watchdog?.enabled !== false,
            intervalMinutes: Number(this.config.watchdog?.intervalMinutes || 30),
            ...this.watchdog
        };
    }

    async runWatchdogChecks() {
        const checks = [];
        const targets = this.getSupportedTargets().targets || [];
        checks.push({
            id: 'wordpress-plugin',
            label: 'WordPress plugin bundle',
            success: fs.existsSync(path.join(this.appRoot, 'wordpress', 'voicelink-wordpress', 'voicelink-wordpress.php')),
            detail: 'Checks that the bundled WordPress deployment plugin exists.'
        });
        checks.push({
            id: 'deployment-targets',
            label: 'Supported site manifest',
            success: targets.length > 0,
            detail: `Detected ${targets.length} supported deployment target${targets.length === 1 ? '' : 's'}.`
        });
        checks.push({
            id: 'package-dir',
            label: 'Package output directory',
            success: fs.existsSync(this.packageDir),
            detail: this.packageDir
        });

        const success = checks.every((item) => item.success);
        this.watchdog = {
            lastRunAt: new Date().toISOString(),
            status: success ? 'ok' : 'error',
            checks
        };
        writeJson(this.watchdogPath, this.watchdog);
        return { success, ...this.watchdog };
    }

    validateDeploymentTarget(target = {}, options = {}) {
        const transport = String(target.transport || '').trim().toLowerCase();
        if (!transport) {
            return { ok: false, error: 'Select a deployment transport first.' };
        }

        const supported = new Set(this.getSupportedTransports().map((item) => item.id));
        if (!supported.has(transport)) {
            return { ok: false, error: `Transport '${transport}' is not enabled on this server.` };
        }

        if (transport === 'sftp') {
            if (!target.host || !target.username) {
                return { ok: false, error: 'SFTP deployment requires a host and username.' };
            }
            const layout = buildDeploymentLayout({ target, serverConfig: options.extraConfig?.server || {}, ownerConfig: options.extraConfig?.owner || {} });
            if (options.requireRemoteCredentials && !target.remotePath && !layout.installRoot) {
                return { ok: false, error: 'Choose a remote install path or provide a domain so VoiceLink can derive apps/voicelink/<role>/<domain>.' };
            }
        }

        if ((transport === 'http' || transport === 'https') && !target.uploadUrl) {
            return { ok: false, error: 'HTTP or HTTPS deployment requires an upload URL.' };
        }

        if (transport === 'smb' && !target.remotePath) {
            return { ok: false, error: 'SMB deployment requires a mounted target path.' };
        }

        if (options.requireBootstrapCredentials && !target.apiBaseUrl && transport !== 'sftp') {
            return { ok: false, error: 'Bootstrap requires an API base URL or SSH-capable target.' };
        }

        return { ok: true };
    }

    async buildDeploymentBundle(options = {}) {
        const preset = options.preset || 'production';
        const extraConfig = options.extraConfig || {};
        const serverConfig = extraConfig.server || {};
        const ownerConfig = extraConfig.owner || {};
        const federationConfig = extraConfig.federation || {};
        const policyConfig = extraConfig.policy || {};
        const moduleUpdateConfig = extraConfig.moduleUpdates || {};
        const bundleId = `${Date.now()}-${crypto.randomUUID().slice(0, 8)}`;
        const targetLabel = options.targetLabel || null;
        const ownerEmail = options.ownerEmail || null;
        const targetServerUrl = normalizePublicUrl(options.targetServerUrl) || null;
        const masterApiUrl = normalizePublicUrl(federationConfig.masterApiUrl || serverConfig.masterApiUrl || 'https://voicelinkapp.app');
        const secondaryApiUrl = normalizePublicUrl(federationConfig.secondaryApiUrl || serverConfig.secondaryApiUrl || 'https://voicelink.dev');
        const masterCommunityApiUrl = normalizePublicUrl(federationConfig.masterCommunityApiUrl || serverConfig.masterCommunityApiUrl || 'https://community.voicelinkapp.app');
        const localApiUrl = normalizePublicUrl(serverConfig.localApiUrl || targetServerUrl);
        const fallbackApiUrls = uniqueList([
            localApiUrl,
            masterApiUrl,
            secondaryApiUrl,
            masterCommunityApiUrl,
            ...(Array.isArray(federationConfig.fallbackApiUrls) ? federationConfig.fallbackApiUrls : []),
            ...(Array.isArray(options.trustedServers) ? options.trustedServers : [])
        ]);
        const targetDomain = serverConfig.domain || extractHostname(targetServerUrl);
        const basePath = serverConfig.basePath || extractBasePath(targetServerUrl);
        const targetAccountOwner = ownerConfig.accountOwner || serverConfig.accountOwner || serverConfig.targetUser || null;
        const deploymentMode = String(serverConfig.deploymentMode || options.deploymentMode || 'fresh').trim().toLowerCase();
        const deploymentLayout = buildDeploymentLayout({
            target: options.target || {},
            deployPayload: { targetServerUrl },
            serverConfig: { ...serverConfig, deploymentMode, domain: targetDomain },
            ownerConfig
        });
        const installRoot = serverConfig.installRoot || serverConfig.remotePath || deploymentLayout.installRoot || null;
        const deploymentLink = {
            deploymentMode,
            sourceInstallUrl: normalizePublicUrl(serverConfig.sourceInstallUrl || options.sourceInstallUrl) || null,
            target: {
                label: targetLabel,
                publicUrl: targetServerUrl,
                domain: targetDomain || null,
                role: deploymentLayout.role,
                basePath,
                installRoot,
                siteRoot: serverConfig.siteRoot || null,
                accountOwner: targetAccountOwner,
                whmcsClientOwner: ownerConfig.whmcsClientOwner || null
            },
            deploymentLayout,
            ownership: {
                owner: ownerConfig.owner || targetLabel || targetDomain || null,
                accountOwner: targetAccountOwner,
                linkedVoiceLinkAccount: ownerConfig.linkedVoiceLinkAccount || 'voicelink',
                linkedServerOwner: ownerConfig.linkedServerOwner || ownerConfig.owner || targetLabel || null,
                whmcsClientOwner: ownerConfig.whmcsClientOwner || null
            },
            federation: {
                linkedToMain: options.linkedToMain !== false,
                masterApiUrl,
                secondaryApiUrl,
                masterCommunityApiUrl,
                fallbackApiUrls,
                nearestApiStrategy: federationConfig.nearestApiStrategy || 'local-first-health-latency',
                localAssetFallback: federationConfig.localAssetFallback !== 'false'
            },
            policy: {
                listedInDirectory: policyConfig.listedInDirectory !== 'false',
                allowDirectReveal: policyConfig.allowDirectReveal !== 'false',
                authRequired: policyConfig.authRequired || 'optional',
                allowGuests: policyConfig.allowGuests !== 'false',
                guestAccess: policyConfig.guestAccess || 'allowed-limited',
                roomDirectory: policyConfig.roomDirectory || 'limited',
                roomAccess: policyConfig.roomAccess || 'mixed',
                verification: {
                    status: policyConfig.verificationStatus || 'pending',
                    method: policyConfig.verificationMethod || 'master-api'
                }
            },
            moduleUpdatePolicy: {
                enabled: moduleUpdateConfig.enabled !== 'false',
                autoEnableUpdates: moduleUpdateConfig.autoEnableUpdates !== 'false',
                autoInstallLatest: moduleUpdateConfig.autoInstallLatest !== 'false',
                installAllMissingModules: moduleUpdateConfig.installAllMissingModules !== 'false',
                localFirst: moduleUpdateConfig.localFirst !== 'false',
                notifyClients: moduleUpdateConfig.notifyClients !== 'false',
                preserveConfig: moduleUpdateConfig.preserveConfig !== 'false',
                requireSignature: moduleUpdateConfig.requireSignature !== 'false',
                requireChecksum: moduleUpdateConfig.requireChecksum !== 'false',
                installStrategy: moduleUpdateConfig.installStrategy || 'platform-native',
                feedUrls: uniqueList([
                    moduleUpdateConfig.localFeedUrl,
                    `${masterApiUrl}/api/modules/updates`,
                    `${secondaryApiUrl}/api/modules/updates`,
                    `${masterCommunityApiUrl}/api/modules/updates`,
                    ...(Array.isArray(moduleUpdateConfig.feedUrls) ? moduleUpdateConfig.feedUrls : [])
                ])
            }
        };
        const labelToken = sanitizeFileToken(targetLabel || extractHostname(targetServerUrl) || 'server');
        const zipName = `voicelink-deploy-${labelToken}-${bundleId}.zip`;
        const bundleRoot = ensureDir(path.join(this.packageDir, bundleId));
        const payloadRoot = path.join(bundleRoot, 'voicelink-deploy');
        ensureDir(payloadRoot);

        const manifest = {
            id: bundleId,
            createdAt: new Date().toISOString(),
            targetLabel,
            targetServerUrl,
            ownerEmail,
            preset,
            linkedToMain: options.linkedToMain !== false,
            deploymentLink,
            trustedServers: Array.isArray(options.trustedServers) ? options.trustedServers : [],
            supportedTargets: this.getSupportedTargets().targets || [],
            databaseManagers: this.getDatabaseManagerCapabilities(),
            releaseArtifacts: this.getReleaseArtifacts()
        };

        const deployConfigPayload = {
            preset,
            ownerEmail,
            targetLabel,
            targetServerUrl,
            bundleName: zipName,
            linkedToMain: options.linkedToMain !== false,
            trustedServers: Array.isArray(options.trustedServers) ? options.trustedServers : [],
            sanitize: options.sanitize !== false,
            deploymentLink,
            extraConfig,
            databaseManagers: this.getDatabaseManagerCapabilities(),
            releaseArtifacts: manifest.releaseArtifacts,
            generatedAt: manifest.createdAt
        };

        writeJson(path.join(payloadRoot, 'manifest.json'), manifest);
        writeJson(path.join(payloadRoot, 'deploy-config.json'), deployConfigPayload);
        writeJson(path.join(payloadRoot, 'deployment-link.json'), deploymentLink);
        writeJson(path.join(payloadRoot, 'supported-targets.json'), this.getSupportedTargets());
        writeJson(path.join(payloadRoot, 'release-artifacts.json'), manifest.releaseArtifacts);

        const pluginSource = path.join(this.appRoot, 'wordpress');
        if (fs.existsSync(pluginSource)) {
            copyRecursive(pluginSource, path.join(payloadRoot, 'wordpress'));
        }

        const docsSource = path.join(this.appRoot, 'docs');
        if (fs.existsSync(docsSource)) {
            copyRecursive(docsSource, path.join(payloadRoot, 'docs'));
        }

        const composrSource = path.join(this.appRoot, 'composr');
        if (fs.existsSync(composrSource)) {
            copyRecursive(composrSource, path.join(payloadRoot, 'composr'));
        }

        const whmcsSource = path.join(this.appRoot, 'whmcs');
        if (fs.existsSync(whmcsSource)) {
            copyRecursive(whmcsSource, path.join(payloadRoot, 'whmcs'));
        }

        const cpanelSource = path.join(this.appRoot, 'cpanel');
        if (fs.existsSync(cpanelSource)) {
            copyRecursive(cpanelSource, path.join(payloadRoot, 'cpanel'));
        }

        const installatronSource = path.join(this.appRoot, 'installatron');
        if (fs.existsSync(installatronSource)) {
            copyRecursive(installatronSource, path.join(payloadRoot, 'installatron'));
        }

        const zipPath = path.join(this.packageDir, zipName);
        await execFileAsync('zip', ['-r', zipPath, 'voicelink-deploy'], { cwd: bundleRoot });

        return {
            bundleId,
            zipName,
            zipPath,
            manifest,
            deployConfig: deployConfigPayload
        };
    }

    async uploadBundle(zipPath, target = {}) {
        const transport = String(target.transport || '').trim().toLowerCase();
        if (!fs.existsSync(zipPath)) {
            throw new Error('Deployment bundle file not found.');
        }

        if (transport === 'sftp') {
            const layout = buildDeploymentLayout({ target });
            const remotePath = target.remotePath || layout.installRoot || '.';
            const args = [];
            const mkdirArgs = [];
            if (target.port) {
                args.push('-P', String(target.port));
                mkdirArgs.push('-p', String(target.port));
            }
            if (target.insecure === true) {
                args.push('-o', 'StrictHostKeyChecking=no');
                mkdirArgs.push('-o', 'StrictHostKeyChecking=no');
            }
            await execFileAsync('ssh', [...mkdirArgs, `${target.username}@${target.host}`, `mkdir -p ${JSON.stringify(remotePath)}`]);
            const remoteZipPath = path.posix.join(remotePath, path.basename(zipPath));
            const remote = `${target.username}@${target.host}:${remoteZipPath}`;
            args.push(zipPath, remote);
            await execFileAsync('scp', args);
            return {
                success: true,
                transport,
                remoteUrl: remote
            };
        }

        if (transport === 'smb') {
            const destinationDir = target.remotePath;
            ensureDir(destinationDir);
            const destination = path.join(destinationDir, path.basename(zipPath));
            fs.copyFileSync(zipPath, destination);
            return {
                success: true,
                transport,
                remoteUrl: destination
            };
        }

        if (transport === 'http' || transport === 'https') {
            const uploadUrl = target.uploadUrl;
            const fileBuffer = fs.readFileSync(zipPath);
            const response = await createRequestPromise(uploadUrl, {
                method: String(target.method || 'PUT').toUpperCase(),
                headers: {
                    'Content-Type': 'application/zip',
                    'Content-Length': String(fileBuffer.length),
                    ...(target.sharedSecret ? { 'X-VoiceLink-Deploy-Secret': target.sharedSecret } : {})
                }
            }, fileBuffer);

            if (response.statusCode < 200 || response.statusCode > 299) {
                throw new Error(`Remote upload failed (${response.statusCode}).`);
            }

            return {
                success: true,
                transport,
                remoteUrl: uploadUrl
            };
        }

        throw new Error(`Unsupported deployment transport: ${transport}`);
    }

    async bootstrapRemoteInstall(target = {}, deployPayload = {}) {
        if (target.apiBaseUrl) {
            const url = `${String(target.apiBaseUrl).replace(/\/+$/, '')}/api/deployment/bootstrap`;
            const body = JSON.stringify({
                deployConfig: deployPayload,
                target
            });
            try {
                const response = await createRequestPromise(url, {
                    method: 'POST',
                    headers: {
                        'Content-Type': 'application/json',
                        'Content-Length': String(Buffer.byteLength(body)),
                        ...(target.apiToken ? { Authorization: `Bearer ${target.apiToken}` } : {}),
                        ...(target.sharedSecret ? { 'X-VoiceLink-Deploy-Secret': target.sharedSecret } : {})
                    }
                }, body);
                return { success: response.statusCode >= 200 && response.statusCode < 300 };
            } catch (_) {
                return { success: false };
            }
        }

        if (String(target.transport || '').toLowerCase() === 'sftp' && target.host && target.username) {
            const layout = buildDeploymentLayout({ target, deployPayload, serverConfig: deployPayload?.extraConfig?.server || {}, ownerConfig: deployPayload?.extraConfig?.owner || {} });
            const remotePath = target.remotePath || layout.installRoot || '.';
            const args = [];
            if (target.port) {
                args.push('-p', String(target.port));
            }
            if (target.insecure === true) {
                args.push('-o', 'StrictHostKeyChecking=no');
            }
            const remoteDeployConfig = Buffer.from(JSON.stringify(deployPayload)).toString('base64');
            const remoteBundleName = sanitizeFileToken(deployPayload.bundleName || '', 'voicelink-deploy.zip');
            const remoteBundlePath = path.posix.join(remotePath, remoteBundleName);
            const backupRoot = path.posix.join(remotePath, 'server-backup');
            const backupStamp = new Date().toISOString().replace(/[:.]/g, '-');
            const backupArchive = path.posix.join(backupRoot, `voicelink-backup-${backupStamp}.tar.gz`);
            const tempExtractRoot = path.posix.join(remotePath, '.deploy-extract');
            const siteType = String(deployPayload?.extraConfig?.server?.siteType || '').trim().toLowerCase();
            const siteRoot = String(target.siteRoot || deployPayload?.extraConfig?.server?.siteRoot || remotePath).trim() || remotePath;
            const remoteUser = String(target.username || '').trim() || 'voicelink';
            const remoteHome = path.posix.join('/home', remoteUser);
            const schedulerReportPath = path.posix.join(remotePath, 'site-integration-report.json');
            const databaseReportPath = path.posix.join(remotePath, 'database-integration-report.json');
            const modulePolicyPath = path.posix.join(remotePath, 'module-update-policy.json');
            const pm2ReportPath = path.posix.join(remotePath, 'pm2-deployment-report.json');
            const modulePolicyPayload = Buffer.from(JSON.stringify(deployPayload?.deploymentLink?.moduleUpdatePolicy || {}, null, 2)).toString('base64');
            const pm2Port = String(layout.appPort || deployPayload?.extraConfig?.server?.appPort || deployPayload?.extraConfig?.server?.port || '').trim();
            const pm2ProcessName = layout.processName;
            const pm2ServiceId = layout.serviceId;
            const pm2DisplayName = layout.displayName;
            const wordpressPluginRoot = path.posix.join(siteRoot, 'wp-content', 'plugins', 'voicelink-wordpress');
            const composrBridgeRoot = path.posix.join(siteRoot, 'sources_custom', 'voicelink');
            const composrPageRoot = path.posix.join(siteRoot, 'pages', 'comcode_custom', 'EN');
            const whmcsAddonRoot = path.posix.join(siteRoot, 'modules', 'addons', 'voicelink-whmcs');
            const whmcsHooksRoot = path.posix.join(whmcsAddonRoot, 'hooks');
            const whmcsTemplatesRoot = path.posix.join(siteRoot, 'templates', 'voicelink');
            const whmcsTempRoot = path.posix.join(remoteHome, 'tmp', 'whmcs');
            const whmcsCacheRoot = path.posix.join(whmcsTempRoot, 'cache');
            const whmcsCompiledTemplatesRoot = path.posix.join(whmcsTempRoot, 'templates_c');
            const whmcsAttachmentsRoot = path.posix.join(remoteHome, 'attachments', 'voicelink');
            const whmcsDownloadsRoot = path.posix.join(remoteHome, 'downloads', 'voicelink');
            const cpanelBridgeRoot = path.posix.join(remotePath, 'cpanel');
            const cpanelFileShareRoot = path.posix.join(siteRoot, 'public_html', 'shared', 'voicelink');
            const installatronAppRoot = path.posix.join(siteRoot, 'installatron', 'voicelink');
            const installatronWellKnownRoot = path.posix.join(siteRoot, '.well-known');
            const reportPayload = Buffer.from(JSON.stringify({
                siteType,
                siteRoot,
                schedulerHints: {
                    preferWordPressCron: siteType === 'wordpress',
                    preferSystemCron: true,
                    schedulerBridge: siteType === 'wordpress'
                        ? 'wordpress+system'
                        : (siteType === 'composr'
                            ? 'composr+system'
                            : (siteType === 'whmcs'
                                ? 'whmcs+system'
                                : (siteType === 'cpanel'
                                    ? 'cpanel+system'
                                    : (siteType === 'installatron'
                                        ? 'installatron+system'
                                        : 'system'))))
                },
                firewallHints: {
                    detectWordfence: siteType === 'wordpress',
                    detectWhmcsAdminProtection: siteType === 'whmcs',
                    detectCpanelAccountPolicies: siteType === 'cpanel' || siteType === 'installatron'
                },
                generatedAt: new Date().toISOString()
            })).toString('base64');
            const databasePayload = Buffer.from(JSON.stringify({
                availableManagers: this.getDatabaseManagerCapabilities(),
                requestedDatabaseHooks: deployPayload?.extraConfig?.server?.databaseHooks || {},
                siteType,
                siteRoot,
                generatedAt: new Date().toISOString()
            })).toString('base64');
            const wordpressInstallCommands = [
                `if [ -d ${shellQuote(path.posix.join(tempExtractRoot, 'voicelink-deploy', 'wordpress', 'voicelink-wordpress'))} ]; then mkdir -p ${shellQuote(wordpressPluginRoot)}; cp -R ${shellQuote(path.posix.join(tempExtractRoot, 'voicelink-deploy', 'wordpress', 'voicelink-wordpress'))}/. ${shellQuote(wordpressPluginRoot)}/; fi`,
                `WORDPRESS_PLUGIN_STATUS=not-installed`,
                `WORDPRESS_CRON_MODE=unknown`,
                `WORDFENCE_STATUS=not-detected`,
                `if [ -x "$(command -v wp)" ]; then if wp plugin is-installed voicelink-wordpress --path=${shellQuote(siteRoot)} >/dev/null 2>&1; then wp plugin activate voicelink-wordpress --path=${shellQuote(siteRoot)} >/dev/null 2>&1 || true; WORDPRESS_PLUGIN_STATUS=active; else wp plugin activate voicelink-wordpress --path=${shellQuote(siteRoot)} >/dev/null 2>&1 || true; if wp plugin is-installed voicelink-wordpress --path=${shellQuote(siteRoot)} >/dev/null 2>&1; then WORDPRESS_PLUGIN_STATUS=active; fi; fi; fi`,
                `if [ -f ${shellQuote(path.posix.join(siteRoot, 'wp-content', 'plugins', 'wordfence', 'wordfence.php'))} ]; then WORDFENCE_STATUS=detected; fi`,
                `if [ -f ${shellQuote(path.posix.join(siteRoot, 'wp-config.php'))} ] && grep -q "DISABLE_WP_CRON" ${shellQuote(path.posix.join(siteRoot, 'wp-config.php'))}; then WORDPRESS_CRON_MODE=system; else WORDPRESS_CRON_MODE=wordpress; fi`,
                `printf %s ${shellQuote(reportPayload)} | base64 --decode > ${shellQuote(schedulerReportPath)}`,
                `printf %s ${shellQuote(databasePayload)} | base64 --decode > ${shellQuote(databaseReportPath)}`,
                `if [ -f ${shellQuote(path.posix.join(siteRoot, 'wp-config.php'))} ]; then python3 - <<'PY'\nimport json, pathlib, re\npath = pathlib.Path(${JSON.stringify(databaseReportPath)})\nconfig = pathlib.Path(${JSON.stringify(path.posix.join(siteRoot, 'wp-config.php'))}).read_text(errors='ignore')\ndata = json.loads(path.read_text())\nfor key, pattern in {'db_name': r\"DB_NAME'\\s*,\\s*'([^']+)'\", 'db_user': r\"DB_USER'\\s*,\\s*'([^']+)'\", 'db_host': r\"DB_HOST'\\s*,\\s*'([^']+)'\"}.items():\n    match = re.search(pattern, config)\n    if match:\n        data.setdefault('wordpress', {})[key] = match.group(1)\ndata.setdefault('wordpress', {})['wpConfigDetected'] = True\npath.write_text(json.dumps(data, indent=2))\nPY\nfi`,
                `python3 - <<'PY'\nimport json, pathlib\npath = pathlib.Path(${JSON.stringify(schedulerReportPath)})\ndata = json.loads(path.read_text())\ndata['wordpress'] = {'pluginStatus': pathlib.Path(${JSON.stringify(wordpressPluginRoot)}).exists(), 'wordfenceDetected': pathlib.Path(${JSON.stringify(path.posix.join(siteRoot, 'wp-content', 'plugins', 'wordfence', 'wordfence.php'))}).exists(), 'siteRoot': ${JSON.stringify(siteRoot)}}\npath.write_text(json.dumps(data, indent=2))\nPY`
            ].join(' && ');
            const composrInstallCommands = [
                `if [ -f ${shellQuote(path.posix.join(tempExtractRoot, 'voicelink-deploy', 'composr', 'voicelink-composr', 'bridge.php'))} ]; then mkdir -p ${shellQuote(composrBridgeRoot)}; cp ${shellQuote(path.posix.join(tempExtractRoot, 'voicelink-deploy', 'composr', 'voicelink-composr', 'bridge.php'))} ${shellQuote(path.posix.join(composrBridgeRoot, 'bridge.php'))}; fi`,
                `mkdir -p ${shellQuote(composrPageRoot)}`,
                `if [ ! -f ${shellQuote(path.posix.join(composrPageRoot, 'voicelink.txt'))} ]; then cat > ${shellQuote(path.posix.join(composrPageRoot, 'voicelink.txt'))} <<'EOF'\n[h1]VoiceLink[/h1]\n\nVoiceLink is linked into this Composr site. Use the desktop app, linked server tools, or the configured web entry points to access rooms, downloads, help, and server setup.\nEOF\nfi`,
                `printf %s ${shellQuote(reportPayload)} | base64 --decode > ${shellQuote(schedulerReportPath)}`,
                `printf %s ${shellQuote(databasePayload)} | base64 --decode > ${shellQuote(databaseReportPath)}`
            ].join(' && ');
            const whmcsInstallCommands = [
                `if [ -d ${shellQuote(path.posix.join(tempExtractRoot, 'voicelink-deploy', 'whmcs', 'voicelink-whmcs'))} ]; then mkdir -p ${shellQuote(whmcsAddonRoot)}; cp -R ${shellQuote(path.posix.join(tempExtractRoot, 'voicelink-deploy', 'whmcs', 'voicelink-whmcs'))}/. ${shellQuote(whmcsAddonRoot)}/; fi`,
                `mkdir -p ${shellQuote(whmcsHooksRoot)} ${shellQuote(whmcsTemplatesRoot)}`,
                `mkdir -p ${shellQuote(whmcsTempRoot)} ${shellQuote(whmcsCacheRoot)} ${shellQuote(whmcsCompiledTemplatesRoot)} ${shellQuote(whmcsAttachmentsRoot)} ${shellQuote(whmcsDownloadsRoot)} || true`,
                `printf %s ${shellQuote(reportPayload)} | base64 --decode > ${shellQuote(schedulerReportPath)}`,
                `printf %s ${shellQuote(databasePayload)} | base64 --decode > ${shellQuote(databaseReportPath)}`,
                `if [ -f ${shellQuote(path.posix.join(siteRoot, 'configuration.php'))} ]; then python3 - <<'PY'\nimport json, pathlib, re\npath = pathlib.Path(${JSON.stringify(databaseReportPath)})\nconfig = pathlib.Path(${JSON.stringify(path.posix.join(siteRoot, 'configuration.php'))}).read_text(errors='ignore')\ndata = json.loads(path.read_text())\nfor key, pattern in {'db_name': r\"\\$db_name\\s*=\\s*'([^']+)'\", 'db_username': r\"\\$db_username\\s*=\\s*'([^']+)'\", 'db_host': r\"\\$db_host\\s*=\\s*'([^']+)'\", 'license': r\"\\$license\\s*=\\s*'([^']+)'\"}.items():\n    match = re.search(pattern, config)\n    if match:\n        data.setdefault('whmcs', {})[key] = match.group(1)\ndata.setdefault('whmcs', {})['configurationDetected'] = True\npath.write_text(json.dumps(data, indent=2))\nPY\nfi`,
                `python3 - <<'PY'\nimport json, pathlib\npath = pathlib.Path(${JSON.stringify(schedulerReportPath)})\ndata = json.loads(path.read_text())\ndata['whmcs'] = {\n  'addonInstalled': pathlib.Path(${JSON.stringify(whmcsAddonRoot)}).exists(),\n  'siteRoot': ${JSON.stringify(siteRoot)},\n  'adminDirDetected': pathlib.Path(${JSON.stringify(path.posix.join(siteRoot, 'admin'))}).exists(),\n  'ownerAccount': ${JSON.stringify(remoteUser)},\n  'ownerHome': ${JSON.stringify(remoteHome)},\n  'tempRoot': ${JSON.stringify(whmcsTempRoot)},\n  'cacheRoot': ${JSON.stringify(whmcsCacheRoot)},\n  'compiledTemplatesRoot': ${JSON.stringify(whmcsCompiledTemplatesRoot)},\n  'attachmentsRoot': ${JSON.stringify(whmcsAttachmentsRoot)},\n  'downloadsRoot': ${JSON.stringify(whmcsDownloadsRoot)}\n}\npath.write_text(json.dumps(data, indent=2))\nPY`
            ].join(' && ');
            const cpanelInstallCommands = [
                `if [ -f ${shellQuote(path.posix.join(tempExtractRoot, 'voicelink-deploy', 'cpanel', 'voicelink-cpanel', 'bridge.php'))} ]; then mkdir -p ${shellQuote(cpanelBridgeRoot)}; cp -R ${shellQuote(path.posix.join(tempExtractRoot, 'voicelink-deploy', 'cpanel'))}/. ${shellQuote(cpanelBridgeRoot)}/; fi`,
                `mkdir -p ${shellQuote(cpanelFileShareRoot)}`,
                `printf %s ${shellQuote(reportPayload)} | base64 --decode > ${shellQuote(schedulerReportPath)}`,
                `printf %s ${shellQuote(databasePayload)} | base64 --decode > ${shellQuote(databaseReportPath)}`,
                `python3 - <<'PY'\nimport json, pathlib\nsite_root = pathlib.Path(${JSON.stringify(siteRoot)})\npath = pathlib.Path(${JSON.stringify(databaseReportPath)})\ndata = json.loads(path.read_text())\ndata['cpanel'] = {\n  'homePath': str(site_root),\n  'publicHtmlDetected': (site_root / 'public_html').exists(),\n  'cpanelMetadataDetected': (site_root / '.cpanel').exists(),\n  'fileShareRoot': ${JSON.stringify(cpanelFileShareRoot)}\n}\npath.write_text(json.dumps(data, indent=2))\nPY`,
                `python3 - <<'PY'\nimport json, pathlib\npath = pathlib.Path(${JSON.stringify(schedulerReportPath)})\ndata = json.loads(path.read_text())\ndata['cpanel'] = {'fileManagerReady': pathlib.Path(${JSON.stringify(cpanelFileShareRoot)}).exists(), 'siteRoot': ${JSON.stringify(siteRoot)}}\npath.write_text(json.dumps(data, indent=2))\nPY`
            ].join(' && ');
            const installatronInstallCommands = [
                `if [ -d ${shellQuote(path.posix.join(tempExtractRoot, 'voicelink-deploy', 'installatron', 'voicelink'))} ]; then mkdir -p ${shellQuote(installatronAppRoot)}; cp -R ${shellQuote(path.posix.join(tempExtractRoot, 'voicelink-deploy', 'installatron', 'voicelink'))}/. ${shellQuote(installatronAppRoot)}/; fi`,
                `mkdir -p ${shellQuote(installatronWellKnownRoot)} ${shellQuote(path.posix.join(siteRoot, 'storage'))}`,
                `if [ ! -f ${shellQuote(path.posix.join(installatronWellKnownRoot, 'acme-challenge'))} ] && [ ! -f ${shellQuote(path.posix.join(installatronWellKnownRoot, 'voicelink.json'))} ]; then printf '%s\\n' '{"installId":"pending","domain":"pending","installMode":"installatron","licenseStatus":"pending","publishedAt":"'$(date -u +"%Y-%m-%dT%H:%M:%SZ")'"}' > ${shellQuote(path.posix.join(installatronWellKnownRoot, 'voicelink.json'))}; fi`,
                `printf %s ${shellQuote(reportPayload)} | base64 --decode > ${shellQuote(schedulerReportPath)}`,
                `printf %s ${shellQuote(databasePayload)} | base64 --decode > ${shellQuote(databaseReportPath)}`,
                `python3 - <<'PY'\nimport json, pathlib, xml.etree.ElementTree as ET\nsite_root = pathlib.Path(${JSON.stringify(siteRoot)})\napp_root = pathlib.Path(${JSON.stringify(installatronAppRoot)})\npath = pathlib.Path(${JSON.stringify(schedulerReportPath)})\ndata = json.loads(path.read_text())\ninstall_xml = app_root / 'install.xml'\ninstallatron = {\n  'appRoot': str(app_root),\n  'installXmlDetected': install_xml.exists(),\n  'wellKnownManifestDetected': (site_root / '.well-known' / 'voicelink.json').exists(),\n  'siteRoot': str(site_root)\n}\nif install_xml.exists():\n    try:\n        root = ET.parse(install_xml).getroot()\n        installatron['appId'] = (root.findtext('id') or '').strip() or None\n        installatron['appVersion'] = (root.findtext('version') or '').strip() or None\n        installatron['appName'] = (root.findtext('name') or '').strip() or None\n    except Exception:\n        installatron['parseError'] = True\n\ndata['installatron'] = installatron\npath.write_text(json.dumps(data, indent=2))\nPY`
            ].join(' && ');
            const command = [
                `mkdir -p ${JSON.stringify(remotePath)}`,
                `mkdir -p ${JSON.stringify(backupRoot)}`,
                `if [ -d ${JSON.stringify(remotePath)} ] && [ "$(find ${JSON.stringify(remotePath)} -mindepth 1 -maxdepth 1 ! -name server-backup ! -name ${JSON.stringify(path.basename(remoteBundlePath))} | wc -l | tr -d ' ')" != "0" ]; then tar -czf ${JSON.stringify(backupArchive)} --exclude=server-backup --exclude=${JSON.stringify(path.basename(remoteBundlePath))} -C ${JSON.stringify(remotePath)} .; fi`,
                `rm -rf ${JSON.stringify(tempExtractRoot)}`,
                `mkdir -p ${JSON.stringify(tempExtractRoot)}`,
                `unzip -oq ${JSON.stringify(remoteBundlePath)} -d ${JSON.stringify(tempExtractRoot)}`,
                `find ${JSON.stringify(remotePath)} -mindepth 1 -maxdepth 1 ! -name server-backup ! -name ${JSON.stringify(path.basename(remoteBundlePath))} -exec rm -rf {} +`,
                `if [ -d ${JSON.stringify(path.posix.join(tempExtractRoot, 'voicelink-deploy'))} ]; then cp -R ${JSON.stringify(path.posix.join(tempExtractRoot, 'voicelink-deploy'))}/. ${JSON.stringify(remotePath)}/; fi`,
                siteType === 'wordpress' ? wordpressInstallCommands : 'true',
                siteType === 'composr' ? composrInstallCommands : 'true',
                siteType === 'whmcs' ? whmcsInstallCommands : 'true',
                siteType === 'cpanel' ? cpanelInstallCommands : 'true',
                siteType === 'installatron' ? installatronInstallCommands : 'true',
                `printf %s ${shellQuote(modulePolicyPayload)} | base64 --decode > ${shellQuote(modulePolicyPath)}`,
                layout.pm2.enabled
                    ? [
                        `PM2_STATUS=not-installed`,
                        `if command -v pm2 >/dev/null 2>&1 && [ -f ${shellQuote(path.posix.join(remotePath, 'server', 'routes', 'local-server.js'))} ]; then cd ${shellQuote(remotePath)}; pm2 delete ${shellQuote(pm2ProcessName)} >/dev/null 2>&1 || true; ${pm2Port ? `PORT=${shellQuote(pm2Port)} ` : ''}NODE_ENV=production VOICELINK_SERVICE_ID=${shellQuote(pm2ServiceId)} VOICELINK_PROCESS_NAME=${shellQuote(pm2ProcessName)} VOICELINK_SERVER_NAME=${shellQuote(pm2DisplayName)} pm2 start server/routes/local-server.js --name ${shellQuote(pm2ProcessName)} >/dev/null 2>&1 && pm2 save >/dev/null 2>&1 && PM2_STATUS=created; fi`,
                        `printf '{"enabled":true,"status":"%s","processName":${JSON.stringify(JSON.stringify(pm2ProcessName))},"serviceId":${JSON.stringify(JSON.stringify(pm2ServiceId))},"appPort":${JSON.stringify(JSON.stringify(pm2Port || null))},"installRoot":${JSON.stringify(JSON.stringify(remotePath))}}\\n' "$PM2_STATUS" > ${shellQuote(pm2ReportPath)}`
                    ].join(' && ')
                    : 'true',
                `rm -rf ${JSON.stringify(tempExtractRoot)}`,
                `rm -f ${JSON.stringify(remoteBundlePath)}`,
                `printf %s ${JSON.stringify(remoteDeployConfig)} | base64 --decode > ${JSON.stringify(path.posix.join(remotePath, 'deploy-config.json'))}`
            ].join(' && ');
            try {
                await execFileAsync('ssh', [...args, `${target.username}@${target.host}`, command]);
                return {
                    success: true,
                    backupArchive
                };
            } catch (_) {
                return { success: false };
            }
        }

        return { success: false };
    }

    async triggerRemoteRestart(target = {}) {
        if (target.restartUrl) {
            try {
                const response = await createRequestPromise(target.restartUrl, {
                    method: String(target.restartMethod || 'POST').toUpperCase(),
                    headers: target.sharedSecret ? { 'X-VoiceLink-Deploy-Secret': target.sharedSecret } : {}
                });
                return {
                    success: response.statusCode >= 200 && response.statusCode < 300
                };
            } catch (error) {
                return { success: false, error: error.message };
            }
        }

        if (String(target.transport || '').toLowerCase() === 'sftp' && target.host && target.username) {
            return {
                skipped: true,
                reason: 'Remote restart command is not configured for this target.'
            };
        }

        return {
            skipped: true,
            reason: 'No restart hook was configured.'
        };
    }

    async emailDeploymentDetails({ recipient, subject, bundleName, remoteUrl, apiBaseUrl }) {
        if (!recipient) {
            throw new Error('Recipient email is required.');
        }

        const normalizedSubject = subject || 'VoiceLink Deployment Details';
        const text = [
            'Your VoiceLink deployment bundle is ready.',
            bundleName ? `Bundle: ${bundleName}` : null,
            remoteUrl ? `Upload target: ${remoteUrl}` : null,
            apiBaseUrl ? `API base URL: ${apiBaseUrl}` : null
        ].filter(Boolean).join(os.EOL);

        if (this.mailer && this.emailFrom) {
            await this.mailer.sendMail({
                from: this.emailFrom,
                to: recipient,
                subject: normalizedSubject,
                text
            });
            return { success: true };
        }

        const outboxDir = ensureDir(path.join(this.dataDir, 'outbox'));
        const messagePath = path.join(outboxDir, `${Date.now()}-${sanitizeFileToken(recipient, 'owner')}.txt`);
        fs.writeFileSync(messagePath, `To: ${recipient}${os.EOL}Subject: ${normalizedSubject}${os.EOL}${os.EOL}${text}${os.EOL}`, 'utf8');
        return { success: true };
    }

    getDatabaseManagerCapabilities() {
        const configured = this.deployConfig?.get?.('database') || {};
        const managers = [];
        if (configured.sqlite?.enabled !== false) {
            managers.push({ id: 'sqlite', label: 'SQLite', createNew: true, migrateExisting: true, provider: 'native' });
        }
        if (configured.mariadb || configured.mysql) {
            managers.push({
                id: 'mariadb',
                label: 'MariaDB/MySQL',
                createNew: true,
                migrateExisting: true,
                provider: 'sql',
                hooks: Object.entries(configured.existingManagers || {})
                    .filter(([, value]) => value?.enabled)
                    .map(([id, value]) => ({ id, ...value }))
            });
        }
        if (configured.postgres) {
            managers.push({ id: 'postgres', label: 'PostgreSQL', createNew: true, migrateExisting: true, provider: 'sql' });
        }
        if (managers.length === 0) {
            managers.push({ id: 'sqlite', label: 'SQLite', createNew: true, migrateExisting: false, provider: 'native' });
        }
        return managers;
    }
}

module.exports = { DeploymentManagerModule };
