# VoiceLink – Documentation Sync & AI Guidelines

## Purpose

Defines how AI tools (including Claude) may update documentation without breaking architecture.

---

## Order of Truth

1. Running code
2. Architecture docs
3. Server docs
4. In-app docs
5. Public docs

If docs conflict with code, docs must change.

---

## AI May

- Rewrite for clarity
- Expand explanations
- Improve accessibility
- Normalize terminology

## AI Must Not

- Centralize authority
- Remove federation
- Assume root `/`
- Break accessibility
- Introduce new dependencies

---

## Mandatory Concepts

- Host-based identity
- Path awareness
- Optional federation
- Canonical server authority
- Sovereign nodes
- VoiceOver-first UX

---

## Docs to Sync

Server:
- /docs
- /docs/api
- /docs/federation

In-App:
- Setup help
- Federation help
- Admin help

Repo/Public:
- README.md
- DEPLOYMENT.md
- ACCESSIBILITY.md

---

## Terminology

- Server → Node
- Sync → Federation
- Add-ons → Plugins
- Paid features → Licensed Features

---

## Change Logging

All AI updates should include:
- Date
- Files changed
- Summary

---

## Final Rule

If documentation and software disagree,
documentation is wrong.
