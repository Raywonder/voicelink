# VoiceLink Installatron + Browser UI Integration

This package assumes VoiceLink already has an existing browser-based web UI and adds an Installatron + WHMCS licensing layer around it.

## Goal
Deploy the existing VoiceLink web UI under:
- a root domain
- a subdomain
- or a subdirectory

Then link licensing, install registration, and install status into the existing web UI and desktop admin control panel.

## Install target examples
- `https://example.com/`
- `https://portal.example.com/`
- `https://example.com/voicelink/`

## Core assumptions
- WHMCS is the billing and license authority
- Installatron handles the web deployment lifecycle
- VoiceLink server validates the license and install target
- The web UI exposes an admin page for install/license status
- The desktop admin control panel can call the same endpoints

## Existing web UI integration points
The existing browser UI should gain:
- an Install Status page
- a License Status page
- a Domain/Path binding viewer
- a Refresh License action
- a Reissue Request action
- a link to the WHMCS client-area product/service when available

## Suggested browser routes
- `/admin/install`
- `/admin/license`
- `/admin/domain-binding`

## Suggested API routes
- `POST /api/install/register`
- `POST /api/install/validate-license`
- `POST /api/install/reissue-request`
- `POST /api/install/report-path-change`
- `GET /api/install/status`
- `GET /.well-known/voicelink.json`

## Web UI behavior
The browser admin UI should show:
- current install ID
- current domain
- install path
- install type: root, subdirectory, or subdomain
- product tier
- license status
- last successful validation
- next remote check

## `.well-known`
Safe optional file:
- `/.well-known/voicelink.json`

Keep `acme-challenge` untouched.

## Desktop admin alignment
The desktop admin panel should read the same data model used by the browser UI so both stay in sync.
