#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
REPO_DIR="$(cd "$ROOT_DIR/../.." && pwd)"
APP_NAME="${APP_NAME:-VoiceLink}"
PRODUCT_NAME="${PRODUCT_NAME:-VoiceLinkNative}"
BUNDLE_ID="${BUNDLE_ID:-com.devinecreations.voicelink}"
APP_VERSION="${APP_VERSION:-1.0.0}"
APP_BUILD="${APP_BUILD:-}"
BUILD_CONFIG="${BUILD_CONFIG:-release}"
BUILD_ARCHS="${BUILD_ARCHS:-x86_64}"
DIST_DIR="${DIST_DIR:-$ROOT_DIR/build/sparkle-release}"
APPCAST_URL="${APPCAST_URL:-https://voicelinkapp.app/downloads/voicelink/appcast.xml}"
DOWNLOAD_BASE_URL="${DOWNLOAD_BASE_URL:-https://voicelinkapp.app/downloads/voicelink}"
SPARKLE_PUBLIC_ED_KEY="${SPARKLE_PUBLIC_ED_KEY:-}"
SIGN_IDENTITY="${SIGN_IDENTITY:-}"
NOTARIZE="${NOTARIZE:-1}"
DOWNLOAD_URL_PREFIX="${DOWNLOAD_BASE_URL%/}/"
MACOS_SIGNING_ENV="${MACOS_SIGNING_ENV:-/Users/admin/dev/appstore/voicelink/macos_signing.env}"
MACOS_NOTARY_ENV="${MACOS_NOTARY_ENV:-/Users/admin/dev/appstore/voicelink/appstoreconnect_api.env}"
MACOS_SIGNING_KEYCHAIN_PATH="${MACOS_SIGNING_KEYCHAIN_PATH:-/Users/admin/Library/Keychains/login.keychain-db}"
NOTARY_KEYCHAIN_PROFILE="${NOTARY_KEYCHAIN_PROFILE:-}"
NOTARY_APPLE_ID="${NOTARY_APPLE_ID:-}"
NOTARY_PASSWORD="${NOTARY_PASSWORD:-}"
NOTARY_TEAM_ID="${NOTARY_TEAM_ID:-${DEVELOPMENT_TEAM:-}}"
KEYCHAIN_TEAM_ID="${KEYCHAIN_TEAM_ID:-${DEVELOPMENT_TEAM:-${NOTARY_TEAM_ID:-}}}"

if [[ -f "$MACOS_SIGNING_ENV" ]]; then
  # shellcheck disable=SC1090
  source "$MACOS_SIGNING_ENV"
fi

if [[ -f "$MACOS_NOTARY_ENV" ]]; then
  # shellcheck disable=SC1090
  source "$MACOS_NOTARY_ENV"
fi

if [[ -n "${MACOS_SIGNING_KEYCHAIN_PASSWORD:-}" && -f "$MACOS_SIGNING_KEYCHAIN_PATH" ]]; then
  security unlock-keychain -p "$MACOS_SIGNING_KEYCHAIN_PASSWORD" "$MACOS_SIGNING_KEYCHAIN_PATH"
  security set-keychain-settings -lut 21600 "$MACOS_SIGNING_KEYCHAIN_PATH"
  security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$MACOS_SIGNING_KEYCHAIN_PASSWORD" "$MACOS_SIGNING_KEYCHAIN_PATH" >/dev/null 2>&1 || true
fi

if [[ -z "$APP_BUILD" ]]; then
  APP_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$ROOT_DIR/Resources/Info.plist")"
fi

if [[ -z "$SPARKLE_PUBLIC_ED_KEY" ]]; then
  echo "ERROR: SPARKLE_PUBLIC_ED_KEY is required for Sparkle release builds." >&2
  echo "Generate/store the private key outside git, then pass only the public key here." >&2
  exit 1
fi

if [[ ! "$APP_BUILD" =~ ^[0-9]+$ ]]; then
  echo "ERROR: APP_BUILD/CFBundleVersion must be numeric for Sparkle. Got: $APP_BUILD" >&2
  exit 1
fi

select_identity() {
  security find-identity -p codesigning -v 2>/dev/null \
    | awk '/Developer ID Application/ { print $2; exit }'
}

if [[ -z "$SIGN_IDENTITY" ]]; then
  SIGN_IDENTITY="$(select_identity || true)"
fi

if [[ -z "$SIGN_IDENTITY" ]]; then
  echo "ERROR: No Developer ID Application signing identity found. Set SIGN_IDENTITY explicitly." >&2
  exit 1
fi

if [[ -z "$KEYCHAIN_TEAM_ID" ]]; then
  echo "ERROR: KEYCHAIN_TEAM_ID or DEVELOPMENT_TEAM is required for VoiceLink keychain entitlements." >&2
  exit 1
fi

notarize_and_staple() {
  local app_bundle="$1"
  local submit_zip="$DIST_DIR/$APP_NAME-$APP_VERSION-$APP_BUILD-notary-submit.zip"
  local args=()

  if ! command -v xcrun >/dev/null 2>&1 || ! xcrun notarytool --help >/dev/null 2>&1; then
    echo "ERROR: xcrun notarytool is required for macOS notarization." >&2
    return 1
  fi

  if [[ -n "$NOTARY_KEYCHAIN_PROFILE" ]]; then
    args=(--keychain-profile "$NOTARY_KEYCHAIN_PROFILE")
  elif [[ -n "${ASC_KEY_ID:-}" && -n "${ASC_ISSUER_ID:-}" && -n "${ASC_PRIVATE_KEY_PATH:-}" ]]; then
    args=(--key "$ASC_PRIVATE_KEY_PATH" --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER_ID")
  elif [[ -n "$NOTARY_APPLE_ID" && -n "$NOTARY_PASSWORD" && -n "$NOTARY_TEAM_ID" ]]; then
    args=(--apple-id "$NOTARY_APPLE_ID" --password "$NOTARY_PASSWORD" --team-id "$NOTARY_TEAM_ID")
  else
    echo "ERROR: NOTARIZE=1 but no notary credentials were found." >&2
    echo "Set NOTARY_KEYCHAIN_PROFILE, ASC_KEY_ID/ASC_ISSUER_ID/ASC_PRIVATE_KEY_PATH, or NOTARY_APPLE_ID/NOTARY_PASSWORD/NOTARY_TEAM_ID." >&2
    return 1
  fi

  rm -f "$submit_zip"
  ditto -c -k --keepParent "$app_bundle" "$submit_zip"
  echo "Submitting $submit_zip for Apple notarization..."
  xcrun notarytool submit "$submit_zip" "${args[@]}" --wait
  echo "Stapling notarization ticket to $app_bundle..."
  xcrun stapler staple "$app_bundle"
  xcrun stapler validate "$app_bundle"
  spctl --assess --type execute --verbose=4 "$app_bundle"
  rm -f "$submit_zip"
}

APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
ZIP_NAME="$APP_NAME-$APP_VERSION-$APP_BUILD-macOS.zip"
ZIP_PATH="$DIST_DIR/$ZIP_NAME"
APPCAST_DIR="$DIST_DIR/appcast"
BUILD_PATH="$ROOT_DIR/.build/sparkle-$BUILD_CONFIG"

echo "Building $PRODUCT_NAME $APP_VERSION ($APP_BUILD) for $BUILD_ARCHS"
rm -rf "$DIST_DIR"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources" "$APP_BUNDLE/Contents/Frameworks" "$APPCAST_DIR"

cd "$ROOT_DIR"

IFS=' ' read -r -a ARCH_ARRAY <<< "$BUILD_ARCHS"
BINARIES=()
for arch in "${ARCH_ARRAY[@]}"; do
  ARCH_BUILD_PATH="$BUILD_PATH/$arch"
  swift build -c "$BUILD_CONFIG" --arch "$arch" --build-path "$ARCH_BUILD_PATH" -Xlinker -rpath -Xlinker @executable_path/../Frameworks
  BINARIES+=("$ARCH_BUILD_PATH/$BUILD_CONFIG/$PRODUCT_NAME")
done

if [[ "${#BINARIES[@]}" -gt 1 ]]; then
  lipo -create "${BINARIES[@]}" -output "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
else
  cp "${BINARIES[0]}" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
fi
chmod +x "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
codesign --remove-signature "$APP_BUNDLE/Contents/MacOS/$APP_NAME" 2>/dev/null || true

SWIFTPM_RESOURCE_BUNDLE=""
for arch in "${ARCH_ARRAY[@]}"; do
  candidate="$BUILD_PATH/$arch/$BUILD_CONFIG/${PRODUCT_NAME}_${PRODUCT_NAME}.bundle"
  if [[ -d "$candidate" ]]; then
    SWIFTPM_RESOURCE_BUNDLE="$candidate"
    break
  fi
done

if [[ -z "$SWIFTPM_RESOURCE_BUNDLE" ]]; then
  echo "ERROR: SwiftPM resource bundle was not produced. The app would launch without bundled sounds/docs." >&2
  exit 1
fi

cp "$ROOT_DIR/Resources/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleExecutable $APP_NAME" "$APP_BUNDLE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" "$APP_BUNDLE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $APP_VERSION" "$APP_BUNDLE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $APP_BUILD" "$APP_BUNDLE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :SUFeedURL $APPCAST_URL" "$APP_BUNDLE/Contents/Info.plist" \
  || /usr/libexec/PlistBuddy -c "Add :SUFeedURL string $APPCAST_URL" "$APP_BUNDLE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :SUPublicEDKey $SPARKLE_PUBLIC_ED_KEY" "$APP_BUNDLE/Contents/Info.plist" \
  || /usr/libexec/PlistBuddy -c "Add :SUPublicEDKey string $SPARKLE_PUBLIC_ED_KEY" "$APP_BUNDLE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :SUEnableAutomaticChecks true" "$APP_BUNDLE/Contents/Info.plist" \
  || /usr/libexec/PlistBuddy -c "Add :SUEnableAutomaticChecks bool true" "$APP_BUNDLE/Contents/Info.plist"

if [[ -f "$ROOT_DIR/Resources/AppIcon.icns" ]]; then
  cp "$ROOT_DIR/Resources/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
fi

SPARKLE_FRAMEWORK=""
for arch in "${ARCH_ARRAY[@]}"; do
  candidate="$BUILD_PATH/$arch/$BUILD_CONFIG/Sparkle.framework"
  if [[ -d "$candidate" ]]; then
    SPARKLE_FRAMEWORK="$candidate"
    break
  fi
done

if [[ -z "$SPARKLE_FRAMEWORK" ]]; then
  echo "ERROR: Sparkle.framework was not produced by SwiftPM." >&2
  exit 1
fi

cp -R "$SPARKLE_FRAMEWORK" "$APP_BUNDLE/Contents/Frameworks/"
chmod -R a+rX "$APP_BUNDLE/Contents/Frameworks/Sparkle.framework"

if [[ -d "$ROOT_DIR/Resources/docs" ]]; then
  cp -R "$ROOT_DIR/Resources/docs" "$APP_BUNDLE/Contents/Resources/docs"
fi
if [[ -d "$ROOT_DIR/Resources/sounds" ]]; then
  cp -R "$ROOT_DIR/Resources/sounds" "$APP_BUNDLE/Contents/Resources/sounds"
elif [[ -d "$ROOT_DIR/Resources/Sounds" ]]; then
  cp -R "$ROOT_DIR/Resources/Sounds" "$APP_BUNDLE/Contents/Resources/sounds"
fi
cp -R "$SWIFTPM_RESOURCE_BUNDLE" "$APP_BUNDLE/Contents/Resources/"

cat > "$DIST_DIR/entitlements.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.application-identifier</key>
    <string>__KEYCHAIN_TEAM_ID__.com.devinecreations.voicelink</string>
    <key>keychain-access-groups</key>
    <array>
        <string>__KEYCHAIN_TEAM_ID__.com.devinecreations.voicelink</string>
    </array>
    <key>com.apple.security.automation.apple-events</key>
    <true/>
    <key>com.apple.security.device.audio-input</key>
    <true/>
    <key>com.apple.security.device.camera</key>
    <true/>
</dict>
</plist>
PLIST
perl -0pi -e "s/__KEYCHAIN_TEAM_ID__/$KEYCHAIN_TEAM_ID/g" "$DIST_DIR/entitlements.plist"

xattr -cr "$APP_BUNDLE"
while IFS= read -r -d '' item; do
  if file "$item" | grep -q "Mach-O"; then
    codesign --force --timestamp --options runtime --sign "$SIGN_IDENTITY" "$item"
  fi
done < <(find "$APP_BUNDLE/Contents/Frameworks" -type f -print0)

if [[ -d "$APP_BUNDLE/Contents/Frameworks/Sparkle.framework/Versions/B/Updater.app" ]]; then
  codesign --force --timestamp --options runtime --sign "$SIGN_IDENTITY" "$APP_BUNDLE/Contents/Frameworks/Sparkle.framework/Versions/B/Updater.app"
fi
codesign --force --timestamp --options runtime --entitlements "$DIST_DIR/entitlements.plist" --sign "$SIGN_IDENTITY" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
codesign --force --timestamp --options runtime --entitlements "$DIST_DIR/entitlements.plist" --sign "$SIGN_IDENTITY" "$APP_BUNDLE"
codesign --verify --deep --strict "$APP_BUNDLE"

if [[ "$NOTARIZE" == "1" ]]; then
  notarize_and_staple "$APP_BUNDLE"
else
  spctl --assess --type execute "$APP_BUNDLE" || true
fi

ditto -c -k --keepParent "$APP_BUNDLE" "$ZIP_PATH"
cp "$ZIP_PATH" "$APPCAST_DIR/$ZIP_NAME"

SPARKLE_BIN=""
for candidate in \
  "$ROOT_DIR/.build/artifacts/sparkle/Sparkle/bin/generate_appcast" \
  "$ROOT_DIR/.build/artifacts/sparkle/Sparkle/bin/sign_update" \
  "$BUILD_PATH/${ARCH_ARRAY[0]}/artifacts/sparkle/Sparkle/bin/generate_appcast"
do
  if [[ -x "$candidate" && "$(basename "$candidate")" == "generate_appcast" ]]; then
    SPARKLE_BIN="$candidate"
    break
  fi
done

if [[ -n "$SPARKLE_BIN" ]]; then
  "$SPARKLE_BIN" --download-url-prefix "$DOWNLOAD_URL_PREFIX" "$APPCAST_DIR"
else
  echo "WARN: generate_appcast was not found. Run Sparkle generate_appcast on $APPCAST_DIR before publishing." >&2
fi

"$ROOT_DIR/scripts/verify_macos_update_artifacts.sh" \
  "$APP_BUNDLE" \
  "$ZIP_PATH" \
  "$APPCAST_DIR/appcast.xml" \
  "$BUNDLE_ID" \
  "$APP_BUILD"

echo "Release artifacts:"
echo "  App: $APP_BUNDLE"
echo "  Zip: $ZIP_PATH"
echo "  Appcast dir: $APPCAST_DIR"
