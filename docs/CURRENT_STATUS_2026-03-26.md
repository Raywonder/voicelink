# VoiceLink Current Status

Last updated: 2026-03-26

## Working Now

- macOS desktop app is running from a current local rebuild in `/Applications/VoiceLink.app`.
- Room list loading is working again on macOS.
- In-room monitoring is working again.
- Message receive sounds are working again.
- Some system messaging is working again, including restart and room rejoin style notices.
- Main and community servers are both back to returning the guest-visible room cap instead of thousands of rooms.
- Main server now has a valid Whisper runtime provisioned for live room transcription support.

## Still Open

- Live transcripts are still not appearing in the room transcript list.
- Room background media is still not reliably starting and stopping for everyone in the room.
- Room action behavior still needs another pass for lock state, richer room details, and menu consistency.
- Bot replies and some room system-message paths are still unstable after recent regressions.
- Community server transcription support is still incomplete because that VPS is missing working Python `pip` / `venv` support for its local Whisper runtime.

## Governance / Ops Notes

- Documentation must be updated before public release replacement.
- Public pages, downloads text, installer metadata, and in-app help must stay aligned with the current feature set.
- `VoiceLink Web Access` is the correct public-facing name for the web client.
- Internal and federated server paths should be preferred before public fallback URLs.
- MariaDB and PostgreSQL support should remain first-class options in admin configuration; MariaDB is the expected default on current Raywonder-hosted stacks.

## Next Technical Priorities

1. Finish room transcript delivery end to end on the main server.
2. Finish room-wide background media playback and stop behavior.
3. Stabilize bot replies and room system-message timing.
4. Clean up room details, lock controls, and action menus.
5. Continue the web auth/accessibility pass and the newer iOS audio-focused test build.
