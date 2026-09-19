#!/bin/zsh
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
swift -module-cache-path /tmp/notchmusic-module-cache "$PROJECT_DIR/scripts/ExportAppIcon.swift" "$PROJECT_DIR/Resources/AppIconArtwork.png" "$PROJECT_DIR/Resources/AppIcon.png"
ICON_DIR="$(mktemp -d "${TMPDIR:-/tmp}/notchmusic-icon.XXXXXX")"
trap 'rm -rf "$ICON_DIR"' EXIT
mkdir -p "$ICON_DIR/AppIcon.iconset"
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$PROJECT_DIR/Resources/AppIcon.png" --out "$ICON_DIR/AppIcon.iconset/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    sips -z "$double" "$double" "$PROJECT_DIR/Resources/AppIcon.png" --out "$ICON_DIR/AppIcon.iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICON_DIR/AppIcon.iconset" -o "$PROJECT_DIR/Resources/AppIcon.icns"
