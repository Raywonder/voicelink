#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

node "$SCRIPT_DIR/expire_old_testflight_builds.js" \
  --pbxproj "$PROJECT_DIR/VoiceLinkiOS.xcodeproj/project.pbxproj" \
  "$@"
