# VoiceLink Installatron + Licensing Integration

## Scope
Installatron is treated as a managed deployment lifecycle around the existing
VoiceLink browser UI and server bundle.

## What VoiceLink Packages
- `installatron/voicelink/install.xml`
- `installatron/voicelink/upgrade.xml`
- `installatron/voicelink/uninstall.xml`
- post-install/post-upgrade/post-clone hooks
- `.well-known/voicelink.json` install metadata, while preserving
  `.well-known/acme-challenge`

## Runtime Behavior
- Side-by-side install is preferred; existing webroots are preserved.
- WHMCS remains the license authority when configured.
- Installatron metadata is reported into `site-integration-report.json`.
- Browser UI and desktop admin UI should read the same install/license state.

## Desktop Admin Behavior
- Use `Installatron` as the deployment site type when the target host/path is
  an Installatron-managed app location.
- Auto-detect can infer Installatron from `installatron`, `install.xml`, or
  `.well-known/voicelink.json`.
- Manual override remains available when auto-detection is wrong.

## API and Browser UI
The browser and desktop admin clients should align on:
- `GET /api/install/status`
- `POST /api/install/register`
- `POST /api/install/validate-license`
- `POST /api/install/reissue-request`
- `GET /.well-known/voicelink.json`
