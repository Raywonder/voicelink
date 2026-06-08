# VoiceLink Composr Integration

This folder is the Composr-side companion to the VoiceLink deployment manager.

Target behavior:

- preserve the existing Composr site root by default
- install VoiceLink integration files into Composr custom locations
- expose a logged-in member bridge for VoiceLink identity linking
- allow site owners to add VoiceLink pages without replacing the main website

Recommended target root:

- `/home/<user>/public_html`

Recommended install style:

- keep the main Composr site intact
- place integration code under `sources_custom/voicelink`
- add linked pages or boxed/embedded entry points for:
  - VoiceLink
  - VoiceLink Downloads
  - VoiceLink Help
  - VoiceLink Server Setup

Composr page and view targets to support:

- `pages/modules_custom`
- `pages/comcode_custom`
- `pages/html_custom`
- `site/pages/modules_custom`
- `site/pages/comcode_custom`
- `site/pages/html_custom`
- `pg/modules_custom`
- `pg/comcode_custom`
- `pg/html_custom`
- `site/pg/modules_custom`
- `site/pg/comcode_custom`
- `site/pg/html_custom`
- fallback read/use of standard `pages/modules`, `pages/comcode`, and `pages/html`

Composr storage paths to use when present:

- `uploads/website_specific/voicelink`
- `uploads/filedump/voicelink`
- `exports/voicelink`
- `imports/voicelink`

These should be treated as optional integration-aware paths. VoiceLink should
namespace its content inside them rather than mixing loose files into the
Composr root.

Identity/linking goals:

- Composr member email should resolve to the same VoiceLink identity when it matches an existing owner or linked account
- if the same owner already has another VoiceLink server, the new Composr-hosted server should attach to that existing identity rather than create a duplicate

Detected from the live DevineCreations Composr install:

- standard Composr tree with `sources/`, `sources_custom/`, and custom module/page paths
- member/session API via `get_member()` in `sources/users.php`
- forum/member access through `$GLOBALS['FORUM_DRIVER']`
- custom addon space already in active use under `sources_custom/`

So the bridge should build on Composr-native patterns:

- read the logged-in member from `get_member()`
- use `$GLOBALS['FORUM_DRIVER']` for username, email, and staff/super-admin checks
- map Composr roles into VoiceLink server roles
- expose identity aliases so a Composr login can attach to the same VoiceLink owner identity used elsewhere
- import existing Composr groups, clubs, private topics, and direct-message relationships where VoiceLink needs to mirror private access
- allow admin UI web views to reflect open/closed site status for Composr-backed sites
- if Composr chat is installed, allow public room mapping to the Composr chat module first, with VoiceLink chat as fallback

This repo pass now includes a bridge implementation that follows those assumptions. The next live step is deploying it into the actual Composr root once the exact target path is confirmed.
