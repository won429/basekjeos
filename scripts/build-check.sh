#!/bin/zsh
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CHECK_NAME="$1"
SDK_PATH="$(zsh "$PROJECT_DIR/scripts/select-macos-sdk.sh")"
STAGING_DIR="$(mktemp -d "${TMPDIR:-/tmp}/nook-check.XXXXXX")"
trap 'rm -rf "$STAGING_DIR"' EXIT
if [[ "$CHECK_NAME" == "MenuBarStartupChecks" ]]; then
    cp "$PROJECT_DIR/Sources/NotchMusic/MenuBarIconCollapser.swift" "$STAGING_DIR/"
else
    for source in "$PROJECT_DIR"/Sources/NotchMusic/*.swift; do
        [[ "$source" == */NotchMusicApp.swift ]] || cp "$source" "$STAGING_DIR/"
    done
fi
cp "$PROJECT_DIR/tests/$CHECK_NAME.swift" "$STAGING_DIR/"
swiftc -O -parse-as-library -sdk "$SDK_PATH" \
    -module-cache-path /tmp/notchmusic-module-cache "$STAGING_DIR"/*.swift \
    -o "/tmp/Nook-$CHECK_NAME" -framework AppKit -framework QuartzCore -framework SwiftUI \
    -framework Combine -framework ScreenCaptureKit -framework CoreMedia -framework AudioToolbox \
    -framework IOKit -framework IOBluetooth -framework Accelerate
