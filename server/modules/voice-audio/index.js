'use strict';

const crypto = require('crypto');
const fs = require('fs');
const { spawn } = require('child_process');

const API_PREFIX = '/api/internal/audio';
const SUPPORTED_TTS_FORMATS = new Set(['wav', 'pcm_s16le']);

function booleanValue(value, fallback = false) {
    if (value === undefined || value === null || value === '') return fallback;
    return ['1', 'true', 'yes', 'on'].includes(String(value).trim().toLowerCase());
}

function boundedInteger(value, fallback, minimum, maximum) {
    const parsed = Number.parseInt(value, 10);
    if (!Number.isFinite(parsed)) return fallback;
    return Math.min(maximum, Math.max(minimum, parsed));
}

function callerSet(value) {
    return new Set(String(value || '').split(',').map((item) => item.trim()).filter(Boolean));
}

function requestId() {
    return typeof crypto.randomUUID === 'function'
        ? crypto.randomUUID()
        : crypto.randomBytes(16).toString('hex');
}

class VoiceAudioModule {
    constructor(env = process.env, logger = console, dependencies = {}) {
        this.env = env;
        this.logger = logger;
        this.accessSync = dependencies.accessSync || fs.accessSync;
        this.spawn = dependencies.spawn || spawn;
        this.localTtsRunner = dependencies.localTtsRunner || ((text) => this.spawnLocalTts(text));
        this.config = {
            enabled: booleanValue(env.VOICELINK_AUDIO_ENABLED, true),
            token: String(env.VOICELINK_AUDIO_INTERNAL_TOKEN || ''),
            allowedCallers: callerSet(env.VOICELINK_AUDIO_ALLOWED_CALLERS),
            maxTextChars: boundedInteger(env.VOICELINK_AUDIO_MAX_TEXT_CHARS, 4000, 1, 16000),
            maxAudioBytes: boundedInteger(env.VOICELINK_AUDIO_MAX_AUDIO_BYTES, 8 * 1024 * 1024, 1024, 32 * 1024 * 1024),
            requestsPerMinute: boundedInteger(env.VOICELINK_AUDIO_REQUESTS_PER_MINUTE, 60, 1, 600),
            ttsFallbackOrder: Array.from(callerSet(env.VOICELINK_AUDIO_TTS_FALLBACK_ORDER || 'elevenlabs,openai,local')),
            sttFallbackOrder: Array.from(callerSet(env.VOICELINK_AUDIO_STT_FALLBACK_ORDER || 'elevenlabs,openai,local')),
            ttsProvider: String(env.VOICELINK_AUDIO_TTS_PROVIDER || 'none').trim().toLowerCase(),
            sttProvider: String(env.VOICELINK_AUDIO_STT_PROVIDER || 'none').trim().toLowerCase(),
            localHelper: String(env.VOICELINK_AUDIO_LOCAL_HELPER || '/usr/local/libexec/voicelink-audio-helper').trim()
        };
        this.requestWindows = new Map();
    }

    localTtsReady() {
        if (this.config.ttsProvider !== 'local' || !this.config.localHelper) return false;
        try {
            this.accessSync(this.config.localHelper, fs.constants.X_OK);
            return true;
        } catch (_error) {
            return false;
        }
    }

    providerState(operation) {
        const providers = operation === 'tts' ? this.config.ttsFallbackOrder : this.config.sttFallbackOrder;
        const readyProvider = operation === 'tts' && providers.includes('local') && this.localTtsReady()
            ? 'local'
            : null;
        return {
            providers,
            readyProvider,
            ready: Boolean(readyProvider),
            state: readyProvider ? 'ready' : (providers.length ? 'no_validated_adapter' : 'no_candidates_configured')
        };
    }

    health() {
        const operations = { tts: this.providerState('tts'), stt: this.providerState('stt') };
        return {
            service: 'voicelink-audio',
            version: 'v1',
            status: this.config.enabled ? (operations.tts.ready || operations.stt.ready ? 'ready' : 'degraded') : 'disabled',
            textFallback: true,
            authenticatedCallersConfigured: Boolean(this.config.token && this.config.allowedCallers.size),
            operations
        };
    }

    install(app) {
        const express = require('express');
        app.get(API_PREFIX + '/health', (req, res) => this.handleHealth(req, res));
        app.post(API_PREFIX + '/tts', express.json({ type: 'application/json', limit: '64kb' }), (req, res) => this.handleTts(req, res));
        app.post(API_PREFIX + '/stt', express.raw({
            type: ['audio/wav', 'audio/pcm', 'application/octet-stream'],
            limit: this.config.maxAudioBytes
        }), (req, res) => this.handleStt(req, res));
    }

    safeLog(event, details = {}) {
        this.logger.info(JSON.stringify({ event, service: 'voicelink-audio', timestamp: new Date().toISOString(), ...details }));
    }

    readCaller(req) {
        const caller = req && req.headers ? req.headers['x-voicelink-caller'] : '';
        return typeof caller === 'string' ? caller.trim() : '';
    }

    tokenMatches(req) {
        const header = req && req.headers ? req.headers.authorization : '';
        const supplied = typeof header === 'string' && header.startsWith('Bearer ') ? header.slice(7) : '';
        if (!supplied || !this.config.token) return false;
        const expectedBuffer = Buffer.from(this.config.token);
        const suppliedBuffer = Buffer.from(supplied);
        return expectedBuffer.length === suppliedBuffer.length && crypto.timingSafeEqual(expectedBuffer, suppliedBuffer);
    }

    authorize(req, operation, id) {
        if (!this.config.enabled) return { ok: false, status: 503, code: 'audio_service_disabled' };
        if (!this.config.token || this.config.allowedCallers.size === 0) return { ok: false, status: 503, code: 'audio_auth_not_configured' };
        const caller = this.readCaller(req);
        if (!this.tokenMatches(req) || !caller || !this.config.allowedCallers.has(caller)) {
            this.safeLog('voice_audio.authorization.denied', { requestId: id, operation, caller: caller || 'unknown' });
            return { ok: false, status: 401, code: 'unauthorized' };
        }
        if (!this.consumeRateLimit(caller)) {
            this.safeLog('voice_audio.rate_limited', { requestId: id, operation, caller });
            return { ok: false, status: 429, code: 'rate_limited', caller };
        }
        return { ok: true, caller };
    }

    consumeRateLimit(caller) {
        const now = Date.now();
        const timestamps = (this.requestWindows.get(caller) || []).filter((item) => item >= now - 60000);
        if (timestamps.length >= this.config.requestsPerMinute) {
            this.requestWindows.set(caller, timestamps);
            return false;
        }
        timestamps.push(now);
        this.requestWindows.set(caller, timestamps);
        return true;
    }

    failure(res, id, operation, status, code) {
        res.status(status).json({ error: code, operation, requestId: id, textFallback: true });
    }

    unavailable(res, id, operation, caller) {
        const state = this.providerState(operation);
        this.safeLog('voice_audio.provider.unavailable', { requestId: id, operation, caller, state: state.state });
        this.failure(res, id, operation, 503, 'audio_provider_unavailable');
    }

    spawnLocalTts(text) {
        return new Promise((resolve, reject) => {
            const child = this.spawn(this.config.localHelper, ['tts'], {
                stdio: ['pipe', 'pipe', 'pipe']
            });
            const chunks = [];
            let bytes = 0;
            let settled = false;
            const finish = (error, value) => {
                if (settled) return;
                settled = true;
                if (error) reject(error);
                else resolve(value);
            };
            child.once('error', (error) => finish(error));
            child.stdout.on('data', (chunk) => {
                bytes += chunk.length;
                if (bytes > this.config.maxAudioBytes) {
                    child.kill();
                    return finish(new Error('local_tts_output_too_large'));
                }
                chunks.push(chunk);
            });
            child.stderr.resume();
            child.once('close', (code) => {
                if (code !== 0) return finish(new Error('local_tts_failed'));
                const audio = Buffer.concat(chunks);
                if (!audio.length) return finish(new Error('local_tts_empty'));
                return finish(null, audio);
            });
            child.stdin.end(text);
        });
    }

    pcmToWav(pcm, sampleRate = 48000, channels = 1, bitsPerSample = 16) {
        const header = Buffer.alloc(44);
        const byteRate = sampleRate * channels * bitsPerSample / 8;
        const blockAlign = channels * bitsPerSample / 8;
        header.write('RIFF', 0);
        header.writeUInt32LE(36 + pcm.length, 4);
        header.write('WAVE', 8);
        header.write('fmt ', 12);
        header.writeUInt32LE(16, 16);
        header.writeUInt16LE(1, 20);
        header.writeUInt16LE(channels, 22);
        header.writeUInt32LE(sampleRate, 24);
        header.writeUInt32LE(byteRate, 28);
        header.writeUInt16LE(blockAlign, 32);
        header.writeUInt16LE(bitsPerSample, 34);
        header.write('data', 36);
        header.writeUInt32LE(pcm.length, 40);
        return Buffer.concat([header, pcm]);
    }

    handleHealth(req, res) {
        const id = requestId();
        const authorization = this.authorize(req, 'health', id);
        if (!authorization.ok) return this.failure(res, id, 'health', authorization.status, authorization.code);
        return res.status(200).json(this.health());
    }

    async handleTts(req, res) {
        const id = requestId();
        const authorization = this.authorize(req, 'tts', id);
        if (!authorization.ok) return this.failure(res, id, 'tts', authorization.status, authorization.code);
        const text = req && req.body ? req.body.text : '';
        const format = req && req.body && req.body.format ? String(req.body.format) : 'wav';
        if (typeof text !== 'string' || !text.trim()) return this.failure(res, id, 'tts', 400, 'text_required');
        if (text.length > this.config.maxTextChars) return this.failure(res, id, 'tts', 413, 'text_too_large');
        if (!SUPPORTED_TTS_FORMATS.has(format)) return this.failure(res, id, 'tts', 400, 'unsupported_audio_format');
        const state = this.providerState('tts');
        if (!state.ready || state.readyProvider !== 'local') {
            return this.unavailable(res, id, 'tts', authorization.caller);
        }
        try {
            const pcm = await this.localTtsRunner(text);
            const audio = format === 'wav' ? this.pcmToWav(pcm) : pcm;
            res.set({
                'Content-Type': format === 'wav' ? 'audio/wav' : 'audio/L16; rate=48000; channels=1',
                'X-VoiceLink-Audio-Provider': 'local'
            });
            this.safeLog('voice_audio.provider.success', {
                requestId: id,
                operation: 'tts',
                caller: authorization.caller,
                provider: 'local'
            });
            return res.status(200).send(audio);
        } catch (_error) {
            this.safeLog('voice_audio.provider.failed', {
                requestId: id,
                operation: 'tts',
                caller: authorization.caller,
                provider: 'local'
            });
            return this.unavailable(res, id, 'tts', authorization.caller);
        }
    }

    handleStt(req, res) {
        const id = requestId();
        const authorization = this.authorize(req, 'stt', id);
        if (!authorization.ok) return this.failure(res, id, 'stt', authorization.status, authorization.code);
        if (!Buffer.isBuffer(req && req.body) || req.body.length === 0) return this.failure(res, id, 'stt', 400, 'audio_required');
        if (req.body.length > this.config.maxAudioBytes) return this.failure(res, id, 'stt', 413, 'audio_too_large');
        return this.unavailable(res, id, 'stt', authorization.caller);
    }
}

module.exports = { VoiceAudioModule, API_PREFIX };
