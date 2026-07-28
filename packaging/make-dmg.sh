#!/usr/bin/env bash
# make-dmg.sh — wrap dist/MacTR AI.app into a drag-to-install disk image.
#
#   ./packaging/make-dmg.sh                     # version read from the bundle
#   MACTR_VERSION=2.0.0 ./packaging/make-dmg.sh
#
# Output: dist/MacTR-AI-<version>-arm64.dmg
#
# Run packaging/build-app.sh first.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

APP_NAME="MacTR AI"
DIST="$REPO_ROOT/dist"
APP="$DIST/$APP_NAME.app"

[[ -d "$APP" ]] || { echo "error: $APP not found — run packaging/build-app.sh" >&2; exit 1; }

VERSION="${MACTR_VERSION:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
    "$APP/Contents/Info.plist")}"
ARCH="$(lipo -archs "$APP/Contents/MacOS/MacTR" | tr ' ' '-')"
DMG="$DIST/MacTR-AI-$VERSION-$ARCH.dmg"

echo "==> staging"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
# -R preserves the signed bundle's symlinks and permissions; plain -r would
# dereference them and break the code signature.
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

echo "==> building $(basename "$DMG")"
rm -f "$DMG"
hdiutil create \
    -volname "$APP_NAME" \
    -srcfolder "$STAGE" \
    -fs HFS+ \
    -format UDZO \
    -imagekey zlib-level=9 \
    -quiet \
    "$DMG"

echo "==> verifying"
hdiutil verify -quiet "$DMG"

echo "==> done: $DMG"
du -sh "$DMG" | awk '{print "    size: " $1}'
shasum -a 256 "$DMG" | awk '{print "    sha256: " $1}'
