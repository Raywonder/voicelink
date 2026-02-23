# VoiceLink Update Notes

## 2026-02-23 (Build 20)

### Desktop App (Native macOS)

- Updated startup audio flow to prevent default system fallback sound at app launch.
- Added background sound asset download notices so users can continue using rooms while sounds sync.
- Added pending-download reminder behavior for next launch when critical sounds are still missing.
- Added built-in self-test scheduler for desktop feature checks and API health checks.
- Added admin management UI for self-tests (enable/disable scheduler, run now, check toggles, history).
- Added admin fallback on login for `datboydommo@layor8.space`.

### Packaging and Update Metadata

- Rebuilt universal native macOS app binary (arm64 + x86_64).
- Repacked release ZIP artifacts:
  - `swift-native/VoiceLinkNative/VoiceLinkMacOS.zip`
  - `swift-native/VoiceLinkNative/VoiceLink-macOS.zip`
- Updated checksum sidecars:
  - `swift-native/VoiceLinkNative/VoiceLinkMacOS.zip.sha256`
  - `swift-native/VoiceLinkNative/VoiceLink-macOS.zip.sha256`
- Updated updater manifests with refreshed `sha512`, `size`, and `releaseDate`:
  - `swift-native/VoiceLinkNative/latest-mac.yml`
  - `swift-native/VoiceLinkNative/latest-mac.server.yml`
- Kept `copyPartyURL` pointed directly at `.zip` artifact URL.

## 2026-02-11

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
