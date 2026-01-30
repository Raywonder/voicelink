#!/bin/bash
#
# VoiceLink Package Builder
# Creates distributable installation package
#

set -e

VERSION="1.0.0"
PACKAGE_NAME="voicelink-server-${VERSION}"
BUILD_DIR="/tmp/voicelink-build"
SOURCE_DIR="$(dirname "$(dirname "$(readlink -f "$0")")")"
OUTPUT_DIR="${SOURCE_DIR}/releases"

echo "Building VoiceLink package v${VERSION}..."

# Clean and create build directory
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR/$PACKAGE_NAME"
mkdir -p "$OUTPUT_DIR"

# Copy source files
echo "Copying source files..."
cp -r "$SOURCE_DIR/server" "$BUILD_DIR/$PACKAGE_NAME/"
cp -r "$SOURCE_DIR/client" "$BUILD_DIR/$PACKAGE_NAME/"
cp -r "$SOURCE_DIR/source/assets" "$BUILD_DIR/$PACKAGE_NAME/assets" 2>/dev/null || mkdir -p "$BUILD_DIR/$PACKAGE_NAME/assets"
cp "$SOURCE_DIR/package.json" "$BUILD_DIR/$PACKAGE_NAME/"
cp "$SOURCE_DIR/package-lock.json" "$BUILD_DIR/$PACKAGE_NAME/" 2>/dev/null || true

# Copy installer
cp "$SOURCE_DIR/installer/install.sh" "$BUILD_DIR/$PACKAGE_NAME/"

# Create default directories
mkdir -p "$BUILD_DIR/$PACKAGE_NAME/data"
mkdir -p "$BUILD_DIR/$PACKAGE_NAME/docs/public"
mkdir -p "$BUILD_DIR/$PACKAGE_NAME/docs/authenticated"
mkdir -p "$BUILD_DIR/$PACKAGE_NAME/logs"

# Remove dev files
find "$BUILD_DIR/$PACKAGE_NAME" -name "*.test.js" -delete
find "$BUILD_DIR/$PACKAGE_NAME" -name ".DS_Store" -delete
find "$BUILD_DIR/$PACKAGE_NAME" -name "node_modules" -type d -exec rm -rf {} + 2>/dev/null || true

# Create README
cat > "$BUILD_DIR/$PACKAGE_NAME/README.md" << 'README'
# VoiceLink Server

Decentralized voice chat platform with spatial audio.

## Quick Install

```bash
chmod +x install.sh
./install.sh
```

## Manual Install

1. Install Node.js 18+
2. Run `npm install`
3. Run `node server/routes/local-server.js`

## Configuration

Edit `data/deploy.json` to configure:
- Server name and port
- Federation settings
- Feature toggles

## Documentation

After installation, docs are available at:
- Public: http://localhost:3010/docs/
- Admin: http://localhost:3010/admin/docs/

Docs sync automatically from the main server.

## Support

- GitHub: https://github.com/devinecreations/voicelink
- Main Server: https://voicelink.devinecreations.net
README

# Create tarball
echo "Creating tarball..."
cd "$BUILD_DIR"
tar -czf "$OUTPUT_DIR/${PACKAGE_NAME}.tar.gz" "$PACKAGE_NAME"

# Create zip for Windows users
if command -v zip &> /dev/null; then
    echo "Creating zip..."
    zip -rq "$OUTPUT_DIR/${PACKAGE_NAME}.zip" "$PACKAGE_NAME"
fi

# Create latest symlinks
cd "$OUTPUT_DIR"
ln -sf "${PACKAGE_NAME}.tar.gz" "latest.tar.gz"
[ -f "${PACKAGE_NAME}.zip" ] && ln -sf "${PACKAGE_NAME}.zip" "latest.zip"

# Cleanup
rm -rf "$BUILD_DIR"

echo ""
echo "Package built successfully!"
echo "  Tarball: $OUTPUT_DIR/${PACKAGE_NAME}.tar.gz"
[ -f "$OUTPUT_DIR/${PACKAGE_NAME}.zip" ] && echo "  Zip:     $OUTPUT_DIR/${PACKAGE_NAME}.zip"
echo ""
echo "To install on a new server:"
echo "  curl -sL https://voicelink.devinecreations.net/releases/latest.tar.gz | tar xz"
echo "  cd $PACKAGE_NAME && ./install.sh"
