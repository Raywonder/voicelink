# VoiceLink Governance – v1.0 Commercial Transition
Last updated: 2026-02-27
Applies to: All agents (Codex, Claude, OpenCode), all repos, all distribution channels.

This document defines the rules for VoiceLink v1.0 and beyond.

============================================================
SECTION 0 – CURRENT EXECUTION STATUS (2026-02-27)
============================================================

Build and deployment status for the current VoiceLink desktop cycle:

- macOS desktop app rebuilt from `publish-clean` commit `6016b52`
- Local `/Applications/VoiceLink.app` replaced with the rebuilt universal binary
- macOS artifacts refreshed:
  - `swift-native/VoiceLinkNative/VoiceLinkMacOS.zip`
  - `swift-native/VoiceLinkNative/VoiceLink-macOS.zip`
  - `swift-native/VoiceLinkNative/latest-mac.yml`
  - `swift-native/VoiceLinkNative/latest-mac.server.yml`
- Windows portable artifact refreshed from `windows-native/publish/win-x64`
  - `windows-native/dist/VoiceLink-windows.zip`
- Updated artifacts uploaded to:
  - Main server: `/home/devinecr/downloads/voicelink/`
  - VPS/community server: `/home/devinecr/downloads/voicelink/`

Behavior changes included in this build:
- Guest access remains enabled for normal users
- Non-logged-in limits remain enforced
- Email/username and admin-invite flows are surfaced directly in login/setup UI
- Admin invite activation is blocked when a different account is already signed in

Operational findings from post-deploy checks:
- VPS `voicelink-local-api` restarted successfully under PM2
- VPS server is currently listening on `http://localhost:3010`
- VPS local rooms endpoint responded successfully (`/api/rooms?source=app`)
- Main server became intermittently unreachable from the build Mac on SSH port `450` after artifact upload, so final post-upload PM2 verification from this machine was incomplete

Known deployment blockers still requiring follow-up:
- VPS process logs show missing runtime dependency: `nodemailer`
- VPS `/api/downloads` is still serving stale legacy metadata and does not yet reflect the new direct-download URLs
- Local DNS resolution for `voicelink.devinecreations.net` and `node2.voicelink.devinecreations.net` failed from the build Mac during final curl verification

Governance rule for this state:
- A build may be marked "artifact-complete" before it is marked "deployment-complete"
- "deployment-complete" requires:
  - uploaded files verified on target host
  - PM2 process restarted or confirmed healthy
  - live API/download endpoints checked on the active service port
  - blockers recorded if any of the above fail

============================================================
SECTION 1 – CURRENT STATE (v1.0 RELEASE MOMENT)
============================================================

We are publishing v1.0 to:
- Direct download (website + GitHub releases)
- App Store/TestFlight builds (planned; links not live yet)
- All official webpages

The current repository:
- Shows GPL-3.0 license on GitHub
- README previously referenced MIT (must be corrected)
- Has 2 contributors
- Uses HubNode APIs for backend calls
- Uses api.* or voicelink.*/api/* paths for API structure

Before any relicensing:
- Produce Relicensing Readiness Report
- Identify contributor ownership
- Identify dependency licenses
- Confirm no GPL contamination in proprietary direction

Until relicensing is legally complete:
- README MUST match actual LICENSE
- No MIT claims if GPL file exists

============================================================
SECTION – CODEX DOCUMENT GENERATION (SOURCE OF TRUTH)
============================================================

Codex (or other agents) may generate or update the following documents
for VoiceLink. Documents may begin as placeholders and be refined over
time, but must always remain internally consistent.

Documents that may be generated/updated:
- LICENSE (VoiceLink Commercial License)
- EULA.md
- CLA.md
- CONTRIBUTING.md
- CODE_OF_CONDUCT.md
- SECURITY.md
- PRIVACY_POLICY.md (or canonical link reference)
- SUPPORT.md
- THIRD_PARTY_NOTICES.md
- APP_STORE_CHECKLIST.md
- PRIVACY_DISCLOSURE_MAP.md
- RELEASE_CHECKLIST.md
- docs/distribution.md
- docs/licensing.md
- docs/api-integration.md

Rules:
- If a document already exists, update it in-place rather than creating duplicates.
- Do not introduce license conflicts (README vs LICENSE vs headers).
- Prefer one canonical copy per repo; other repos should link to canonical URLs.
- Any doc changes must be reflected in README and release notes when relevant.

Codex may use and adapt existing policy/support language from official pages, including:
- tappedin.fm
- devine-creations.com
- devinecreations.net
- raywonderis.me
- Official Mastodon instance pages
- Official support and privacy pages

If needed, Codex must also update those pages (or output a patch list + exact page/path list).

============================================================
SECTION – REQUIRED OUTPUTS WHEN CODEX RUNS A GOVERNANCE TASK
============================================================

When Codex performs a licensing/distribution/governance task, it must output:

1) Files changed/created (exact paths)
2) What content was generated vs updated
3) Any placeholders inserted (list them clearly)
4) A list of website pages requiring updates (by domain + page/path)
5) A short validation checklist:
   - README license matches LICENSE
   - No duplicate license files
   - Store build gates enforced
   - No secrets committed

============================================================
SECTION – WEBSITE POLICY SYNCHRONIZATION (DOMAINS)
============================================================

Rules:
- Prefer canonical policy pages as the source of truth (link to them where possible).
- If policy text is duplicated into VoiceLink docs, keep it consistent.
- Privacy policy must match actual data collection and telemetry behavior.
- Support contact details must match official support pages.
- Licensing language must match the VoiceLink Commercial License.
- Store builds must comply with the strictest applicable privacy policy.

Non-negotiable:
- Never publish contradictions between VoiceLink docs and the domain policies.

============================================================
SECTION – COMMERCIAL LICENSE AUTHORITY
============================================================

VoiceLink Commercial License v1.0 and all future commercial licenses are issued under the authority of:

Dominique Stansberry
Devine Creations (or applicable business entity)

Only official releases tagged and distributed through authorized channels constitute valid commercial releases.

No unofficial forks, modified builds, or repackaged installers are authorized for commercial distribution.

============================================================
SECTION – RELICENSING EXECUTION CHECKLIST (AGENT PLAYBOOK)
============================================================

When executing relicensing for the commercial transition:

1) Generate Relicensing Readiness Report:
   - Confirm authorship: primary author is Dominique Stansberry
   - Confirm secondary contributors are AI tools / machines under primary control
   - Inventory third-party dependencies and licenses
   - Identify any GPL/AGPL/LGPL risks in shipped binaries

2) Fix repo messaging BEFORE swapping licenses:
   - README must match current LICENSE until the moment of relicensing
   - Remove any “MIT” claims while GPL file exists
   - Add a transition notice for private-core + public SDK/protocol

3) Perform relicensing change in one commit set:
   - Replace LICENSE with VoiceLink Commercial License
   - Update README “License” section to match
   - Update package metadata license fields (e.g., UNLICENSED or SEE LICENSE)
   - Add/Update docs/licensing.md explaining direct vs store vs server installers
   - Add PRIOR LICENSE SNAPSHOT ACKNOWLEDGEMENT section if not present

4) Tag and release:
   - Tag v1.0.0 (or v1.0.0-commercial if needed)
   - Release notes must state:
     - Commercial licensing applies to official release artifacts
     - Prior publicly available snapshots remain under original license terms

5) Post-change validation:
   - Confirm GitHub detects the new license correctly
   - Confirm no duplicate LICENSE files remain (LICENSE, LICENSE.md, etc.)
   - Confirm README and docs do not reference the old license

============================================================
SECTION – RELICENSING PLAN (v1.0 COMMERCIAL TRANSITION)
============================================================

A. Contributor Ownership Verification
- Extract contributor list (GitHub Insights or git log authors)
- Confirm whether any contributor is an independent human
- Document any required consents (if applicable)

B. Contributor Legal Agreement (Future)
- All future external contributors must sign a CLA for non-trivial contributions.

C. Dependencies License Audit
- Generate full dependency license inventory
- Flag GPL/AGPL/LGPL for review
- Replace or document any conflicts

D. Relicensing Steps (when approved)
1) Replace LICENSE with the commercial proprietary license.
2) Remove outdated badges/references from README and docs.
3) Update license headers if used.
4) Include relicensing notice in release notes (plain language).

============================================================
SECTION – PRIOR LICENSE SNAPSHOT ACKNOWLEDGEMENT
============================================================

Any repository state that was publicly available under GPL-3.0 remains governed by GPL-3.0 for that historical snapshot.

VoiceLink v1.0 commercial release applies to tagged release artifacts and future distributions under the VoiceLink Commercial License.

This ensures clarity between historical open-source repository states and official commercial releases.

============================================================
SECTION – AUTHORSHIP CONFIRMATION (v1.0)
============================================================

Authorship status for VoiceLink prior to v1.0 commercial transition:

- All code contributions were created by Dominique Stansberry.
- Any secondary commit authors visible in Git history were:
  - AI-assisted tooling (e.g., Claude, Codex)
  - Local machines under primary author control
- No independent human contributors have contributed original creative work.

Therefore:
- Dominique Stansberry is the sole copyright holder.
- The project may be relicensed without external consent.
- No Contributor License Agreements are required for past work.
- Future contributors will require CLA prior to merging.

============================================================
SECTION 2 – TARGET ARCHITECTURE (POST v1.0)
============================================================

We are moving to:

PRIVATE (Commercial / Proprietary):
- voicelink-app (desktop + store builds)
- voicelink-server (hosted infrastructure)
License: Commercial + EULA

PUBLIC (Permissive Open Source):
- voicelink-protocol (schemas, specs)
- voicelink-sdk (client SDKs)
License: Apache-2.0 preferred

============================================================
SECTION – STORE VS DIRECT BUILD COMPLIANCE (DISTRIBUTION GATES)
============================================================

Build channels must be enforced via:

DIST_CHANNEL = direct | appstore | playstore | windows_store

Rules:
- direct:
  - Self-updater allowed (must verify signatures)
  - Can use update manifests (e.g., latest-mac.yml)
- appstore:
  - Self-updater MUST be disabled
  - No runtime downloading/executing code
  - Updates must be delivered through the store mechanism
- playstore/windows_store:
  - Apply store-equivalent constraints (no self-updater unless store allows)

Note (v1.0):
- App Store distribution planned but links not live yet.
- DIST_CHANNEL=appstore reserved for future releases.

============================================================
SECTION – SELF-HOSTED SERVER INSTALLERS
============================================================

VoiceLink v1.0 supports self-hosted server deployments.

Rules:
- Self-hosting grants the right to operate a private instance only.
- Redistribution, resale, SaaS hosting, or white-label deployment requires an explicit commercial agreement.
- License keys may be required for certain tiers or federation features.
- Installers must not contain embedded secrets or private API tokens.
- Server builds must clearly identify:
  - version number
  - build channel
  - license mode

All installer artifacts must be reproducible from tagged source.

============================================================
SECTION – VERSIONING RULES
============================================================

Versioning format: MAJOR.MINOR.PATCH

v1.0.0 marks first commercial-ready release.

Rules:
- Breaking changes bump MAJOR.
- New features bump MINOR.
- Fixes bump PATCH.
- Build metadata may include channel tags:
  - 1.0.0-direct
  - 1.0.0-appstore
  - 1.0.0-server

============================================================
SECTION 4 – v1.0 RELEASE CHECKLIST
============================================================

Before publishing:

1) LICENSE consistency check
   - README license matches LICENSE file
   - No conflicting statements

2) Store compliance check (future-proof)
   - Updater disabled in store builds
   - No runtime code download
   - Privacy disclosures documented

3) Direct build verification
   - Updater signed (if enabled)
   - Version numbers consistent
   - latest-mac.yml only used in direct builds

4) Documentation updated
   - README
   - docs/distribution.md
   - docs/licensing.md
   - APP_STORE_CHECKLIST.md

5) Tag release
   - v1.0.0
   - Release notes written clearly

============================================================
SECTION 5 – CONTRIBUTIONS + CLA
============================================================

We allow feature contributions.

Requirements:
- CLA.md must exist.
- CONTRIBUTING.md must require CLA.
- PR templates reference CLA.
- CODE_OF_CONDUCT.md present.
- SECURITY.md present.

============================================================
SECTION 6 – API STRUCTURE (HubNode Integration)
============================================================

HubNode provides backend API patterns.

Conventions:
- hubnode/* repo handles shared API patterns
- api.* or voicelink.*/api/* paths define endpoints/clients
- No hardcoded production URLs
- Base URL must be environment-configurable
- No secrets committed

Agents must:
- Standardize API client layer
- Document API usage in docs/api-integration.md

============================================================
SECTION 7 – WEBSITE + REPO MESSAGING
============================================================

Public messaging must clearly separate:

DIRECT DOWNLOAD
- From website
- May auto-update
- May use license keys

APP STORE
- Updates via store
- No self-updater
- Store-compliant features only

No false “open source” claims if core becomes proprietary.

============================================================
SECTION 8 – REPO SPLIT PLAN
============================================================

Future split steps:

1) Create private repos:
   - voicelink-app
   - voicelink-server

2) Create public repos:
   - voicelink-protocol (Apache-2.0)
   - voicelink-sdk (Apache-2.0)

3) Use git subtree split to preserve history.
4) Archive original repo if needed.

============================================================
SECTION 9 – AGENT EXECUTION RULES
============================================================

Agents must:
- Always create a branch before major changes.
- Produce audit report before changing licenses.
- Never commit secrets.
- Keep documentation screen-reader friendly.
- Update docs when behavior changes.

============================================================
SECTION 10 – TRANSITION NOTICE (FOR README)
============================================================

VoiceLink v1.0 marks the beginning of a distribution transition.
Core application and server components will move to commercial repositories.
Public protocol and SDK components will remain open under a permissive license.

Contributions are welcome under a Contributor License Agreement (CLA).

============================================================
END OF DOCUMENT
============================================================
