'use strict';

const crypto = require('crypto');

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
    constructor(env = process.env, logger = console) {
        this.env = env;
        this.logger = logger;
        this.config = {
            enabled: booleanValue(env.VOICELINK_AUDIO_ENABLED, true),
            token: String(env.VOICELINK_AUDIO_INTERNAL_TOKEN || ''),
            allowedCallers: callerSet(env.VOICELINK_AUDIO_ALLOWED_CALLERS),
            maxTextChars: boundedInteger(env.VOICELINK_AUDIO_MAX_TEXT_CHARS, 4000, 1, 16000),
            maxAudioBytes: boundedInteger(env.VOICELINK_AUDIO_MAX_AUDIO_BYTES, 8 * 1024 * 1024, 1024, 32 * 1024 * 1024),
            requestsPerMinute: boundedInteger(env.VOICELINK_AUDIO_REQUESTS_PER_MINUTE, 60, 1, 600),
            ttsFallbackOrder: Array.from(callerSet(env.VOICELINK_AUDIO_TTS_FALLBACK_ORDER || 'elevenlabs,openai,local')),
            sttFallbackOrder: Array.from(callerSet(env.VOICELINK_AUDIO_STT_FALLBACK_ORDER || 'elevenlabs,openai,local'))
        };
        this.requestWindows = new Map();
    }

    providerState(operation) {
        const providers = operation === 'tts' ? this.config.ttsFallbackOrder : this.config.sttFallbackOrder;
        return { providers, readyProvider: null, ready: false, state: providers.length ? 'no_validated_adapter' : 'no_candidates_configured' };
    }

    health() {
        return {
            service: 'voicelink-audio',
            version: 'v1',
            status: this.config.enabled ? 'degraded' : 'disabled',
            textFallback: true,
            authenticatedCallersConfigured: Boolean(this.config.token && this.config.allowedCallers.size),
            operations: { tts: this.providerState('tts'), stt: this.providerState('stt') }
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

    handleHealth(req, res) {
        const id = requestId();
        const authorization = this.authorize(req, 'health', id);
        if (!authorization.ok) return this.failure(res, id, 'health', authorization.status, authorization.code);
        return res.status(200).json(this.health());
    }

    handleTts(req, res) {
        const id = requestId();
        const authorization = this.authorize(req, 'tts', id);
        if (!authorization.ok) return this.failure(res, id, 'tts', authorization.status, authorization.code);
        const text = req && req.body ? req.body.text : '';
        const format = req && req.body && req.body.format ? String(req.body.format) : 'wav';
        if (typeof text !== 'string' || !text.trim()) return this.failure(res, id, 'tts', 400, 'text_required');
        if (text.length > this.config.maxTextChars) return this.failure(res, id, 'tts', 413, 'text_too_large');
        if (!SUPPORTED_TTS_FORMATS.has(format)) return this.failure(res, id, 'tts', 400, 'unsupported_audio_format');
        return this.unavailable(res, id, 'tts', authorization.caller);
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
