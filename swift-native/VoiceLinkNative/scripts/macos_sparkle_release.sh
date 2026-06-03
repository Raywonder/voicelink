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
NOTARIZE="${NOTARIZE:-0}"
DOWNLOAD_URL_PREFIX="${DOWNLOAD_BASE_URL%/}/"
MACOS_SIGNING_ENV="${MACOS_SIGNING_ENV:-/Users/admin/dev/appstore/voicelink/macos_signing.env}"
MACOS_SIGNING_KEYCHAIN_PATH="${MACOS_SIGNING_KEYCHAIN_PATH:-/Users/admin/Library/Keychains/login.keychain-db}"

if [[ -f "$MACOS_SIGNING_ENV" ]]; then
  # shellcheck disable=SC1090
  source "$MACOS_SIGNING_ENV"
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
if [[ -d "$ROOT_DIR/Resources/Sounds" ]]; then
  cp -R "$ROOT_DIR/Resources/Sounds" "$APP_BUNDLE/Contents/Resources/Sounds"
fi

cat > "$DIST_DIR/entitlements.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.automation.apple-events</key>
    <true/>
    <key>com.apple.security.device.audio-input</key>
    <true/>
    <key>com.apple.security.device.camera</key>
    <true/>
</dict>
</plist>
PLIST

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
spctl --assess --type execute "$APP_BUNDLE" || true

ditto -c -k --keepParent "$APP_BUNDLE" "$ZIP_PATH"
cp "$ZIP_PATH" "$APPCAST_DIR/$ZIP_NAME"

if [[ "$NOTARIZE" == "1" ]]; then
  echo "Notarization requested. Submit $ZIP_PATH with xcrun notarytool before publishing."
fi

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
