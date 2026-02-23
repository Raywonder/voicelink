#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_FILE="$ROOT_DIR/VoiceLinkNative/VoiceLinkNative.csproj"
PUBLISH_DIR="$ROOT_DIR/publish/win-x64"
DIST_DIR="$ROOT_DIR/dist"
WIX_MSI="$ROOT_DIR/installer/wix/VoiceLink.msi.wxs"
WIX_BUNDLE="$ROOT_DIR/installer/wix/VoiceLink.bundle.wxs"
VERSION="${VERSION:-1.0.0}"

DOTNET_ROOT="${DOTNET_ROOT:-/Users/admin/.dotnet}"
DOTNET_CLI_HOME="${DOTNET_CLI_HOME:-/tmp/dotnet-cli-home}"
WIX_TOOLS_DIR="$DOTNET_CLI_HOME/.dotnet/tools"

export DOTNET_ROOT DOTNET_CLI_HOME
export PATH="$DOTNET_ROOT:$WIX_TOOLS_DIR:$PATH"

mkdir -p "$DOTNET_CLI_HOME" "$DIST_DIR"

if ! command -v dotnet >/dev/null 2>&1; then
  echo "dotnet not found. Install .NET SDK first."
  exit 1
fi

dotnet restore "$PROJECT_FILE"
dotnet publish "$PROJECT_FILE" -c Release -r win-x64 --self-contained true -o "$PUBLISH_DIR" /p:PublishSingleFile=true

if [[ "${OSTYPE:-}" != msys* && "${OSTYPE:-}" != cygwin* && "${OSTYPE:-}" != win32* ]]; then
  echo "Portable Windows binary built: $PUBLISH_DIR/VoiceLinkNative.exe"
  echo "MSI/setup EXE requires Windows (WiX bind depends on msi.dll)."
  echo "Run windows-native/scripts/build_windows_installers.ps1 on a Windows 10/11 host."
  exit 2
fi

if ! command -v wix >/dev/null 2>&1; then
  dotnet tool install --tool-path "$WIX_TOOLS_DIR" wix
fi

wix extension add WixToolset.UI.wixext >/dev/null 2>&1 || true
wix extension add WixToolset.Bal.wixext >/dev/null 2>&1 || true

MSI_OUT="$DIST_DIR/VoiceLinkNative-${VERSION}-win-x64.msi"
EXE_OUT="$DIST_DIR/VoiceLinkNative-${VERSION}-setup.exe"

wix build "$WIX_MSI" \
  -arch x64 \
  -d Version="$VERSION" \
  -o "$MSI_OUT"

wix build "$WIX_BUNDLE" \
  -arch x64 \
  -ext WixToolset.Bal.wixext \
  -d Version="$VERSION" \
  -o "$EXE_OUT"

echo "Built artifacts:"
ls -lh "$MSI_OUT" "$EXE_OUT"
