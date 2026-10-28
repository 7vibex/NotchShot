#!/usr/bin/env bash
# Regenerates Resources/AppIcon.icns from the mascot geometry in
# Sources/NotchShotKit/UI/NotchShotLogo.swift. build_app.sh picks the .icns up.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/notchshot-icon.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

swiftc -O \
    "$ROOT/Sources/NotchShotKit/UI/NotchShotLogo.swift" \
    "$ROOT/Scripts/AppIcon/main.swift" \
    -o "$WORK/render_icon"

"$WORK/render_icon" "$WORK/AppIcon.iconset"
iconutil -c icns "$WORK/AppIcon.iconset" -o "$ROOT/Resources/AppIcon.icns"
echo "Wrote $ROOT/Resources/AppIcon.icns"
