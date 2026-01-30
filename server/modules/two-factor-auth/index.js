/**
 * VoiceLink Two-Factor Authentication Module
 *
 * Supports multiple 2FA methods:
 * - TOTP (Time-based One-Time Password) - Google Authenticator, Authy, etc.
 * - Passkey/WebAuthn - Biometric and hardware key authentication
 * - SMS - Via FlexPBX API (with international fallback)
 * - Email - Code sent to verified email
 *
 * Admin controls:
 * - Force 2FA for admins only
 * - Force 2FA for all users
 * - Allow user choice (optional)
 * - Enable/disable specific methods
 */

const crypto = require('crypto');
const fs = require('fs');
const path = require('path');

// TOTP implementation (RFC 6238)
class TOTPGenerator {
    constructor(options = {}) {
        this.digits = options.digits || 6;
        this.period = options.period || 30;
        this.algorithm = options.algorithm || 'sha1';
        this.window = options.window || 1; // Accept codes from this many periods before/after
    }

    /**
     * Generate a random secret (base32 encoded)
     */
    generateSecret(length = 20) {
        const buffer = crypto.randomBytes(length);
        return this.base32Encode(buffer);
    }

    /**
     * Base32 encode
     */
    base32Encode(buffer) {
        const alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';
        let bits = '';
        let result = '';

        for (const byte of buffer) {
            bits += byte.toString(2).padStart(8, '0');
        }

        for (let i = 0; i < bits.length; i += 5) {
            const chunk = bits.substr(i, 5).padEnd(5, '0');
            result += alphabet[parseInt(chunk, 2)];
        }

        return result;
    }

    /**
     * Base32 decode
     */
    base32Decode(encoded) {
        const alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';
        let bits = '';

        for (const char of encoded.toUpperCase().replace(/[^A-Z2-7]/g, '')) {
            const val = alphabet.indexOf(char);
            if (val === -1) continue;
            bits += val.toString(2).padStart(5, '0');
        }

        const bytes = [];
        for (let i = 0; i + 8 <= bits.length; i += 8) {
            bytes.push(parseInt(bits.substr(i, 8), 2));
        }

        return Buffer.from(bytes);
    }

    /**
     * Generate TOTP code for a given time
     */
    generateCode(secret, timestamp = Date.now()) {
        const counter = Math.floor(timestamp / 1000 / this.period);
        const counterBuffer = Buffer.alloc(8);
        counterBuffer.writeBigUInt64BE(BigInt(counter));

        const key = this.base32Decode(secret);
        const hmac = crypto.createHmac(this.algorithm, key);
        hmac.update(counterBuffer);
        const digest = hmac.digest();

        const offset = digest[digest.length - 1] & 0x0f;
        const code = (
            ((digest[offset] & 0x7f) << 24) |
            ((digest[offset + 1] & 0xff) << 16) |
            ((digest[offset + 2] & 0xff) << 8) |
            (digest[offset + 3] & 0xff)
        ) % Math.pow(10, this.digits);

        return code.toString().padStart(this.digits, '0');
    }

    /**
     * Verify TOTP code with window tolerance
     */
    verifyCode(secret, code, timestamp = Date.now()) {
        for (let i = -this.window; i <= this.window; i++) {
            const checkTime = timestamp + (i * this.period * 1000);
            if (this.generateCode(secret, checkTime) === code) {
                return true;
            }
        }
        return false;
    }

    /**
     * Generate otpauth:// URI for QR code
     */
    generateOTPAuthURI(secret, accountName, issuer = 'VoiceLink') {
        const params = new URLSearchParams({
            secret,
            issuer,
            algorithm: this.algorithm.toUpperCase(),
            digits: this.digits.toString(),
            period: this.period.toString()
        });

        return `otpauth://totp/${encodeURIComponent(issuer)}:${encodeURIComponent(accountName)}?${params}`;
    }
}

// SMS Provider - FlexPBX integration
class FlexPBXSMSProvider {
    constructor(config) {
        this.apiUrl = config.apiUrl || 'https://api.flexpbx.com';
        this.apiKey = config.apiKey;
        this.apiSecret = config.apiSecret;
        this.fromNumber = config.fromNumber;
        this.enabled = config.enabled && this.apiKey;
    }

    async sendCode(phoneNumber, code, options = {}) {
        if (!this.enabled) {
            throw new Error('SMS provider not configured');
        }

        const message = options.message || `Your VoiceLink verification code is: ${code}. Valid for ${options.expiryMinutes || 10} minutes.`;

        try {
            const response = await fetch(`${this.apiUrl}/v1/sms/send`, {
                method: 'POST',
                headers: {
                    'Content-Type': 'application/json',
                    'Authorization': `Bearer ${this.apiKey}`,
                    'X-API-Secret': this.apiSecret
                },
                body: JSON.stringify({
                    from: this.fromNumber,
                    to: phoneNumber,
                    message,
                    type: 'verification'
                })
            });

            const result = await response.json();

            if (!response.ok) {
                throw new Error(result.error || 'SMS send failed');
            }

            return { success: true, messageId: result.messageId };
        } catch (error) {
            console.error('[FlexPBX SMS] Send error:', error.message);
            return { success: false, error: error.message };
        }
    }

    /**
     * Check if phone number is supported (US numbers primarily)
     */
    isNumberSupported(phoneNumber) {
        // US numbers start with +1
        const cleaned = phoneNumber.replace(/\D/g, '');
        return cleaned.startsWith('1') && cleaned.length === 11;
    }
}

// Email Code Provider
class EmailCodeProvider {
    constructor(config, emailTransport) {
        this.config = config;
        this.emailTransport = emailTransport; // Nodemailer transport
        this.fromAddress = config.fromAddress || 'noreply@voicelink.local';
        this.fromName = config.fromName || 'VoiceLink';
    }

    async sendCode(email, code, options = {}) {
        const expiryMinutes = options.expiryMinutes || 10;

        const html = `
<!DOCTYPE html>
<html>
<head>
    <style>
        body { font-family: -apple-system, BlinkMacSystemFont, sans-serif; background: #f5f5f5; padding: 20px; }
        .container { max-width: 500px; margin: 0 auto; background: white; border-radius: 12px; padding: 30px; box-shadow: 0 4px 20px rgba(0,0,0,0.1); }
        .header { text-align: center; margin-bottom: 20px; }
        .logo { font-size: 24px; font-weight: bold; color: #6364FF; }
        .code-box { background: #f0f0ff; border: 2px dashed #6364FF; border-radius: 8px; padding: 20px; text-align: center; margin: 20px 0; }
        .code { font-size: 32px; font-weight: bold; letter-spacing: 8px; color: #333; font-family: monospace; }
        .info { color: #666; font-size: 14px; text-align: center; }
        .warning { color: #ff6b6b; font-size: 12px; margin-top: 20px; text-align: center; }
    </style>
</head>
<body>
    <div class="container">
        <div class="header">
            <div class="logo">🔐 VoiceLink</div>
            <p>Verification Code</p>
        </div>
        <div class="code-box">
            <div class="code">${code}</div>
        </div>
        <p class="info">Enter this code to verify your identity.<br>This code expires in <strong>${expiryMinutes} minutes</strong>.</p>
        <p class="warning">If you didn't request this code, please ignore this email.</p>
    </div>
</body>
</html>`;

        const text = `Your VoiceLink verification code is: ${code}\n\nThis code expires in ${expiryMinutes} minutes.\n\nIf you didn't request this code, please ignore this email.`;

        try {
            if (this.emailTransport) {
                await this.emailTransport.sendMail({
                    from: `"${this.fromName}" <${this.fromAddress}>`,
                    to: email,
                    subject: `Your VoiceLink Verification Code: ${code}`,
                    text,
                    html
                });
            } else {
                // Fallback: Log for development
                console.log(`[Email 2FA] Would send to ${email}: Code ${code}`);
            }

            return { success: true };
        } catch (error) {
            console.error('[Email 2FA] Send error:', error.message);
            return { success: false, error: error.message };
        }
    }
}

// WebAuthn/Passkey Manager
class PasskeyManager {
    constructor(config) {
        this.rpId = config.rpId || 'localhost';
        this.rpName = config.rpName || 'VoiceLink';
        this.origin = config.origin || 'https://localhost';
        this.challengeTimeout = config.challengeTimeout || 60000; // 1 minute
    }

    /**
     * Generate registration options for a new passkey
     */
    generateRegistrationOptions(userId, userName, existingCredentials = []) {
        const challenge = crypto.randomBytes(32);

        return {
            challenge: challenge.toString('base64url'),
            rp: {
                id: this.rpId,
                name: this.rpName
            },
            user: {
                id: Buffer.from(userId).toString('base64url'),
                name: userName,
                displayName: userName
            },
            pubKeyCredParams: [
                { type: 'public-key', alg: -7 },   // ES256
                { type: 'public-key', alg: -257 }  // RS256
            ],
            timeout: this.challengeTimeout,
            attestation: 'none',
            excludeCredentials: existingCredentials.map(cred => ({
                type: 'public-key',
                id: cred.credentialId,
                transports: cred.transports || ['internal', 'usb', 'ble', 'nfc']
            })),
            authenticatorSelection: {
                authenticatorAttachment: 'platform',
                userVerification: 'preferred',
                residentKey: 'preferred'
            }
        };
    }

    /**
     * Generate authentication options
     */
    generateAuthenticationOptions(allowedCredentials = []) {
        const challenge = crypto.randomBytes(32);

        return {
            challenge: challenge.toString('base64url'),
            timeout: this.challengeTimeout,
            rpId: this.rpId,
            allowCredentials: allowedCredentials.map(cred => ({
                type: 'public-key',
                id: cred.credentialId,
                transports: cred.transports || ['internal', 'usb', 'ble', 'nfc']
            })),
            userVerification: 'preferred'
        };
    }

    /**
     * Verify registration response
     * Note: Full verification requires @simplewebauthn/server or similar
     * This is a simplified version
     */
    verifyRegistration(credential, expectedChallenge) {
        try {
            const clientDataJSON = JSON.parse(
                Buffer.from(credential.response.clientDataJSON, 'base64url').toString()
            );

            // Verify challenge
            if (clientDataJSON.challenge !== expectedChallenge) {
                return { verified: false, error: 'Challenge mismatch' };
            }

            // Verify origin
            if (clientDataJSON.origin !== this.origin) {
                return { verified: false, error: 'Origin mismatch' };
            }

            // Extract credential data
            return {
                verified: true,
                credential: {
                    credentialId: credential.id,
                    publicKey: credential.response.publicKey,
                    counter: 0,
                    transports: credential.response.transports || ['internal']
                }
            };
        } catch (error) {
            return { verified: false, error: error.message };
        }
    }

    /**
     * Verify authentication response
     */
    verifyAuthentication(credential, expectedChallenge, storedCredential) {
        try {
            const clientDataJSON = JSON.parse(
                Buffer.from(credential.response.clientDataJSON, 'base64url').toString()
            );

            if (clientDataJSON.challenge !== expectedChallenge) {
                return { verified: false, error: 'Challenge mismatch' };
            }

            // In production, verify signature against stored public key
            // This requires proper crypto verification

            return {
                verified: true,
                newCounter: storedCredential.counter + 1
            };
        } catch (error) {
            return { verified: false, error: error.message };
        }
    }
}

// Main TwoFactorAuth Module
class TwoFactorAuthModule {
    constructor(options = {}) {
        this.config = options.config || {};
        this.dataDir = options.dataDir || path.join(__dirname, '../../../data/2fa');
        this.emailTransport = options.emailTransport;

        // Initialize providers
        this.totp = new TOTPGenerator({
            window: this.config.codeSettings?.totpWindow || 1
        });

        this.smsProvider = new FlexPBXSMSProvider(this.config.sms || {});

        this.emailProvider = new EmailCodeProvider(
            this.config.email || {},
            this.emailTransport
        );

        this.passkeyManager = new PasskeyManager({
            rpId: this.config.passkey?.rpId,
            rpName: this.config.passkey?.rpName || 'VoiceLink',
            origin: this.config.passkey?.origin
        });

        // Pending codes storage (in-memory, could be Redis in production)
        this.pendingCodes = new Map();
        this.pendingChallenges = new Map();

        // Ensure data directory exists
        if (!fs.existsSync(this.dataDir)) {
            fs.mkdirSync(this.dataDir, { recursive: true });
        }

        // Clean up expired codes periodically
        setInterval(() => this.cleanupExpiredCodes(), 60000);
    }

    /**
     * Get user's 2FA settings
     */
    getUserSettings(userId) {
        const filePath = path.join(this.dataDir, `${userId}.json`);
        try {
            if (fs.existsSync(filePath)) {
                return JSON.parse(fs.readFileSync(filePath, 'utf8'));
            }
        } catch (e) { /* file doesn't exist */ }

        return {
            userId,
            enabled: false,
            methods: {
                totp: { enabled: false, secret: null, verified: false },
                passkey: { enabled: false, credentials: [] },
                sms: { enabled: false, phoneNumber: null, verified: false },
                email: { enabled: false, email: null, verified: false }
            },
            backupCodes: [],
            createdAt: null,
            lastUsed: null
        };
    }

    /**
     * Save user's 2FA settings
     */
    saveUserSettings(userId, settings) {
        const filePath = path.join(this.dataDir, `${userId}.json`);
        fs.writeFileSync(filePath, JSON.stringify(settings, null, 2));
    }

    /**
     * Check if 2FA is required for a user
     */
    is2FARequired(userId, userRole = 'user') {
        const { enforcement } = this.config;

        if (enforcement?.requireForAdmins && userRole === 'admin') {
            return true;
        }

        if (enforcement?.requireForUsers) {
            return true;
        }

        // Check if user has enabled 2FA voluntarily
        const settings = this.getUserSettings(userId);
        return settings.enabled;
    }

    /**
     * Check if user has 2FA enabled
     */
    has2FAEnabled(userId) {
        const settings = this.getUserSettings(userId);
        return settings.enabled && Object.values(settings.methods).some(m => m.enabled && m.verified !== false);
    }

    /**
     * Get available 2FA methods for user
     */
    getAvailableMethods(userId) {
        const settings = this.getUserSettings(userId);
        const methods = [];

        if (settings.methods.totp?.enabled && settings.methods.totp.verified) {
            methods.push({ type: 'totp', name: 'Authenticator App' });
        }

        if (settings.methods.passkey?.enabled && settings.methods.passkey.credentials?.length > 0) {
            methods.push({ type: 'passkey', name: 'Passkey', count: settings.methods.passkey.credentials.length });
        }

        if (settings.methods.sms?.enabled && settings.methods.sms.verified) {
            const phone = settings.methods.sms.phoneNumber;
            methods.push({ type: 'sms', name: 'SMS', hint: phone ? `***${phone.slice(-4)}` : null });
        }

        if (settings.methods.email?.enabled && settings.methods.email.verified) {
            const email = settings.methods.email.email;
            methods.push({ type: 'email', name: 'Email', hint: email ? email.replace(/(.{2}).*@/, '$1***@') : null });
        }

        if (settings.backupCodes?.length > 0) {
            methods.push({ type: 'backup', name: 'Backup Code', remaining: settings.backupCodes.length });
        }

        return methods;
    }

    // ==========================================
    // TOTP Methods
    // ==========================================

    /**
     * Setup TOTP for user
     */
    setupTOTP(userId, accountName) {
        const secret = this.totp.generateSecret();
        const issuer = this.config.methods?.totp?.issuer || 'VoiceLink';
        const uri = this.totp.generateOTPAuthURI(secret, accountName, issuer);

        const settings = this.getUserSettings(userId);
        settings.methods.totp = {
            enabled: true,
            secret,
            verified: false,
            setupAt: Date.now()
        };
        this.saveUserSettings(userId, settings);

        return { secret, uri, issuer };
    }

    /**
     * Verify and activate TOTP
     */
    verifyAndActivateTOTP(userId, code) {
        const settings = this.getUserSettings(userId);
        const { secret } = settings.methods.totp || {};

        if (!secret) {
            return { success: false, error: 'TOTP not set up' };
        }

        if (this.totp.verifyCode(secret, code)) {
            settings.methods.totp.verified = true;
            settings.methods.totp.activatedAt = Date.now();
            settings.enabled = true;
            settings.createdAt = settings.createdAt || Date.now();
            this.saveUserSettings(userId, settings);

            // Generate backup codes
            const backupCodes = this.generateBackupCodes(userId);

            return { success: true, backupCodes };
        }

        return { success: false, error: 'Invalid code' };
    }

    /**
     * Verify TOTP code
     */
    verifyTOTP(userId, code) {
        const settings = this.getUserSettings(userId);
        const { secret, verified } = settings.methods.totp || {};

        if (!secret || !verified) {
            return { success: false, error: 'TOTP not configured' };
        }

        if (this.totp.verifyCode(secret, code)) {
            settings.lastUsed = Date.now();
            this.saveUserSettings(userId, settings);
            return { success: true };
        }

        return { success: false, error: 'Invalid code' };
    }

    // ==========================================
    // SMS Methods
    // ==========================================

    /**
     * Setup SMS 2FA
     */
    async setupSMS(userId, phoneNumber) {
        // Validate phone number format
        const cleaned = phoneNumber.replace(/\D/g, '');
        if (cleaned.length < 10) {
            return { success: false, error: 'Invalid phone number' };
        }

        // Check if SMS is supported for this number
        if (!this.smsProvider.isNumberSupported(phoneNumber)) {
            return {
                success: false,
                error: 'SMS verification is only available for US numbers. Please use email or authenticator app.',
                alternatives: ['email', 'totp']
            };
        }

        const code = this.generateNumericCode(this.config.codeSettings?.smsCodeLength || 6);
        const expiryMinutes = this.config.codeSettings?.codeExpiryMinutes || 10;

        // Store pending verification
        this.pendingCodes.set(`sms:${userId}`, {
            code,
            phoneNumber,
            expiresAt: Date.now() + (expiryMinutes * 60 * 1000),
            attempts: 0
        });

        // Send SMS
        const result = await this.smsProvider.sendCode(phoneNumber, code, { expiryMinutes });

        if (result.success) {
            return { success: true, expiresIn: expiryMinutes * 60 };
        }

        return { success: false, error: result.error };
    }

    /**
     * Verify SMS code and activate
     */
    verifySMSSetup(userId, code) {
        const pending = this.pendingCodes.get(`sms:${userId}`);

        if (!pending) {
            return { success: false, error: 'No pending SMS verification' };
        }

        if (Date.now() > pending.expiresAt) {
            this.pendingCodes.delete(`sms:${userId}`);
            return { success: false, error: 'Code expired' };
        }

        pending.attempts++;
        if (pending.attempts > (this.config.codeSettings?.maxAttempts || 5)) {
            this.pendingCodes.delete(`sms:${userId}`);
            return { success: false, error: 'Too many attempts' };
        }

        if (pending.code === code) {
            this.pendingCodes.delete(`sms:${userId}`);

            const settings = this.getUserSettings(userId);
            settings.methods.sms = {
                enabled: true,
                phoneNumber: pending.phoneNumber,
                verified: true,
                activatedAt: Date.now()
            };
            settings.enabled = true;
            settings.createdAt = settings.createdAt || Date.now();
            this.saveUserSettings(userId, settings);

            return { success: true };
        }

        return { success: false, error: 'Invalid code' };
    }

    /**
     * Send SMS verification code for login
     */
    async sendSMSCode(userId) {
        const settings = this.getUserSettings(userId);
        const { phoneNumber, verified } = settings.methods.sms || {};

        if (!phoneNumber || !verified) {
            return { success: false, error: 'SMS not configured' };
        }

        const code = this.generateNumericCode(this.config.codeSettings?.smsCodeLength || 6);
        const expiryMinutes = this.config.codeSettings?.codeExpiryMinutes || 10;

        this.pendingCodes.set(`sms-login:${userId}`, {
            code,
            expiresAt: Date.now() + (expiryMinutes * 60 * 1000),
            attempts: 0
        });

        const result = await this.smsProvider.sendCode(phoneNumber, code, { expiryMinutes });

        if (result.success) {
            return { success: true, expiresIn: expiryMinutes * 60, hint: `***${phoneNumber.slice(-4)}` };
        }

        return { success: false, error: result.error };
    }

    /**
     * Verify SMS login code
     */
    verifySMSLogin(userId, code) {
        const pending = this.pendingCodes.get(`sms-login:${userId}`);

        if (!pending) {
            return { success: false, error: 'No pending code' };
        }

        if (Date.now() > pending.expiresAt) {
            this.pendingCodes.delete(`sms-login:${userId}`);
            return { success: false, error: 'Code expired' };
        }

        pending.attempts++;
        if (pending.attempts > (this.config.codeSettings?.maxAttempts || 5)) {
            this.pendingCodes.delete(`sms-login:${userId}`);
            return { success: false, error: 'Too many attempts' };
        }

        if (pending.code === code) {
            this.pendingCodes.delete(`sms-login:${userId}`);

            const settings = this.getUserSettings(userId);
            settings.lastUsed = Date.now();
            this.saveUserSettings(userId, settings);

            return { success: true };
        }

        return { success: false, error: 'Invalid code' };
    }

    // ==========================================
    // Email Methods
    // ==========================================

    /**
     * Setup email 2FA
     */
    async setupEmail(userId, email) {
        const code = this.generateNumericCode(this.config.codeSettings?.emailCodeLength || 6);
        const expiryMinutes = this.config.codeSettings?.codeExpiryMinutes || 10;

        this.pendingCodes.set(`email:${userId}`, {
            code,
            email,
            expiresAt: Date.now() + (expiryMinutes * 60 * 1000),
            attempts: 0
        });

        const result = await this.emailProvider.sendCode(email, code, { expiryMinutes });

        if (result.success) {
            return { success: true, expiresIn: expiryMinutes * 60 };
        }

        return { success: false, error: result.error };
    }

    /**
     * Verify email setup code
     */
    verifyEmailSetup(userId, code) {
        const pending = this.pendingCodes.get(`email:${userId}`);

        if (!pending) {
            return { success: false, error: 'No pending email verification' };
        }

        if (Date.now() > pending.expiresAt) {
            this.pendingCodes.delete(`email:${userId}`);
            return { success: false, error: 'Code expired' };
        }

        pending.attempts++;
        if (pending.attempts > (this.config.codeSettings?.maxAttempts || 5)) {
            this.pendingCodes.delete(`email:${userId}`);
            return { success: false, error: 'Too many attempts' };
        }

        if (pending.code === code) {
            this.pendingCodes.delete(`email:${userId}`);

            const settings = this.getUserSettings(userId);
            settings.methods.email = {
                enabled: true,
                email: pending.email,
                verified: true,
                activatedAt: Date.now()
            };
            settings.enabled = true;
            settings.createdAt = settings.createdAt || Date.now();
            this.saveUserSettings(userId, settings);

            return { success: true };
        }

        return { success: false, error: 'Invalid code' };
    }

    /**
     * Send email verification code for login
     */
    async sendEmailCode(userId) {
        const settings = this.getUserSettings(userId);
        const { email, verified } = settings.methods.email || {};

        if (!email || !verified) {
            return { success: false, error: 'Email not configured' };
        }

        const code = this.generateNumericCode(this.config.codeSettings?.emailCodeLength || 6);
        const expiryMinutes = this.config.codeSettings?.codeExpiryMinutes || 10;

        this.pendingCodes.set(`email-login:${userId}`, {
            code,
            expiresAt: Date.now() + (expiryMinutes * 60 * 1000),
            attempts: 0
        });

        const result = await this.emailProvider.sendCode(email, code, { expiryMinutes });

        if (result.success) {
            return {
                success: true,
                expiresIn: expiryMinutes * 60,
                hint: email.replace(/(.{2}).*@/, '$1***@')
            };
        }

        return { success: false, error: result.error };
    }

    /**
     * Verify email login code
     */
    verifyEmailLogin(userId, code) {
        const pending = this.pendingCodes.get(`email-login:${userId}`);

        if (!pending) {
            return { success: false, error: 'No pending code' };
        }

        if (Date.now() > pending.expiresAt) {
            this.pendingCodes.delete(`email-login:${userId}`);
            return { success: false, error: 'Code expired' };
        }

        pending.attempts++;
        if (pending.attempts > (this.config.codeSettings?.maxAttempts || 5)) {
            this.pendingCodes.delete(`email-login:${userId}`);
            return { success: false, error: 'Too many attempts' };
        }

        if (pending.code === code) {
            this.pendingCodes.delete(`email-login:${userId}`);

            const settings = this.getUserSettings(userId);
            settings.lastUsed = Date.now();
            this.saveUserSettings(userId, settings);

            return { success: true };
        }

        return { success: false, error: 'Invalid code' };
    }

    // ==========================================
    // Passkey Methods
    // ==========================================

    /**
     * Start passkey registration
     */
    startPasskeyRegistration(userId, userName) {
        const settings = this.getUserSettings(userId);
        const existingCredentials = settings.methods.passkey?.credentials || [];

        const options = this.passkeyManager.generateRegistrationOptions(
            userId,
            userName,
            existingCredentials
        );

        this.pendingChallenges.set(`passkey-reg:${userId}`, {
            challenge: options.challenge,
            expiresAt: Date.now() + 60000
        });

        return options;
    }

    /**
     * Complete passkey registration
     */
    completePasskeyRegistration(userId, credential) {
        const pending = this.pendingChallenges.get(`passkey-reg:${userId}`);

        if (!pending || Date.now() > pending.expiresAt) {
            return { success: false, error: 'Registration expired' };
        }

        const result = this.passkeyManager.verifyRegistration(credential, pending.challenge);

        if (!result.verified) {
            return { success: false, error: result.error };
        }

        this.pendingChallenges.delete(`passkey-reg:${userId}`);

        const settings = this.getUserSettings(userId);
        if (!settings.methods.passkey) {
            settings.methods.passkey = { enabled: true, credentials: [] };
        }

        settings.methods.passkey.credentials.push({
            ...result.credential,
            name: credential.name || `Passkey ${settings.methods.passkey.credentials.length + 1}`,
            createdAt: Date.now()
        });
        settings.methods.passkey.enabled = true;
        settings.enabled = true;
        settings.createdAt = settings.createdAt || Date.now();
        this.saveUserSettings(userId, settings);

        return { success: true };
    }

    /**
     * Start passkey authentication
     */
    startPasskeyAuth(userId) {
        const settings = this.getUserSettings(userId);
        const credentials = settings.methods.passkey?.credentials || [];

        if (credentials.length === 0) {
            return { success: false, error: 'No passkeys registered' };
        }

        const options = this.passkeyManager.generateAuthenticationOptions(credentials);

        this.pendingChallenges.set(`passkey-auth:${userId}`, {
            challenge: options.challenge,
            expiresAt: Date.now() + 60000
        });

        return { success: true, options };
    }

    /**
     * Complete passkey authentication
     */
    completePasskeyAuth(userId, credential) {
        const pending = this.pendingChallenges.get(`passkey-auth:${userId}`);

        if (!pending || Date.now() > pending.expiresAt) {
            return { success: false, error: 'Authentication expired' };
        }

        const settings = this.getUserSettings(userId);
        const storedCred = settings.methods.passkey?.credentials.find(
            c => c.credentialId === credential.id
        );

        if (!storedCred) {
            return { success: false, error: 'Unknown credential' };
        }

        const result = this.passkeyManager.verifyAuthentication(
            credential,
            pending.challenge,
            storedCred
        );

        if (!result.verified) {
            return { success: false, error: result.error };
        }

        this.pendingChallenges.delete(`passkey-auth:${userId}`);

        // Update counter
        storedCred.counter = result.newCounter;
        settings.lastUsed = Date.now();
        this.saveUserSettings(userId, settings);

        return { success: true };
    }

    // ==========================================
    // Backup Codes
    // ==========================================

    /**
     * Generate backup codes
     */
    generateBackupCodes(userId, count = 10) {
        const codes = [];
        for (let i = 0; i < count; i++) {
            codes.push(this.generateBackupCode());
        }

        const settings = this.getUserSettings(userId);
        settings.backupCodes = codes.map(code => ({
            code: this.hashCode(code),
            used: false,
            createdAt: Date.now()
        }));
        this.saveUserSettings(userId, settings);

        return codes; // Return unhashed codes to show user once
    }

    /**
     * Verify backup code
     */
    verifyBackupCode(userId, code) {
        const settings = this.getUserSettings(userId);
        const normalizedCode = code.replace(/\s/g, '').toUpperCase();
        const hashedInput = this.hashCode(normalizedCode);

        const backupCode = settings.backupCodes?.find(
            bc => bc.code === hashedInput && !bc.used
        );

        if (backupCode) {
            backupCode.used = true;
            backupCode.usedAt = Date.now();
            settings.lastUsed = Date.now();
            this.saveUserSettings(userId, settings);

            return {
                success: true,
                remaining: settings.backupCodes.filter(bc => !bc.used).length
            };
        }

        return { success: false, error: 'Invalid backup code' };
    }

    // ==========================================
    // Utility Methods
    // ==========================================

    generateNumericCode(length) {
        const digits = '0123456789';
        let code = '';
        const bytes = crypto.randomBytes(length);
        for (let i = 0; i < length; i++) {
            code += digits[bytes[i] % 10];
        }
        return code;
    }

    generateBackupCode() {
        const chars = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'; // Removed confusing chars
        let code = '';
        const bytes = crypto.randomBytes(8);
        for (let i = 0; i < 8; i++) {
            code += chars[bytes[i] % chars.length];
            if (i === 3) code += '-';
        }
        return code;
    }

    hashCode(code) {
        return crypto.createHash('sha256').update(code).digest('hex');
    }

    cleanupExpiredCodes() {
        const now = Date.now();
        for (const [key, value] of this.pendingCodes) {
            if (value.expiresAt < now) {
                this.pendingCodes.delete(key);
            }
        }
        for (const [key, value] of this.pendingChallenges) {
            if (value.expiresAt < now) {
                this.pendingChallenges.delete(key);
            }
        }
    }

    /**
     * Disable 2FA for user
     */
    disable2FA(userId) {
        const settings = this.getUserSettings(userId);
        settings.enabled = false;
        settings.methods = {
            totp: { enabled: false, secret: null, verified: false },
            passkey: { enabled: false, credentials: [] },
            sms: { enabled: false, phoneNumber: null, verified: false },
            email: { enabled: false, email: null, verified: false }
        };
        settings.backupCodes = [];
        this.saveUserSettings(userId, settings);

        return { success: true };
    }

    /**
     * Get 2FA status for admin view
     */
    getAdminStatus() {
        const files = fs.readdirSync(this.dataDir).filter(f => f.endsWith('.json'));
        const stats = {
            totalUsers: files.length,
            enabled: 0,
            methods: { totp: 0, passkey: 0, sms: 0, email: 0 }
        };

        for (const file of files) {
            try {
                const settings = JSON.parse(fs.readFileSync(path.join(this.dataDir, file), 'utf8'));
                if (settings.enabled) {
                    stats.enabled++;
                    if (settings.methods.totp?.verified) stats.methods.totp++;
                    if (settings.methods.passkey?.credentials?.length > 0) stats.methods.passkey++;
                    if (settings.methods.sms?.verified) stats.methods.sms++;
                    if (settings.methods.email?.verified) stats.methods.email++;
                }
            } catch (e) { /* skip invalid files */ }
        }

        return stats;
    }
}

module.exports = { TwoFactorAuthModule, TOTPGenerator, FlexPBXSMSProvider, EmailCodeProvider, PasskeyManager };
