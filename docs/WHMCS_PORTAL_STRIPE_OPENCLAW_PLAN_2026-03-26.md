# WHMCS, Stripe, and OpenClaw Integration Plan

Last updated: 2026-03-26

## Current Truth

- VoiceLink already has WHMCS auth and client-portal routing in source.
- VoiceLink already has passkey, 2FA, wallet-access, and payment-provider config surfaces in source.
- Stripe config already exists in deploy config under both:
  - `payments.providers.stripe`
  - legacy `stripe`
- OpenClaw already has a supported macOS onboarding and daemon flow.

## VoiceLink / WHMCS Portal Direction

The WHMCS client portal surfaces should be updated so they align with the newer platform direction:

- account portal login
- passkeys
- notifications
- wallet access where enabled
- 2FA
- linked-service awareness for VoiceLink, FlexPBX, FlexPhone, and future user-owned installs

Relevant current source anchors:

- [deploy-config.js](/Users/admin/dev/apps/voicelink-local/server/config/deploy-config.js)
- [local-server.js](/Users/admin/dev/apps/voicelink-local/server/routes/local-server.js)
- [app.js](/Users/admin/dev/apps/voicelink-local/client/js/core/app.js)

## Stripe

Current config location:

- `payments.providers.stripe`
- `stripe` legacy compatibility section

Needed admin/client portal work:

1. show which Stripe mode is active
2. expose publishable-key presence without exposing secrets
3. map billing products to owned installs and license entitlements
4. show renewal / payment state cleanly in client-facing surfaces

## OpenClaw on This Mac

OpenClaw already documents the supported local path:

- `openclaw onboard --install-daemon`
- `openclaw doctor`
- `openclaw gateway --port 18789 --verbose`

The current desired outcome is:

- OpenClaw running locally on this Mac
- Codex/OpenAI-backed account auth available where permitted
- stable daemon/gateway workflow
- future bridge into Raywonder project operations

## TappedIn Sales Account for Ale

Target:

- dedicated sales account under the `tappedin.fm` domain
- usable for Ale
- separated from owner/admin credentials
- can later map into WHMCS/client portal and service ownership

This should be modeled as:

- account identity
- portal access
- billing/contact role
- service/license ownership visibility
- least-privilege permissions

## Next Implementation Order

1. update WHMCS client portal/account docs and config mapping
2. expose the right Stripe state in admin/client-facing config
3. bring up OpenClaw locally on this Mac with a clean daemon path
4. create and document the TappedIn sales-account model for Ale
