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

Canonical managed-runtime paths:

```text
apps/voicelink/
  main/<domain>/
  community/<domain>/
  dev/<domain>/
  cms/<domain>/
  remote/<domain>/
```

Use the cPanel account that owns or operates the server:

- the `voicelink` account owns `voicelinkapp.app`,
  `community.voicelinkapp.app`, and `voicelink.dev` runtimes
- the `devinecr` account owns Devine Creations VoiceLink runtimes
- any other hosting account uses its own `apps/voicelink/...` tree

Use domain-aware process names. Prefer names like
`voicelinkapp.app-main`, `community.voicelinkapp.app-community`, or
`devinecreations.net-cms`; avoid permanent names such as `voicelink-local`,
`local`, or `node2`.

Use `remote/<domain>/` only when this account hosts a VoiceLink server for a
remote owner or organization that does not have its own local cPanel/system
account on this host.

Useful cPanel-backed capabilities:

- file manager compatible upload/share paths
- database creation and migration hooks
- owned-domain detection
- backup-aware replacement and restore
