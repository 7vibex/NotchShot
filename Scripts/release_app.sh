#!/bin/bash
# Builds, Developer-ID signs, notarizes, staples, assesses, and packages the
# public direct-distribution artifact. Local development builds remain the job
# of build_app.sh; this script refuses development or ad-hoc identities.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IDENTITY=""
KEYCHAIN_PROFILE=""
MARKETING_VERSION=""
BUILD_VERSION=""

require_argument() {
    if [[ $# -lt 2 || -z "$2" ]]; then
        echo "Missing value for $1." >&2
        exit 2
    fi
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --identity) require_argument "$@"; IDENTITY="$2"; shift 2 ;;
        --keychain-profile) require_argument "$@"; KEYCHAIN_PROFILE="$2"; shift 2 ;;
        --version) require_argument "$@"; MARKETING_VERSION="$2"; shift 2 ;;
        --build) require_argument "$@"; BUILD_VERSION="$2"; shift 2 ;;
        -h|--help)
            echo "Usage: $0 --identity 'Developer ID Application: …' --keychain-profile PROFILE \\"
            echo "          --version 1.2.0 --build 42"
            exit 0
            ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

if [[ "$IDENTITY" != "Developer ID Application:"* ]]; then
    echo "A Developer ID Application identity is required for public release." >&2
    exit 2
fi
if [[ -z "$KEYCHAIN_PROFILE" ]]; then
    echo "Pass a notarytool Keychain profile with --keychain-profile." >&2
    exit 2
fi
# A public build must carry its own version. Sparkle compares CFBundleVersion
# against the appcast, so shipping two releases at the same version leaves every
# installed copy unable to update — including past a security fix.
if [[ -z "$MARKETING_VERSION" || -z "$BUILD_VERSION" ]]; then
    echo "Pass --version and --build; a public release must not reuse the previous version." >&2
    exit 2
fi

APP="$ROOT/dist/NotchShot.app"
SUBMISSION_ZIP="$ROOT/dist/NotchShot-notary-submission.zip"
RELEASE_ZIP="$ROOT/dist/NotchShot.zip"

"$ROOT/Scripts/build_app.sh" --release --identity "$IDENTITY" \
    --version "$MARKETING_VERSION" --build "$BUILD_VERSION"

# Confirm the stamp landed before anything is signed, notarized, or published.
STAMPED_SHORT="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
STAMPED_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")"
if [[ "$STAMPED_SHORT" != "$MARKETING_VERSION" || "$STAMPED_BUILD" != "$BUILD_VERSION" ]]; then
    echo "Bundle version stamp failed: got $STAMPED_SHORT ($STAMPED_BUILD)." >&2
    exit 1
fi
echo "==> Releasing NotchShot $STAMPED_SHORT ($STAMPED_BUILD)"

codesign --verify --strict --verbose=4 "$APP"

rm -f "$SUBMISSION_ZIP" "$RELEASE_ZIP"
ditto -c -k --keepParent "$APP" "$SUBMISSION_ZIP"
xcrun notarytool submit "$SUBMISSION_ZIP" \
    --keychain-profile "$KEYCHAIN_PROFILE" \
    --wait
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
spctl --assess --type execute --verbose=4 "$APP"

ditto -c -k --keepParent "$APP" "$RELEASE_ZIP"
codesign --verify --strict --verbose=4 "$APP"

echo "Release artifact: $RELEASE_ZIP ($MARKETING_VERSION build $BUILD_VERSION)"
