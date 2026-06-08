const fs = require('fs');
const path = require('path');

class VoiceLinkFlexPBXModule {
    constructor(options = {}) {
        this.config = options.config || {};
        this.server = options.server || null;
        this.dataDir = options.dataDir || path.join(__dirname, '../../../data/voicelink-flexpbx');
        this.stateFile = path.join(this.dataDir, 'state.json');
        this.state = {
            otpCalls: [],
            roomPolicies: {},
            verificationSessions: {},
            suppressedNumbers: {}
        };

        fs.mkdirSync(this.dataDir, { recursive: true });
        this.loadState();
    }

    loadState() {
        try {
            if (fs.existsSync(this.stateFile)) {
                const loaded = JSON.parse(fs.readFileSync(this.stateFile, 'utf8'));
                if (loaded && typeof loaded === 'object') {
                    this.state = {
                        otpCalls: Array.isArray(loaded.otpCalls) ? loaded.otpCalls : [],
                        roomPolicies: loaded.roomPolicies && typeof loaded.roomPolicies === 'object' ? loaded.roomPolicies : {},
                        verificationSessions: loaded.verificationSessions && typeof loaded.verificationSessions === 'object' ? loaded.verificationSessions : {},
                        suppressedNumbers: loaded.suppressedNumbers && typeof loaded.suppressedNumbers === 'object' ? loaded.suppressedNumbers : {}
                    };
                }
            }
        } catch (error) {
            console.warn('[VoiceLinkFlexPBX] Failed to load state:', error.message);
        }
    }

    saveState() {
        try {
            fs.writeFileSync(this.stateFile, JSON.stringify(this.state, null, 2));
        } catch (error) {
            console.warn('[VoiceLinkFlexPBX] Failed to save state:', error.message);
        }
    }

    getStatus() {
        return {
            enabled: this.isEnabled(),
            pbxApiUrl: this.config.pbxApiUrl || null,
            defaultExtension: this.getDefaultExtension(),
            otpVoiceEnabled: !!this.config?.otpVoice?.enabled,
            trackedOtpCalls: this.state.otpCalls.length,
            activeVerificationSessions: Object.keys(this.state.verificationSessions || {}).length,
            suppressedNumbers: Object.keys(this.state.suppressedNumbers || {}).length,
            userCount: typeof this.server?.users?.size === 'number' ? this.server.users.size : 0,
            healthy: !!this.config?.pbxApiUrl && !!this.config?.apiKey,
            quickActions: {
                status: true,
                restart: true,
                syncFiles: true,
                checkUsers: true
            },
            voiceEngine: {
                provider: this.config?.voiceEngine?.provider || 'piper',
                defaultVoice: this.config?.voiceEngine?.defaultVoice || 'piper-female',
                allowClonedVoice: this.config?.voiceEngine?.allowClonedVoice !== false,
                allowRecordedName: this.config?.voiceEngine?.allowRecordedName !== false,
                selectionMode: this.config?.voiceEngine?.selectionMode || 'prefer-recorded-name'
            },
            holdMedia: {
                enabled: this.config?.holdMedia?.enabled !== false,
                optionalSource: this.config?.holdMedia?.optionalSource !== false,
                targetCount: Array.isArray(this.config?.holdMedia?.pbxTargets) ? this.config.holdMedia.pbxTargets.length : 0
            }
        };
    }

    isEnabled() {
        return this.config.enabled !== false;
    }

    getDefaultExtension() {
        return String(this.config.defaultExtension || this.config?.otpVoice?.fromExtension || '2000');
    }

    createVerificationSessionId() {
        return `vls_${Date.now().toString(36)}${Math.random().toString(36).slice(2, 10)}`;
    }

    maskPhoneNumber(phoneNumber) {
        const normalized = this.normalizePhoneNumber(phoneNumber);
        return normalized ? `***${normalized.slice(-4)}` : null;
    }

    getVerificationSession(sessionId) {
        return sessionId ? (this.state.verificationSessions[sessionId] || null) : null;
    }

    updateVerificationSession(sessionId, patch = {}) {
        const existing = this.getVerificationSession(sessionId);
        if (!existing) return null;
        this.state.verificationSessions[sessionId] = {
            ...existing,
            ...patch,
            updatedAt: Date.now()
        };
        this.saveState();
        return this.state.verificationSessions[sessionId];
    }

    suppressNumber(phoneNumber, details = {}) {
        const normalized = this.normalizePhoneNumber(phoneNumber);
        if (!normalized) return null;
        this.state.suppressedNumbers[normalized] = {
            phoneNumber: normalized,
            displayName: details.displayName || null,
            reason: details.reason || 'wrong-person',
            userId: details.userId || null,
            supportTicketId: details.supportTicketId || null,
            supportTicketNumber: details.supportTicketNumber || null,
            status: details.status || 'suppressed',
            createdAt: Date.now(),
            updatedAt: Date.now()
        };
        this.saveState();
        return this.state.suppressedNumbers[normalized];
    }

    normalizePhoneNumber(phoneNumber) {
        const digits = String(phoneNumber || '').replace(/\D/g, '');
        if (!digits) {
            return null;
        }
        if (digits.length === 10) {
            return `+1${digits}`;
        }
        if (digits.length === 11 && digits.startsWith('1')) {
            return `+${digits}`;
        }
        if (digits.length > 11) {
            return `+${digits}`;
        }
        return null;
    }

    isUSSupportedNumber(phoneNumber) {
        const normalized = this.normalizePhoneNumber(phoneNumber);
        if (!normalized) {
            return false;
        }
        if (this.config?.otpVoice?.usOnly === false) {
            return true;
        }
        return normalized.startsWith('+1') && normalized.length === 12;
    }

    buildOtpMessage(code, expiryMinutes = null, displayName = null) {
        const minutes = Number(expiryMinutes || this.config?.otpVoice?.expiryMinutes || 10);
        const template = this.getPromptText(
            'otpMessageTemplate',
            this.config?.otpVoice?.messageTemplate
            || 'Hello from VoiceLink. Your verification code is {code}. This code expires in {expiryMinutes} minutes.'
        );
        const safeDisplayName = String(displayName || '').trim();
        return template
            .replaceAll('{name}', safeDisplayName || 'the intended person')
            .replaceAll('{code}', String(code))
            .replaceAll('{expiryMinutes}', String(minutes));
    }

    buildVerificationPromptText({ displayName = '', code = '', expiryMinutes = null } = {}) {
        const safeDisplayName = String(displayName || '').trim();
        const digits = String(code || '').split('').join(' ');
        const minutes = Number(expiryMinutes || this.config?.otpVoice?.expiryMinutes || 10);
        const lines = [
            safeDisplayName
                ? `${this.getPromptText('callIsFor', 'This call is for')} ${safeDisplayName}.`
                : this.getPromptText('personNameUnavailable', 'This call is for the intended VoiceLink user.'),
            this.getPromptText('verificationIntro', 'This is your VoiceLink verification call.'),
            `${this.getPromptText('codeIntro', 'Your verification code is')} ${digits}.`,
            `${this.getPromptText('codeValidForMinutes', 'You have this many minutes to enter the code before it expires.')} ${minutes} minutes.`,
            this.getPromptText('stayOnTheLine', 'Stay on the line while we wait for your code to be entered.'),
            this.getPromptText('waitingForCode', 'We are still waiting for your code to be entered.'),
            this.getPromptText('repeatOptions', 'Press 1 to repeat the code, press 2 to hear it more slowly, or press 3 if you are not the intended person.'),
            safeDisplayName
                ? `${this.getPromptText('wrongPersonPrompt', 'If you are not the intended person, press 3 and we will stop calling this number for verification.')} ${safeDisplayName}.`
                : this.getPromptText('wrongPersonPrompt', 'If you are not the intended person, press 3 and we will stop calling this number for verification.')
        ].filter(Boolean);

        return lines.join(' ');
    }

    getRoomTelephonyCapabilities(room = {}, user = {}) {
        const allowedRoles = Array.isArray(this.config.allowedRoomRoles) && this.config.allowedRoomRoles.length
            ? this.config.allowedRoomRoles
            : ['admin', 'moderator'];
        const role = String(user.role || user.userRole || 'guest').toLowerCase();
        const roomPolicy = this.state.roomPolicies[room.id] || {};
        const roomDialingEnabled = roomPolicy.allowDialOut !== false && room.allowDialOut !== false;
        const otpVoiceEnabled = !!this.config?.otpVoice?.enabled && roomPolicy.allowOtpVoice !== false;

        return {
            roomId: room.id || null,
            allowed: roomDialingEnabled && allowedRoles.includes(role),
            role,
            roomDialingEnabled,
            otpVoiceEnabled,
            defaultExtension: roomPolicy.fromExtension || this.getDefaultExtension(),
            supportedDestinations: {
                usVoiceOtp: otpVoiceEnabled,
                roomDialOut: roomDialingEnabled
            }
        };
    }

    canPlaceOtpVoiceCall(phoneNumber) {
        if (!this.isEnabled() || !this.config?.otpVoice?.enabled) {
            return { allowed: false, reason: 'Voice OTP is disabled' };
        }
        if (!this.config.apiKey) {
            return { allowed: false, reason: 'FlexPBX API key is not configured' };
        }
        if (this.state.suppressedNumbers[this.normalizePhoneNumber(phoneNumber)]) {
            return { allowed: false, reason: 'This number is suppressed for verification calls' };
        }
        if (!this.isUSSupportedNumber(phoneNumber)) {
            return { allowed: false, reason: 'Only supported US numbers can receive voice OTP calls right now' };
        }
        return { allowed: true };
    }

    getOtpAttemptCount(phoneNumber, withinMs = 60 * 60 * 1000) {
        const normalized = this.normalizePhoneNumber(phoneNumber);
        if (!normalized) {
            return 0;
        }
        const cutoff = Date.now() - withinMs;
        return this.state.otpCalls.filter((entry) => entry.phoneNumber === normalized && entry.createdAt >= cutoff).length;
    }

    recordOtpCall(entry) {
        this.state.otpCalls.push(entry);
        if (this.state.otpCalls.length > 500) {
            this.state.otpCalls = this.state.otpCalls.slice(-500);
        }
        this.saveState();
    }

    async requestFlexPBX(endpointPath, options = {}) {
        const baseUrl = String(this.config.pbxApiUrl || '').replace(/\/+$/, '');
        if (!baseUrl) {
            throw new Error('FlexPBX API URL is not configured');
        }

        const endpoint = String(endpointPath || '').replace(/^\/+/, '');
        const url = `${baseUrl}/${endpoint}`;
        const headers = {
            'Content-Type': 'application/json',
            'X-API-Key': this.config.apiKey,
            ...(options.headers || {})
        };

        const response = await fetch(url, {
            method: options.method || 'POST',
            headers,
            body: options.body ? JSON.stringify(options.body) : undefined
        });

        let payload = null;
        try {
            payload = await response.json();
        } catch (_) {
            payload = null;
        }

        if (!response.ok) {
            const message = payload?.error || payload?.message || `FlexPBX request failed with status ${response.status}`;
            throw new Error(message);
        }

        return payload || { success: true };
    }

    buildVerificationPromptPlan({ displayName = '', code = '', expiryMinutes = null } = {}) {
        return {
            displayName: displayName || null,
            codeLength: String(code || '').length,
            codeDigits: String(code || '').split(''),
            expiryMinutes: Number(expiryMinutes || this.config?.otpVoice?.expiryMinutes || 10),
            provider: this.config?.voiceEngine?.provider || 'piper',
            defaultVoice: this.config?.voiceEngine?.defaultVoice || 'piper-female',
            clonedVoiceId: this.config?.voiceEngine?.clonedVoiceId || null,
            selectionMode: this.config?.voiceEngine?.selectionMode || 'prefer-recorded-name',
            promptText: this.getPromptTextOverrides(),
            spokenText: this.buildVerificationPromptText({ displayName, code, expiryMinutes })
        };
    }

    getPromptTextOverrides() {
        return this.config?.promptTextOverrides || {};
    }

    getPromptText(key, fallback = '') {
        const overrides = this.getPromptTextOverrides();
        const value = overrides && Object.prototype.hasOwnProperty.call(overrides, key) ? overrides[key] : fallback;
        return String(value || fallback || '').trim();
    }

    getQuickActionsStatus() {
        return {
            healthy: !!this.config?.pbxApiUrl && !!this.config?.apiKey,
            userCount: typeof this.server?.users?.size === 'number' ? this.server.users.size : 0,
            activeVerificationSessions: Object.keys(this.state.verificationSessions || {}).length,
            suppressedNumbers: Object.keys(this.state.suppressedNumbers || {}).length,
            actions: {
                status: true,
                restart: true,
                syncFiles: true
            }
        };
    }

    getHoldMediaConfig() {
        const configuredTargets = Array.isArray(this.config?.holdMedia?.pbxTargets) ? this.config.holdMedia.pbxTargets : [];
        return {
            enabled: this.config?.holdMedia?.enabled !== false,
            optionalSource: this.config?.holdMedia?.optionalSource !== false,
            autoReload: this.config?.holdMedia?.autoReload !== false,
            allowedSourceTypes: Array.isArray(this.config?.holdMedia?.allowedSourceTypes) && this.config.holdMedia.allowedSourceTypes.length
                ? this.config.holdMedia.allowedSourceTypes
                : ['server-stream', 'room-background', 'room-stream', 'room-mix'],
            globalAssignment: this.config?.holdMedia?.globalAssignment || {
                enabled: false,
                sourceType: 'server-stream',
                sourceId: 'server-default',
                mohClass: 'voicelink-global',
                targetIds: ['community-pbx']
            },
            roomAssignments: this.config?.holdMedia?.roomAssignments || {},
            pbxTargets: configuredTargets.length ? configuredTargets : [
                {
                    id: 'community-pbx',
                    name: 'Community PBX',
                    apiUrl: this.config?.pbxApiUrl || 'https://pbx.devinecreations.net/api',
                    enabled: true
                }
            ]
        };
    }

    normalizeHoldMediaConfig(nextConfig = {}) {
        const current = this.getHoldMediaConfig();
        const pbxTargets = Array.isArray(nextConfig.pbxTargets) ? nextConfig.pbxTargets : current.pbxTargets;
        const allowedSourceTypes = Array.isArray(nextConfig.allowedSourceTypes) && nextConfig.allowedSourceTypes.length
            ? nextConfig.allowedSourceTypes.map((value) => String(value || '').trim()).filter(Boolean)
            : current.allowedSourceTypes;
        return {
            enabled: nextConfig.enabled !== undefined ? nextConfig.enabled !== false : current.enabled,
            optionalSource: nextConfig.optionalSource !== undefined ? nextConfig.optionalSource !== false : current.optionalSource,
            autoReload: nextConfig.autoReload !== undefined ? nextConfig.autoReload !== false : current.autoReload,
            allowedSourceTypes,
            globalAssignment: {
                ...current.globalAssignment,
                ...(nextConfig.globalAssignment || {})
            },
            roomAssignments: nextConfig.roomAssignments && typeof nextConfig.roomAssignments === 'object'
                ? nextConfig.roomAssignments
                : current.roomAssignments,
            pbxTargets: pbxTargets.map((target, index) => ({
                id: String(target?.id || `pbx-target-${index + 1}`).trim(),
                name: String(target?.name || `PBX Target ${index + 1}`).trim(),
                apiUrl: String(target?.apiUrl || '').replace(/\/+$/, ''),
                enabled: target?.enabled !== false
            })).filter((target) => target.id && target.apiUrl)
        };
    }

    getKnownRooms() {
        const rooms = this.server?.rooms;
        if (rooms instanceof Map) {
            return Array.from(rooms.values()).filter(Boolean);
        }
        if (Array.isArray(rooms)) {
            return rooms.filter(Boolean);
        }
        if (rooms && typeof rooms === 'object') {
            return Object.values(rooms).filter(Boolean);
        }
        return [];
    }

    getHoldMediaSources() {
        const config = this.getHoldMediaConfig();
        const sources = [];
        const pushSource = (source) => {
            if (!source?.id) return;
            if (config.allowedSourceTypes.includes(source.sourceType) === false) return;
            sources.push(source);
        };

        pushSource({
            id: 'server-default',
            name: 'Server Default Hold Source',
            sourceType: 'server-stream',
            description: 'Uses the configured default hold stream or fallback stream for the server.',
            streamUrl: String(this.config?.holdMedia?.serverDefaultStreamUrl || '').trim(),
            supported: true,
            roomId: null,
            roomName: null
        });

        for (const room of this.getKnownRooms()) {
            const roomId = String(room?.id || '').trim();
            const roomName = String(room?.name || roomId || 'Room').trim();
            if (!roomId) continue;
            const background = typeof this.server?.getConfiguredBackgroundStreamForRoom === 'function'
                ? this.server.getConfiguredBackgroundStreamForRoom(room)
                : null;
            if (background?.streamUrl) {
                pushSource({
                    id: `room-background:${roomId}`,
                    name: `${roomName} Background Stream`,
                    sourceType: 'room-background',
                    description: 'Uses the room background stream assignment from VoiceLink.',
                    streamUrl: String(background.streamUrl || '').trim(),
                    roomId,
                    roomName,
                    supported: true
                });
            }

            pushSource({
                id: `room-stream:${roomId}`,
                name: `${roomName} Media Stream`,
                sourceType: 'room-stream',
                description: 'Uses the room media endpoint as a direct stream source for hold audio.',
                streamUrl: this.buildRoomStreamUrl(roomId),
                roomId,
                roomName,
                supported: true
            });

            pushSource({
                id: `room-mix:${roomId}`,
                name: `${roomName} Full Room Mix`,
                sourceType: 'room-mix',
                description: 'Uses a live room mix source when supported by the server audio bridge.',
                streamUrl: '',
                roomId,
                roomName,
                supported: false
            });

            pushSource({
                id: `individual-room:${roomId}`,
                name: `${roomName} Individual Source`,
                sourceType: 'individual-room',
                description: 'Reserves a per-room routed source for later use when dedicated per-room streams are enabled.',
                streamUrl: '',
                roomId,
                roomName,
                supported: false
            });
        }

        return sources;
    }

    buildRoomStreamUrl(roomId) {
        const base = String(this.server?.publicBaseURL || this.server?.canonicalBaseURL || this.config?.voiceLinkBaseUrl || '').replace(/\/+$/, '');
        const trimmedRoomId = String(roomId || '').trim();
        if (!base || !trimmedRoomId) return '';
        return `${base}/api/jellyfin/room-stream/${encodeURIComponent(trimmedRoomId)}`;
    }

    buildHoldMediaStatus() {
        const config = this.getHoldMediaConfig();
        const sources = this.getHoldMediaSources();
        return {
            enabled: config.enabled,
            optionalSource: config.optionalSource,
            autoReload: config.autoReload,
            allowedSourceTypes: config.allowedSourceTypes,
            globalAssignment: config.globalAssignment,
            roomAssignments: config.roomAssignments,
            pbxTargets: config.pbxTargets,
            sources,
            roomCount: this.getKnownRooms().length
        };
    }

    buildDesiredHoldMediaClasses() {
        const status = this.buildHoldMediaStatus();
        const sourceById = new Map(status.sources.map((source) => [source.id, source]));
        const classes = [];
        const addAssignment = (assignment, roomId = null) => {
            if (!assignment?.enabled) return;
            const source = sourceById.get(String(assignment.sourceId || '').trim());
            if (!source) return;
            if (!source.supported || !source.streamUrl) return;
            const mohClass = String(assignment.mohClass || (roomId ? `voicelink-room-${roomId}` : 'voicelink-global')).trim();
            if (!mohClass) return;
            classes.push({
                roomId,
                sourceId: source.id,
                sourceType: source.sourceType,
                roomName: source.roomName || null,
                name: mohClass,
                targetIds: Array.isArray(assignment.targetIds) ? assignment.targetIds : [],
                streamUrl: source.streamUrl,
                description: roomId
                    ? `VoiceLink room hold source for ${source.roomName || roomId}`
                    : 'VoiceLink global hold source'
            });
        };

        addAssignment(status.globalAssignment, null);
        for (const [roomId, assignment] of Object.entries(status.roomAssignments || {})) {
            addAssignment(assignment, roomId);
        }
        return classes;
    }

    async requestFlexPBXForm(endpointPath, fields = {}) {
        const baseUrl = String(this.config.pbxApiUrl || '').replace(/\/+$/, '');
        if (!baseUrl) {
            throw new Error('FlexPBX API URL is not configured');
        }

        const endpoint = String(endpointPath || '').replace(/^\/+/, '');
        const response = await fetch(`${baseUrl}/${endpoint}`, {
            method: 'POST',
            headers: {
                'Content-Type': 'application/x-www-form-urlencoded',
                'X-API-Key': this.config.apiKey || ''
            },
            body: new URLSearchParams(
                Object.entries(fields).reduce((acc, [key, value]) => {
                    acc[key] = value == null ? '' : String(value);
                    return acc;
                }, {})
            ).toString()
        });

        let payload = null;
        try {
            payload = await response.json();
        } catch (_) {
            payload = null;
        }
        if (!response.ok || payload?.success === false) {
            throw new Error(payload?.message || payload?.error || `FlexPBX form request failed with status ${response.status}`);
        }
        return payload || { success: true };
    }

    async syncHoldMediaToPBX() {
        const config = this.getHoldMediaConfig();
        const classes = this.buildDesiredHoldMediaClasses();
        const targetMap = new Map(config.pbxTargets.filter((target) => target.enabled !== false).map((target) => [target.id, target]));
        const results = [];

        for (const target of targetMap.values()) {
            const targetClasses = classes.filter((entry) => entry.targetIds.length === 0 || entry.targetIds.includes(target.id));
            const targetResult = {
                targetId: target.id,
                targetName: target.name,
                apiUrl: target.apiUrl,
                classes: [],
                success: true
            };

            const previousBase = this.config.pbxApiUrl;
            try {
                this.config.pbxApiUrl = target.apiUrl;
                for (const entry of targetClasses) {
                    try {
                        await this.requestFlexPBX('moh.php?path=delete_class', {
                            body: { name: entry.name }
                        });
                    } catch (_) {
                        // Ignore missing class deletes.
                    }

                    const created = await this.requestFlexPBXForm('jellyfin-moh.php?path=add_moh_class', {
                        name: entry.name,
                        type: 'custom',
                        source: entry.streamUrl,
                        description: entry.description
                    });
                    targetResult.classes.push({
                        name: entry.name,
                        sourceType: entry.sourceType,
                        roomId: entry.roomId,
                        streamUrl: entry.streamUrl,
                        success: created?.success !== false
                    });
                }

                if (config.autoReload !== false) {
                    await this.requestFlexPBX('moh.php?path=reload', { body: {} });
                }
            } catch (error) {
                targetResult.success = false;
                targetResult.error = error.message;
            } finally {
                this.config.pbxApiUrl = previousBase;
            }

            results.push(targetResult);
        }

        return {
            success: results.every((result) => result.success !== false),
            syncedAt: Date.now(),
            targets: results,
            classCount: classes.length
        };
    }

    async sendVoiceOTP({ phoneNumber, code, userId = null, extension = null, roomId = null, expiryMinutes = null, displayName = null, prompt = null }) {
        const eligibility = this.canPlaceOtpVoiceCall(phoneNumber);
        if (!eligibility.allowed) {
            throw new Error(eligibility.reason);
        }

        const maxAttempts = Number(this.config?.otpVoice?.maxAttemptsPerHour || 5);
        const normalizedPhone = this.normalizePhoneNumber(phoneNumber);
        if (this.getOtpAttemptCount(normalizedPhone) >= maxAttempts) {
            throw new Error('Voice OTP rate limit reached for this phone number');
        }
        const verificationSessionId = this.createVerificationSessionId();
        const promptPlan = this.buildVerificationPromptPlan({ displayName, code, expiryMinutes });
        this.state.verificationSessions[verificationSessionId] = {
            id: verificationSessionId,
            userId,
            roomId,
            phoneNumber: normalizedPhone,
            phoneHint: this.maskPhoneNumber(normalizedPhone),
            displayName: displayName || null,
            code,
            status: 'pending-entry',
            expiresAt: Date.now() + (Number(expiryMinutes || this.config?.otpVoice?.expiryMinutes || 10) * 60 * 1000),
            createdAt: Date.now(),
            updatedAt: Date.now(),
            supportTicketId: null,
            supportTicketNumber: null,
            supportStatus: null,
            promptPlan
        };
        this.saveState();

        const body = {
            extension: String(extension || this.config?.otpVoice?.fromExtension || this.getDefaultExtension()),
            destination: normalizedPhone,
            prompt: prompt || this.config?.otpVoice?.fallbackPrompt || 'demo-congrats',
            metadata: {
                type: 'voicelink-otp',
                roomId,
                userId,
                codeLength: String(code || '').length,
                verificationSessionId,
                displayName: displayName || null,
                promptPlan
            },
            message: this.buildOtpMessage(code, expiryMinutes, displayName),
            spokenText: promptPlan.spokenText
        };

        const endpoint = `${this.config?.otpVoice?.endpoint || 'textnow-calling.php'}?action=make_call`;
        const payload = await this.requestFlexPBX(endpoint, {
            method: 'POST',
            headers: {
                'X-Extension': body.extension
            },
            body
        });

        const auditEntry = {
            createdAt: Date.now(),
            phoneNumber: normalizedPhone,
            extension: body.extension,
            roomId,
            userId,
            verificationSessionId,
            success: payload?.success !== false,
            provider: 'flexpbx',
            response: payload
        };
        this.recordOtpCall(auditEntry);
        this.updateVerificationSession(verificationSessionId, {
            extension: body.extension,
            provider: payload?.provider || 'flexpbx',
            call: payload
        });

        return {
            success: payload?.success !== false,
            provider: 'flexpbx',
            destination: normalizedPhone,
            extension: body.extension,
            verificationSessionId,
            promptPlan,
            call: payload,
            auditEntry
        };
    }

    markCodeEntered(sessionId, details = {}) {
        const session = this.getVerificationSession(sessionId);
        if (!session) {
            return { success: false, error: 'Verification session not found' };
        }
        return {
            success: true,
            session: this.updateVerificationSession(sessionId, {
                status: details.status || 'code-entered',
                enteredAt: Date.now(),
                completedAt: Date.now()
            })
        };
    }

    async reportWrongPerson(sessionId, details = {}) {
        const session = this.getVerificationSession(sessionId);
        if (!session) {
            return { success: false, error: 'Verification session not found' };
        }
        const ticket = typeof this.config.openSupportTicket === 'function'
            ? await this.config.openSupportTicket({
                userId: session.userId,
                displayName: session.displayName,
                phoneNumber: session.phoneNumber,
                phoneHint: session.phoneHint,
                verificationSessionId: session.id,
                source: 'voice-otp-wrong-person'
            })
            : null;
        const suppression = this.suppressNumber(session.phoneNumber, {
            displayName: session.displayName,
            userId: session.userId,
            supportTicketId: ticket?.ticketId || null,
            supportTicketNumber: ticket?.ticketNumber || null,
            status: ticket?.status || 'suppressed'
        });
        return {
            success: true,
            session: this.updateVerificationSession(sessionId, {
                status: 'wrong-person',
                completedAt: Date.now(),
                supportTicketId: ticket?.ticketId || null,
                supportTicketNumber: ticket?.ticketNumber || null,
                supportStatus: ticket?.status || null
            }),
            supportTicketId: ticket?.ticketId || null,
            supportTicketNumber: ticket?.ticketNumber || null,
            supportStatus: ticket?.status || null,
            suppression
        };
    }
}

module.exports = { VoiceLinkFlexPBXModule };
