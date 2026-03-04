#!/usr/bin/env bash
set -euo pipefail

API_BASE=""
TITLE="VoiceLink Server"
PUBLIC_URL=""
ANNOUNCE="true"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --api-base) API_BASE="$2"; shift 2 ;;
    --title) TITLE="$2"; shift 2 ;;
    --public-url) PUBLIC_URL="$2"; shift 2 ;;
    --announce) ANNOUNCE="$2"; shift 2 ;;
    *) echo "Unknown arg: $1"; exit 1 ;;
  esac
done

if [[ -z "${API_BASE}" || -z "${PUBLIC_URL}" ]]; then
  echo "Usage: $0 --api-base <https://server> --public-url <https://server> [--title <name>] [--announce true|false]"
  exit 1
fi

curl -fsSL -X POST "${API_BASE%/}/api/federation/connect" \
  -H 'Content-Type: application/json' \
  -d "{\"serverUrl\":\"${PUBLIC_URL}\",\"title\":\"${TITLE}\",\"announce\":${ANNOUNCE}}"

echo "Public server registration request sent to ${API_BASE}"
