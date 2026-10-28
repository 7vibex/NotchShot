#!/usr/bin/env bash
# Packages the source artwork into Resources/AppIcon.icns and AppIcon.png.
# build_app.sh copies the .icns into the signed application bundle.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/notchshot-icon.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

swiftc -O \
    "$ROOT/Scripts/AppIcon/main.swift" \
    -o "$WORK/render_icon"

"$WORK/render_icon" \
    "$ROOT/Resources/Brand/AppIconArtwork.png" \
    "$WORK/AppIcon.iconset" \
    "$ROOT/Resources/AppIcon.png"
iconutil -c icns "$WORK/AppIcon.iconset" -o "$ROOT/Resources/AppIcon.icns"
echo "Wrote $ROOT/Resources/AppIcon.icns and AppIcon.png"
