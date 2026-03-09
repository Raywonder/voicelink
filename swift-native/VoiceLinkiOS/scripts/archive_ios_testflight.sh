#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ARCHIVE_PATH="$ROOT_DIR/build/VoiceLinkiOS.xcarchive"
EXPORT_PATH="$ROOT_DIR/build/export-testflight"
IPA_PATH="$EXPORT_PATH/VoiceLink.ipa"
MANUAL_IPA_DIR="$ROOT_DIR/build/manual-ipa"
MANUAL_IPA_PATH="$ROOT_DIR/build/VoiceLink-manual.ipa"
APPLE_ID_EMAIL="${APPLE_ID_EMAIL:-}"
APP_SPECIFIC_PASSWORD="${APP_SPECIFIC_PASSWORD:-}"
ITC_PROVIDER="${ITC_PROVIDER:-G5232LU4Z7}"
AUTO_UPLOAD="${AUTO_UPLOAD:-0}"
BUILD_NUMBER="${BUILD_NUMBER:-}"
CREDENTIALS_FILE="${CREDENTIALS_FILE:-/Users/admin/dev/appstore/voicelink/ios_testflight_credentials.env}"
KEYCHAIN_SERVICE="${KEYCHAIN_SERVICE:-voicelink.transporter}"
LEDGER_FILE="${LEDGER_FILE:-/Users/admin/dev/appstore/voicelink/TESTFLIGHT_BUILD_LEDGER.md}"

if [[ -f "$CREDENTIALS_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$CREDENTIALS_FILE"
fi

APPLE_ID_EMAIL="${APPLE_ID_EMAIL:-${VOICELINK_APPLE_ID_EMAIL:-}}"
APP_SPECIFIC_PASSWORD="${APP_SPECIFIC_PASSWORD:-${VOICELINK_APP_SPECIFIC_PASSWORD:-}}"

if [[ -z "$APP_SPECIFIC_PASSWORD" && -n "$APPLE_ID_EMAIL" ]]; then
  APP_SPECIFIC_PASSWORD="$(security find-generic-password -a "$APPLE_ID_EMAIL" -s "$KEYCHAIN_SERVICE" -w 2>/dev/null || true)"
fi

cd "$ROOT_DIR"

xcodegen generate

xcodebuild \
  -project VoiceLinkiOS.xcodeproj \
  -scheme VoiceLinkiOS \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath "$ARCHIVE_PATH" \
  archive \
  CODE_SIGN_STYLE=Automatic \
  DEVELOPMENT_TEAM=G5232LU4Z7 \
  PRODUCT_BUNDLE_IDENTIFIER=com.devinecreations.voicelink \
  SUPPORTED_PLATFORMS=iphoneos \
  ${BUILD_NUMBER:+CURRENT_PROJECT_VERSION=$BUILD_NUMBER} \
  -allowProvisioningUpdates

if ! xcodebuild \
  -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportPath "$EXPORT_PATH" \
  -exportOptionsPlist "$ROOT_DIR/ExportOptions-AppStore.plist" \
  -allowProvisioningUpdates; then
  echo "xcodebuild export failed; falling back to manual IPA packaging from archive."
  rm -rf "$MANUAL_IPA_DIR"
  mkdir -p "$MANUAL_IPA_DIR/Payload"
  cp -R "$ARCHIVE_PATH/Products/Applications/VoiceLink.app" "$MANUAL_IPA_DIR/Payload/VoiceLink.app"
  (cd "$MANUAL_IPA_DIR" && /usr/bin/zip -qry "$MANUAL_IPA_PATH" Payload)
  IPA_PATH="$MANUAL_IPA_PATH"
fi

echo
echo "Archive: $ARCHIVE_PATH"
echo "Export:  $EXPORT_PATH"
echo "IPA:     $IPA_PATH"
echo

MARKETING_VERSION="$(
  /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
    "$ARCHIVE_PATH/Products/Applications/VoiceLink.app/Info.plist" 2>/dev/null || echo "1.0"
)"

if [[ "$AUTO_UPLOAD" == "1" ]]; then
  if [[ -z "$BUILD_NUMBER" ]]; then
    echo "AUTO_UPLOAD=1 requires BUILD_NUMBER to avoid duplicate IPA uploads."
    echo "Example: BUILD_NUMBER=5 AUTO_UPLOAD=1 ./scripts/archive_ios_testflight.sh"
    exit 1
  fi

  if [[ -z "$APPLE_ID_EMAIL" || -z "$APP_SPECIFIC_PASSWORD" ]]; then
    echo "AUTO_UPLOAD=1 set, but credentials are missing."
    echo "Set credentials in:"
    echo "  $CREDENTIALS_FILE"
    echo "or save password in Keychain service '$KEYCHAIN_SERVICE' for account '$APPLE_ID_EMAIL'."
    exit 1
  fi

  echo "Uploading IPA to App Store Connect via iTMSTransporter..."
  xcrun iTMSTransporter \
    -m upload \
    -assetFile "$IPA_PATH" \
    -u "$APPLE_ID_EMAIL" \
    -p "$APP_SPECIFIC_PASSWORD" \
    -itc_provider "$ITC_PROVIDER"
  echo "Upload finished."

  if [[ -n "$BUILD_NUMBER" ]]; then
    if [[ ! -f "$LEDGER_FILE" ]]; then
      mkdir -p "$(dirname "$LEDGER_FILE")"
      cat >"$LEDGER_FILE" <<'EOF'
# VoiceLink iOS TestFlight Build Ledger

| Date (ET) | Marketing Version | Build Number | Status | Notes |
|---|---:|---:|---|---|
EOF
    fi

    printf '| %s | %s | %s | uploaded | iTMSTransporter upload finished successfully. |\n' \
      "$(TZ=America/New_York date '+%Y-%m-%d %H:%M')" \
      "$MARKETING_VERSION" \
      "$BUILD_NUMBER" >>"$LEDGER_FILE"
    echo "Ledger updated: $LEDGER_FILE"
  fi
else
  echo "Upload with Transporter:"
  echo "APPLE_ID_EMAIL=\"<APPLE_ID_EMAIL>\" APP_SPECIFIC_PASSWORD=\"<APP_SPECIFIC_PASSWORD>\" AUTO_UPLOAD=1 ./scripts/archive_ios_testflight.sh"
fi
