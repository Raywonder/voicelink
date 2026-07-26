# Clawdia TeamTalk VoiceLink Audio deployment

## Ownership and runtime

- Platform owner: VoiceLink / TappedIn, managed by Devine Creations.
- Host: `dvc.raywonderis.me` (`100.64.0.2` on the approved mesh).
- VoiceLink account: `voicelink`.
- VoiceLink runtime: `/home/voicelink/apps/voicelink/main/voicelinkapp.app`.
- Supervisor: `pm2-voicelink.service`.
- PM2 process: `voicelinkapp.app-main`.
- Internal API: `http://127.0.0.1:3010/api/internal/audio`.
- TeamTalk bridge account: `tappedin`.
- TeamTalk bridge source: `/home/tappedin/.openclaw/workspace/scripts/teamtalk_elevenlabs_realtime_bridge.py`.
- Discovery probe: `/home/tappedin/.openclaw/workspace/scripts/voicelink_audio_health.py`.
- Caller identity: `clawdia-teamtalk`.

The API is loopback-only for this integration. There is no public webhook or
callback URL.

## Credentials and providers

The shared internal bearer token is stored separately for each owning account:

- `/home/voicelink/.config/voicelink-audio/runtime.env`
- `/home/tappedin/.config/voicelink-audio/bridge.env`

Both files are mode `0600`. Never copy their values into Git, tickets, logs, or
chat.

No external TTS or STT provider is enabled. ElevenLabs, OpenAI, and a future
local adapter are ordered candidates only. Provider account email, cost, 2FA,
and business verification are therefore not applicable yet. Provider-specific
credentials must not be added until the provider and owning account are
approved and the adapter passes readiness tests.

## Safe fallback and verification

Authenticated health must return HTTP 200 with `textFallback: true`. Until a
validated adapter exists, health reports `degraded` and both operations report
`ready: false`. The bridge discovery probe then returns `textOnly: true`.

An unauthenticated health request must return HTTP 401.

Run the bridge probe without printing its token:

```sh
sudo -u tappedin sh -c '
  set -a
  . /home/tappedin/.config/voicelink-audio/bridge.env
  set +a
  python3 /home/tappedin/.openclaw/workspace/scripts/voicelink_audio_health.py
'
```

## Recovery

The initial production backup is:

`/home/voicelink/apps/voicelink/main/voicelinkapp.app/.backups/voice-audio-20260726T111935Z`

To roll back, restore `local-server.js` from that directory, remove the
`server/modules/voice-audio` directory if it did not previously exist, and
restart only `voicelinkapp.app-main`. Do not restart the TeamTalk bridge merely
because VoiceLink Audio is degraded.

The next manual prerequisite is approval and implementation of one real audio
adapter, including its provider ownership, credential storage, audio format,
timeouts, retries, and failure tests. Until then, text-only behavior is the
supported API outcome.
