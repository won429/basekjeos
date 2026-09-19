#!/bin/zsh
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DIST_DIR="$PROJECT_DIR/dist"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PROJECT_DIR/Resources/Info.plist")"
ZIP_PATH="$DIST_DIR/Nook-$VERSION.zip"
# Stage outside synced folders so Finder metadata cannot invalidate the signature.
STAGING_DIR="$(mktemp -d "${TMPDIR:-/tmp}/notchmusic-package.XXXXXX")"
trap 'rm -rf "$STAGING_DIR"' EXIT
APP_DIR="$STAGING_DIR/Nook.app"
CONTENTS_DIR="$APP_DIR/Contents"
mkdir -p "$CONTENTS_DIR/MacOS" "$CONTENTS_DIR/Resources" "$DIST_DIR"
cp "$PROJECT_DIR/.build/release/NotchMusic" "$CONTENTS_DIR/MacOS/Nook"
cp "$PROJECT_DIR/Resources/Info.plist" "$CONTENTS_DIR/Info.plist"
cp "$PROJECT_DIR/Resources/AppIcon.icns" "$CONTENTS_DIR/Resources/AppIcon.icns"
cp "$PROJECT_DIR/Resources/NowPlayingBridge.js" "$CONTENTS_DIR/Resources/NowPlayingBridge.js"
cp -R "$PROJECT_DIR/Resources/AirPodsRotation" "$CONTENTS_DIR/Resources/AirPodsRotation"
/usr/bin/xattr -cr "$APP_DIR"
/usr/bin/codesign --force --deep --sign - \
    --requirements '=designated => identifier "com.notchmusic.app"' "$APP_DIR"
/usr/bin/codesign --verify --deep --strict "$APP_DIR"
/usr/bin/ditto -c -k --norsrc --noextattr --keepParent "$APP_DIR" "$ZIP_PATH"
/usr/bin/ditto -x -k "$ZIP_PATH" "$STAGING_DIR/verify"
/usr/bin/codesign --verify --deep --strict "$STAGING_DIR/verify/Nook.app"
# Keep only the verified ZIP in dist. Unpacked copies with the production
# bundle identifier are registered by LaunchServices and can make macOS open
# an older build from Finder, Spotlight, or the Dock.
echo "$ZIP_PATH"
