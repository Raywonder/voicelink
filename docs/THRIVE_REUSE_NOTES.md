# Thrive -> VoiceLink Reuse Notes (Build Integration)

This file tracks which ThriveMessenger patterns are reused in VoiceLink without changing the current VoiceLink UI layout.

## Implemented in this patch

1. Chat link safety flow (from Thrive chat URL handling)
- VoiceLink chat messages now detect links in message text.
- Links are clickable in-room and DM chat bubbles.
- Opening a link now shows a warning prompt first with options:
  - Open
  - Cancel
  - Copy Link

2. Typing indicator naming (from Thrive typing events)
- VoiceLink now stores user display names seen in incoming chat/DM events.
- Typing indicator now prefers a user name (`<name> is typing...`) instead of generic text when known.

3. File save behavior parity (from Thrive auto-open received files option)
- Added `autoOpenSavedFiles` setting in file transfer settings.
- When saving a received file, VoiceLink now either:
  - Opens the file directly, or
  - Reveals it in Downloads,
  based on that setting.
- Added transfer panel toggle: `Open files after saving`.

## Candidate next ports (safe, UI-preserving)

1. Server pre-login welcome preview
- Add a read-only endpoint and client preview before login.

2. Context help overlays per screen
- Keep current UI and add F1 contextual help sheets/web views.

3. Multi-file transfer handshake
- Extend existing transfer API from single transfer style to offer/accept batched files.

4. Message accessibility options parity
- Add optional "read incoming chat aloud" and "announce typing start/stop" toggles tied to AccessibilityManager.
