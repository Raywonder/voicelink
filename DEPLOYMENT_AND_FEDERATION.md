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
https://voicelink.devinecreations.net

Responsibilities:
- Primary API
- Federation registry
- Plugin repository
- Licensing (WHMCS)
- Apple App Store backend

The canonical server is authoritative but does not own user data.

---

## Node Types

### Main Node
- DNS authority
- Licensing authority
- Plugin distributor
- Always online

### Secondary / VPS Nodes
Example:
https://node2.voicelink.devinecreations.net

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
