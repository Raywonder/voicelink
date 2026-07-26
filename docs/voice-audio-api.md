# VoiceLink Audio API (internal contract)

VoiceLink Audio is a shared server-side interface for speech output (TTS) and speech input (STT). It is intended for approved first-party callers such as the Claudia TeamTalk bridge. It does not create a provider account, send external messages, or expose credentials to clients.

## Current state

The authenticated API is enabled by default. No TTS or STT adapter has been installed in VoiceLink yet. Its ordered candidates are ElevenLabs, OpenAI, and a future local VoiceLink engine for both TTS and STT. A configured candidate name is not treated as available: health reports no_validated_adapter and requests return a clear 503 with textFallback true.

This is deliberate. The TeamTalk bridge must continue with text-only output rather than claim that voice was produced.

## Configuration

Copy the names in [`server/modules/voice-audio/.env.example`](../server/modules/voice-audio/.env.example) into the approved server-side secret/configuration store. Do not commit the real internal token, provider credentials, provider URLs, transcripts, or audio.

Request authorization requires:

- `VOICELINK_AUDIO_ENABLED=true`
- a high-entropy `VOICELINK_AUDIO_INTERNAL_TOKEN` in the approved secret store
- an explicit caller allowlist such as `clawdia-teamtalk`
- explicit TTS and STT fallback orders

The API can be disabled with VOICELINK_AUDIO_ENABLED=false. A reviewed adapter still must pass readiness validation before it is selected.

## Endpoints

All endpoints are private service endpoints and must be network-restricted by the deployment proxy or service mesh. Clients send:

    Authorization: Bearer <server-side internal token>
    X-VoiceLink-Caller: clawdia-teamtalk

| Endpoint | Body | Result today |
| --- | --- | --- |
| `GET /api/internal/audio/health` | none | Safe readiness status; no URLs, secrets, text, or audio. |
| `POST /api/internal/audio/tts` | JSON: `text`, optional `format` (`wav` or `pcm_s16le`) | Validates then returns `503 audio_provider_unavailable` and `textFallback: true` until a TTS adapter is installed. |
| `POST /api/internal/audio/stt` | Raw `audio/wav`, `audio/pcm`, or `application/octet-stream` | Validates then returns `503 audio_provider_unavailable` and `textFallback: true` until an STT adapter is installed. |

Audio is bounded by `VOICELINK_AUDIO_MAX_AUDIO_BYTES`; TTS text is bounded by `VOICELINK_AUDIO_MAX_TEXT_CHARS`. Each authorized caller has an in-memory per-minute request limit. The first adapter must document sample rate/channel format and produce either WAV or signed 16-bit PCM.

## Provider and fallback policy

For the Claudia TeamTalk bridge:

1. Use the ordered healthy engine for the requested operation; initial order is ElevenLabs, OpenAI, then local VoiceLink.
2. On an actionable engine failure, select the next engine only when authenticated health says it is ready.
3. If VoiceLink Audio is disabled, degraded, unavailable, or returns an error, deliver text only.

No provider error, access token, request text, transcript, or audio is logged by this module. Logs contain only event name, timestamp, operation, caller identity, request correlation ID, and safe provider state.

## Adapter implementation checklist

Before an adapter is added:

1. Confirm the provider/runtime is owned and approved in the target account.
2. Keep credentials exclusively in the approved server-side secret store.
3. Add provider readiness, timeout, cancellation, and bounded retries.
4. Return WAV or PCM with declared sample rate/channel count.
5. Add tests for failures, malformed audio, authorization, limits, and text-only degradation.
6. Update recovery documentation without secrets.
7. Test outside production before changing the stopped TeamTalk bridge; back up and restart only that bridge.

## Operations and recovery

`GET /api/internal/audio/health` is safe for internal monitoring. It should remain `disabled` or `degraded` until a reviewed adapter and server-side configuration are present. Do not restart the TeamTalk bridge merely because this module is deployed.

The module intentionally has no outbound provider code yet. That avoids creating paid-provider usage or a misleading fallback during the current ElevenLabs funding failure.
