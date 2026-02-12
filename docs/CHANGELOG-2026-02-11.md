# VoiceLink Update Notes (2026-02-11)

## Desktop App

- Moved `Check for Updates...` to the app menu area (near File-level app commands).
- Added Jellyfin/media event handling updates so announcements use media title wording:
  - "`<Media Name>` started"
  - "`<Media Name>` stopped"
- Added video playback controls in desktop now-playing for video media:
  - Show video window
  - Minimize video window
  - Toggle full screen

## Server API

- Added Jellyfin webhook ingestion endpoint:
  - `POST /api/jellyfin/webhook`
  - Broadcasts `jellyfin-webhook-event` to connected clients.
- Added direct HTTPS URL media streaming API:
  - `POST /api/jellyfin/direct-url/stream`
  - Target modes:
    - `self` (single user client)
    - `room` (broadcast to room)
- Added admin-configurable direct URL media controls:
  - `GET /api/jellyfin/direct-url/config`
  - `PUT /api/jellyfin/direct-url/config`
  - Controls:
    - enable/disable direct URL streaming
    - enable/disable media save
    - storage path for saved media

## Web Client Download UX

- Updated desktop app download links to ZIP-only macOS artifact:
  - `https://voicelink.devinecreations.net/downloads/voicelink/VoiceLinkMacOS.zip`
- Removed Windows download buttons from the main web client index view for this release channel.

## Packaging + Update Metadata

- Standardized release artifact name for this channel:
  - `VoiceLinkMacOS.zip`
- Updater manifest remains under:
  - `swift-native/VoiceLinkNative/latest-mac.yml`
