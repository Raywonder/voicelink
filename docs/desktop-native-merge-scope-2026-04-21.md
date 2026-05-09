# VoiceLink Native Desktop Merge Scope

Date: 2026-04-21

Purpose:
- define what belongs in the current native desktop merge
- reduce regressions caused by carrying forward stale or undocumented behavior
- align the largest native desktop files with documented project direction

Issue review:
- no open GitHub issues were returned for `raywonder/voicelink` during this pass
- merge decisions below are therefore based on repository docs and current source, not backlog tickets

## Primary Source Docs Reviewed

- `README.md`
- `ADMIN_DOCS_AND_FEDERATION_VISIBILITY.md`
- `DOCS_SYNC_AND_AI_GUIDELINES.md`
- `DEPLOYMENT_AND_FEDERATION.md`
- `ROOM_INTERACTION_GUIDE.md`
- `docs/desktop-regression-restore-audit-2026-03-19.md`
- `docs/CURRENT_STATUS_2026-03-26.md`
- `docs/ADMIN-AUTH-PLAN.md`
- `docs/CHANGELOG-2026-02-11.md`

## Product Direction Confirmed

These are explicitly supported by the docs and should remain in the native desktop line:

- native desktop first, not Electron-first
- admin status and moderation controls
- federation-aware visibility and trusted-node flows
- VoiceOver-first and keyboard-safe desktop UX
- room preview, room actions, room lock controls, and compact room details
- local monitoring and desktop audio recovery controls
- CopyParty/shared access and SMB-aware file sharing
- WHMCS-compatible auth and portal routing
- in-app docs sync and admin-only docs visibility
- scheduler/self-test capabilities
- deployment/bootstrap flows for managed installs

## Large File Scope

### `swift-native/VoiceLinkNative/Sources/AdminServerManager.swift`

Keep:
- admin status and permission resolution
- config, room, user, support, database, scheduler, federation, module, and deployment API access
- secure transport recovery
- background stream config management
- WHMCS/auth provider health access

Refactor direction:
- move support models and request/response types into companion files
- keep manager file focused on request orchestration and state changes

Do not remove:
- scheduler support
- federation settings
- deployment/install packaging support
- auth provider health
- backup manager APIs

### `swift-native/VoiceLinkNative/Sources/AdminSettingsView.swift`

Keep:
- management target selection
- admin overview, users, support, rooms, modules, deployment, self-tests, config, streams, API sync, federation
- WHMCS/client portal controls
- OpenLink/OpenClaw-related sync surfaces where they are part of documented deployment and routing behavior
- SSL manager, backup manager, and hold media manager

Review carefully before expanding:
- any new panel that duplicates an existing panel instead of extending it
- controls that do not map to a documented backend feature
- temporary wording that conflicts with federation or accessibility docs

Do not restore:
- oversized legacy admin layouts
- duplicate auth/runtime surfaces

### `swift-native/VoiceLinkNative/Sources/VoiceLinkApp.swift`

Keep:
- room browser filters and server-aware browsing
- compact room details
- room preview/peek behavior
- chat and transcript panels
- room lock and background media flows
- account/admin visibility in the main desktop UI
- startup and audio recovery behavior that the regression audit marks as required

Validate after rebuild:
- startup sound behavior
- room transcript delivery
- room-wide background media start/stop
- bot/system-message stability

Do not regress to:
- duplicated provider buttons on the main screen
- cluttered older room action flows
- bot-name heuristics as the permanent source of capability truth

### `swift-native/VoiceLinkNative/Sources/LocalMonitorManager.swift`

Keep:
- local monitoring
- shared transmission fallback
- selected-input capture path
- latency and effect controls
- diagnostics snapshot support

Required by docs:
- local monitoring must work while idle and while joined to rooms
- audio recovery controls remain first-class

### `swift-native/VoiceLinkNative/Sources/RoomActionMenu.swift`

Keep:
- room action sheet/menu
- hold-to-preview and peek support
- room lock support
- background media assignment
- compact room detail presentation

Rework instead of blindly restoring:
- any older bulky room action layout
- any behavior that duplicates room actions now handled in `VoiceLinkApp.swift`

## Immediate Refactor Rules

1. prefer extraction over deletion when code maps to documented features
2. delete only stale artifacts, orphaned legacy docs, and truly unreferenced helpers
3. keep one canonical auth/runtime path
4. keep one authoritative native desktop source tree
5. validate large-file refactors with build checks whenever possible

## Current Cleanup Progress

Completed in this pass:
- restored the known-good older installed macOS app for live testing
- removed stale generated macOS artifacts from the repo tree
- removed legacy Electron doc remnants from the native desktop bundled docs
- extracted admin support models from `AdminServerManager.swift` into `AdminServerSupportModels.swift`

Next recommended order:
1. continue shrinking `AdminServerManager.swift` by extracting additional model groups where safe
2. split `AdminSettingsView.swift` by tab/feature area
3. isolate room chat and transcript surfaces from `VoiceLinkApp.swift` where possible
4. rebuild and validate the native desktop target
