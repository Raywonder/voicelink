# Live Deploy Checklist — Downloads, TestFlight Flow, and WHMCS Callback

Date: April 22, 2026

## Scope

This deploy set covers:

- Website download pages
- Server-side TestFlight invite request flow
- SMTP-backed invite delivery
- Optional Cloudflare alternate invite link
- WHMCS PayPal callback compatibility endpoint

## Current Live Status

As of April 22, 2026, this URL still returns `HTTP/2 406` on the live host:

- `https://devine-creations.com/modules/gateways/callback/paypal.php`

That means the live WHMCS host has not yet been updated with the new compatibility callback file.

## Files To Deploy

### Website Pages

Deploy these files to the web root that serves the download pages:

- [index.html](/Users/admin/git/Raywonder/voicelink/index.html)
- [downloads.html](/Users/admin/git/Raywonder/voicelink/downloads.html)
- [downloads-enhanced.html](/Users/admin/git/Raywonder/voicelink/downloads-enhanced.html)
- [client/downloads.html](/Users/admin/git/Raywonder/voicelink/client/downloads.html)

Expected result:

- No raw TestFlight join URL in page HTML
- Email request form instead of direct TestFlight link
- Required human checkbox
- Hidden honeypot field for bot filtering
- Accessible live status text after submit
- Donation links use `PayPal@raywonderis.me`

### VoiceLink Server Runtime

Deploy these files to the running VoiceLink server instance:

- [server/routes/local-server.js](/Users/admin/git/Raywonder/voicelink/server/routes/local-server.js)
- [source/server/routes/local-server.js](/Users/admin/git/Raywonder/voicelink/source/server/routes/local-server.js)

Expected result:

- `POST /api/downloads/testflight-request` exists
- Requests are validated server-side
- Bot submissions are rejected
- Invite requests are stored in `data/testflight-invite-requests.json`
- SMTP email delivery is used when configured
- Alternate fallback link can be included in the email

Note:

- If the production build process publishes from another copy of `local-server.js`, update that build source too before rebuilding.

### WHMCS Host

Copy these files into the WHMCS installation:

- [whmcs/voicelink-whmcs/modules/gateways/callback/paypal.php](/Users/admin/git/Raywonder/voicelink/whmcs/voicelink-whmcs/modules/gateways/callback/paypal.php)
- [whmcs/voicelink-whmcs/modules/gateways/callback/.htaccess](/Users/admin/git/Raywonder/voicelink/whmcs/voicelink-whmcs/modules/gateways/callback/.htaccess)

Target path on the live WHMCS host:

- `modules/gateways/callback/paypal.php`
- `modules/gateways/callback/.htaccess`

Reference doc:

- [whmcs/README.md](/Users/admin/git/Raywonder/voicelink/whmcs/README.md)

Expected result:

- Browser visit returns a plain-text verification response
- Callback POSTs no longer die with an opaque `406`
- When WHMCS bootstrap is available, payloads are logged through WHMCS

## Environment Variables

Set these on the running VoiceLink server host.

### Required For Email Delivery

- `VOICELINK_SMTP_HOST`
- `VOICELINK_SMTP_PORT`
- `VOICELINK_SMTP_USER`
- `VOICELINK_SMTP_PASS`
- `VOICELINK_EMAIL_FROM`

Optional related values already supported:

- `VOICELINK_SMTP_SECURE`
- `VOICELINK_SMTP_REQUIRE_TLS`
- `VOICELINK_SMTP_INTERNAL`

### TestFlight Invite Settings

- `VOICELINK_TESTFLIGHT_URL`
  Recommended value:
  `https://testflight.apple.com/join/duD9ycHJ`

- `VOICELINK_TESTFLIGHT_NOTIFY_EMAIL`
  Recommended value:
  `support@devine-creations.com`

### Cloudflare Alternate Link Support

Set this when you want invite emails to include a second backup link:

- `VOICELINK_TESTFLIGHT_URL_FALLBACK`

Use this for:

- Cloudflare-hosted fallback page
- Alternate room/file share link landing page
- Any backup route you want users to try if the primary link fails

Recommended pattern:

- Primary: Apple TestFlight invite URL
- Fallback: Cloudflare-hosted landing page that redirects or explains alternate access

## Verification Steps

### Website Verification

Open each page and confirm:

- iOS section shows an email form, not a direct TestFlight URL
- Email field has a visible label
- Human checkbox is visible and keyboard reachable
- Submit result is announced in the live status area
- Donation buttons point to PayPal donation URLs using `PayPal@raywonderis.me`

### Server Verification

Submit a request from one of the download pages and verify:

- Request reaches `POST /api/downloads/testflight-request`
- Invalid email is rejected
- Missing human checkbox is rejected
- Honeypot submission is rejected
- A new entry appears in `data/testflight-invite-requests.json`
- Email is sent when SMTP is configured
- Fallback link appears in the email when `VOICELINK_TESTFLIGHT_URL_FALLBACK` is set

### WHMCS Verification

After copying the callback file, verify:

- Visit `https://devine-creations.com/modules/gateways/callback/paypal.php`
- Expected response is plain text, not `406`

Then test a PayPal callback flow and confirm:

- The request reaches the callback script
- WHMCS remains stable
- Callback details are logged through WHMCS when bootstrap is available

## Recommended Deploy Order

1. Deploy the VoiceLink server route files.
2. Set or update the SMTP and TestFlight environment variables.
3. Restart the VoiceLink server process.
4. Deploy the website pages.
5. Deploy the WHMCS callback files.
6. Verify the live callback URL no longer returns `406`.
7. Submit a real TestFlight request from the website and confirm the email arrives.

## Post-Deploy Checks

- `https://devine-creations.com/modules/gateways/callback/paypal.php`
- `https://voicelink.devinecreations.net/`
- `https://voicelink.devinecreations.net/downloads.html`
- `https://voicelink.devinecreations.net/downloads-enhanced.html`

If the callback still returns `406` after file deployment, the remaining issue is host-level:

- WHMCS path mismatch
- nginx or Apache rule conflict
- permissions on `modules/gateways/callback`
- ModSecurity or WAF rule blocking the request
