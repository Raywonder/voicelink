#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

node "$SCRIPT_DIR/update_testflight_notes.js" \
  --pbxproj "$PROJECT_DIR/VoiceLinkiOS.xcodeproj/project.pbxproj" \
  --notes-file "$PROJECT_DIR/TestFlight/WhatToTest.en-US.txt" \
  "$@"
