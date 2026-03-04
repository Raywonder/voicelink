# VoiceLink Distribution Channels

## Direct Channel
- Desktop downloads from `voicelink.devinecreations.net`.
- Uses updater manifests for direct installs.
- Linux direct artifacts include:
  - `VoiceLink-linux.AppImage`
  - `voicelink-local_1.0.0_amd64.deb`

## Store Channels
- App Store/other store channels must disable self-updater.
- Store builds should follow governance store restrictions.

## Server Channel
- Linux server install via:
  - `installer/install.sh` (native)
  - `installer/docker-compose.server.yml` (container)

## Public Discovery
- Servers may register through federation/discovery endpoints.
- Client-facing UI should show only server title and hosted rooms.
