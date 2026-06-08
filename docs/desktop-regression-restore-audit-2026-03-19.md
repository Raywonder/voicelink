# VoiceLink Desktop Regression Restore Audit

Date: 2026-03-19

Scope:
- `swift-native/VoiceLinkNative/Sources`
- February/March 2026 desktop changes
- Current source tree vs recent known-good feature work

Governance constraints:
- Update existing implementations in place.
- Do not create duplicate route trees or competing runtimes.
- Accessibility regressions block release.
- Preserve working WHMCS behavior without regressions.

## Validation Update (2026-03-20)

Validated live on the rebooted macOS machine after reinstalling `/Applications/VoiceLink.app` from current source:

- audio and UI sounds are working again
- local monitoring/input-monitor path is restored
- local monitoring also works again while inside active rooms
- current macOS source still contains real CoreAudio input/output device detection
- admin UI remains wired to real backend endpoints for user moderation and transmit control
- built-in user recovery controls were added for macOS audio stack problems:
  - `Audio` menu -> `Restart Audio Services`
  - Settings -> Audio -> `Refresh Device List`
  - Settings -> Audio -> `Restart Audio Services`
- input and output sliders now apply an internal `+15%` gain boost to avoid mid-range values sounding too quiet in live use

Operational note:
- the live installed app before reinstall was stale and older than the current source tree
- after replacement, the audio regressions no longer reproduced on this Intel Mac test path
- the local installed validation app is now current-source, but a fresh universal/public artifact rebuild is still a separate release task

## Source Baseline Reviewed

Recent desktop feature commits reviewed:
- `d166f87` Stabilize VoiceLink internal auth and support flow
- `445d235` Add desktop API bootstrap, lounge radio defaults, and build24 readiness
- `1ab5f42` Fix startup audio and media status flows
- `12938ae` Prevent local monitor freeze
- `c7d259f` Keep room streams playing
- `c3fbf26` Hold-to-peek preview controls
- `22d1cd2` Improve server filter/detail visibility
- `aca839d` Organize room filter menu
- `a145d4d` Harden room joins and startup sound-sync behavior
- `4095641` Finalize room accessibility updates
- `111e646` Fix startup welcome audio
- `08663d7` Add profile settings, sound test, per-user controls
- `a82263e` Add WHMCS auth and native login updates

## Current Finding

The main problem is not that all requested features are absent from source.

The real issue is drift between:
- current source
- stale local app snapshots
- duplicated build artifacts like `build-temp` and older bundled app copies

That drift is causing regressions to reappear even when the source already contains the newer behavior.

## Already Present In Current Source

These features are already in the current tree and should not be re-added again:

- Main window uses `Sign In to VoiceLink` instead of Mastodon-only wording.
- OAuth provider buttons are moved into the sign-in flow instead of living on the main window.
- Recovery entry points exist in native auth UI:
  - `Forgot Password?`
  - `Forgot Username? Use Email Code Sign-In`
- Lobby header code now prefers server display name over raw hostname.
- Lobby header code supports server welcome text and MOTD.
- Main room heading includes `Available Rooms (N)`.
- Room browser header includes a `Server Administration` button path.
- Bot rows suppress audio controls and show a bot interaction message.
- Settings contain `Play startup welcome sound`.

Primary files:
- `swift-native/VoiceLinkNative/Sources/VoiceLinkApp.swift`
- `swift-native/VoiceLinkNative/Sources/LoginView.swift`
- `swift-native/VoiceLinkNative/Sources/AuthenticationManager.swift`
- `swift-native/VoiceLinkNative/Sources/AppSoundManager.swift`

## Restore Or Validate Against Live App

These are in source and need live validation after rebuild/reinstall, not blind reimplementation:

1. Main window cleanup
- Keep only the main sign-in entry on the main screen.
- Keep provider buttons inside the sign-in UI.

2. Lobby status/header
- Show `Connected to <server name>`.
- Show server welcome text and MOTD when available.
- Show room count in the heading.

3. Bot behavior
- No audio controls for bots without audio capability.
- Show usage guidance instead.

4. Startup/lobby sounds
- Startup welcome sound should play when enabled.
- Lobby/background media should play when enabled.
- Sound assets are bundled, so failures here are playback/session regressions, not missing files.

5. Room browsing/actions
- Join should remain the default action.
- Room detail presentation should stay compact.
- Preview should remain available without restoring the older bulky action UI.

## Restore Into Current UI

These features should be restored, but fit into the newer UI instead of reverting the whole older layout:

1. Admin controls placement
- Ensure `Server Administration` is visible in the room browser header for eligible users.
- Keep it beside layout/grouping controls, not buried.

2. User admin actions
- Add admin-only user context actions for transmission control:
  - allow user to transmit audio
  - disallow user to transmit audio
- Fit this into the existing user context menu, not a separate legacy panel.

3. Welcome and lobby feedback
- Restore reliable startup sound and background stream behavior.
- Keep the newer settings model with explicit toggles.

4. Account panel clarity
- Show signed-in account identity clearly.
- Show admin access state in the current main-window account area.

## Rework Instead Of Blindly Restoring

These areas need redesign or capability-driven restoration rather than copy/paste from older code:

1. Bot audio controls
- Do not rely permanently on bot-name heuristics.
- Replace with a backend capability flag such as `supportsAudioControls`.

2. Admin visibility logic
- Current source was temporarily broadened to surface the admin button more often.
- Replace that with correct permission checks once the visibility regression is stable.

3. WHMCS/native account merge
- Do not fork separate identity systems.
- Use one canonical VoiceLink user identity that can sync with WHMCS.

4. Notification and account preference surfaces
- Email vs push vs both should be implemented in current settings/account UI.
- Do not restore old scattered controls if they conflict with the present structure.

## High-Risk Stale Paths

These paths are likely regression sources and should not be treated as authoritative code:

- `swift-native/VoiceLinkNative/build-temp`
- `swift-native/VoiceLinkNative/VoiceLink-release.app`

Risk notes:
- `build-temp` shows deleted bundled resources and stale app contents.
- Older bundled app snapshots can reintroduce outdated UI and audio behavior.

## Latest Commit / Tree Triage

Latest commit scan used:
- `2431f62` Windows Inno Setup release flow
- `6965a8a` iOS room join/TestFlight notes
- `c96e7be` iOS TestFlight automation/diagnostics
- `d166f87` internal auth/support flow
- `445d235` desktop API bootstrap and lounge defaults
- `1ab5f42` room management/startup audio/media status
- `4095641` room accessibility/macOS build 22

Current tree classification:

Keep as authoritative:
- `swift-native/VoiceLinkNative/Sources`
- `swift-native/VoiceLinkNative/.build`
- `swift-native/VoiceLinkNative/VoiceLink.app` only as the current tracked bundle snapshot, not as source of truth over `Sources`

Keep but audit/merge carefully:
- latest source edits in `VoiceLinkApp.swift`, `AdminSettingsView.swift`, `ServerManager.swift`, `MessagingManager.swift`, `AppSoundManager.swift`
- iOS changes from `6965a8a` and `c96e7be`
- auth/admin work from `d166f87`

Treat as stale artifact trees:
- `swift-native/VoiceLinkNative/VoiceLink-release.app`
- `swift-native/VoiceLinkNative/build-temp`
- `swift-native/VoiceLinkNative/build-temp/VoiceLink.app`

Why:
- `VoiceLink-release.app` last major tracked refresh points to older macOS build artifact cycles.
- `build-temp` duplicates bundled resources and has already shown deleted-resource drift in git status.
- these trees are tracked artifacts, not the correct place to recover behavioral source changes from

Cleanup rule:
- recover behavior from commit history and `Sources`, not from stale bundled app trees
- only remove stale tracked app trees after feature parity is restored and no unique content remains

## Next Restore Order

1. Rebuild and reinstall only from the current source tree.
2. Validate the features already present in source before re-adding anything else.
3. Add missing admin user transmission controls to the user context menu.
4. Fix startup sound, lobby stream, monitoring, and audio-driver regressions.
   Status update (2026-03-20):
   startup/UI sounds and local monitoring are validated as restored on the live macOS install.
5. Replace bot heuristics with capability-driven UI when backend support is ready.
6. Audit and remove stale build trees after current release-critical regressions are resolved.

## Explicit Hold List

Do not blindly restore these from older snapshots:
- oversized room action sheets
- duplicated provider buttons on the main window
- older room browser clutter that conflicts with the newer filtered/layout-driven UI
- any duplicate route tree or parallel auth runtime
