# VoiceLink Local Workspace (FULL SOURCE + RUNNABLE) — AGENTS.md

This folder is a FULL SOURCE workspace for VoiceLink that can run locally and on the server
after sync/upload.

It is also the workspace where VoiceLink-owned embed tools live (VoiceLink controls the
embed, not WHMCS/Composr).

Canonical upstream repo reference:
https://github.com/raywonder/voicelink
(VoiceLink includes multiple surfaces: server/client/native/etc.) :contentReference[oaicite:1]{index=1}

==================================================
MANDATORY READ ORDER (NO SKIPPING)
==================================================

1) dev/AGENTS.md  (global bootstrap + conflict order)
2) dev/systemrules.md
3) dev/global-Infrastructure.md
4) dev/global-PROJECT_SETUP_GUIDELINES.md
5) dev/distributed_ai_control_execution_spec_for_open_code.md
6) dev/apps/AGENTS.md
7) dev/apps/voicelink-local/AGENTS.md (this file)

If any required file is missing: STOP and ask. Never guess infra.

==================================================
WHAT THIS FOLDER IS
==================================================

voicelink-local is a "working + runnable" workspace:
- contains full VoiceLink source (not just artifacts)
- builds app outputs for macOS/Windows
- can run server-side via PM2 after sync to /home/devinecr/apps/voicelink-local
- owns/embed-controls the embed tooling that other sites can use

This folder syncs across your machines and to the server.
Treat it as the day-to-day "active workspace".

==================================================
REPO RELATIONSHIP (IMPORTANT)
==================================================

There are two sibling folders:

- dev/apps/voicelink-local/  (ACTIVE WORKSPACE, synced to server)
- dev/apps/voicelink/        (GIT REPO CLONE used for pushing upstream changes)

Rules:
- Work can happen in voicelink-local.
- When changes are ready to publish, they MUST be transferred into dev/apps/voicelink/
  and pushed from there (keeps git history clean and avoids syncing .git + build junk).

Agents must NOT create duplicate subtrees or copy entire folders back and forth blindly.
Prefer targeted sync of changed source files only.

==================================================
OUTPUT NAMING (NON-NEGOTIABLE)
==================================================

macOS output:  VoiceLink.app
Windows output: VoiceLink.exe

Never rename based on:
- voicelink-local
- staging
- platform labels

==================================================
SERVER PATHS + SYMLINK WEBROOT BRIDGE (CRITICAL)
==================================================

Server runtime/source location (sync target):
/home/devinecr/apps/voicelink-local/

Frontend real webroot (bypasses Composr):
/home/devinecr/devinecreations.net/voicelink-local/*

Public compatibility webroot via symlink (WHMCS domain webroot):
/home/devinecr/public_html/voicelink-local/*  -> symlink ->  /home/devinecr/devinecreations.net/voicelink-local/*

Reason:
- devine-creations.com uses WHMCS under public_html
- devinecreations.net uses Composr
- VoiceLink must bypass Composr routing entirely
- Symlink prevents old/public paths from breaking

Agents MUST:
- preserve existing symlinks
- NEVER replace symlinks with real directories
- NEVER route VoiceLink through Composr pages/rewrites
- NEVER restructure WHMCS paths under public_html
- If a change impacts this bridge, STOP and ask first

==================================================
RUNNING VOICELINK SERVER-SIDE
==================================================

- PM2 ONLY for Node services
- systemd FORBIDDEN for Node
- never run applications as root
- run under the designated service user

When syncing to server, agents must:
1) verify permissions are correct
2) verify PM2 process config matches current source entrypoint
3) restart/reload via PM2 safely (no data loss)

==================================================
EMBED OWNERSHIP RULES
==================================================

VoiceLink provides embed tooling for other properties to consume.

Embed must:
- be generated/served by VoiceLink frontend tools (not WHMCS/Composr plugins)
- support accessibile embed defaults (keyboard + screen-reader + focus rules)
- be safe-by-default (no leaking private room IDs, tokens, or admin endpoints)
- allow whitelisted configuration (size/theme/room join flow/etc.)
- be versioned and backward compatible where possible

WHMCS may provide links or provisioning, but embed rendering/behavior remains VoiceLink-owned.

==================================================
PERMISSIONS (CRITICAL)
==================================================

- service-owned only (devinecr or designated service user)
- NEVER root-owned
- directories 755
- files 644
- executables 755

==================================================
SYNC HYGIENE (DO NOT DESTROY YOUR FUTURE)
===========================================
