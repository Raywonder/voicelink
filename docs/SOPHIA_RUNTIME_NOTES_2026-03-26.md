# Sophia Runtime Notes

Last updated: 2026-03-26

## Purpose

Reserve a clean integration path for future Sophia versions so they can be used across VoiceLink and other Raywonder AI surfaces.

## Current Truth

- No Sophia runtime was found in the current workspace.
- OpenClaw is the best current host/control plane for future Sophia integration.

## VoiceLink Relevance

When Sophia exists as a usable runtime or profile, VoiceLink can use it for:

- room assistant behavior
- support/help assistant behavior
- admin helper flows
- guided onboarding or accessibility help

## Preferred Integration Order

1. Sophia profile inside OpenClaw
2. VoiceLink integration through existing AI / agent hooks
3. optional later dedicated Sophia runtime with its own service boundary

## Constraint

Do not claim Sophia is installed or working until an actual Sophia repo, package, or config profile exists in source.
Update: Sophia now exists as a real local OpenClaw multi-agent profile on this Mac.

Current configured state:
- OpenClaw agent id: `sophia`
- workspace: `~/.openclaw/workspace-sophia`
- local model: `ollama-ollama/qwen3:LATEST`
- local agent files seeded from the existing main agent so auth/model config is valid immediately

Still not done:
- no dedicated Sophia code/runtime repo exists yet
- no Sophia-specific routing or channel bindings are set yet
- no VoiceLink-side Sophia integration was wired in this pass
