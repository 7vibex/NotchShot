#!/bin/bash
#
# Builds NotchShot.app from the Swift package and code-signs it with the
# Hardened Runtime.
#
# A real .app bundle is not optional here: macOS ties TCC grants (Screen
# Recording, Microphone, Automation) to a bundle identifier and a stable code
# signature. A bare `swift run` binary gets prompted every launch, or silently
# denied, so always test through this script.
#
#   ./Scripts/build_app.sh                 # debug build, ad-hoc signature
#   ./Scripts/build_app.sh --release       # optimised build
#   ./Scripts/build_app.sh --release --identity "Developer ID Application: …"
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

CONFIGURATION="debug"
# "-" is an ad-hoc signature: enough for TCC to remember the app across
# launches on this Mac, but it will not pass Gatekeeper elsewhere.
IDENTITY="-"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --release) CONFIGURATION="release"; shift ;;
        --debug) CONFIGURATION="debug"; shift ;;
        --identity) IDENTITY="$2"; shift 2 ;;
        -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

APP_NAME="NotchShot"
APP_DIR="$ROOT/dist/$APP_NAME.app"
CONTENTS="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS/MacOS"
RESOURCES_DIR="$CONTENTS/Resources"

echo "==> Building ($CONFIGURATION)"
swift build -c "$CONFIGURATION" --product "$APP_NAME"
BINARY="$(swift build -c "$CONFIGURATION" --product "$APP_NAME" --show-bin-path)/$APP_NAME"

if [[ ! -x "$BINARY" ]]; then
    echo "Build produced no executable at $BINARY" >&2
    exit 1
fi

echo "==> Assembling bundle"
rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

cp "$BINARY" "$MACOS_DIR/$APP_NAME"
cp "$ROOT/Resources/Info.plist" "$CONTENTS/Info.plist"
printf 'APPL????' > "$CONTENTS/PkgInfo"

if [[ -f "$ROOT/Resources/AppIcon.icns" ]]; then
    cp "$ROOT/Resources/AppIcon.icns" "$RESOURCES_DIR/AppIcon.icns"
    /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$CONTENTS/Info.plist" 2>/dev/null || true
fi

echo "==> Signing with identity: $IDENTITY"
# --options runtime enables the Hardened Runtime; the entitlements grant back
# exactly the two things it would otherwise block.
codesign \
    --force \
    --sign "$IDENTITY" \
    --options runtime \
    --entitlements "$ROOT/Resources/NotchShot.entitlements" \
    --timestamp=none \
    "$APP_DIR"

echo "==> Verifying"
codesign --verify --verbose=2 "$APP_DIR"

echo
echo "Built: $APP_DIR"
echo
echo "Next steps:"
echo "  open $APP_DIR"
echo
echo "The first capture will ask for Screen Recording. macOS caches the old"
echo "signature, so if permission seems stuck after a rebuild, remove NotchShot"
echo "from System Settings > Privacy & Security > Screen & System Audio"
echo "Recording and let it re-prompt."
