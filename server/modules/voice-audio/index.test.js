'use strict';

const assert = require('assert');
const { VoiceAudioModule } = require('./index');

function response() {
    return {
        statusCode: 200,
        body: null,
        status(code) { this.statusCode = code; return this; },
        json(body) { this.body = body; return this; }
    };
}

function request({ token, caller, body = {} } = {}) {
    return { headers: { authorization: token ? 'Bearer ' + token : '', 'x-voicelink-caller': caller || '' }, body };
}

const silentLogger = { info() {} };
const disabled = new VoiceAudioModule({ VOICELINK_AUDIO_ENABLED: 'false' }, silentLogger);
assert.strictEqual(disabled.health().status, 'disabled');
const defaults = new VoiceAudioModule({}, silentLogger);
assert.deepStrictEqual(defaults.health().operations.tts.providers, ['elevenlabs', 'openai', 'local']);

const service = new VoiceAudioModule({
    VOICELINK_AUDIO_ENABLED: 'true',
    VOICELINK_AUDIO_INTERNAL_TOKEN: 'unit-test-token',
    VOICELINK_AUDIO_ALLOWED_CALLERS: 'clawdia-teamtalk'
}, silentLogger);

let res = response();
service.handleTts(request({ caller: 'clawdia-teamtalk', body: { text: 'hello' } }), res);
assert.strictEqual(res.statusCode, 401);
assert.strictEqual(res.body.error, 'unauthorized');

res = response();
service.handleTts(request({ token: 'unit-test-token', caller: 'clawdia-teamtalk', body: { text: 'hello', format: 'wav' } }), res);
assert.strictEqual(res.statusCode, 503);
assert.strictEqual(res.body.error, 'audio_provider_unavailable');
assert.strictEqual(res.body.textFallback, true);

res = response();
service.handleTts(request({ token: 'unit-test-token', caller: 'clawdia-teamtalk', body: { text: '', format: 'wav' } }), res);
assert.strictEqual(res.statusCode, 400);
assert.strictEqual(res.body.error, 'text_required');

res = response();
service.handleStt({
    headers: { authorization: 'Bearer unit-test-token', 'x-voicelink-caller': 'clawdia-teamtalk' },
    body: Buffer.from([1, 2, 3])
}, res);
assert.strictEqual(res.statusCode, 503);
assert.strictEqual(res.body.operation, 'stt');

console.log('voice-audio module tests passed');
