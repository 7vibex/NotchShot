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
IDENTITY=""

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

# Pick a stable signing identity if the caller didn't name one.
#
# This matters far more than it looks: macOS ties Screen Recording and
# Microphone grants to the app's *designated requirement*. Under an ad-hoc
# signature ("-") that requirement is the code hash, so every rebuild looks like
# a brand-new app and the permission you granted five minutes ago is silently
# dropped — the app then fails to capture with no visible reason. Signing with a
# real certificate keys the requirement to the identity plus the bundle id, so
# the grant survives rebuilds.
if [[ -z "$IDENTITY" ]]; then
    IDENTITY_LIST="$(security find-identity -v -p codesigning 2>/dev/null || true)"
    for PREFIX in "Developer ID Application" "Apple Development" "Mac Developer" "NotchShot"; do
        # `|| true` matters: a non-matching grep exits 1, and under
        # `set -euo pipefail` that would abort the whole script before it ever
        # reached the next candidate.
        FOUND="$(printf '%s\n' "$IDENTITY_LIST" | grep "$PREFIX" | head -1 | sed -E 's/.*"(.*)"/\1/' || true)"
        if [[ -n "$FOUND" ]]; then
            IDENTITY="$FOUND"
            break
        fi
    done
fi

if [[ -z "$IDENTITY" ]]; then
    IDENTITY="-"
    cat >&2 <<'WARN'

⚠️  No code-signing certificate found — falling back to an ad-hoc signature.

    macOS will forget Screen Recording and Microphone permission on EVERY
    rebuild, because an ad-hoc signature's identity is its code hash.

    To fix permanently, create a free self-signed certificate:
      Keychain Access ▸ Certificate Assistant ▸ Create a Certificate…
      Name: NotchShot Local · Type: Code Signing · Self Signed Root
    then rerun:  ./Scripts/build_app.sh --identity "NotchShot Local"

WARN
fi

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
echo "Signed as: $IDENTITY"
echo
if [[ "$IDENTITY" == "-" ]]; then
    echo "Ad-hoc signature: macOS will forget Screen Recording on the next"
    echo "rebuild. See the warning above to fix that permanently."
else
    echo "The first capture asks for Screen Recording. Allow it, then QUIT AND"
    echo "REOPEN NotchShot — macOS only applies a new capture grant to freshly"
    echo "launched processes. Because this build is signed with a real"
    echo "certificate, you only have to do this once; later rebuilds keep it."
fi
