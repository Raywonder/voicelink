# VoiceLink Canonical Downloads And Updates

VoiceLink public client and server artifacts are published from one canonical download root:

`https://voicelinkapp.app/downloads/voicelink`

Public aliases, including `https://voicelink.dev/...` and approved `https://cloud.*` links, must redirect or proxy to the same canonical files and checksums. Normal public and hosted installs must not generate account-local public artifact URLs.

Enterprise licensed installs may self-host artifacts when explicitly configured, but they must still read central update metadata and participate in update check-in tracking. User-facing links must remain HTTPS and must not expose server filesystem paths, temporary folders, cPanel account paths, or build-machine paths.

## Update Metadata

The update API reports separate client and server update objects:

- `clientUpdates`
- `serverUpdates`
- `combinedUpdates`

Each update object includes platform, version, build number, release notes, checksum where available, mandatory or critical status, and the final HTTPS download URL. Clients should ignore any offered update with a build number lower than the installed build.

macOS update metadata is read from Sparkle-compatible release metadata such as `latest-mac.yml` or `appcast.xml`. The API must not hard-code stale build numbers. Windows metadata should follow the current wxPython package manifest under the canonical `windows/` artifact folder.

## Default Update Behavior

Clients auto-check, auto-download, and auto-install updates by default. Users may postpone non-critical updates. Critical or security updates may be mandatory. Server installs check from the self-test/internal scheduler and apply enabled server updates automatically unless an enterprise policy disables auto-apply.

Server administrators should receive a safe system/admin notification when client-only, server-only, or combined updates are available. Notification bodies must not contain secrets.
