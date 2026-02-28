# VoiceLink Governance – v1.0 Commercial Transition
Last updated: 2026-02-28
Applies to: All agents (Codex, Claude, OpenCode), all repos, all distribution channels.

This document defines the rules for VoiceLink v1.0 and beyond.

============================================================
SECTION 0 – CURRENT EXECUTION STATUS (2026-02-28)
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
- Main server SSH access on port `450` was later restored and verified with the shared `raywonder` key for both `root` and `devinecr`
- Main server PM2 status is now confirmed:
  - `voicelink-primary` online
  - `voicelink-hubnode-gateway` recovered and online after installing the missing `nodemailer` runtime dependency
- Main server API surfaces are confirmed healthy:
  - `http://127.0.0.1:3010/api/rooms?source=app` returned room data
  - `http://127.0.0.1:3110/api/rooms?source=app` returned room data
  - both `/api/downloads` endpoints now return current direct-download metadata
- Public main-server checks are confirmed:
  - `https://voicelink.devinecreations.net/admin-invite.html` returned `200`
  - `https://voicelink.devinecreations.net/downloads/voicelink/VoiceLink-windows.zip` returned `200`
- Main-server local auth persistence is now valid again:
  - owner account `domdom` / `d.stansberry@me.com` exists and is verified
  - temporary bootstrap owner used for recovery was removed after the invite claim completed
- WHMCS/admin platform separation is now explicit and must be preserved:
  - `devine-creations.com` = WHMCS install and admin/client-account surface
  - `devinecreations.net` = Composr/site install
- WHMCS built-in updater path is no longer the active blocker:
  - WHMCS was upgraded to `9.0.1-release.1`
  - live PHP `8.2` and public `/admin` login were restored
  - cPanel PHP-FPM metadata for `devine-creations.com` was repaired
  - cPanel package drift caused by broken `python3` alternatives was repaired
- WHMCS admin protection baseline was restored after recovery:
  - `forceadmin=1`
  - TOTP module remains enabled for admins and clients
- Active VoiceLink runtime drift was corrected in `server/routes/local-server.js` and deployed to live server copies:
  - WHMCS auth endpoints now exist on active runtimes:
    - `/api/auth/whmcs/login`
    - `/api/auth/whmcs/session/:token`
    - `/api/auth/whmcs/logout`
    - `/api/auth/whmcs/sso/start`
  - non-WHMCS installs may now delegate WHMCS auth to a central authority instead of requiring local WHMCS credentials
  - main runtime now accepts WHMCS admin-bridge sessions as real admin sessions for:
    - `/api/admin/status`
    - admin-invite actions
    - admin-only request checks that use the shared request auth resolver
  - VPS/community server now delegates WHMCS auth to the directly reachable main API authority:
    - `http://64.20.46.178:3010`
    - this is required because VPS-to-main public `443` is not reachable even though direct API port `3010` is reachable
  - socket session registration for `provider=whmcs` is now present on active runtimes
  - live smoke tests now pass on main and VPS:
    - main `POST /api/auth/whmcs/login` succeeds for WHMCS admin `Domdom`
    - VPS delegated `POST /api/auth/whmcs/login` succeeds for the same admin
    - main and VPS `/api/admin/status` now recognize the returned WHMCS admin bearer token as administrative
    - room APIs remain healthy after restart
  - VPS frontend shell drift was corrected:
    - the stale download-only `client/index.html` was replaced with the auth-capable app shell
    - top-level `client/js` and `client/css` were synced so `/js/core/app.js` and `/css/style.css` resolve again

Known deployment blockers still requiring follow-up:
- WHMCS-backed VoiceLink admin-role sync is improved but not complete:
  - current live WHMCS login bridge authenticates WHMCS admins directly and client accounts through WHMCS API
  - deeper mapping of WHMCS admin/staff/client roles, product tiers, and install/server-license entitlements still needs a dedicated integration pass
- WHMCS member "username" login is limited by the current WHMCS schema on main:
  - `tblusers` currently exposes email/password and second-factor fields, but no native username column
  - VoiceLink now supports WHMCS login by:
    - email address
    - WHMCS admin username through the admin bridge
    - synced/local VoiceLink username aliases that resolve to a WHMCS email
  - arbitrary WHMCS-only client usernames are not available until the upstream account model provides or syncs a stable username field
- Repository drift still exists:
  - `server/routes/local-server.js` is the active runtime
  - `source/routes/local-server.js` is the closer source mirror
  - `source/server/routes/local-server.js` is an older divergent copy and must not be treated as the canonical auth/runtime source during rebuilds

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
Additional VoiceLink details
============================================================
## 1. Platform Philosophy

Voicelink is a hybrid federated voice infrastructure platform designed to:

- Support decentralized identity (Mastodon OAuth)  
- Enable self-hosted community nodes  
- Provide native desktop and mobile clients  
- Prioritize accessibility at the system level  
- Integrate AI-assisted transcription and analysis  
- Separate infrastructure from tokenization (Ecripto remains independent)  

Voicelink is not a cryptocurrency exchange or custody service.

---

## 2. Federation & Identity

- Any Mastodon-compatible instance may authenticate users.  
- Feature access is determined dynamically based on OAuth scopes and API capability.  
- Nodes may be classified as:
  - **Full Capability**
  - **Partial Capability**
  - **Restricted Capability**  

- Users are notified if compatibility limitations exist.  
- Administrator Outreach: Users may request expanded compatibility via API-generated email templates.  

Login Methods:

- Mastodon OAuth (primary federated identity)  
- Email/password fallback  
- Sign in with Apple (iOS compliance)  
- License key validation (desktop)

---

## 3. Node Infrastructure

- Self-hosted Voicelink nodes register automatically with the central API.  
- Nodes send health checks and report active rooms.  
- Nodes may implement AI features locally, including Whisper for transcription and LLaMA models for automated notes.  
- Nodes retain moderation responsibility and are responsible for maintaining API authentication.  

Fallback & Routing:

- If local or connected servers are available via API, they are used as the primary connection for audio and AI features.  
- Central servers act as fallback when no user-owned or connected nodes are available.  

---

## 4. Audio Architecture – Hybrid Model

**Connection Flow:**

1. **Peer-to-Peer (P2P) first**
   - Direct connection using WebRTC.
   - Low latency, minimal bandwidth usage.
   - Accessibility: VoiceOver announces “Connecting peer-to-peer…” and status changes.

2. **Server Relay Fallback**
   - Activated when P2P fails due to NAT, firewall, or network limitations.
   - Relays audio through node or central server.
   - Recording, moderation, or logging possible if relay is used.

3. **Dynamic Switching**
   - Automatic monitoring of connection quality.
   - Switches seamlessly between P2P and server relay.

**Benefits:**

- Optimized bandwidth usage  
- Reliable connection across heterogeneous devices  
- Supports accessibility with real-time status announcements  
- Supports recording & moderation where necessary  

**Recording Notification:**

- Users are informed when sessions are recorded:  
“Session is being recorded via server relay.”

---

## 5. AI Integration

- **Local Whisper**: Transcription of live audio on the user’s device.  
- **Server-side LLaMA models**: Automatic generation of notes and summaries for sessions.  
- AI features integrate across nodes via API when permitted.  
- AI-generated content respects privacy; nodes retain control of stored data.

---

## 6. Trust Score System

- Every user account has a **Trust Score** (0–100) used to determine access to advanced features.  
- Trust Score is dynamically updated based on:
  - Node reputation
  - Behavior history
  - Feature usage  
- Access thresholds may be applied before enabling API features, transcription, or moderation privileges.  

---

## 7. Client Architecture

### macOS
- Native Swift (SwiftUI / AppKit)  
- Core Audio + AVFoundation for low-latency audio  
- Secure token storage in Keychain  
- Intel Mac primary build environment, universal binaries for Apple Silicon optional  

### Windows (Planned)
- Native Windows framework (WinUI 3 recommended)  
- Native accessibility integration with UI Automation  

### iOS
- Native Swift  
- In-App Purchases required for premium features  
- OAuth via system authentication session  

Cross-platform frameworks (Electron) are no longer used due to layout inconsistencies and accessibility limitations.

---

## 8. API Versioning

All endpoints are versioned to maintain compatibility across native clients:

- `/v1/auth`  
- `/v1/rooms`  
- `/v1/nodes`  
- `/v1/license`  

Breaking changes increment the version; legacy endpoints remain supported until deprecation.

---

## 9. Accessibility Commitment

Accessibility is a core principle:

- Full VoiceOver support  
- Deterministic focus order  
- Explicit state announcements for audio and UI events  
- Keyboard-first navigation  
- No critical gesture-only controls  
- Audio and recording state changes are announced  

Accessibility regressions are treated as critical bugs.

---

## 10. Monetization Model

- **Desktop:** WHMCS license verification, secure API validation  
- **iOS:** Apple In-App Purchases required for premium features  
- **Node Hosting:** Free core functionality, optional premium features via subscription  
- Desktop licenses do not bypass iOS IAP requirements  

---

## 11. Separation of Ecosystems

- Voicelink operates independently of Ecripto token infrastructure and Divine Creations hosting.  
- Future tokenization (if any) will be evaluated separately.  

---

## 12. Key Governance Notes

- Federation is open by philosophy; full feature access depends on node/operator permission.  
- Nodes may be certified as “Voicelink Compatible” for best user experience.  
- Users retain agency; administrators retain responsibility.  
- Hybrid P2P/server audio routing ensures reliable connections.  
- AI integration provides transcription and note generation while respecting node ownership.  
- Trust Score system safeguards access to sensitive features.
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
SECTION – AUTH + LICENSE + ACCESS SURFACES (MULTI-PROVIDER, MULTI-DB, RESILIENT)
VoiceLink MUST support multiple authentication providers, multiple license authorities, and configurable access surfaces (desktop-first, optional web UI) without making any single external service a hard dependency.
Agents MUST update existing implementations in-place where they already exist and work, and MUST NOT create duplicate competing runtimes or duplicate route trees.
 
A) PLATFORM PRIORITY + ACCESS SURFACES (DESKTOP-FIRST)
Primary access surfaces:
• 
Desktop Apps (macOS + Windows) are the primary “full feature” clients.
• 
Full access to VoiceLink features MUST be available via desktop apps.
Optional access surfaces:
• 
Web UI may be enabled or disabled per install at the server owner’s discretion.
• 
If Web UI is disabled, users must be guided to use native apps for joining rooms and managing accounts.
Rules:
• 
Disabling Web UI MUST NOT break APIs needed by native apps.
• 
When Web UI is disabled, server must return a clear, accessible message for web routes:
• 
“Web access is disabled by the server owner. Please use the VoiceLink desktop or iOS app.”
• 
Server owners must be able to control:
• 
public web landing visibility
• 
room directory visibility
• 
unauthenticated guest access
• 
which rooms can be joined via each surface (web vs apps)
All access-surface controls MUST be configurable in:
VoiceLink Admin Dashboard → Settings → System Configuration (or equivalent)
 
B) PROVIDER ABSTRACTION (SOURCE OF TRUTH)
VoiceLink MUST implement provider abstraction so authentication and licensing can be switched, combined, or degraded without downtime.
VoiceLink implements two independent provider interfaces:
1. 
AuthProvider
• 
startLogin()
• 
handleCallback()
• 
validateSession()
• 
logout()
• 
getUserProfile()
• 
linkIdentity()
• 
unlinkIdentity()
• 
healthCheck()
2. 
LicenseProvider
• 
validateLicenseKey()
• 
validateEntitlements()
• 
refreshEntitlements()
• 
syncEntitlements()
• 
healthCheck()
VoiceLink runtime MUST call providers only through these interfaces.
 
C) AUTH PROVIDERS (SUPPORTED)
VoiceLink MUST support the following authentication providers (enable/disable per install):
Core providers:
• 
Native (email/username + password)
• 
WHMCS (client identity + optional licensing)
• 
Mastodon OAuth (federated identity)
• 
WordPress (OAuth/JWT/Application Passwords)
Modern SSO providers:
• 
Google Sign-In (OAuth 2.0 / OpenID Connect)
• 
Sign in with Apple (OAuth / OpenID Connect; required for iOS compliance where applicable)
• 
GitHub (OAuth)
• 
(Optional extensible set) Microsoft, GitLab, Discord, etc via generic OIDC/OAuth adapter
Rules:
• 
Providers may be enabled individually.
• 
Provider configuration must be environment-configurable and editable in admin UI.
• 
Provider linking must attach identities to the same user record (no accidental duplicate accounts).
• 
Provider outages must not invalidate existing sessions.
 
D) LICENSE AUTHORITIES (SUPPORTED)
VoiceLink MUST support multiple licensing authorities without breaking operation:
• 
WHMCS Authority (external commercial authority)
• 
VoiceLink Native License Manager (local authority)
• 
Hybrid Sync Mode (WHMCS primary with native mirrored signed tokens)
• 
Offline Grace Mode (native temporary authority when upstream is unavailable)
• 
Native-Only Mode (no WHMCS installed; VoiceLink manages licensing internally)
Rules:
• 
Existing sessions must not be invalidated solely due to WHMCS downtime.
• 
License checks must support a configurable grace window (recommended 24–72 hours).
• 
Licensing must not interrupt audio/room connectivity.
• 
iOS builds must obey platform policies (IAP requirements) regardless of licensing authority.
 
E) REQUIRED IMPLEMENTATIONS (MINIMUM MODULE SET)
Agents MUST implement or preserve these modules (update in-place if already present):
Auth:
• 
providers/auth/native
• 
providers/auth/whmcs
• 
providers/auth/mastodon
• 
providers/auth/wordpress
• 
providers/auth/google
• 
providers/auth/apple
• 
providers/auth/github
• 
providers/auth/oidc (generic adapter)
License:
• 
providers/license/native
• 
providers/license/whmcs
• 
providers/license/hybrid
System:
• 
authority-state-machine (HEALTHY/DEGRADED/UNAVAILABLE per provider)
• 
sync scheduler (internal, reliable, idempotent)
• 
encrypted settings store + secrets handling
• 
audit log events for auth/licensing/recovery actions
Non-negotiable:
• 
Agents MUST NOT create duplicate route trees or parallel server entrypoints.
• 
Use existing working paths/routers as the canonical implementation if no change is required.
• 
Canonical runtime source for changes must match the active deployment structure:
• 
server/routes/local-server.js is active runtime
• 
source/routes/local-server.js is mirror
• 
source/server/routes/local-server.js is older divergent copy and must not be treated as canonical
 
F) STORAGE BACKENDS (MULTI-DB SUPPORT)
VoiceLink MUST support multiple data stores for user/session/license/system metadata:
Supported DB engines:
• 
SQLite (default for local installs and small nodes)
• 
MySQL
• 
MariaDB
• 
PostgreSQL
Rules:
• 
Data models must remain consistent across DB backends.
• 
Migrations must be automated and idempotent.
• 
Provider-agnostic core tables/collections must exist for:
• 
users
• 
identities (linked provider identities per user)
• 
sessions
• 
roles + roleAssignments
• 
licenseEntitlements
• 
trustScore
• 
recoveryTokens + recoveryCodes
• 
systemSettings (auth + smtp + notifications + provider configs)
• 
syncJobs + jobHistory
• 
auditLog
 
G) FIRST-RUN OWNER BOOTSTRAP (ADMIN = OWNER)
On first setup of any VoiceLink install:
• 
The first successfully created admin account MUST be assigned Owner of the install.
• 
Owner is the highest local authority role (Owner > Admin > Moderator > User).
• 
Owner privileges MUST remain enforceable even if external providers are unavailable.
Owner assignment:
• 
If the first user is created via any provider (WHMCS/Mastodon/WordPress/Google/Apple/GitHub/Native) and is designated admin (or installer marks them admin), they become Owner.
• 
If upstream provider lacks role concept, installer must explicitly prompt: “Designate this first account as Owner?”
Installer MUST generate an Owner Recovery Kit:
• 
One-time recovery codes (displayed once, exportable)
• 
“Break Glass” instructions (local-only recovery)
• 
A reminder if SMTP is not yet configured
 
H) SMTP + EMAIL BOOTSTRAP (BUILT-IN MAIL CONFIG)
VoiceLink must support email notifications and recovery via SMTP.
Rules:
• 
SMTP setup is optional at install time.
• 
If SMTP is not configured:
• 
Owner/admin credentials and recovery codes MUST still be displayed once and saved locally/exportable.
• 
System must remind admins that email delivery is disabled.
• 
When SMTP is configured later:
• 
System can optionally re-send account setup emails and enable email-based recovery.
SMTP configuration must be available in:
Admin Dashboard → Settings → Authentication/Login (or System Configuration)
Required templates:
• 
account created
• 
admin created
• 
password reset
• 
recovery code usage
• 
provider link/unlink notices
• 
license grace mode warnings (optional)
• 
provider health degradation alerts (optional)
 
I) ACCOUNT RECOVERY (NO DB DIGGING)
VoiceLink MUST provide recovery methods that do not require database access:
Required recovery methods:
• 
One-time recovery codes (install-time and regenerable)
• 
Email-based reset (when SMTP configured)
• 
Admin “Break Glass” recovery mode (local-only, time-limited, logged)
• 
Provider re-link recovery (Mastodon/WordPress/WHMCS/Google/Apple/GitHub)
Rules:
• 
Break Glass mode requires local server access or pre-issued recovery key.
• 
All recovery events must be audited and visible in admin UI.
• 
Recovery flows must be screen-reader friendly and deterministic.
 
J) IDENTITY LINKING + ROLE/ENTITLEMENT RESOLUTION
Users may link multiple identities:
• 
Mastodon OAuth identity
• 
WordPress identity
• 
WHMCS identity
• 
Google identity
• 
Apple identity
• 
GitHub identity
• 
Native identity (email/username+password)
Rules:
• 
Linking identities must not create duplicate user accounts.
• 
Each user has a configurable “Primary Login Method,” but may switch methods if allowed.
• 
Role + entitlement resolution must be deterministic with documented precedence rules.
Suggested precedence (configurable):
1. 
Owner override (local)
2. 
Local role assignment (VoiceLink)
3. 
WHMCS entitlements/roles (if enabled)
4. 
Provider claims mapping (OIDC scopes/claims)
5. 
Default role (User)
 
K) SYNC SCHEDULER (BUILT-IN, IDP + LICENSE SYNC)
VoiceLink includes a built-in internal scheduler to keep data in sync across providers and authorities.
Scheduler responsibilities:
• 
Provider health checks
• 
Identity sync (profile updates, verified email status, etc.)
• 
Role/entitlement refresh
• 
License token refresh (hybrid mode)
• 
Cleanup/rotation of session tokens
• 
Alert dispatch for repeated failures
Rules:
• 
Jobs are queued, retried with exponential backoff, and recorded in jobHistory.
• 
Sync must be idempotent (safe to re-run).
• 
Provider unavailability flips only that provider to DEGRADED/UNAVAILABLE.
• 
Sync never interrupts audio/room connectivity.
 
L) DEGRADED MODE + OFFLINE GRACE (RESILIENCE)
VoiceLink tracks provider health:
• 
HEALTHY
• 
DEGRADED
• 
UNAVAILABLE
Behavior:
• 
Existing sessions continue normally.
• 
New login attempts fail only for the impacted provider with precise messaging:
• 
“Authentication provider temporarily unavailable.”
• 
License checks may enter OFFLINE_GRACE for a configurable window.
• 
Audio and room connectivity MUST NOT be interrupted by auth/licensing outages.
• 
Admins should receive alerts when a provider enters DEGRADED/UNAVAILABLE.
 
M) ADMIN UI REQUIREMENTS (AUTHENTICATION/LOGIN TAB)
All provider configuration, linking controls, health indicators, recovery tools, and sync status MUST be available within:
Admin Dashboard → Settings → Authentication/Login (or System Configuration)
This settings area must include:
• 
enable/disable toggles for each provider (native, whmcs, mastodon, wordpress, google, apple, github, oidc)
• 
provider configuration forms (URLs, client IDs, secrets, scopes, redirect URIs)
• 
provider health indicators + last check time
• 
role mapping rules per provider
• 
license authority mode selection (WHMCS_PRIMARY / HYBRID_SYNC / NATIVE_ONLY / OFFLINE_GRACE)
• 
SMTP configuration + send test email
• 
recovery settings (codes, break-glass)
• 
sync scheduler status + job history
• 
web UI access toggles (enabled/disabled; landing, directory, join rules)
• 
guest access toggles + restrictions by surface
• 
audit log viewer for auth/licensing/recovery actions
Rule:
• 
This tab is additive: create missing sections only; update existing sections if incomplete; never duplicate.
 
N) NOTIFICATIONS (PUSHOVER SUPPORTED)
VoiceLink supports Pushover notifications for operational and security events.
Requirements:
• 
Full Pushover API support is allowed and encouraged for admin alerts.
• 
Configurable per install and optionally per admin user.
• 
Can be disabled globally or per alert type.
Recommended alert triggers:
• 
auth provider enters DEGRADED/UNAVAILABLE
• 
license grace mode activated
• 
repeated sync job failures exceed threshold
• 
SMTP misconfiguration detected
• 
break-glass recovery used
• 
DB unreachable or migration failure
• 
core runtime process health failure (PM2/system service down)
 
O) STORE CHANNEL COMPATIBILITY (DIST_CHANNEL)
DIST_CHANNEL rules apply:
• 
direct builds:
• 
self-updater allowed (must verify signatures)
• 
server-managed licensing allowed
• 
appstore builds:
• 
self-updater disabled
• 
premium unlock must comply with Apple IAP policies
• 
playstore/windows_store:
• 
store-equivalent constraints apply
Auth providers may be available across platforms, but entitlements must respect channel constraints.
============================================================
END SECTION
============================================================
PATCH LIST + IMPLEMENTATION PLAN (AGENT-EXECUTABLE)
Agents MUST implement the above using the existing working runtime and routes where possible.
Do not introduce parallel server entrypoints.
A) CANONICAL ENTRYPOINTS (DO NOT DUPLICATE)
• 
Use: server/routes/local-server.js (active runtime)
• 
Mirror updates in: source/routes/local-server.js
• 
Do NOT treat: source/server/routes/local-server.js as canonical
B) FILES TO ADD (ONLY IF MISSING)
1. 
server/auth/provider-interface.js
• 
Exports AuthProvider base interface + adapter helpers
2. 
server/auth/providers/
• 
native/
• 
native-provider.js (email/username + password)
• 
native-routes.js (register/login/logout/session)
• 
whmcs/
• 
whmcs-provider.js (existing endpoints kept; refactor into provider)
• 
mastodon/
• 
mastodon-provider.js (OAuth)
• 
wordpress/
• 
wordpress-provider.js (JWT/OAuth/App Passwords adapters)
• 
google/
• 
google-provider.js (OIDC)
• 
apple/
• 
apple-provider.js (OIDC)
• 
github/
• 
github-provider.js (OAuth)
• 
oidc/
• 
oidc-provider.js (generic OIDC adapter for future providers)
3. 
server/license/provider-interface.js
• 
Exports LicenseProvider base interface
4. 
server/license/providers/
• 
native/
• 
native-license-provider.js
• 
token-signer.js (signed entitlement tokens)
• 
whmcs/
• 
whmcs-license-provider.js
• 
hybrid/
• 
hybrid-license-provider.js (WHMCS + mirrored local token)
5. 
server/system/
• 
authority-state-machine.js (provider health tracking)
• 
health-monitor.js (periodic provider checks)
• 
scheduler.js (job queue + retry/backoff)
• 
jobs/
• 
sync-identities.js
• 
sync-entitlements.js
• 
refresh-license-tokens.js
• 
rotate-sessions.js
• 
provider-health-check.js
• 
audit-log.js
6. 
server/storage/
• 
db.js (adapter layer: sqlite/mysql/mariadb/postgres)
• 
migrations/ (idempotent migrations)
• 
models/ (users, identities, sessions, roles, entitlements, recovery, settings, jobs, audit)
7. 
server/notifications/
• 
notifier-interface.js
• 
pushover-notifier.js
8. 
server/admin-ui/
• 
settings-authentication-login.js (schema + handlers backing the admin dashboard tab)
• 
settings-system-config.js (web UI toggles, guest access, surface rules)
• 
(If UI already exists elsewhere, update in-place instead of creating new)
C) FILES TO UPDATE (IN-PLACE)
1. 
server/routes/local-server.js
• 
Route existing working WHMCS endpoints through provider abstraction (no behavior regressions)
• 
Add auth provider routing without breaking current paths
• 
Add surface gating (web enabled/disabled) for web routes only
• 
Ensure API routes used by desktop apps remain available
2. 
source/routes/local-server.js
• 
Mirror the same changes as runtime source-of-truth
3. 
Any existing auth/whmcs bridge code
• 
Keep paths stable:
• 
/api/auth/whmcs/login
• 
/api/auth/whmcs/session/:token
• 
/api/auth/whmcs/logout
• 
/api/auth/whmcs/sso/start
• 
Only refactor behind the interface; do not change URLs unless absolutely necessary
D) CONFIG (ENV + ADMIN UI)
• 
Add config schema (if missing):
• 
AUTH_PROVIDERS_ENABLED (comma list)
• 
LICENSE_AUTHORITY_MODE (WHMCS_PRIMARY | HYBRID_SYNC | NATIVE_ONLY | OFFLINE_GRACE)
• 
DB_ENGINE (sqlite | mysql | mariadb | postgres)
• 
DB_URL / DB_HOST/USER/PASS/NAME
• 
SMTP_HOST/PORT/USER/PASS/FROM
• 
PUSHOVER_APP_TOKEN / PUSHOVER_USER_KEY
• 
WEB_UI_ENABLED (true/false)
• 
GUEST_ACCESS_ENABLED (true/false)
• 
PROVIDER-specific OAUTH creds (GOOGLE_CLIENT_ID, etc.)
Admin Dashboard must allow editing these safely (store secrets encrypted).
E) MINIMUM FUNCTIONALITY GATES (MUST PASS)
• 
Existing WHMCS auth endpoints keep working with same paths and expected behaviors
• 
Desktop apps retain full access regardless of web UI enabled/disabled
• 
Web UI disablement only blocks web pages, not APIs
• 
First admin becomes Owner; Recovery Kit generated even without SMTP
• 
Recovery flows work without database access
• 
Provider DEGRADED/UNAVAILABLE states show precise errors for new logins
• 
Existing sessions continue; license grace prevents sudden lockouts
• 
Scheduler jobs run; failures logged; optional Pushover alerts fire
F) AGENT OUTPUT REQUIREMENTS (MANDATORY)
When implementing this section, the agent MUST output:
1. 
Files changed/created (exact paths)
2. 
What was generated vs updated
3. 
Any placeholders inserted (clear list)
4. 
Any admin pages/paths requiring updates
5. 
Validation checklist results:
• 
No duplicate runtime entrypoints created
• 
Existing WHMCS auth endpoints unchanged
• 
Desktop-first behavior verified
• 
Web UI gating verified
• 
Recovery + owner bootstrap verified
• 
Provider health states verified
• 
No secrets committed
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
END PATCH LIST + IMPLEMENTATION PLAN
============================================================
END OF DOCUMENT
============================================================
