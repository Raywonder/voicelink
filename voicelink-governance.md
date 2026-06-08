# VoiceLink Governance – v1.0 Commercial Transition
Last updated: 2026-03-26
Applies to: All agents (Codex, Claude, OpenCode), all repos, all distribution channels AND DEFAULT TEMPLITS IN .GITHUB REPO FOR APPS. UPDATE UNIVERSAL GOVERNANCE.MD AND OTHER .MD RELATED FILES PER APP WHERE NEEDED TO FLLOW APP SETUP IN THIS DIRECTORY FOR APP CREATION AND GENERATIONS ACROSS ALL REPOS..

This document defines the rules for VoiceLink v1.0 and beyond.
This file should not be deleted, but instead read and followed.
But should not be shown in public repo, instead in the .github REPO .GITIGNORE FOLDER OR DOCS folder and kept updated per apP. UPDATE THE TEMPLITS WHERE NEEDED IN THE .GITHUB REPO FOR GITHUB.COM/RAYWONDER/.GITHUB TEMPLITS PATHS WHERE NEEDED FOR ALL REPOS TO USE.
.
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
- Windows installer channel moved to setup EXE with portable fallback
  - `windows-native/dist/VoiceLink-1.0.0-windows-setup.exe`
  - `windows-native/dist/VoiceLink-1.0.0-windows-portable.exe`
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
  - `https://voicelink.devinecreations.net/downloads/voicelink/VoiceLink-1.0.0-windows-setup.exe` should return `200`
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
- macOS public artifact drift still needs final cleanup:
  - local live app validation on 2026-03-20 confirmed restored audio/sound behavior after replacing a stale installed app with a current-source rebuild
  - local live validation also confirmed monitoring works again while joined to rooms
  - built-in macOS audio recovery controls now exist in the app for empty device-list conditions
- current source now applies an internal `+15%` gain boost to desktop input/output sliders so mid-range values are less underpowered
- a fresh universal/public macOS artifact rebuild is still required before replacing public release files
- main server transcription runtime was later provisioned with a working Linux Whisper environment, but live transcript delivery still needs final validation in the room UI
- room-wide media playback, room action consistency, and bot/system message stability remain active regression items
- all docs, bug trackers, download pages, and embedded promo assets must be updated whenever feature wording or deployment behavior changes

Cross-project doc rule:

- VoiceLink, FlexPBX, FlexPhone, and BEMA must each keep:
  - a current status document
  - a maintained README
  - bug-tracker metadata that reflects the real workspace and deploy paths

Media / promo rule:

- Promotional stills and videos must ship with plain-language descriptions.
- If AI-generated promotional media is used, it must stay anchored to the real product behavior and current UI labels.

Per-user server ownership and entitlement rule:

- VoiceLink server licensing must support ownership per server, per install, and per user.
- Each licensed user may own their own VoiceLink server install with its own license key and update path.
- Each running server instance must map back to the authenticated owning account, not only to a machine fingerprint.
- Module updates and server updates must be applied per owned install, not treated as one global license blob across unrelated users.
- The admin and licensing surfaces must show:
  - owning user
  - install identifier
  - server identifier
  - domain or host mapping
  - license state
  - next renewal or entitlement status
- DevineCreations is allowed two primary server entitlements because it operates more than one domain. This is an explicit domain-based exception and must remain visible in billing and licensing logic.
- Server selection views must group servers behind owner buttons, display the number of servers in each owner group, and use server-provided owner/display metadata where available.
- Server owners can choose how their server appears in clients from administrative settings. Discovery APIs should expose owner display name, server display name, display mode, and owner group count information without leaking private install details.
- Future WHMCS and account-entitlement work must treat:
  - one user-owned server install as the normal case
  - domain-based extra install grants as explicit policy exceptions
  - delegated admins and co-owners as management roles, not as silent license owners unless billing policy says otherwise

Documentation governance for VoiceLink:
- Before any new VoiceLink build or public artifact replacement, documentation must follow:
  1. doc update pass
  2. doc review pass
  3. final confirmation
- This applies to:
  - in-app help/docs
  - `docs/` and `source/docs/`
  - downloads pages
  - bugtracker/status pages
  - admin docs
- Live docs should only be replaced from reviewed, current source copies.
- Public builds should not be published against stale docs when the feature set changed.

Governance rule for this state:
- A build may be marked "artifact-complete" before it is marked "deployment-complete"
- "deployment-complete" requires:
  - uploaded files verified on target host
  - PM2 process restarted or confirmed healthy
  - live API/download endpoints checked on the active service port
  - blockers recorded if any of the above fail

====================================================
# Platform Architecture

VoiceLink operates as a distributed platform built around
a gateway architecture.

Core principles:

1. HubNode acts as the API gateway for iOS app and other thirdparty apps if any.
2. Voice services operate independently of external APIs.
3. Federation nodes can be deployed automatically.
4. Domains follow the platform namespace model.

Example:

voicelink.app
   api.voicelink.app
   nodes.voicelink.app
   community.voicelink.app

==================================================
FEDERATION MODEL
==================================================

VoiceLink supports federated server deployments.

Federation nodes may run on:

- main servers
- VPS
- client deployments

Nodes must register with the gateway.

Example endpoint:

/federation/register

Nodes must report:

- hostname
- region
- latency
- capacity

Nodes must never trust external nodes without validation and if clients connect, warn them of verification status but do not block them from joining.
====================================================

## 🎙️ Live Broadcast / Live Streaming Module Governance

### Overview
The **Live Broadcast Module** is an optional, modular component of Voice Link that enables multi-protocol audio and video streaming. This module **must be enabled by the server administrator** before users can access its features.

Supported protocols include:
- RTMP / RTMPS
- Icecast (HTTP-based audio streaming)
- SHOUTcast
- HLS (HTTP Live Streaming)
- Optional future protocols: SRT, WebRTC

The module prioritizes:
- Accessibility-first workflows
- Multi-platform streaming flexibility
- User autonomy and self-hosting
- Secure, auditable operation

---

### Architecture Model

The Live Broadcast Module supports three primary streaming modes:

#### 1. Direct Streaming (Client → Destination)
- Voice Link client publishes directly to a specified endpoint.
- Supports RTMP, Icecast, SHOUTcast, and HLS.
- Users provide server URLs, ports, mount points, and credentials via **Account Settings → Live Broadcast**.

#### 2. Cloud Relay (Client → Voice Link Cloud → Destination)
- Streams route through Voice Link-managed cloud infrastructure.
- Cloud handles protocol conversion, multi-destination routing, failover, and load balancing.

#### 3. Self-Hosted Node (Client → User Node → Destination)
- Optional Node deployment for advanced users.
- Node provides multi-protocol ingest, processing, and relay.
- Offers full control over routing, encoding, and privacy.

---

### Module Administration & Enablement

- Module **must be enabled by server administrators**.
- Administrators configure:
  - Enabled protocols (RTMP, Icecast, SHOUTcast, HLS)
  - Resource limits (bitrate, max streams)
  - Trust-score thresholds for user access
- Default for new users: **disabled** until activation.

---

### Voice Link Node (Self-Hosted Server)

Optional advanced server component:

**Core Features:**
1. **Ingest Module**
   - RTMP / RTMPS
   - Icecast
   - SHOUTcast
   - Optional SRT
2. **Processing Module**
   - Audio normalization, encoding, and transcoding
   - AI modules (transcription, enhancement)
3. **Output / Relay Module**
   - Multi-destination streaming
   - Protocol-specific output
   - HLS segment generation
4. **Control & API Module**
   - REST API and WebSocket interface
   - Stream health monitoring
   - API key generation, revocation, and rotation

---

### API Functionality

The API supports:

- **API Key Management**
  - Server generates keys for clients
  - Keys are securely transmitted and can be revoked or rotated
- **Stream Control**
  - Start, stop, and restart streams
  - Change destination or protocol dynamically
  - Monitor health, bitrate, and latency
- **Protocol Management**
  - Enable or disable protocols per user or deployment
  - Configure default parameters (bitrate, mount, encryption)
- **Account Integration**
  - Module status visible in **Settings → Live Broadcast**
  - Users can view API keys, allowed protocols, and active streams
  - Real-time statistics for each destination
- **Node Monitoring**
  - Status and health checks for self-hosted Nodes
  - Alerts for failures or latency issues

---

### Trust Score Enforcement

Streaming capabilities are tied to **Voice Link Trust Score (0–100)**:

- **0–30**: Local audio processing only, module unavailable
- **30–70**: Single-destination streaming allowed (RTMP, Icecast, SHOUTcast)
- **70–100**: Multi-destination streaming, Node federation, cloud relay, protocol conversion, and advanced API features

Trust score governs protocol access, destination limits, resource usage, and API capabilities.

---

### Security Requirements

All module operations must implement:

- API key authentication (client ↔ server / Node)
- Credential-based authentication for Icecast / SHOUTcast
- Token-based stream publishing and revocation
- TLS/HTTPS encryption where supported
- Optional IP allowlisting for Node endpoints

Unauthorized publishing or key misuse **must be rejected**.

---

### Accessibility Requirements

Module features must:

- Be fully operable via keyboard and screen readers
- Provide real-time audio feedback:
  - Audio levels
  - Connection status
  - Stream health
- Announce state changes clearly:
  - “Streaming started”
  - “Connection lost”
  - “Reconnecting”
- Provide feedback and controls in **Account Settings → Live Broadcast**

---

### Account Settings & VoiceOver-Friendly UI

**Live Broadcast Screen (under Settings tab):**

- **Module Status:** Announces “Enabled” or “Disabled”
- **Active API Keys:** List with creation and expiration dates
- **Allowed Protocols:** RTMP, Icecast, SHOUTcast, HLS
- **Active Streams:** Shows destination, protocol, status, and bitrate
- **Controls:**
  - Generate new API key (announces key generated)
  - Revoke existing key (announces key revoked)
  - Start / Stop stream (announces stream state change)

**VoiceOver Example Announcements:**
- “Live Broadcast Module enabled”
- “API key generated. Key valid for 30 days”
- “Streaming to TikTok via RTMP. Audio level -4 dB. Stable.”

---

### Deployment Guidelines

- Module enabled only by server admin
- Default UX prioritizes Direct or Cloud streaming
- Node deployment optional, advanced users only
- One-command Node setup recommended
- Templates provided for RTMP, Icecast, SHOUTcast, and HLS

---

### Future Considerations

- Automatic fallback between protocols
- Adaptive bitrate based on network conditions
- Distributed Node federation
- AI-assisted audio quality optimization
- Enhanced accessibility telemetry and reporting

---

### Summary

The **Live Broadcast Module** is a modular, multi-protocol system that:

- Supports RTMP, Icecast, SHOUTcast, and HLS
- Provides direct, cloud relay, and self-hosted Node workflows
- Includes API key management, account settings integration, and real-time monitoring
- Maintains accessibility-first design
- Requires server administrator enablement
- Ensures secure, auditable, and user-controlled broadcast capabilities

## VoiceLink Unified Governance, Identity, Federation, Licensing, and Platform Policy, updated or reiterated

This section defines the architectural, operational, and policy requirements for the VoiceLink ecosystem.

Automation systems including development agents, CI pipelines, repository scanners, and internal schedulers must continuously verify the presence of these capabilities.

If functionality described in this section is already implemented, automation must **reuse or extend existing components rather than generating duplicates**.

This policy applies to:

VoiceLink Server
VoiceLink Desktop Client
VoiceLink Web Administration Interface
VoiceLink Mobile Clientt
VoiceLink Plugins
VoiceLink Federation System
VoiceLink Identity Infrastructure

---

# 1. Identity Layer and Account Federation

VoiceLink must implement a unified identity layer capable of linking accounts across multiple services.

Supported identity sources may include:

VoiceLink native accounts
email/password authentication
external OAuth providers
federated social accounts
server-issued credentials

Where possible, authentication systems should be modular and extensible.

Identity linking may include:

community membership mapping
role synchronization
license entitlement mapping
federation trust relationships

If identity functionality already exists within the platform, automation must extend the existing identity layer rather than creating new parallel systems.

---

# 2. Mastodon Integration

VoiceLink must support full integration with **[Mastodon]
This integration may support authentication, identity linking, media hosting, and full administrative integration.

VoiceLink servers may allow Mastodon to act as the primary identity provider.

Capabilities include:

Mastodon OAuth login
profile linking
identity verification
timeline announcements
event notifications
community discovery
Lists
Boosts tied to rooms
VoiceLink may optionally interact with the **[ActivityPub] ecosystem.

Possible integrations include:

voice room announcements
community event notifications
shared identity metadata

---

# 3. Mastodon Instance Support

VoiceLink provides a default Mastodon instance for compatibility and full support.

Administrators may instead use their own Mastodon server.

Supported configurations include:

VoiceLink default Mastodon server
third-party Mastodon servers
self-hosted Mastodon instances

When administrators provide their own Mastodon instance, VoiceLink must support:

authentication via that instance
media storage integration
administrative linking
profile metadata synchronization
Read/write full capability support per user
User wroles
---

# 4. Mastodon Media and Administration

When enabled, Mastodon servers may act as a primary media storage backend.

Media storage may include:

user avatars
room images
event graphics
shared files

VoiceLink administrators may also optionally link moderation or administrative actions with Mastodon moderation workflows.

---

# 5. Mandatory Licensing Requirement

All VoiceLink server installations must possess a valid license.

A license must be generated automatically during installation OR WITHIN 6-48 HOUR TIME FRAME AND STATUS KEPT UPDATED IN ADMIN PANNEL, AND NOTIFICATIONS PUSHED TO SERVER OWNERS OF STATUS OF  LICENSE PROCESS.

Installation metadata may include:

server identifier
installation timestamp
domain or host
server fingerprint

Licenses must be issued by the VoiceLink API, internal licence manager that detects client connections and main api endpoint and both should stay synced when possible.

Servers must refuse to start without a valid license unless within an allowed grace period such as 6hours-48hours and should be shown in admin pannel of such status.

## License Retention and Purge

VoiceLink licensing must support inactivity retention rules for owned installs without deleting installed server data.

Required behavior:

- Main platform servers are exempt from inactivity purge.
- Standard owned installs may be purged from the central API if they have not checked in to the API or otherwise shown activity for a long retention window such as 365 days.
- Before purge, server owners must receive warnings by email and notifications at multiple checkpoints.
- Admins must have a manual purge option.
- Paid non-purge or extended-retention options may keep a license active longer.
- If a license is purged, the installed server data remains intact and the owner may re-register the install later.

The admin and licensing surfaces must show:

- last activity
- scheduled purge date
- warning state
- extension or exemption state
- whether the install is a main-server exemption or a standard owned install

## Supported Site Data Managers

VoiceLink should treat existing WordPress, Composr, and WHMCS installs as managed site integrations, not disposable webroots.

Required behavior:

- Existing database managers and configuration sources may be reused for migration and linking when safe, including cPanel-managed MariaDB/MySQL, WHMCS client and service records, WordPress configuration, and Composr member/site data.
- For WHMCS installs such as `/home/devinecr/public_html`, VoiceLink should preserve the portal root and integrate through addon, template, hook, and client/admin data paths.
- For cPanel-backed installs, VoiceLink should support file-manager friendly sharing roots, owned-domain detection, database hooks, and side-by-side deployment under the account home instead of forcing root replacement.
- Database and identity hooks should allow a newly deployed VoiceLink server to attach to an existing VoiceLink owner when the linked WHMCS, client portal, cPanel, or domain identity already exists.

---

# 6. License Abuse Prevention

The license system must detect and prevent abuse.

Safeguards may include:

duplicate installation detection
hardware fingerprint comparison
domain verification
API request rate limiting
If more then one install is detected, only one install per user is allowed per system.
If suspicious license generation occurs, the API may temporarily restrict license creation.

Existing legitimate installations must not be disrupted.

---

# 7. License Scope

A single license may authorize:

server operation
desktop administration tools
plugin hosting capability
persistent rooms
advanced federation features

Licenses may support feature tiers including:
					personal server
professional server
enterprise deployment

License upgrades must unlock features without requiring server reinstallation.

---

# 8. Storage Architecture

VoiceLink must support pluggable storage engines.

Supported engines include:

JSON storage
SQLite (default embedded storage)
PostgreSQL
MariaDB / MySQL compatible databases

If storage adapters are missing, automation tools must generate them.

---

# 9. JSON Compatibility

VoiceLink must maintain compatibility with JSON configuration files.

Servers must start successfully using JSON-only configuration.

When a database backend is enabled, the system must automatically migrate JSON records.

---

# 10. Federation Architecture

VoiceLink must support decentralized server networking.

Federation features may include:

server discovery
cross-server room discovery
invite links resolving across servers
metadata synchronization

Servers must remain operational if central services become unavailable.

---

# 11. Voice Transport

VoiceLink voice communication must support modular transport systems.

Supported transport layers may include:

WebRTC
UDP voice streaming
Opus audio encoding
relay nodes
hybrid peer/server models

Transport modules must remain replaceable and extensible.

---

# 12. Room Infrastructure

VoiceLink must support:

temporary rooms
persistent rooms
template room packs

Template rooms may include:

Conference Room
Creative Corner
Event Hall
Executive Boardroom
Community Lounge

Administrators must be able to enable, add, delete, hide, or disable default room templates.

---

# 13. Plugin Architecture

VoiceLink must support modular plugins.

Plugins may provide:

authentication providers
analytics tools
CMS integrations
AI services
moderation tools
streaming features

Plugins must load dynamically from a `plugins/` directory.

Each plugin must define:

metadata
permissions
configuration schema
initialization hooks

---

# 14. Plugin UI Hooks

Plugins may register UI hooks for both desktop and web interfaces.

Hooks may generate:

administration pages
analytics panels
configuration screens
dashboard widgets

---

# 15. Desktop-First Administration

The VoiceLink Desktop Client must act as the primary administrative interface.

Administrative capabilities include:

server configuration
room management
user administration
plugin installation
backup management
diagnostics and logging

The interface must remain accessible and keyboard navigable.

---

# 16. Web Administration Interface

The web interface provides secondary administration tools.

The web UI may include:

internal administration pages
plugin configuration
API management
dashboard panels

---

# 17. Backup and Migration

VoiceLink servers must support automated backup systems.

Backups must include:

rooms
users
configuration
plugins
federation data

---

# 18. Supported Archive Formats

VoiceLink must support the following archive formats:

`.flx`
Flex PBX archive format.

`.flxx`
Extended Flex archive format.

`.vclb`
VoiceLink Complete Backup format.

---

# 19. VCLB Archive Structure

Example `.vclb` archive contents:

manifest.json
server-config/
rooms/
users/
database/
plugins/
certificates/
logs/
federation/

Capabilities include:

full server backup
partial backup
encrypted archives
automated restoration
server migration

---

# 20. Offline Operation

VoiceLink must support offline operation.

Capabilities include:

direct IP connections
LAN discovery
manual server entry

Servers must remain usable without central services.

---

# 21. Regression Prevention

All builds must include regression testing.

Testing must verify compatibility across:

server software
desktop client
web interface
mobile clients
plugin APIs
backup systems

CI pipelines must block builds that introduce regressions.

---

# 22. iOS Platform Compliance

VoiceLink mobile clients must comply with Apple platform requirements.

The iOS application must support:

secure authentication
push notifications
voice connectivity
server discovery

Monetization within the iOS client must use Apple's In-App Purchase system.

Possible purchases include:

subscriptions
feature unlocks
persistent room upgrades
hosting tiers

Server APIs must verify purchase entitlements.

---

# 23. Default Internal Web Pages

VoiceLink must provide default internal web pages accessible from both the desktop application and web interface.

Default pages include:

Privacy Policy
Terms of Service
Community Guidelines
Server Information
User Profile Pages

Administrators may customize these pages but default templates must always exist.

---

# 24. Privacy Policy Baseline

VoiceLink installations must include a default privacy policy.

Key principles include:

minimal data collection
user control of personal information
transparent data usage
secure authentication practices

Administrators may customize the policy for their deployment.

---

# 25. Dynamic Content Placeholders

VoiceLink templates must support placeholder fields for automatically inserting server and user information.

Example placeholders:

Server name:

```
{{SERVER_NAME}}
```

Server owner:

```
{{SERVER_OWNER}}
```

Administrator name:

```
{{ADMIN_NAME}}
```

User profile link:

```
{{USER_PROFILE_LINK}}
```

User display name:

```
{{USER_DISPLAY_NAME}}
```

Room or topic title:

```
{{ROOM_TOPIC}}
```

Room description:

```
{{ROOM_DESCRIPTION}}
```

Server status:

```
{{SERVER_STATUS}}
```

These placeholders must be usable within:

system messages
policy pages
notifications
community announcements

Automation tools may dynamically replace placeholders when rendering pages or generating text.

---

# 26. Extensibility Requirement

All VoiceLink systems must remain modular and extensible.

Core subsystems include:

identity
authentication
transport
federation
plugins
administration
backup systems
licensing

Automation tools must prioritize extending existing components rather than creating duplicates.
## VoiceLink Capability Flags and Feature Negotiation

VoiceLink servers must expose a standardized capability flag system that allows clients, plugins, and external integrations to determine what features are supported by a specific server.

This mechanism ensures compatibility between:

VoiceLink Server
VoiceLink Desktop Client
VoiceLink Web UI
VoiceLink Mobile Client
VoiceLink Plugins
Federated VoiceLink Servers

Automation systems must verify that capability flags are present and extend existing implementations rather than creating duplicate systems.

---

# 1. Capability Discovery

VoiceLink servers must provide an endpoint or configuration resource that lists supported capabilities.

Example capability endpoint:

```
/api/capabilities
```

Example response structure:

```
{
  "server_name": "{{SERVER_NAME}}",
  "server_version": "x.x.x",
  "capabilities": [
    "voice_transport_webrtc",
    "voice_transport_udp",
    "persistent_rooms",
    "plugin_support",
    "federation_enabled",
    "mastodon_auth",
    "activitypub_support",
    "backup_vclb",
    "backup_flx",
    "backup_flxx",
    "ios_client_support",
    "desktop_admin_tools",
    "web_admin_interface"
  ]
}
```

Clients must use this information to determine which features should be enabled or disabled within their interfaces.

---

# 2. Feature Negotiation

Clients connecting to a VoiceLink server must negotiate capabilities during connection initialization.

The connection process may follow this model:

Client connects to server
↓
Client requests capability list
↓
Client enables supported features
↓
Unsupported features remain hidden or disabled

This prevents incompatible features from appearing in client interfaces.

---

# 3. Default Capability Categories

Capability flags may be grouped into the following categories.

Voice transport:

```
voice_transport_webrtc
voice_transport_udp
voice_transport_relay
```

Room infrastructure:

```
persistent_rooms
temporary_rooms
room_templates
```

Federation:

```
federation_enabled
federated_room_discovery
remote_invites
```

Identity providers:

```
native_auth
mastodon_auth
oauth_providers
external_identity_linking
```

Administration:

```
desktop_admin_tools
web_admin_interface
plugin_management
```

Backup systems:

```
backup_json
backup_vclb
backup_flx
backup_flxx
```

Mobile compatibility:

```
ios_client_support
push_notifications
iap_enabled
```

Plugins:

```
plugin_support
plugin_ui_hooks
plugin_marketplace
```

---

# 4. Mastodon and Federation Flags

When Mastodon integration is enabled through **[Mastodon] the following capability flags should be exposed.

```
mastodon_auth
mastodon_media_storage
mastodon_profile_linking
activitypub_support
```

The ActivityPub compatibility flag corresponds to **[ActivityPub] integration.

Servers must allow administrators to enable or disable these features.

---

# 5. Licensing Capability Flags

Licensing features must also expose capability flags.

Example flags:

```
license_required
license_verified
license_professional
license_enterprise
```

Clients must hide restricted features when the appropriate license flag is not present.

---

# 6. Plugin Capability Registration

Plugins may register additional capability flags during initialization.

Example plugin capability registration:

```
analytics_plugin
ai_transcription
streaming_watch_party
advanced_moderation
```

Plugins must register their flags through the plugin initialization system.

Clients must dynamically detect plugin capabilities when connecting to a server.

---

# 7. Capability Versioning

Capability flags should include optional version metadata.

Example:

```
{
  "feature": "federation_enabled",
  "version": "1.0"
}
```

This allows future clients to adapt to newer server features.

---

# 8. Backward Compatibility

Clients must gracefully handle unknown capability flags.

If a client encounters an unknown flag:

the feature should be ignored
the connection should remain stable

This ensures forward compatibility with future server features.

---

# 9. Automation and Capability Validation

Automation systems must verify that new features register capability flags when appropriate.

If a subsystem is implemented but no capability flag exists, automation agents must generate one.

This ensures consistent feature discovery across the VoiceLink ecosystem.

---

# 10. Example Capability Template

Example capability template used during server initialization:

```
{
  "server_name": "{{SERVER_NAME}}",
  "owner": "{{SERVER_OWNER}}",
  "admin": "{{ADMIN_NAME}}",
  "server_status": "{{SERVER_STATUS}}",
  "capabilities": [
    "voice_transport_webrtc",
    "persistent_rooms",
    "plugin_support",
    "desktop_admin_tools",
    "web_admin_interface",
    "backup_vclb",
    "mastodon_auth",
    "federation_enabled"
  ]
}
```

Template placeholders may be dynamically replaced when rendering server metadata.

---

# 11. Extensibility Requirement

Capability flags must remain extensible.

New features must register capability flags rather than altering existing flags.

Automation tools must enforce consistent naming conventions and reuse existing capability identifiers whenever possible.

# 📦 Apple Developer Governance & Distribution

## 1. Membership & Account Requirements

### 1.1 Membership Status
- Apple Developer Program membership **must be Active**
- Membership Type: Individual (or Organization if upgraded)
- Expiration date must be tracked and monitored
- Renewal reminder recommended 30 days before expiration

### 1.2 Account Ownership
- Apple ID must be controlled by project owner
- Email must remain accessible
- 2FA must be enabled
- Recovery contact information documented securely

### 1.3 Support Case Tracking
- Store Apple Developer Support case numbers in secure internal documentation
- Reference case IDs when contacting support for enrollment or review issues

---

## 2. App Record Creation (App Store Connect)

### 2.1 App Naming
- Public display name should be consistent across:
  - App Store listing
  - GitHub repository
  - Website branding
- Reserve alternate bundle names early if expansion is planned

### 2.2 Bundle Identifier Strategy
Use reverse domain format:

```
com.devinecreations.voicelink
```

For modular releases:

```
com.devinecreations.voicelink.beta
com.devinecreations.voicelink.enterprise
```

Rules:
- Must match Xcode project exactly
- Cannot be changed after release
- Should not use temporary naming

---

## 3. Code Signing & Certificates

### 3.1 Signing Configuration
- Use Automatic Signing when possible
- Team must be set correctly in Xcode
- Provisioning Profiles must match:
  - Bundle ID
  - Capabilities enabled

### 3.2 Required Certificates
- Apple Development
- Apple Distribution

Certificates should:
- Be backed up securely
- Not be shared insecurely
- Be documented in governance notes

---

## 4. TestFlight Governance

### 4.1 Internal Testing
- Up to 100 internal testers
- No App Review required
- Used for:
  - Accessibility verification
  - API testing
  - Authentication testing

### 4.2 External Testing
- Requires Beta App Review
- Provide:
  - Demo account (if needed)
  - Explanation of features
  - Notes on authentication flow (e.g., Mastodon login)

### 4.3 Beta Notes Template
Each build must include:

- What changed
- Known issues
- Required permissions
- Federation/server dependencies
- Accessibility updates

### 4.4 Execution Runbook (Current)
- macOS app should use HTTPS for remote APIs and only allow HTTP on local/LAN development endpoints.
- If ATS-related errors appear in admin/settings fetches, treat them as release blockers for TestFlight.
- Keep insecure HTTP fallback behavior disabled for store/TestFlight channel by default.

### 4.5 Manual Gate (Safari + Xcode)
TWhen moving from local validation to TestFlight distribution, stop automation and perform these manual steps first:
1. Safari → App Store Connect: verify app record, bundle ID mapping, tester groups, and compliance forms.
2. Safari → app metadata: verify privacy policy URL, support URL, and beta review notes.
3. Xcode Organizer: archive and upload the selected build.
4. Resume automation only after build processing completes and appears in TestFlight.

---

## 5. App Permissions & Privacy Governance

### 5.1 Required Usage Descriptions
If app uses:

- Microphone → `NSMicrophoneUsageDescription`
- Camera → `NSCameraUsageDescription`
- Network → ATS configuration
- Notifications → `NSUserNotificationUsageDescription`

Each string must:
- Clearly explain purpose
- Reference feature functionality
- Avoid vague language

Example:

> “Voice Link uses the microphone for live audio communication between federated servers.”

---

### 5.2 Privacy Policy Requirements
- Public URL required before App Store submission
- Must explain:
  - Federation architecture
  - Data storage location
  - Server synchronization
  - User authentication method (Mastodon OAuth)

---

## 6. Federation & Server Architecture Disclosure

Because Voice Link uses a federated model:

### 6.1 Review Notes Must Include
- Explanation of decentralized hosting
- Clarification that:
  - Users may host independent instances
  - Main server acts as primary federation hub
  - Data is not centrally locked

### 6.2 Demo Server
Maintain:
- Stable primary API endpoint
- Known working federation node for review testing

---

## 7. Mac Catalyst Governance (Optional but Supported)

### 7.1 Catalyst Enablement Policy
Mac Catalyst may be enabled when:
- Shared iOS codebase exists
- Desktop testing is required
- Distribution through Mac App Store is planned

### 7.2 Catalyst Configuration Checklist
- Enable Mac Catalyst in Xcode target settings
- Adjust UI scaling for Mac layouts
- Verify:
  - Keyboard navigation
  - VoiceOver on macOS
  - Window resizing support

### 7.3 When NOT to Use Catalyst
Avoid Catalyst if:
- Native macOS app already exists
- Feature set diverges significantly
- Performance constraints require AppKit

---

## 8. Release Track Strategy

### 8.1 Distribution Phases
1. Internal TestFlight
2. External TestFlight
3. Public App Store Release

### 8.2 Infrastructure Requirements Before Release
- API uptime verified
- Authentication validated
- Federation stable
- DNS records confirmed
- SSL certificates valid

---

## 9. Accessibility Governance

Voice Link is accessibility-first.

### 9.1 VoiceOver Compliance
Each release must verify:
- Proper button labels
- Logical rotor navigation
- Accessible authentication flow
- Status updates announced properly
- Default action behavior is preserved (double-tap opens details/main action)
- Secondary actions are exposed via VoiceOver custom actions (join/preview/etc)
- Focus remains stable after async updates and navigation changes
- Microphone permission flow follows iOS policy (request only, never auto-grant)

Reference baseline for implementation and QA:
- `docs/VOICEOVER_IOS_DEVELOPMENT_BASELINE.md`

### 9.2 Testing Requirements
- Test with:
  - VoiceOver enabled
  - Dynamic Type scaling
  - Reduced motion setting

Accessibility regressions block release.

---

## 10. Future Template Standardization (.github Integration)

All new projects must include:

- Apple Developer checklist
- Signing verification section
- Privacy policy template
- TestFlight notes template
- Catalyst decision checklist
- Federation disclosure template

Recommended repo folder structure:

```
/docs
  governance.md
  privacy-policy.md
  app-store-notes.md
  testflight-template.md
```

---

## 11. Risk & Recovery Governance

### 11.1 Membership Lapse Prevention
- Calendar renewal reminder 30 days before expiration
- Secondary payment method documented

### 11.2 App Store Rejection Handling
- Maintain changelog
- Maintain review communication log
- Respond within 24 hours to review queries

---

## 12. Multi-App Scaling Policy

If future apps are added:

- Maintain unique bundle IDs
- Separate API keys where needed
- Document shared infrastructure dependencies
- Avoid hard-coded server assumptions

## 13. Build Command Automation (Mandatory)

For repeated iOS builds/TestFlight uploads, agents must use:

`cd /Users/admin/dev/apps/voicelink-local/swift-native/VoiceLinkiOS`

`BUILD_NUMBER=<next> AUTO_UPLOAD=1 ./scripts/archive_ios_testflight.sh`

Credential resolution order (no prompt flow):
1. `/Users/admin/dev/appstore/voicelink/ios_testflight_credentials.env`
2. macOS Keychain service `voicelink.transporter`
3. fallback parse from `/Users/admin/dev/appstore/NOTARIZE_CREDENTIALS_NEXT_STEP.txt`

Requirements:
- keep `CODE_SIGN_STYLE=Automatic` for routine archive/upload cycles
- do not persist real account passwords in tracked files
- include `-itc_provider G5232LU4Z7` when using manual transporter commands
- if archive fails, fix project/signing state first, then rerun the same command
- do not switch to manual signing unless release governance explicitly requires it
- before every iOS/TestFlight upload, increment build number (CURRENT_PROJECT_VERSION)
- update `/Users/admin/dev/appstore/voicelink/TESTFLIGHT_BUILD_LEDGER.md` before upload
- duplicate IPA uploads (same checksum / "already uploaded") do not count as update delivery
- "upload-complete" for iOS requires a new processed build visible in App Store Connect/TestFlight

---

# Optional Section: Infrastructure Dependency Notice

Voice Link requires:

- Active primary API server
- SSL certificates
- Domain stability
- DNS propagation

App releases must not occur during server instability.

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
Pages and urls should not return 404 errors or invalid content when linked.
============================================================
Additional VoiceLink details
============================================================
## 1. Platform Philosophy

Voicelink is a hybrid federated voice infrastructure platform designed to:

- Support decentralized identity (Mastodon OAuth)
- Enable self-hosted community server nodes
- Provide native desktop and mobile client
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

## Hosted Runtime Ownership and Naming

VoiceLink hosted server installs are account-owned. The account that owns or
operates a domain must also own the canonical runtime folder for that domain.

Canonical layout:

```text
~/apps/voicelink/
  main/<domain>/
  community/<domain>/
  dev/<domain>/
  cms/<domain>/
  remote/<domain>/
```

Required rules:

- `voicelinkapp.app` belongs under the main VoiceLink account as
  `~/apps/voicelink/main/voicelinkapp.app/`.
- `community.voicelinkapp.app` belongs under the main VoiceLink account as
  `~/apps/voicelink/community/community.voicelinkapp.app/`.
- `voicelink.dev` and development-only servers belong under
  `~/apps/voicelink/dev/<domain>/`.
- CMS-backed runtimes and integration services belong under
  `~/apps/voicelink/cms/<domain>/`.
- Hosted servers for remote owners without local accounts belong under
  `~/apps/voicelink/remote/<domain>/`.
- Devine Creations account servers belong under the Devine Creations account's
  own `~/apps/voicelink/...` tree.
- Any other customer or hosting account follows the same ownership rule.

Process and service names must include owner/domain context. Do not leave
permanent production services named only `VoiceLink`, `voicelink-local`,
`local`, or `node2`. Good examples:

- `voicelinkapp.app-main`
- `community.voicelinkapp.app-community`
- `voicelink.dev-dev`
- `devinecreations.net-cms`

Do not rename or move a live server runtime unless all related PM2/systemd
process names, reverse proxy rules, document roots, update/download manifests,
cron jobs, monitoring checks, and backup paths are updated in the same change.

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

Future WHMCS server-ownership model must support:
- one primary server owner
- up to two additional co-owners
- co-owner delegation and revocation by the primary owner
- admin-config visibility for current ownership and pending ownership billing changes
- WHMCS-backed billing recalculation on the next invoice with proration when ownership changes mid-cycle
- pricing logic where the configured base server price can be split across the active ownership group, with additional service uplift rules applied by the commercial billing configuration

Future federated admin control must support:
- primary/main server initiated remote administration for trusted connected servers without requiring separate direct login to each server
- remote module install, update, enable, disable, uninstall, and config reapply actions from the main server admin UI
- remote server-config sync from main to community/connected servers on an internal-scheduler controlled minute-based interval
- delegated admin authentication from main to trusted servers using short-lived signed server-to-server admin assertions, not raw password replay
- optional auto-authenticate flow so an authorized main-server owner/admin can open a trusted remote server admin surface already authenticated when policy allows
- AI-assisted server maintenance may install, enable, update, or repair missing required modules automatically when policy allows, including on trusted connected servers
- AI auto-install/repair must be limited to approved module-catalog entries and approved dependencies only
- AI auto-install/repair must respect target-server policy for:
- local-only scope
- trusted-linked-server scope
- main-controlled linked-server scope
- AI must not install revoked modules, unknown third-party modules, or modules outside the active governance scope
- AI-driven module changes must be audited, user-visible to admins, and recoverable with rollback or explicit retry if installation/update fails
- hard trust boundaries:
- only explicitly trusted servers may accept remote admin delegation
- only owner/admin roles with the correct federation/admin scope may initiate remote control
- remote actions must be scope-limited and policy-limited per target server
- every delegated admin session and remote module/config action must be audited and visible in admin logs on both the initiating and target servers
- target servers must be able to disable delegated admin, disable remote module management, or require additional confirmation even when linked to the main server
- remote admin must not silently grant billing, licensing, or destructive filesystem authority outside the approved server-management scope
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

============================================================
APPLE CERTIFICATES + APP STORE BILLING AUTORUNBOOK (MANDATORY WHEN NEEDED)
============================================================

Trigger condition:
- Any request mentioning App Store, TestFlight, certificates, signing, IAP,
  subscriptions, payments, payouts, or Apple distribution.

Execution rules:
1. Use next-step-only guidance for beginners.
2. Provide one immediate action at a time.
3. Provide exact field values when data entry is required.
4. Update docs in-place while user progresses.

Certificate order:
1. Apple Development
2. Apple Distribution
3. Developer ID Application
4. Developer ID Installer (optional; only for .pkg)

Required local artifacts:
1. CSR folder must exist:
   - `/Users/admin/dev/appstore/csr`
2. Mapping doc must exist:
   - `/Users/admin/dev/appstore/csr/UPLOAD_ORDER.md`
3. Upload only `.csr`; never upload `.key`.

Create New App minimum fields:
1. Platform
2. App Name
3. Primary Language
4. Bundle ID (exact match with Apple Developer Identifier)
5. SKU (unique internal value)

Payments/subscriptions rules:
1. Default payout destination:
   - App Store Connect -> Agreements, Tax, and Banking -> Banking
2. Real subscription billing starts only when approved and live on App Store.
3. TestFlight billing is non-production test billing.
4. Subscription Product IDs are permanent after creation.

Skip logic:
1. Completed steps must be marked "skip" in docs.
2. Do not repeat completed steps unless explicitly requested.
