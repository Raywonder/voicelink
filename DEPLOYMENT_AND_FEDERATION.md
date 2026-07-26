# VoiceLink – Deployment, Hosting & Federation Configuration

## Overview

VoiceLink is a federated, voice-first communication platform.  
It can run on a dedicated domain, subdomain, sub-path, or root domain.

Each installation is treated as a **node** in a federated network.
Nodes may operate independently or optionally connect to the canonical service.

---

## Core Design Principles

1. Host-based identity (domain or path)
2. Path-aware deployments (no `/` assumptions)
3. Event-based federation
4. Optional central services
5. Accessibility-first design

---

## Canonical Server

Recommended:
https://voicelinkapp.app

Responsibilities:
- Primary API
- Federation registry
- Plugin repository
- Licensing (WHMCS)
- Apple App Store backend

The canonical server is authoritative but does not own user data.

---

## Public API Routing Requirements

Public clients, including iOS TestFlight, macOS, Windows, and browser builds,
must be able to load the server directory from both of these paths:

```text
GET /api/discovery/servers
GET /api/servers
```

`/api/servers` is a compatibility alias for clients that expect the shorter
directory route. It must return the same JSON shape as `/api/discovery/servers`.

Current public routing:

```text
https://voicelinkapp.app              -> main stable VoiceLink runtime
https://community.voicelinkapp.app    -> community VoiceLink runtime
https://voicelink.dev                 -> beta/dev VoiceLink runtime
https://dev.voicelinkapp.app          -> beta/dev VoiceLink runtime alias
```

On shared-IP or cPanel hosts, the exact HTTPS SNI vhost for each domain must
proxy `/health`, `/api/`, `/api/servers`, and `/socket.io/` to the VoiceLink
runtime before any generic cPanel document-root location. If this is missed,
clients can receive an HTML 404 page or a neighboring app's API instead of the
VoiceLink JSON server list.

Before calling a routing change complete, verify the apex, `www` variant, API
directory endpoints, and neighboring sites on the same IP.

---

## Account-Owned Runtime Layout

Every hosted VoiceLink server runtime MUST be organized by the account that owns
or operates that server, then by VoiceLink role and domain. Avoid ambiguous
runtime names such as `voicelink-local`, `local`, or `node2` unless they are
only temporary working directories.

Canonical cPanel/server-account layout:

```text
~/apps/voicelink/
  main/<domain>/
  community/<domain>/
  dev/<domain>/
  cms/<domain>/
  remote/<domain>/
```

Rules:

- `main/<domain>/` is for the account's primary VoiceLink server, for example
  `~/apps/voicelink/main/voicelinkapp.app/`.
- `community/<domain>/` is for community-facing shared servers, for example
  `~/apps/voicelink/community/community.voicelinkapp.app/`.
- `dev/<domain>/` is for development or staging servers, for example
  `~/apps/voicelink/dev/voicelink.dev/`.
- `cms/<domain>/` is for CMS-backed runtimes and integration glue tied to a
  WordPress, Composr, WHMCS, or similar site.
- `remote/<domain>/` is for a server hosted by this account for a remote user or
  organization that does not have a local system account on the same host.
- PM2/systemd/service names MUST include the account or owner context and the
  domain, for example `voicelinkapp.app-main`,
  `community.voicelinkapp.app-community`, or
  `devinecreations.net-cms`.
- Public display names should be human-readable, for example `VoiceLink Main`,
  `Community VoiceLink`, or `VoiceLink Development`, not only `VoiceLink Server`.

Domain ownership rule:

- Domains under the `voicelink` account belong under that account's
  `~/apps/voicelink/...` tree.
- Domains under the `devinecr` account belong under that account's
  `~/apps/voicelink/...` tree.
- Any account hosting VoiceLink for itself or others follows the same structure.

Do not move or rename a live runtime until the process manager entry, reverse
proxy, document root, download links, update manifests, cron jobs, and monitoring
checks have all been updated together.

---

## Node Types

### Main Node
- DNS authority
- Licensing authority
- Plugin distributor
- Always online

### Secondary / VPS Nodes
Example:
https://dev.voicelinkapp.app

- Treated as peer instances
- Register with main server
- Do not issue licenses

### Community / Self-Hosted Nodes
Examples:
- https://example.com/voicelink
- https://voicelink.example.com
- https://voice.home.server

Fully sovereign, federation optional.

---

## Supported Hosting Layouts

- Dedicated domain
- Subdomain
- Sub-path
- Root domain

VoiceLink MUST be path-aware.

---

## Base Path Configuration

Required variables:

BASE_URL=https://example.com  
BASE_PATH=/voicelink  
PUBLIC_URL=https://example.com/voicelink  

No internal route may assume `/`.

---

## Federation Model

Federation is event-based.

Examples:
- Voice session start/end
- Identity verification
- Metadata exchange
- License sync

Nodes may queue events when offline.

---

## Plugin & Feature Distribution

Nodes may pull:
- Base features (free)
- Licensed plugins (paid)
- Optional federation modules

Licensing is enforced by the canonical server.

---

## Apple App Store Compatibility

- Default server provided
- Self-hosting optional
- iOS 16.0+
- TestFlight for testing
- Accessibility guaranteed

---

## Summary

One canonical service.
Many optional homes.
Federation without lock-in.
