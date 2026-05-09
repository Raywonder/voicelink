# VoiceLink WordPress Support

This directory holds WordPress-specific deployment assets for VoiceLink.

## Included

- `voicelink-wordpress/`
  - installable WordPress plugin
  - activation hook to create standard VoiceLink pages
  - shortcodes for app, downloads, docs, and server setup
  - REST bridge for WordPress-aware VoiceLink onboarding

## Intended deployment behavior

Use the plugin when a site already has WordPress content and VoiceLink should be added without replacing the whole site.

Typical paths:

- keep the existing home page and theme
- install the plugin into `wp-content/plugins/voicelink-wordpress`
- create pages like:
  - `/voicelink`
  - `/voicelink-downloads`
  - `/voicelink-server-setup`
  - `/voicelink-help`

## Future wiring

Deployment Manager should detect WordPress and offer:

1. install VoiceLink plugin beside the existing site
2. link WordPress account roles to VoiceLink auth
3. create or update the standard VoiceLink pages
4. preserve the existing site root unless the owner explicitly chooses replacement mode
