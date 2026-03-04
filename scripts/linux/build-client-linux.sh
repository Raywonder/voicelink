#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUT_DIR="${ROOT_DIR}/dist/linux"

mkdir -p "${OUT_DIR}"
cd "${ROOT_DIR}"

npm run build:prod
# Build Linux artifacts: AppImage + deb + tar.gz
npx electron-builder --linux AppImage deb tar.gz

# Normalize names for website links
find ../releases -maxdepth 1 -type f -name "*.AppImage" -print -quit | while read -r f; do
  cp -f "$f" "${OUT_DIR}/VoiceLink-linux.AppImage"
  sha256sum "${OUT_DIR}/VoiceLink-linux.AppImage" | awk '{print $1}' > "${OUT_DIR}/VoiceLink-linux.AppImage.sha256"
done

find ../releases -maxdepth 1 -type f -name "*.deb" -print -quit | while read -r f; do
  cp -f "$f" "${OUT_DIR}/voicelink-local_1.0.0_amd64.deb"
  sha256sum "${OUT_DIR}/voicelink-local_1.0.0_amd64.deb" | awk '{print $1}' > "${OUT_DIR}/voicelink-local_1.0.0_amd64.deb.sha256"
done

echo "Linux client artifacts ready in ${OUT_DIR}"
ls -lh "${OUT_DIR}" || true
