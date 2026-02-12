#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="/home/devinecr/apps/hubnode/voicelink"
LOG_FILE="/home/devinecr/apps/hubnode/voicelink/.git/hooks/deploy.log"
PM2_APP="voicelink"

# Canonical targets only. public_html/voicelink-local is a symlink bridge to devinecreations.net/voicelink-local.
TARGETS=(
  "/home/devinecr/apps/voicelink-local"
  "/home/devinecr/devinecreations.net/voicelink-local"
  "/home/devinecr/apps/hubnode/clients/voicelink-local"
)

check_health() {
  curl -fsS --max-time 8 "http://127.0.0.1:3010/api/health" >/dev/null 2>&1 || \
  curl -fsS --max-time 8 "http://127.0.0.1:3010/health" >/dev/null 2>&1
}

{
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] deploy start"

  cd "$REPO_ROOT"
  git checkout -q main
  git reset --hard -q HEAD

  for raw_dst in "${TARGETS[@]}"; do
    mkdir -p "$raw_dst"
    dst="$(readlink -f "$raw_dst" 2>/dev/null || echo "$raw_dst")"

    rsync -a --delete --no-owner --no-group \
      --exclude='.git/' \
      --exclude='node_modules/' \
      --exclude='.worktrees/' \
      --exclude='.DS_Store' \
      --exclude='releases.zip' \
      --exclude='windows-native/VoiceLinkNative/obj/' \
      --exclude='windows-native/VoiceLinkNative/bin/' \
      --exclude='windows-native/.vs/' \
      --exclude='swift-native/VoiceLinkNative/.build/' \
      --exclude='swift-native/VoiceLinkNative/build/' \
      --exclude='swift-native/VoiceLinkNative/.swiftpm/' \
      "$REPO_ROOT/" "$dst/"

    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] synced -> $raw_dst (resolved: $dst)"
  done

  if check_health; then
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] health ok (no restart needed)"
  else
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] health failed, restarting pm2 app: $PM2_APP"
    pm2 restart "$PM2_APP"
    pm2 save
    sleep 3

    if check_health; then
      echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] health ok after restart"
    else
      echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] health still failing after restart"
      exit 1
    fi
  fi

  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] deploy done"
} >> "$LOG_FILE" 2>&1
