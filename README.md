# VoiceLink

VoiceLink is a federated voice communication platform.

Use our default server or host your own.
Federation is optional.
Accessibility is mandatory.

---

## Platform Priority

- Desktop app is the primary VoiceLink experience.
- Desktop clients are native apps (macOS/Windows), not Electron.
- iOS builds should include the same desktop features as much as possible.
- Web app is secondary and receives a subset of features.
- Features not implemented for web must be hidden for web users.
- New feature work should target desktop first, then web support where practical.

---

## Implementation Tracking (Audit: 2026-02-11)

- Active native macOS source: `swift-native/VoiceLinkNative/Sources/*`
- Active desktop API routes: `source/routes/local-server.js`
- Web/Desktop shared client logic: `source/client/js/core/app.js`

Current high-priority parity targets to keep enforced:
- Room preview/peek and room context actions are desktop-first features.
- Double-Escape room actions menu is required in desktop builds.
- Jukebox controls are available via room context actions for eligible users.
- Desktop updater and API-driven update checks must stay in sync.
- Web UI must hide any feature that is not fully implemented on web.

---

## Features

- Voice-first communication
- Federation support
- Self-hosting
- Plugin-based expansion
- iOS, desktop, and web clients

---

## Hosting Options

- Dedicated domain
- Subdomain
- Sub-path
- Root domain

---

## Accessibility

Designed for VoiceOver and screen readers.

---

## Learn More

See:
- DEPLOYMENT_AND_FEDERATION.md
- ACCESSIBILITY_COMMITMENTS.md
