#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUT_DIR="${ROOT_DIR}/dist/linux-server"

mkdir -p "${OUT_DIR}"
cd "${ROOT_DIR}"

# Minimal reproducible server bundle for Linux hosts
rm -f "${OUT_DIR}/voicelink-server-linux.tar.gz"
tar -czf "${OUT_DIR}/voicelink-server-linux.tar.gz" \
  server client installer scripts package.json package-lock.json README.md

sha256sum "${OUT_DIR}/voicelink-server-linux.tar.gz" | awk '{print $1}' > "${OUT_DIR}/voicelink-server-linux.tar.gz.sha256"

echo "Linux server bundle ready in ${OUT_DIR}"
ls -lh "${OUT_DIR}" || true
