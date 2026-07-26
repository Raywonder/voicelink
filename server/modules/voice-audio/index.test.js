'use strict';

const assert = require('assert');
const { VoiceAudioModule } = require('./index');

function response() {
    return {
        statusCode: 200,
        body: null,
        headers: {},
        status(code) { this.statusCode = code; return this; },
        json(body) { this.body = body; return this; },
        set(headers) { Object.assign(this.headers, headers); return this; },
        send(body) { this.body = body; return this; }
    };
}

function request({ token, caller, body = {} } = {}) {
    return { headers: { authorization: token ? 'Bearer ' + token : '', 'x-voicelink-caller': caller || '' }, body };
}

const silentLogger = { info() {} };

async function run() {
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
    service.handleHealth(request({ caller: 'clawdia-teamtalk' }), res);
    assert.strictEqual(res.statusCode, 401);
    assert.strictEqual(res.body.textFallback, true);

    res = response();
    service.handleHealth(request({ token: 'unit-test-token', caller: 'clawdia-teamtalk' }), res);
    assert.strictEqual(res.statusCode, 200);
    assert.strictEqual(res.body.status, 'degraded');
    assert.strictEqual(res.body.operations.tts.ready, false);

    res = response();
    await service.handleTts(request({ caller: 'clawdia-teamtalk', body: { text: 'hello' } }), res);
    assert.strictEqual(res.statusCode, 401);

    res = response();
    await service.handleTts(request({
        token: 'unit-test-token',
        caller: 'clawdia-teamtalk',
        body: { text: 'hello', format: 'wav' }
    }), res);
    assert.strictEqual(res.statusCode, 503);
    assert.strictEqual(res.body.textFallback, true);

    const readyService = new VoiceAudioModule({
        VOICELINK_AUDIO_ENABLED: 'true',
        VOICELINK_AUDIO_INTERNAL_TOKEN: 'unit-test-token',
        VOICELINK_AUDIO_ALLOWED_CALLERS: 'clawdia-teamtalk',
        VOICELINK_AUDIO_TTS_PROVIDER: 'local'
    }, silentLogger, {
        accessSync() {},
        async localTtsRunner() { return Buffer.from([0, 0, 1, 0]); }
    });

    res = response();
    readyService.handleHealth(request({ token: 'unit-test-token', caller: 'clawdia-teamtalk' }), res);
    assert.strictEqual(res.body.status, 'ready');
    assert.strictEqual(res.body.operations.tts.readyProvider, 'local');

    res = response();
    await readyService.handleTts(request({
        token: 'unit-test-token',
        caller: 'clawdia-teamtalk',
        body: { text: 'hello', format: 'wav' }
    }), res);
    assert.strictEqual(res.statusCode, 200);
    assert.strictEqual(res.headers['Content-Type'], 'audio/wav');
    assert.strictEqual(res.body.subarray(0, 4).toString(), 'RIFF');

    const failingService = new VoiceAudioModule({
        VOICELINK_AUDIO_ENABLED: 'true',
        VOICELINK_AUDIO_INTERNAL_TOKEN: 'unit-test-token',
        VOICELINK_AUDIO_ALLOWED_CALLERS: 'clawdia-teamtalk',
        VOICELINK_AUDIO_TTS_PROVIDER: 'local'
    }, silentLogger, {
        accessSync() {},
        async localTtsRunner() { throw new Error('provider failed'); }
    });
    res = response();
    await failingService.handleTts(request({
        token: 'unit-test-token',
        caller: 'clawdia-teamtalk',
        body: { text: 'hello', format: 'pcm_s16le' }
    }), res);
    assert.strictEqual(res.statusCode, 503);
    assert.strictEqual(res.body.textFallback, true);

    res = response();
    service.handleStt({
        headers: { authorization: 'Bearer unit-test-token', 'x-voicelink-caller': 'clawdia-teamtalk' },
        body: Buffer.from([1, 2, 3])
    }, res);
    assert.strictEqual(res.statusCode, 503);

    console.log('voice-audio module tests passed');
}

run().catch((error) => {
    console.error(error);
    process.exitCode = 1;
});
