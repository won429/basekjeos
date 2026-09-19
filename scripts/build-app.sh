#!/bin/zsh

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$PROJECT_DIR/.build"
SDK_PATH="$(zsh "$PROJECT_DIR/scripts/select-macos-sdk.sh")"

# Compile a stable snapshot outside synced folders. Metadata updates in a
# synced checkout can otherwise make Swift reject inputs as modified mid-build.
STAGING_DIR="$(mktemp -d "${TMPDIR:-/tmp}/notchmusic-build.XXXXXX")"
trap 'rm -rf "$STAGING_DIR"' EXIT
CACHE_DIR="${TMPDIR:-/tmp}/notchmusic-module-cache"
mkdir -p "$CACHE_DIR" "$BUILD_DIR/release"
cp "$PROJECT_DIR"/Sources/NotchMusic/*.swift "$STAGING_DIR/"
SOURCE_FILES=("$STAGING_DIR"/*.swift)
TARGET_ARCH="$(uname -m)"

env CLANG_MODULE_CACHE_PATH="$CACHE_DIR" \
    swiftc \
    -O \
    -parse-as-library \
    -sdk "$SDK_PATH" \
    -target "$TARGET_ARCH-apple-macos13.0" \
    "${SOURCE_FILES[@]}" \
    -o "$STAGING_DIR/NotchMusic" \
    -framework AppKit \
    -framework QuartzCore \
    -framework SwiftUI \
    -framework Combine \
    -framework ScreenCaptureKit \
    -framework CoreMedia \
    -framework AudioToolbox \
    -framework IOKit \
    -framework IOBluetooth \
    -framework Accelerate

cp "$STAGING_DIR/NotchMusic" "$BUILD_DIR/release/NotchMusic"
zsh "$PROJECT_DIR/scripts/package-app.sh"
