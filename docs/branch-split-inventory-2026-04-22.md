# Branch Split Inventory

Date: 2026-04-22
Repo: `raywonder/voicelink`
Current branch: `smb-layer-admin-20260326`

This inventory groups the current dirty tree into branch-sized cleanup buckets so
the repo can be organized before any push to `main` or `master`.

## Status

- `voicelink` is not push-ready as one branch.
- `openlink` is also dirty in its own repo and should be handled separately.
- Native desktop Swift cleanup has a verified green `swift build`.
- OpenLink-specific behavior should move behind a module/integration boundary in VoiceLink.

## Branch Buckets

### 1. `cleanup/native-desktop-admin-split`

Scope: macOS native Swift refactor, native resources, docs bundling, and desktop behavior cleanup.

Files:

- `.gitignore`
- `swift-native/VoiceLinkNative/Resources/Info.plist`
- `swift-native/VoiceLinkNative/Resources/docs/ADMIN-AUTH-PLAN.html`
- `swift-native/VoiceLinkNative/Resources/docs/authenticated/admin-panel.html`
- `swift-native/VoiceLinkNative/Resources/docs/authenticated/index.html`
- `swift-native/VoiceLinkNative/Resources/docs/authentication.html`
- `swift-native/VoiceLinkNative/Resources/docs/getting-started.html`
- `swift-native/VoiceLinkNative/Resources/docs/index.html`
- `swift-native/VoiceLinkNative/Resources/docs/installation/INSTALL-LINUX.html`
- `swift-native/VoiceLinkNative/Resources/docs/installation/INSTALL-MACOS.html`
- `swift-native/VoiceLinkNative/Resources/docs/installation/INSTALL-WINDOWS.html`
- `swift-native/VoiceLinkNative/Resources/docs/installation/index.html`
- `swift-native/VoiceLinkNative/Resources/docs/public/index.html`
- `swift-native/VoiceLinkNative/Resources/docs/public/video-clips.html`
- `swift-native/VoiceLinkNative/Resources/docs/room-management.html`
- `swift-native/VoiceLinkNative/Resources/docs/scripts/docs.js`
- `swift-native/VoiceLinkNative/Resources/docs/scripts/generate-docs.js`
- `swift-native/VoiceLinkNative/Resources/docs/scripts/search.js`
- `swift-native/VoiceLinkNative/Resources/docs/styles/docs.css`
- `swift-native/VoiceLinkNative/Resources/docs/voiceover-support.html`
- `swift-native/VoiceLinkNative/Resources/sounds/ambience/son.m4a`
- `swift-native/VoiceLinkNative/Resources/sounds/error.mp3`
- `swift-native/VoiceLinkNative/Resources/sounds/ui-sounds/error.mp3`
- `swift-native/VoiceLinkNative/Resources/sounds/voicelink1.wav`
- `swift-native/VoiceLinkNative/Resources/sounds/voicelink2.wav`
- `swift-native/VoiceLinkNative/Resources/sounds/voicelink3.wav`
- `swift-native/VoiceLinkNative/Resources/sounds/voicelink4.wav`
- `swift-native/VoiceLinkNative/Sources/APIEndpointResolver.swift`
- `swift-native/VoiceLinkNative/Sources/AdminServerManager.swift`
- `swift-native/VoiceLinkNative/Sources/AdminServerSupportModels.swift`
- `swift-native/VoiceLinkNative/Sources/AdminSettingsSectionsAPISync.swift`
- `swift-native/VoiceLinkNative/Sources/AdminSettingsSectionsDeployment.swift`
- `swift-native/VoiceLinkNative/Sources/AdminSettingsSectionsFederation.swift`
- `swift-native/VoiceLinkNative/Sources/AdminSettingsSectionsModules.swift`
- `swift-native/VoiceLinkNative/Sources/AdminSettingsSectionsOverviewUsersSupport.swift`
- `swift-native/VoiceLinkNative/Sources/AdminSettingsSectionsRooms.swift`
- `swift-native/VoiceLinkNative/Sources/AdminSettingsSectionsSelfTests.swift`
- `swift-native/VoiceLinkNative/Sources/AdminSettingsSectionsStreams.swift`
- `swift-native/VoiceLinkNative/Sources/AdminSettingsView.swift`
- `swift-native/VoiceLinkNative/Sources/AppSoundManager.swift`
- `swift-native/VoiceLinkNative/Sources/AuthenticationManager.swift`
- `swift-native/VoiceLinkNative/Sources/AutoUpdater.swift`
- `swift-native/VoiceLinkNative/Sources/ChatViews.swift`
- `swift-native/VoiceLinkNative/Sources/DocsManager.swift`
- `swift-native/VoiceLinkNative/Sources/FoundationCompat.swift`
- `swift-native/VoiceLinkNative/Sources/JellyfinManager.swift`
- `swift-native/VoiceLinkNative/Sources/LicensingManager.swift`
- `swift-native/VoiceLinkNative/Sources/LicensingView.swift`
- `swift-native/VoiceLinkNative/Sources/LocalAPIBootstrap.swift`
- `swift-native/VoiceLinkNative/Sources/LoginView.swift`
- `swift-native/VoiceLinkNative/Sources/MenuBarServer.swift`
- `swift-native/VoiceLinkNative/Sources/MessagingManager.swift`
- `swift-native/VoiceLinkNative/Sources/PairingManager.swift`
- `swift-native/VoiceLinkNative/Sources/RecordingManager.swift`
- `swift-native/VoiceLinkNative/Sources/RoomActionMenu.swift`
- `swift-native/VoiceLinkNative/Sources/RoomManager.swift`
- `swift-native/VoiceLinkNative/Sources/SelectedAudioInputCapture.swift`
- `swift-native/VoiceLinkNative/Sources/ServerExitManager.swift`
- `swift-native/VoiceLinkNative/Sources/ServerManager.swift`
- `swift-native/VoiceLinkNative/Sources/ServersView.swift`
- `swift-native/VoiceLinkNative/Sources/SpatialAudioEngine.swift`
- `swift-native/VoiceLinkNative/Sources/StatusManager.swift`
- `swift-native/VoiceLinkNative/Sources/SyncManager.swift`
- `swift-native/VoiceLinkNative/Sources/UserAudioControlManager.swift`
- `swift-native/VoiceLinkNative/Sources/VoiceLinkApp.swift`
- `swift-native/VoiceLinkNative/Sources/WhisperModeManager.swift`
- `swift-native/VoiceLinkNative/Sources/ServerManager-fix.swift`
- `swift-native/VoiceLinkNative/VoiceLink-macOS.zip.new`
- `swift-native/VoiceLinkNative/VoiceLink-macOS.zip.sha256`
- `swift-native/VoiceLinkNative/VoiceLinkMacOS.zip.sha256`
- `swift-native/VoiceLinkNative/latest-mac.server.yml`
- `swift-native/VoiceLinkNative/latest-mac.yml`
- `swift-native/VoiceLinkNative/latest-mac.yml.new`
- `docs/desktop-native-merge-scope-2026-04-21.md`
- `docs/desktop-regression-restore-audit-2026-03-19.md`

Notes:

- Remove generated release artifacts from commits where possible.
- Do not include OpenLink native app content from `swift-native/OpenLink*` in this branch.

### 2. `cleanup/server-module-catalog`

Scope: server runtime, module registry, scheduler, licensing endpoints, deployment config, FlexPBX server module support.

Files:

- `data/deploy.json`
- `server/config/deploy-config.js`
- `server/modules/internal-scheduler/index.js`
- `server/modules/media-rooms/index.js`
- `server/modules/module-registry.js`
- `server/modules/two-factor-auth/index.js`
- `server/modules/voicelink-flexpbx/ivr-prompts/README.md`
- `server/modules/voicelink-flexpbx/ivr-prompts/generate_piper_prompts.py`
- `server/modules/voicelink-flexpbx/ivr-prompts/prompt-manifest.json`
- `server/routes/install-license.js`
- `server/routes/local-server.js`
- `server/tools/whmcs-local-api.php`
- `server/utils/jellyfin-service-manager.js`
- `source/modules/module-registry.js`
- `source/server/modules/voicelink-flexpbx/index.js`
- `source/server/routes/licensing-routes.js`
- `source/server/routes/local-server.js`
- `source/server/tools/whmcs-local-api.php`
- `source/src/main.js`
- `source/src/settings-manager.js`
- `src/main.js`
- `src/settings-manager.js`

Notes:

- OpenLink should remain as an installable/configurable module entry, not a built-in admin subsection.
- Remove `__pycache__` file from tracking candidates:
  `server/modules/voicelink-flexpbx/ivr-prompts/__pycache__/generate_piper_prompts.cpython-314.pyc`

### 3. `cleanup/web-docs-installers`

Scope: website downloads, docs, installatron, packaging docs, governance docs, web UI placeholders, hosting bridges.

Files:

- `MACOS_BUILD_INSTRUCTIONS.md`
- `README.md`
- `client/downloads.html`
- `client/embed.html`
- `client/js/auth/mastodon-oauth.js`
- `client/js/core/app.js`
- `client/js/ui/default-rooms-interface.js`
- `client/js/ui/encryption-status-display.js`
- `client/js/ui/media-streaming-interface.js`
- `client/assets/sounds/ambience/son.m4a`
- `client/assets/sounds/error.mp3`
- `client/downloads-enhanced.html`
- `docs/INSTALLATRON_BROWSER_UI_INTEGRATION.md`
- `docs/INSTALLATRON_INTEGRATION.md`
- `docs/CURRENT_STATUS_2026-03-26.md`
- `docs/SOPHIA_RUNTIME_NOTES_2026-03-26.md`
- `docs/VOICE_LINK_PROMO_MEDIA_BRIEF.md`
- `docs/WHMCS_PORTAL_STRIPE_OPENCLAW_PLAN_2026-03-26.md`
- `docs/authenticated/admin-panel.html`
- `docs/authentication.html`
- `docs/getting-started.html`
- `docs/index.html`
- `docs/installation/INSTALL-LINUX.html`
- `docs/installation/INSTALL-LINUX.md`
- `docs/installation/INSTALL-MACOS.html`
- `docs/installation/INSTALL-MACOS.md`
- `docs/installation/INSTALL-WINDOWS.html`
- `docs/installation/INSTALL-WINDOWS.md`
- `docs/installation/index.html`
- `docs/legacy/releases-electron/README.md`
- `docs/legacy/releases-electron/getting-started.html`
- `docs/legacy/releases-electron/index.html`
- `docs/legacy/releases-electron/install.html`
- `docs/legacy/releases-electron/version-native.json`
- `docs/room-management.html`
- `docs/scripts/docs.js`
- `docs/scripts/search.js`
- `docs/styles/docs.css`
- `docs/voiceover-support.html`
- `downloads-enhanced.html`
- `downloads.html`
- `index.html`
- `installatron/voicelink/hooks/post_install.php`
- `installatron/voicelink/install.xml`
- `installatron/voicelink/uninstall.xml`
- `installatron/voicelink/upgrade.xml`
- `source/assets/sounds/ambience/son.m4a`
- `source/assets/sounds/error.mp3`
- `source/client/js/ui/media-streaming-interface.js`
- `source/docs/authentication.html`
- `source/docs/getting-started.html`
- `source/docs/index.html`
- `source/docs/room-management.html`
- `source/docs/scripts/docs.js`
- `source/docs/scripts/search.js`
- `source/docs/styles/docs.css`
- `source/docs/voiceover-support.html`
- `voicelink-app/docs/authentication.html`
- `voicelink-app/docs/getting-started.html`
- `voicelink-app/docs/index.html`
- `voicelink-app/docs/room-management.html`
- `voicelink-app/docs/scripts/docs.js`
- `voicelink-app/docs/scripts/search.js`
- `voicelink-app/docs/styles/docs.css`
- `voicelink-app/docs/voiceover-support.html`
- `.github/voicelink-governance.md`
- `voicelink-governance.md`
- `.htaccess`
- `web-ui/admin/README.md`
- `web-ui/admin/install-status-example.json`
- `composr/README.md`
- `composr/voicelink-composr/bridge.php`
- `cpanel/README.md`
- `cpanel/voicelink-cpanel/bridge.php`
- `whmcs/README.md`
- `whmcs/voicelink-whmcs/bridge.php`
- `wordpress/README.md`
- `wordpress/voicelink-wordpress/readme.txt`
- `wordpress/voicelink-wordpress/voicelink-wordpress-mu-loader.php`
- `wordpress/voicelink-wordpress/voicelink-wordpress.php`
- `releases/voicelink-server-1.0.0.tar.gz.sha256`
- `releases/voicelink-server-1.0.0.zip.sha256`
- `error.mp3`

Notes:

- This branch still needs review for duplicated docs across `docs`, `source/docs`, and `voicelink-app/docs`.
- Keep docs-only removals like `OPENCODE_INTEGRATION.md` and `OPENCODE_STATUS.md` out of native/server branches.

### 4. `cleanup/windows-native`

Scope: Windows native client, notifications/sync/admin views, installer and build scripts.

Files:

- `windows-native/VoiceLinkNative/App.xaml`
- `windows-native/VoiceLinkNative/App.xaml.cs`
- `windows-native/VoiceLinkNative/Services/NotificationService.cs`
- `windows-native/VoiceLinkNative/Services/SyncManager.cs`
- `windows-native/VoiceLinkNative/ViewModels/SettingsViewModel.cs`
- `windows-native/VoiceLinkNative/Views/AdminView.xaml`
- `windows-native/VoiceLinkNative/Views/MainWindow.xaml`
- `windows-native/VoiceLinkNative/Views/MainWindow.xaml.cs`
- `windows-native/VoiceLinkNative/Views/RoomsView.xaml`
- `windows-native/VoiceLinkNative/Views/SettingsView.xaml`
- `windows-native/VoiceLinkNative/VoiceLinkNative.csproj`
- `windows-native/installer/inno/VoiceLink.iss`
- `windows-native/scripts/build_windows_installers.ps1`

Generated files to avoid committing:

- `windows-native/publish/win-x64/D3DCompiler_47_cor3.dll`
- `windows-native/publish/win-x64/PenImc_cor3.dll`
- `windows-native/publish/win-x64/PresentationNative_cor3.dll`
- `windows-native/publish/win-x64/VoiceLinkNative.exe`
- `windows-native/publish/win-x64/VoiceLinkNative.pdb`
- `windows-native/publish/win-x64/vcruntime140_cor3.dll`
- `windows-native/publish/win-x64/wpfgfx_cor3.dll`

### 5. `cleanup/ios`

Scope: iOS native app and TestFlight notes/scripts.

Files:

- `swift-native/VoiceLinkiOS/Sources/ContentView.swift`
- `swift-native/VoiceLinkiOS/Sources/IOSNativeRoomSocketClient.swift`
- `swift-native/VoiceLinkiOS/TestFlight/WhatToTest.en-US.txt`
- `swift-native/VoiceLinkiOS/VoiceLinkiOS.xcodeproj/project.pbxproj`
- `swift-native/VoiceLinkiOS/scripts/archive_ios_testflight.sh`

### 6. `cleanup/openlink-boundary-in-voicelink`

Scope: only the VoiceLink-side integration boundary for OpenLink, not OpenLink runtime/product code.

Likely files:

- `server/modules/module-registry.js`
- `source/modules/module-registry.js`
- `server/routes/local-server.js`
- `source/server/routes/local-server.js`
- `swift-native/VoiceLinkNative/Sources/AdminServerManager.swift`
- `swift-native/VoiceLinkNative/Sources/AdminSettingsSectionsAPISync.swift`
- `swift-native/VoiceLinkNative/Sources/RoomManager.swift`
- `swift-native/VoiceLinkNative/Sources/ServerExitManager.swift`

Notes:

- This branch should only leave install/detect/connect/config hooks in VoiceLink.
- OpenLink-specific runtime logic should move to the separate `raywonder/openlink` repo.
- Do not mix this with full native Swift cleanup if the goal is a reviewable branch.

### 7. `cleanup/openlink-repo-separate`

Repo: `/Users/admin/git/Raywonder/openlink`

Files currently dirty there:

- `electron/installer/OpenLink.iss`
- `electron/package.json`
- `electron/scripts/build-win-inno.ps1`
- `electron/src/main.js`
- `scripts/build-windows-openlink.bat`

Notes:

- This should be committed and pushed in the `openlink` repo, not `voicelink`.

## Suggested Push Order

1. `cleanup/native-desktop-admin-split`
2. `cleanup/server-module-catalog`
3. `cleanup/openlink-boundary-in-voicelink`
4. `cleanup/web-docs-installers`
5. `cleanup/windows-native`
6. `cleanup/ios`
7. separate `openlink` repo branch

## Blockers Before Any Mainline Push

- Remove generated artifacts and publish outputs from candidate commits.
- Resolve duplicated content between `server/` and `source/server/`, and between `docs/`, `source/docs/`, and `voicelink-app/docs/`.
- Keep `OpenLink` product/runtime changes out of `voicelink` except for the integration boundary.
- Verify each split branch builds or validates for its own surface before pushing.
