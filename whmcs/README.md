# VoiceLink WHMCS Integration

VoiceLink server installs include WHMCS auth support by default. The required
default connector delegates client login to the official VoiceLink WHMCS
authority so paid/licensed VoiceLink accounts work immediately on any installed
server. When a server also has its own WHMCS installation, VoiceLink can
auto-detect that install and enable an additional local bridge without replacing
the official authority connector.

Default behavior:

- Keep the official VoiceLink WHMCS authority as the primary client-account
  login path.
- Use mirrored local auth as the grace-mode fallback when the authority is
  temporarily unreachable.
- Auto-detect a local WHMCS install when `configuration.php` and `init.php` are
  present in common cPanel/WHM paths such as `/home/<account>/public_html`.
- Preserve the active WHMCS root.
- Install VoiceLink under `modules/addons/voicelink-whmcs`.
- Reuse existing client, admin, service, and owned-domain data to link the
  install to an existing VoiceLink identity.
- Extract database and site-integration hints from `configuration.php` so the
  deployment manager and scheduler can reconcile the install later.

Expected integration points:

- `modules/addons/voicelink-whmcs`
- `modules/gateways/callback/paypal.php`
- `modules/addons/voicelink-whmcs/hooks`
- `templates/voicelink`
- `clientarea.php` / WHMCS client area entry points
- `admin/` for admin-side bridge and status visibility

Server environment:

- `VOICELINK_WHMCS_AUTHORITY_URL` overrides the official authority when a
  reseller or private deployment has its own VoiceLink authority.
- `VOICELINK_WHMCS_AUTH_MODE=local` or `admin-bridge` disables authority
  delegation for controlled local-only testing.
- `VOICELINK_WHMCS_CONFIG_PATH` pins a local WHMCS `configuration.php`.
- `VOICELINK_WHMCS_ROOT` or `WHMCS_ROOT` can point at a local WHMCS root when it
  is outside the common auto-detect paths.
- If no local WHMCS install is detected, the local bridge stays inactive and the
  official authority connector remains available.

Suggested storage targets when they exist:

- `attachments/voicelink`
- `downloads/voicelink`
- `modules/addons/voicelink-whmcs/backups`
- `modules/addons/voicelink-whmcs/imports`
- `modules/addons/voicelink-whmcs/exports`

PayPal callback compatibility:

- Deploy `whmcs/voicelink-whmcs/modules/gateways/callback/paypal.php` to
  `modules/gateways/callback/paypal.php` on the WHMCS host.
- Direct browser visits should return a plain-text verification response instead
  of an opaque `406`.
- POST callbacks are logged through WHMCS when `init.php` is available.
