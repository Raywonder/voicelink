'use strict';

const DEFAULT_AUDIO_ENGINE = Object.freeze({
    server: 'voicelink-relay',
    abstraction: 'miniaudio-ready',
    primaryCodec: 'opus',
    fallbackCodec: 'pcm-f32',
    sampleRate: 48000,
    channels: 2,
    frameSize: 960,
    audioMode: 'original',
    originalAudio: true,
    noiseSuppression: false,
    echoCancellation: false,
    autoGainControl: false,
    supportsStereo: true,
    supportsOpus: false,
    supportsDynamicProcessing: true,
    supportsBackgroundMedia: true,
    supportsMultiSourceMixing: true,
    miniaudioReady: true
});

const AUDIO_MODES = Object.freeze({
    original: {
        noiseSuppression: false,
        echoCancellation: false,
        autoGainControl: false,
        originalAudio: true
    },
    voiceIsolation: {
        noiseSuppression: true,
        echoCancellation: true,
        autoGainControl: false,
        originalAudio: false
    },
    meeting: {
        noiseSuppression: true,
        echoCancellation: true,
        autoGainControl: true,
        originalAudio: false
    },
    studio: {
        noiseSuppression: false,
        echoCancellation: false,
        autoGainControl: false,
        originalAudio: true
    }
});

function sanitizeNumber(value, fallback, min, max) {
    const parsed = Number(value);
    if (!Number.isFinite(parsed)) return fallback;
    return Math.min(max, Math.max(min, parsed));
}

function normalizeAudioMode(mode) {
    const key = typeof mode === 'string' ? mode.trim() : '';
    return Object.prototype.hasOwnProperty.call(AUDIO_MODES, key) ? key : DEFAULT_AUDIO_ENGINE.audioMode;
}

function buildRelayRegistration(input = {}) {
    const audioMode = normalizeAudioMode(input.audioMode);
    const modeDefaults = AUDIO_MODES[audioMode];
    const codec = typeof input.codec === 'string' && input.codec.trim()
        ? input.codec.trim()
        : DEFAULT_AUDIO_ENGINE.fallbackCodec;
    const preferredCodec = typeof input.preferredCodec === 'string' && input.preferredCodec.trim()
        ? input.preferredCodec.trim()
        : DEFAULT_AUDIO_ENGINE.primaryCodec;

    return {
        enabled: input.enabled !== false,
        sampleRate: sanitizeNumber(input.sampleRate, DEFAULT_AUDIO_ENGINE.sampleRate, 8000, 192000),
        channels: sanitizeNumber(input.channels, DEFAULT_AUDIO_ENGINE.channels, 1, 8),
        frameSize: sanitizeNumber(input.frameSize, DEFAULT_AUDIO_ENGINE.frameSize, 120, 4096),
        codec,
        preferredCodec,
        engine: typeof input.engine === 'string' && input.engine.trim()
            ? input.engine.trim()
            : DEFAULT_AUDIO_ENGINE.abstraction,
        audioMode,
        originalAudio: input.originalAudio ?? modeDefaults.originalAudio,
        noiseSuppression: input.noiseSuppression ?? modeDefaults.noiseSuppression,
        echoCancellation: input.echoCancellation ?? modeDefaults.echoCancellation,
        autoGainControl: input.autoGainControl ?? modeDefaults.autoGainControl,
        supportsStereo: input.supportsStereo !== false,
        supportsOpus: input.supportsOpus === true,
        supportsDynamicProcessing: input.supportsDynamicProcessing !== false,
        supportsBackgroundMedia: input.supportsBackgroundMedia !== false,
        supportsMultiSourceMixing: input.supportsMultiSourceMixing !== false
    };
}

function buildRelayStatus(registration = {}) {
    const normalized = buildRelayRegistration(registration);
    return {
        ...DEFAULT_AUDIO_ENGINE,
        sampleRate: normalized.sampleRate,
        channels: normalized.channels,
        frameSize: normalized.frameSize,
        fallbackCodec: normalized.codec,
        primaryCodec: normalized.preferredCodec,
        audioMode: normalized.audioMode,
        originalAudio: normalized.originalAudio,
        noiseSuppression: normalized.noiseSuppression,
        echoCancellation: normalized.echoCancellation,
        autoGainControl: normalized.autoGainControl,
        supportsStereo: normalized.supportsStereo,
        supportsOpus: normalized.supportsOpus,
        supportsDynamicProcessing: normalized.supportsDynamicProcessing,
        supportsBackgroundMedia: normalized.supportsBackgroundMedia,
        supportsMultiSourceMixing: normalized.supportsMultiSourceMixing
    };
}

module.exports = {
    DEFAULT_AUDIO_ENGINE,
    AUDIO_MODES,
    normalizeAudioMode,
    buildRelayRegistration,
    buildRelayStatus
};
