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

The first enabled provider is the account-local Piper TTS helper:

- provider: `local`
- executable: `/usr/local/libexec/voicelink-audio-helper`
- voice runtime: `/usr/local/bin/piper`
- output: 48 kHz mono signed 16-bit PCM, optionally wrapped as WAV
- cost and external account: none

No external TTS or STT provider is enabled. ElevenLabs and OpenAI remain
disabled candidates. Provider-specific credentials must not be added until the
provider and owning account are approved and the adapter passes readiness
tests.

## Safe fallback and verification

Authenticated health must return HTTP 200 with `textFallback: true`. With the
local helper installed, health reports `ready`, TTS reports provider `local`,
and STT remains unavailable through this API. If Piper or its helper fails,
TTS returns HTTP 503 with `textFallback: true`.

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

## Active runtimes

The module and local TTS adapter are deployed to:

- main: `voicelinkapp.app-main`, port `3010`
- community: `community.voicelinkapp.app-community`, port `3110`
- dev: `voicelink.dev-dev`, port `3210`

The July 26 TTS rollout backups are under each runtime's `.backups` directory
as `voice-audio-tts-20260726T124728Z`.

Each runtime passed authenticated health, real WAV generation, unauthorized
health rejection, and module tests. A two-client Socket.IO test also confirmed
live message delivery, room-history retrieval, and the iOS message payload on
all three runtimes.

## iOS validation

Commit `8cb769b` built and launched on the already-booted `VoiceLink Dev iPhone`
simulator on `admin-s-mac-mini.tailnet.raywonderis.me`. The simulator initially
retained the obsolete `https://dev.voicelinkapp.app` preference; changing that
test-only preference to `https://voicelinkapp.app` restored server-directory
loading.

The remaining manual prerequisite is a physical iPhone or iPad check that
joins a room, sends and receives a message, verifies history after reconnect,
and confirms VoiceOver announcements and focus order.

Build 102 additionally repairs the half-joined iOS state when an already-active
room session is reopened, loads all configured iOS servers in parallel, and
opens administration for the selected server after checking that server's
permissions. The physical-device prerequisite is now to install build 102 and
confirm the current user and other participants appear before testing speech
and room audio.
