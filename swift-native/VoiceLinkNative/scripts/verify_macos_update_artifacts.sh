#!/usr/bin/env bash
set -euo pipefail

APP_BUNDLE="${1:?app bundle path required}"
ZIP_PATH="${2:?zip path required}"
APPCAST_PATH="${3:?appcast path required}"
EXPECTED_BUNDLE_ID="${4:?expected bundle id required}"
EXPECTED_BUILD="${5:?expected build required}"

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

[[ -d "$APP_BUNDLE" ]] || fail "app bundle missing: $APP_BUNDLE"
[[ -f "$ZIP_PATH" ]] || fail "zip missing: $ZIP_PATH"

BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP_BUNDLE/Contents/Info.plist")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP_BUNDLE/Contents/Info.plist")"
SHORT_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_BUNDLE/Contents/Info.plist")"
EXECUTABLE="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP_BUNDLE/Contents/Info.plist")"
FEED_URL="$(/usr/libexec/PlistBuddy -c 'Print :SUFeedURL' "$APP_BUNDLE/Contents/Info.plist" 2>/dev/null || true)"
PUBLIC_KEY="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$APP_BUNDLE/Contents/Info.plist" 2>/dev/null || true)"

[[ "$BUNDLE_ID" == "$EXPECTED_BUNDLE_ID" ]] || fail "bundle id mismatch: $BUNDLE_ID != $EXPECTED_BUNDLE_ID"
[[ "$BUILD" == "$EXPECTED_BUILD" ]] || fail "build mismatch: $BUILD != $EXPECTED_BUILD"
[[ "$BUILD" =~ ^[0-9]+$ ]] || fail "CFBundleVersion must be numeric: $BUILD"
[[ -n "$SHORT_VERSION" ]] || fail "CFBundleShortVersionString is empty"
[[ -x "$APP_BUNDLE/Contents/MacOS/$EXECUTABLE" ]] || fail "CFBundleExecutable missing or not executable: $EXECUTABLE"
[[ -n "$FEED_URL" && "$FEED_URL" == https://* ]] || fail "SUFeedURL must be HTTPS"
[[ -n "$PUBLIC_KEY" ]] || fail "SUPublicEDKey is missing"
[[ -d "$APP_BUNDLE/Contents/Frameworks/Sparkle.framework" ]] || fail "Sparkle.framework missing"
[[ -d "$APP_BUNDLE/Contents/Resources/VoiceLinkNative_VoiceLinkNative.bundle" ]] || fail "SwiftPM resource bundle missing"
[[ -d "$APP_BUNDLE/Contents/Resources/docs" ]] || fail "documentation resources missing"
[[ -d "$APP_BUNDLE/Contents/Resources/sounds" ]] || fail "sound resources missing"

EXECUTABLE_COUNT="$(find "$APP_BUNDLE/Contents/MacOS" -maxdepth 1 -type f -perm +111 | wc -l | tr -d ' ')"
[[ "$EXECUTABLE_COUNT" == "1" ]] || fail "expected exactly one executable in Contents/MacOS, found $EXECUTABLE_COUNT"

codesign --verify --deep --strict "$APP_BUNDLE"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
ditto -xk "$ZIP_PATH" "$TMP_DIR"
APP_COUNT="$(find "$TMP_DIR" -maxdepth 1 -name '*.app' -type d | wc -l | tr -d ' ')"
[[ "$APP_COUNT" == "1" ]] || fail "zip must contain exactly one top-level .app, found $APP_COUNT"
ZIP_APP="$(find "$TMP_DIR" -maxdepth 1 -name '*.app' -type d | head -n1)"
[[ -f "$ZIP_APP/Contents/Info.plist" ]] || fail "zip app layout invalid"
[[ -d "$ZIP_APP/Contents/Resources/VoiceLinkNative_VoiceLinkNative.bundle" ]] || fail "zip SwiftPM resource bundle missing"
[[ -d "$ZIP_APP/Contents/Resources/docs" ]] || fail "zip documentation resources missing"
[[ -d "$ZIP_APP/Contents/Resources/sounds" ]] || fail "zip sound resources missing"
ZIP_BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$ZIP_APP/Contents/Info.plist")"
ZIP_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$ZIP_APP/Contents/Info.plist")"
[[ "$ZIP_BUNDLE_ID" == "$EXPECTED_BUNDLE_ID" ]] || fail "zip bundle id mismatch"
[[ "$ZIP_BUILD" == "$EXPECTED_BUILD" ]] || fail "zip build mismatch"
codesign --verify --deep --strict "$ZIP_APP"

if [[ -f "$APPCAST_PATH" ]]; then
  grep -q "sparkle:edSignature=" "$APPCAST_PATH" || fail "appcast missing sparkle EdDSA signature"
  grep -q "$EXPECTED_BUILD" "$APPCAST_PATH" || fail "appcast missing expected build"
  grep -q 'https://' "$APPCAST_PATH" || fail "appcast must use HTTPS download URLs"
else
  echo "WARN: appcast not present yet: $APPCAST_PATH" >&2
fi

echo "macOS update artifacts verified:"
echo "  bundle id: $BUNDLE_ID"
echo "  version: $SHORT_VERSION"
echo "  build: $BUILD"
echo "  zip: $ZIP_PATH"
