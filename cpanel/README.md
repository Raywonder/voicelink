# VoiceLink cPanel Integration

This bundle lets VoiceLink treat a cPanel account as a managed hosting root.

Primary goals:

- preserve the main website root
- deploy VoiceLink side by side under `apps/voicelink` or a dedicated web path
- reuse cPanel-owned domains, databases, and home paths for owner linking
- expose file-manager friendly shared storage paths for VoiceLink file sharing

Suggested integration paths:

- `public_html/voicelink`
- `public_html/shared/voicelink`
- `apps/voicelink`
- `apps/voicelink/server-backup`

Useful cPanel-backed capabilities:

- file manager compatible upload/share paths
- database creation and migration hooks
- owned-domain detection
- backup-aware replacement and restore
