/**
 * VoiceLink Security & Encryption Manager
 * End-to-end encryption, 2FA, and comprehensive security management
 */

class SecurityEncryptionManager {
    constructor(keychainAuthManager) {
        this.keychainAuthManager = keychainAuthManager;

        // Encryption configuration
        this.encryptionConfig = {
            mode: 'end-to-end', // 'end-to-end', 'server-side', 'hybrid', 'disabled'
            algorithm: 'AES-GCM',
            keySize: 256,
            audioBitrate: 'lossless', // 'lossless', 'high', 'medium', 'low'
            compressionLevel: 'none' // 'none', 'low', 'medium', 'high'
        };

        // 2FA configuration
        this.twoFactorConfig = {
            enabled: false,
            methods: new Set(), // 'totp', 'sms', 'email', 'push', 'hardware_key', 'biometric'
            backupCodes: [],
            gracePeriod: 300000 // 5 minutes
        };

        // Security policies
        this.securityPolicies = {
            requireEncryption: true,
            require2FA: false,
            allowGuestAccess: true,
            sessionTimeout: 3600000, // 1 hour
            maxFailedAttempts: 5,
            lockoutDuration: 900000, // 15 minutes
            auditLogging: true
        };

        // Encryption keys and sessions
        this.encryptionKeys = new Map(); // userId -> keyPair
        this.sessionKeys = new Map(); // sessionId -> symmetricKey
        this.encryptedSessions = new Map(); // sessionId -> sessionData

        // 2FA tokens and states
        this.twoFactorTokens = new Map(); // userId -> 2FA data
        this.pendingAuth = new Map(); // sessionId -> pending auth data
        this.backupCodes = new Map(); // userId -> backup codes

        // Security audit
        this.auditLog = [];
        this.securityEvents = new Map(); // eventType -> handlers

        this.init();
    }

    async init() {
        console.log('Initializing Security & Encryption Manager...');

        // Initialize encryption subsystem
        await this.initializeEncryption();

        // Initialize 2FA subsystem
        await this.initialize2FA();

        // Setup security monitoring
        this.setupSecurityMonitoring();

        // Load security policies
        await this.loadSecurityPolicies();

        // Initialize audit logging
        this.initializeAuditLogging();

        console.log('Security & Encryption Manager initialized');
    }

    // Encryption Management

    async initializeEncryption() {
        // Generate master encryption key if not exists
        await this.generateMasterKey();

        // Initialize crypto modules
        this.cryptoModules = {
            symmetric: new SymmetricCrypto(),
            asymmetric: new AsymmetricCrypto(),
            hash: new HashCrypto(),
            stream: new StreamCrypto()
        };

        console.log(`Encryption initialized: ${this.encryptionConfig.algorithm}-${this.encryptionConfig.keySize}`);
    }

    async generateMasterKey() {
        try {
            // Check if master key exists
            let masterKey = await this.keychainAuthManager.keychainProvider.retrieveCredential('voicelink_master_key');

            if (!masterKey) {
                // Generate new master key
                const key = await crypto.subtle.generateKey(
                    {
                        name: 'AES-GCM',
                        length: this.encryptionConfig.keySize
                    },
                    true,
                    ['encrypt', 'decrypt']
                );

                const exportedKey = await crypto.subtle.exportKey('raw', key);
                masterKey = {
                    key: Array.from(new Uint8Array(exportedKey)),
                    created: Date.now(),
                    algorithm: this.encryptionConfig.algorithm
                };

                // Store in secure keychain
                await this.keychainAuthManager.keychainProvider.storeCredential(
                    'voicelink_master_key',
                    masterKey,
                    'local_secure'
                );

                console.log('Generated new master encryption key');
            }

            this.masterKey = masterKey;

        } catch (error) {
            console.error('Failed to generate master key:', error);
            throw new Error('Encryption initialization failed');
        }
    }

    async generateUserKeyPair(userId) {
        try {
            // Generate RSA key pair for user
            const keyPair = await crypto.subtle.generateKey(
                {
                    name: 'RSA-OAEP',
                    modulusLength: 4096,
                    publicExponent: new Uint8Array([1, 0, 1]),
                    hash: 'SHA-256'
                },
                true,
                ['encrypt', 'decrypt']
            );

            // Export keys
            const publicKey = await crypto.subtle.exportKey('spki', keyPair.publicKey);
            const privateKey = await crypto.subtle.exportKey('pkcs8', keyPair.privateKey);

            const userKeys = {
                publicKey: Array.from(new Uint8Array(publicKey)),
                privateKey: Array.from(new Uint8Array(privateKey)),
                created: Date.now(),
                userId
            };

            // Store user keys
            this.encryptionKeys.set(userId, userKeys);

            // Store private key in secure keychain
            await this.keychainAuthManager.keychainProvider.storeCredential(
                `voicelink_user_key_${userId}`,
                { privateKey: userKeys.privateKey },
                'local_secure'
            );

            console.log(`Generated encryption key pair for user: ${userId}`);
            return userKeys;

        } catch (error) {
            console.error('Failed to generate user key pair:', error);
            throw error;
        }
    }

    async encryptAudioStream(audioData, recipientUserIds, options = {}) {
        if (this.encryptionConfig.mode === 'disabled') {
            return audioData; // No encryption
        }

        try {
            const encryptionMetadata = {
                algorithm: this.encryptionConfig.algorithm,
                keySize: this.encryptionConfig.keySize,
                timestamp: Date.now(),
                recipients: recipientUserIds
            };

            if (this.encryptionConfig.mode === 'end-to-end') {
                return await this.encryptEndToEnd(audioData, recipientUserIds, encryptionMetadata);
            } else if (this.encryptionConfig.mode === 'server-side') {
                return await this.encryptServerSide(audioData, encryptionMetadata);
            } else if (this.encryptionConfig.mode === 'hybrid') {
                return await this.encryptHybrid(audioData, recipientUserIds, encryptionMetadata);
            }

        } catch (error) {
            console.error('Audio encryption failed:', error);
            throw error;
        }
    }

    async encryptEndToEnd(audioData, recipientUserIds, metadata) {
        // Generate session key for this audio stream
        const sessionKey = await crypto.subtle.generateKey(
            { name: 'AES-GCM', length: 256 },
            true,
            ['encrypt', 'decrypt']
        );

        // Encrypt audio data with session key
        const iv = crypto.getRandomValues(new Uint8Array(12));
        const encryptedAudio = await crypto.subtle.encrypt(
            { name: 'AES-GCM', iv },
            sessionKey,
            audioData
        );

        // Encrypt session key for each recipient
        const encryptedKeys = {};
        for (const userId of recipientUserIds) {
            const userKeys = this.encryptionKeys.get(userId);
            if (userKeys) {
                const publicKey = await crypto.subtle.importKey(
                    'spki',
                    new Uint8Array(userKeys.publicKey),
                    { name: 'RSA-OAEP', hash: 'SHA-256' },
                    false,
                    ['encrypt']
                );

                const exportedSessionKey = await crypto.subtle.exportKey('raw', sessionKey);
                const encryptedSessionKey = await crypto.subtle.encrypt(
                    { name: 'RSA-OAEP' },
                    publicKey,
                    exportedSessionKey
                );

                encryptedKeys[userId] = Array.from(new Uint8Array(encryptedSessionKey));
            }
        }

        return {
            type: 'end-to-end-encrypted',
            data: Array.from(new Uint8Array(encryptedAudio)),
            iv: Array.from(iv),
            keys: encryptedKeys,
            metadata
        };
    }

    async decryptAudioStream(encryptedPacket, userId) {
        if (!encryptedPacket.type || encryptedPacket.type !== 'end-to-end-encrypted') {
            return encryptedPacket; // Not encrypted
        }

        try {
            // Get user's private key
            const userKeyData = await this.keychainAuthManager.keychainProvider.retrieveCredential(
                `voicelink_user_key_${userId}`
            );

            if (!userKeyData) {
                throw new Error('User private key not found');
            }

            // Import private key
            const privateKey = await crypto.subtle.importKey(
                'pkcs8',
                new Uint8Array(userKeyData.privateKey),
                { name: 'RSA-OAEP', hash: 'SHA-256' },
                false,
                ['decrypt']
            );

            // Decrypt session key
            const encryptedSessionKey = encryptedPacket.keys[userId];
            if (!encryptedSessionKey) {
                throw new Error('Session key not found for user');
            }

            const sessionKeyBuffer = await crypto.subtle.decrypt(
                { name: 'RSA-OAEP' },
                privateKey,
                new Uint8Array(encryptedSessionKey)
            );

            // Import session key
            const sessionKey = await crypto.subtle.importKey(
                'raw',
                sessionKeyBuffer,
                { name: 'AES-GCM' },
                false,
                ['decrypt']
            );

            // Decrypt audio data
            const decryptedAudio = await crypto.subtle.decrypt(
                { name: 'AES-GCM', iv: new Uint8Array(encryptedPacket.iv) },
                sessionKey,
                new Uint8Array(encryptedPacket.data)
            );

            return new Uint8Array(decryptedAudio);

        } catch (error) {
            console.error('Audio decryption failed:', error);
            throw error;
        }
    }

    // 2FA Management

    async initialize2FA() {
        // Load 2FA configuration
        await this.load2FAConfig();

        // Initialize TOTP generator
        this.totpGenerator = new TOTPGenerator();

        // Setup 2FA methods
        this.setupTwoFactorMethods();

        console.log('2FA system initialized');
    }

    async enable2FA(userId, method, options = {}) {
        try {
            let setupData;

            switch (method) {
                case 'totp':
                    setupData = await this.setupTOTP(userId, options);
                    break;
                case 'sms':
                    setupData = await this.setupSMS(userId, options);
                    break;
                case 'email':
                    setupData = await this.setupEmail(userId, options);
                    break;
                case 'push':
                    setupData = await this.setupPushNotification(userId, options);
                    break;
                case 'hardware_key':
                    setupData = await this.setupHardwareKey(userId, options);
                    break;
                case 'biometric':
                    setupData = await this.setupBiometric2FA(userId, options);
                    break;
                default:
                    throw new Error(`Unsupported 2FA method: ${method}`);
            }

            // Store 2FA configuration
            const twoFactorData = {
                userId,
                method,
                setupData,
                enabled: true,
                createdAt: Date.now(),
                backupCodes: this.generateBackupCodes()
            };

            this.twoFactorTokens.set(userId, twoFactorData);

            // Store in secure keychain
            await this.keychainAuthManager.keychainProvider.storeCredential(
                `voicelink_2fa_${userId}`,
                twoFactorData,
                'local_secure'
            );

            this.auditLog.push({
                type: 'security',
                action: '2fa_enabled',
                userId,
                method,
                timestamp: Date.now()
            });

            console.log(`2FA enabled for user ${userId} using ${method}`);
            return setupData;

        } catch (error) {
            console.error('Failed to enable 2FA:', error);
            throw error;
        }
    }

    async setupTOTP(userId, options) {
        // Generate TOTP secret
        const secret = this.totpGenerator.generateSecret();
        const issuer = options.issuer || 'VoiceLink';
        const accountName = options.accountName || userId;

        // Generate QR code data
        const otpUrl = `otpauth://totp/${encodeURIComponent(issuer)}:${encodeURIComponent(accountName)}?secret=${secret}&issuer=${encodeURIComponent(issuer)}`;

        return {
            secret,
            qrCode: otpUrl,
            backupCodes: this.generateBackupCodes(),
            instructions: 'Scan the QR code with your authenticator app'
        };
    }

    async setupSMS(userId, options) {
        const phoneNumber = options.phoneNumber;
        if (!phoneNumber) {
            throw new Error('Phone number required for SMS 2FA');
        }

        // In a real implementation, verify phone number
        const verificationCode = this.generateVerificationCode();

        return {
            phoneNumber,
            verificationCode,
            instructions: 'A verification code will be sent to your phone'
        };
    }

    async setupEmail(userId, options) {
        const email = options.email;
        if (!email) {
            throw new Error('Email address required for email 2FA');
        }

        const verificationCode = this.generateVerificationCode();

        return {
            email,
            verificationCode,
            instructions: 'A verification code will be sent to your email'
        };
    }

    async setupPushNotification(userId, options) {
        // Setup push notification 2FA
        const deviceToken = options.deviceToken;

        return {
            deviceToken,
            instructions: 'Push notifications will be sent to your registered device'
        };
    }

    async setupHardwareKey(userId, options) {
        // Setup hardware security key (WebAuthn)
        const challenge = crypto.getRandomValues(new Uint8Array(32));

        const credentialCreationOptions = {
            challenge,
            rp: { name: 'VoiceLink' },
            user: {
                id: new TextEncoder().encode(userId),
                name: userId,
                displayName: options.displayName || userId
            },
            pubKeyCredParams: [
                { alg: -7, type: 'public-key' }, // ES256
                { alg: -257, type: 'public-key' } // RS256
            ],
            authenticatorSelection: {
                authenticatorAttachment: 'cross-platform',
                userVerification: 'required'
            },
            timeout: 60000
        };

        return {
            credentialOptions: credentialCreationOptions,
            instructions: 'Insert and activate your hardware security key'
        };
    }

    async setupBiometric2FA(userId, options) {
        // Setup biometric 2FA using WebAuthn
        const challenge = crypto.getRandomValues(new Uint8Array(32));

        const credentialCreationOptions = {
            challenge,
            rp: { name: 'VoiceLink' },
            user: {
                id: new TextEncoder().encode(userId),
                name: userId,
                displayName: options.displayName || userId
            },
            pubKeyCredParams: [
                { alg: -7, type: 'public-key' }
            ],
            authenticatorSelection: {
                authenticatorAttachment: 'platform',
                userVerification: 'required'
            },
            timeout: 60000
        };

        return {
            credentialOptions: credentialCreationOptions,
            instructions: 'Use your biometric authentication (fingerprint, face, etc.)'
        };
    }

    async verify2FA(userId, method, token, options = {}) {
        const twoFactorData = this.twoFactorTokens.get(userId);
        if (!twoFactorData || !twoFactorData.enabled) {
            throw new Error('2FA not enabled for user');
        }

        try {
            let isValid = false;

            switch (method) {
                case 'totp':
                    isValid = this.totpGenerator.verify(token, twoFactorData.setupData.secret);
                    break;
                case 'sms':
                case 'email':
                    isValid = await this.verifyCodeToken(userId, token);
                    break;
                case 'hardware_key':
                case 'biometric':
                    isValid = await this.verifyWebAuthn(userId, token);
                    break;
                case 'backup_code':
                    isValid = this.verifyBackupCode(userId, token);
                    break;
                default:
                    throw new Error(`Unsupported 2FA verification method: ${method}`);
            }

            if (isValid) {
                this.auditLog.push({
                    type: 'security',
                    action: '2fa_verified',
                    userId,
                    method,
                    timestamp: Date.now()
                });

                return true;
            } else {
                this.auditLog.push({
                    type: 'security',
                    action: '2fa_failed',
                    userId,
                    method,
                    timestamp: Date.now()
                });

                return false;
            }

        } catch (error) {
            console.error('2FA verification failed:', error);
            throw error;
        }
    }

    generateBackupCodes() {
        const codes = [];
        for (let i = 0; i < 10; i++) {
            codes.push(Math.random().toString(36).substring(2, 10).toUpperCase());
        }
        return codes;
    }

    generateVerificationCode() {
        return Math.floor(100000 + Math.random() * 900000).toString();
    }

    verifyBackupCode(userId, code) {
        const twoFactorData = this.twoFactorTokens.get(userId);
        if (!twoFactorData) return false;

        const codeIndex = twoFactorData.backupCodes.indexOf(code);
        if (codeIndex !== -1) {
            // Remove used backup code
            twoFactorData.backupCodes.splice(codeIndex, 1);
            return true;
        }

        return false;
    }

    // Security Policy Management

    async loadSecurityPolicies() {
        try {
            const savedPolicies = await this.keychainAuthManager.keychainProvider.retrieveCredential(
                'voicelink_security_policies'
            );

            if (savedPolicies) {
                Object.assign(this.securityPolicies, savedPolicies);
            }

            console.log('Security policies loaded:', this.securityPolicies);

        } catch (error) {
            console.error('Failed to load security policies:', error);
        }
    }

    async updateSecurityPolicy(policyName, value, adminUserId) {
        if (!this.isValidSecurityPolicy(policyName)) {
            throw new Error(`Invalid security policy: ${policyName}`);
        }

        const oldValue = this.securityPolicies[policyName];
        this.securityPolicies[policyName] = value;

        // Save updated policies
        await this.keychainAuthManager.keychainProvider.storeCredential(
            'voicelink_security_policies',
            this.securityPolicies,
            'local_secure'
        );

        // Audit log
        this.auditLog.push({
            type: 'security',
            action: 'policy_updated',
            adminUserId,
            policy: policyName,
            oldValue,
            newValue: value,
            timestamp: Date.now()
        });

        console.log(`Security policy updated: ${policyName} = ${value}`);

        // Apply policy changes
        this.applySecurityPolicyChanges(policyName, value);
    }

    isValidSecurityPolicy(policyName) {
        return Object.prototype.hasOwnProperty.call(this.securityPolicies, policyName);
    }

    applySecurityPolicyChanges(policyName, value) {
        switch (policyName) {
            case 'requireEncryption':
                this.encryptionConfig.mode = value ? 'end-to-end' : 'disabled';
                break;
            case 'require2FA':
                this.twoFactorConfig.enabled = value;
                break;
            case 'sessionTimeout':
                this.setupSessionTimeout(value);
                break;
            default:
                console.log(`Applied policy change: ${policyName} = ${value}`);
        }
    }

    // Security Monitoring

    setupSecurityMonitoring() {
        // Monitor failed authentication attempts
        this.failedAttempts = new Map(); // userId -> attempt count

        // Monitor suspicious activity
        this.suspiciousActivity = new Map(); // userId -> activity log

        // Setup security event handlers
        this.setupSecurityEventHandlers();

        console.log('Security monitoring enabled');
    }

    setupSecurityEventHandlers() {
        // Authentication failure handler
        this.securityEvents.set('auth_failed', (userId, reason) => {
            this.handleAuthenticationFailure(userId, reason);
        });

        // Suspicious activity handler
        this.securityEvents.set('suspicious_activity', (userId, activity) => {
            this.handleSuspiciousActivity(userId, activity);
        });

        // Account lockout handler
        this.securityEvents.set('account_locked', (userId, reason) => {
            this.handleAccountLockout(userId, reason);
        });
    }

    handleAuthenticationFailure(userId, reason) {
        const attempts = this.failedAttempts.get(userId) || 0;
        const newAttempts = attempts + 1;

        this.failedAttempts.set(userId, newAttempts);

        if (newAttempts >= this.securityPolicies.maxFailedAttempts) {
            // Lock account
            this.lockAccount(userId, this.securityPolicies.lockoutDuration);
        }

        this.auditLog.push({
            type: 'security',
            action: 'auth_failed',
            userId,
            reason,
            attemptCount: newAttempts,
            timestamp: Date.now()
        });
    }

    handleSuspiciousActivity(userId, activity) {
        const userActivity = this.suspiciousActivity.get(userId) || [];
        userActivity.push({
            activity,
            timestamp: Date.now()
        });

        this.suspiciousActivity.set(userId, userActivity);

        // Check for patterns
        if (userActivity.length > 5) {
            this.auditLog.push({
                type: 'security',
                action: 'suspicious_activity_detected',
                userId,
                activityPattern: userActivity.slice(-5),
                timestamp: Date.now()
            });
        }
    }

    lockAccount(userId, duration) {
        const lockUntil = Date.now() + duration;

        this.lockedAccounts = this.lockedAccounts || new Map();
        this.lockedAccounts.set(userId, lockUntil);

        this.auditLog.push({
            type: 'security',
            action: 'account_locked',
            userId,
            duration,
            lockUntil,
            timestamp: Date.now()
        });

        console.log(`Account locked: ${userId} until ${new Date(lockUntil)}`);
    }

    isAccountLocked(userId) {
        if (!this.lockedAccounts) return false;

        const lockUntil = this.lockedAccounts.get(userId);
        if (lockUntil && Date.now() < lockUntil) {
            return true;
        } else if (lockUntil) {
            // Lock expired, remove from locked accounts
            this.lockedAccounts.delete(userId);
        }

        return false;
    }

    // Audit Logging

    initializeAuditLogging() {
        // Setup audit log rotation
        setInterval(() => {
            this.rotateAuditLog();
        }, 24 * 60 * 60 * 1000); // Daily rotation

        console.log('Audit logging initialized');
    }

    async rotateAuditLog() {
        if (this.auditLog.length === 0) return;

        const timestamp = new Date().toISOString().split('T')[0];
        const archiveKey = `voicelink_audit_log_${timestamp}`;

        // Archive current log
        await this.keychainAuthManager.keychainProvider.storeCredential(
            archiveKey,
            { logs: this.auditLog },
            'local_secure'
        );

        // Clear current log
        this.auditLog = [];

        console.log(`Audit log rotated: ${archiveKey}`);
    }

    getAuditLog(filters = {}) {
        let filteredLog = [...this.auditLog];

        if (filters.type) {
            filteredLog = filteredLog.filter(entry => entry.type === filters.type);
        }

        if (filters.action) {
            filteredLog = filteredLog.filter(entry => entry.action === filters.action);
        }

        if (filters.userId) {
            filteredLog = filteredLog.filter(entry => entry.userId === filters.userId);
        }

        if (filters.startTime) {
            filteredLog = filteredLog.filter(entry => entry.timestamp >= filters.startTime);
        }

        if (filters.endTime) {
            filteredLog = filteredLog.filter(entry => entry.timestamp <= filters.endTime);
        }

        return filteredLog.sort((a, b) => b.timestamp - a.timestamp);
    }

    // Configuration Management

    getEncryptionConfig() {
        return { ...this.encryptionConfig };
    }

    async updateEncryptionConfig(updates, adminUserId) {
        const validKeys = ['mode', 'algorithm', 'keySize', 'audioBitrate', 'compressionLevel'];
        const validModes = ['end-to-end', 'server-side', 'hybrid', 'disabled'];

        Object.keys(updates).forEach(key => {
            if (!validKeys.includes(key)) {
                throw new Error(`Invalid encryption config key: ${key}`);
            }

            if (key === 'mode' && !validModes.includes(updates[key])) {
                throw new Error(`Invalid encryption mode: ${updates[key]}`);
            }
        });

        const oldConfig = { ...this.encryptionConfig };
        Object.assign(this.encryptionConfig, updates);

        // Save configuration
        await this.keychainAuthManager.keychainProvider.storeCredential(
            'voicelink_encryption_config',
            this.encryptionConfig,
            'local_secure'
        );

        // Audit log
        this.auditLog.push({
            type: 'security',
            action: 'encryption_config_updated',
            adminUserId,
            oldConfig,
            newConfig: this.encryptionConfig,
            timestamp: Date.now()
        });

        console.log('Encryption configuration updated:', this.encryptionConfig);
    }

    get2FAConfig() {
        return { ...this.twoFactorConfig };
    }

    getSecurityPolicies() {
        return { ...this.securityPolicies };
    }

    // Security Status

    getSecurityStatus() {
        return {
            encryption: {
                enabled: this.encryptionConfig.mode !== 'disabled',
                mode: this.encryptionConfig.mode,
                algorithm: this.encryptionConfig.algorithm
            },
            twoFactor: {
                enabled: this.twoFactorConfig.enabled,
                methods: Array.from(this.twoFactorConfig.methods),
                usersWithTwoFactor: this.twoFactorTokens.size
            },
            policies: this.securityPolicies,
            audit: {
                totalEvents: this.auditLog.length,
                recentEvents: this.auditLog.slice(-10)
            },
            threats: {
                lockedAccounts: this.lockedAccounts?.size || 0,
                suspiciousActivity: this.suspiciousActivity.size
            }
        };
    }
}

// Crypto Modules

class SymmetricCrypto {
    async encrypt(data, key, algorithm = 'AES-GCM') {
        const iv = crypto.getRandomValues(new Uint8Array(12));
        const encrypted = await crypto.subtle.encrypt(
            { name: algorithm, iv },
            key,
            data
        );
        return { encrypted, iv };
    }

    async decrypt(encryptedData, key, iv, algorithm = 'AES-GCM') {
        return await crypto.subtle.decrypt(
            { name: algorithm, iv },
            key,
            encryptedData
        );
    }
}

class AsymmetricCrypto {
    async generateKeyPair(algorithm = 'RSA-OAEP') {
        return await crypto.subtle.generateKey(
            {
                name: algorithm,
                modulusLength: 4096,
                publicExponent: new Uint8Array([1, 0, 1]),
                hash: 'SHA-256'
            },
            true,
            ['encrypt', 'decrypt']
        );
    }

    async encrypt(data, publicKey, algorithm = 'RSA-OAEP') {
        return await crypto.subtle.encrypt(
            { name: algorithm },
            publicKey,
            data
        );
    }

    async decrypt(encryptedData, privateKey, algorithm = 'RSA-OAEP') {
        return await crypto.subtle.decrypt(
            { name: algorithm },
            privateKey,
            encryptedData
        );
    }
}

class HashCrypto {
    async hash(data, algorithm = 'SHA-256') {
        return await crypto.subtle.digest(algorithm, data);
    }

    async hmac(data, key, algorithm = 'SHA-256') {
        const hmacKey = await crypto.subtle.importKey(
            'raw',
            key,
            { name: 'HMAC', hash: algorithm },
            false,
            ['sign']
        );

        return await crypto.subtle.sign('HMAC', hmacKey, data);
    }
}

class StreamCrypto {
    async encryptStream(stream, key) {
        const encryptedChunks = [];
        const reader = stream.getReader();

        try {
            while (true) {
                const { done, value } = await reader.read();
                if (done) break;

                const iv = crypto.getRandomValues(new Uint8Array(12));
                const encrypted = await crypto.subtle.encrypt(
                    { name: 'AES-GCM', iv },
                    key,
                    value
                );

                encryptedChunks.push({ encrypted, iv });
            }
        } finally {
            reader.releaseLock();
        }

        return encryptedChunks;
    }
}

class TOTPGenerator {
    generateSecret() {
        const charset = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';
        let secret = '';
        for (let i = 0; i < 32; i++) {
            secret += charset.charAt(Math.floor(Math.random() * charset.length));
        }
        return secret;
    }

    async generate(secret, timestamp = Date.now()) {
        const timeSlice = Math.floor(timestamp / 30000);
        const key = this.base32ToBytes(secret);
        const timeBytes = new ArrayBuffer(8);
        const timeView = new DataView(timeBytes);
        timeView.setUint32(4, timeSlice, false);

        const hmacKey = await crypto.subtle.importKey(
            'raw',
            key,
            { name: 'HMAC', hash: 'SHA-1' },
            false,
            ['sign']
        );

        const signature = await crypto.subtle.sign('HMAC', hmacKey, timeBytes);
        const signatureArray = new Uint8Array(signature);

        const offset = signatureArray[19] & 0xf;
        const code = (
            ((signatureArray[offset] & 0x7f) << 24) |
            ((signatureArray[offset + 1] & 0xff) << 16) |
            ((signatureArray[offset + 2] & 0xff) << 8) |
            (signatureArray[offset + 3] & 0xff)
        ) % 1000000;

        return code.toString().padStart(6, '0');
    }

    async verify(token, secret, window = 1) {
        const now = Date.now();
        for (let i = -window; i <= window; i++) {
            const testTime = now + (i * 30000);
            const generated = await this.generate(secret, testTime);
            if (generated === token) {
                return true;
            }
        }
        return false;
    }

    base32ToBytes(base32) {
        const alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';
        let bits = '';
        for (let i = 0; i < base32.length; i++) {
            const val = alphabet.indexOf(base32[i]);
            bits += val.toString(2).padStart(5, '0');
        }

        const bytes = new Uint8Array(Math.floor(bits.length / 8));
        for (let i = 0; i < bytes.length; i++) {
            bytes[i] = parseInt(bits.substr(i * 8, 8), 2);
        }

        return bytes;
    }
}

// Export for use in other modules
window.SecurityEncryptionManager = SecurityEncryptionManager;