'use strict';

const assert = require('assert');
const {
    buildRelayRegistration,
    buildRelayStatus,
    normalizeAudioMode
} = require('../server/modules/audio-engine');

assert.strictEqual(normalizeAudioMode('original'), 'original');
assert.strictEqual(normalizeAudioMode('not-a-mode'), 'original');

const registration = buildRelayRegistration({});
assert.strictEqual(registration.sampleRate, 48000);
assert.strictEqual(registration.channels, 2);
assert.strictEqual(registration.preferredCodec, 'opus');
assert.strictEqual(registration.codec, 'pcm-f32');
assert.strictEqual(registration.supportsOpus, true);
assert.strictEqual(registration.originalAudio, true);
assert.strictEqual(registration.noiseSuppression, false);

const status = buildRelayStatus({
    audioMode: 'meeting',
    sampleRate: 44100,
    channels: 1,
    frameSize: 480,
    jitterBufferMs: 120,
    codec: 'pcm-s16',
    preferredCodec: 'opus'
});

assert.strictEqual(status.sampleRate, 44100);
assert.strictEqual(status.channels, 1);
assert.strictEqual(status.frameSize, 480);
assert.strictEqual(status.jitterBufferMs, 120);
assert.strictEqual(status.primaryCodec, 'opus');
assert.strictEqual(status.fallbackCodec, 'pcm-s16');
assert.strictEqual(status.audioMode, 'meeting');
assert.strictEqual(status.noiseSuppression, true);
assert.strictEqual(status.echoCancellation, true);
assert.strictEqual(status.autoGainControl, true);

console.log('Audio engine defaults and relay status checks passed.');
