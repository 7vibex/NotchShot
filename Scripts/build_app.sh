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
#   ./Scripts/build_app.sh                 # debug build, stable identity required
#   ./Scripts/build_app.sh --release       # optimised build
#   ./Scripts/build_app.sh --release --identity "Developer ID Application: …"
#   ./Scripts/build_app.sh --adhoc          # explicit, permission-unstable fallback
#   ./Scripts/build_app.sh --identity - --allow-permission-loss
#                                          # packaging check that may overwrite
#                                          # a signed bundle (voids TCC grants)
#   ./Scripts/build_app.sh --release --version 1.2.0 --build 42
#
# --version/--build set the bundle's marketing and build versions. Sparkle
# compares these against the appcast to decide whether an update is newer, so a
# published build that reuses the previous version can never be updated past.
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

CONFIGURATION="debug"
IDENTITY=""
ALLOW_ADHOC=false
ALLOW_PERMISSION_LOSS=false
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
        --release) CONFIGURATION="release"; shift ;;
        --debug) CONFIGURATION="debug"; shift ;;
        --identity) require_argument "$@"; IDENTITY="$2"; shift 2 ;;
        --adhoc) ALLOW_ADHOC=true; shift ;;
        --allow-permission-loss) ALLOW_PERMISSION_LOSS=true; shift ;;
        --version) require_argument "$@"; MARKETING_VERSION="$2"; shift 2 ;;
        --build) require_argument "$@"; BUILD_VERSION="$2"; shift 2 ;;
        -h|--help) sed -n '2,25p' "$0"; exit 0 ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

APP_NAME="NotchShot"
RECOVERY_NAME="NotchShotOSDRecovery"
ADAPTER_RUNNER_NAME="NotchShotAdapterRunner"
AI_REPORTER_NAME="NotchShotAIReporter"
# Assembled and signed under a staging name, then swapped into place only
# after `codesign --verify` passes. The previous version of this script removed
# the destination bundle before it built anything, so any later failure — a
# locked keychain, a rejected Sparkle key, a missing framework — left the user
# with a broken half-signed bundle where a working app used to be.
FINAL_APP_DIR="$ROOT/dist/$APP_NAME.app"
APP_DIR="$ROOT/dist/.$APP_NAME.app.staging"
CONTENTS="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS/MacOS"
RESOURCES_DIR="$CONTENTS/Resources"
FRAMEWORKS_DIR="$CONTENTS/Frameworks"

# Pick a stable signing identity if the caller didn't name one.
#
# This matters far more than it looks: macOS ties Screen Recording and
# Microphone grants to the app's *designated requirement*. Under an ad-hoc
# signature ("-") that requirement is the code hash, so every rebuild looks like
# a brand-new app and the permission you granted five minutes ago is silently
# dropped — the app then fails to capture with no visible reason. Signing with a
# real certificate keys the requirement to the identity plus the bundle id, so
# the grant survives rebuilds.
IDENTITY_LIST="$(security find-identity -v -p codesigning 2>/dev/null || true)"
if [[ -z "$IDENTITY" ]]; then
    for PREFIX in "Developer ID Application" "Apple Development" "Mac Developer" "NotchShot"; do
        # `|| true` matters: a non-matching grep exits 1, and under
        # `set -euo pipefail` that would abort the whole script before it ever
        # reached the next candidate. Keep the certificate fingerprint rather
        # than its display name: renewed certificates often share a name, and
        # `codesign` rejects that name as ambiguous.
        FOUND="$(printf '%s\n' "$IDENTITY_LIST" | grep "$PREFIX" | head -1 | sed -E 's/^[[:space:]]*[0-9]+\) ([[:xdigit:]]+) ".*"/\1/' || true)"
        if [[ -n "$FOUND" ]]; then
            IDENTITY="$FOUND"
            break
        fi
    done
fi

# Whether this build is Developer ID cannot be read back off $IDENTITY: the
# auto-selection above deliberately keeps the certificate *fingerprint*, and a
# fingerprint never matches a "Developer ID Application:" prefix test. Resolve
# it against the identity list instead, so a fingerprint and a display name
# reach the same answer — and so an auto-selected Developer ID build still gets
# Apple's secure timestamp, which notarization requires.
IS_DEVELOPER_ID=false
if [[ "$IDENTITY" == "Developer ID Application:"* ]]; then
    IS_DEVELOPER_ID=true
elif [[ "$IDENTITY" != "-" ]] && printf '%s\n' "$IDENTITY_LIST" \
    | grep -iF -- "$IDENTITY" | grep -qF "Developer ID Application"; then
    IS_DEVELOPER_ID=true
fi

if [[ -z "$IDENTITY" ]]; then
    if [[ "$ALLOW_ADHOC" == true ]]; then
        IDENTITY="-"
    else
        cat >&2 <<'WARN'

No usable code-signing identity was found, so the build stopped before it
could replace a permission-stable app with an ad-hoc build.

Create a Code Signing certificate in Keychain Access, pass an existing one with
--identity, or use --adhoc only when you accept that macOS will forget Screen
Recording and Microphone permission after the next rebuild.

WARN
        exit 2
    fi

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
swift build -c "$CONFIGURATION" --product "$RECOVERY_NAME"
swift build -c "$CONFIGURATION" --product "$ADAPTER_RUNNER_NAME"
swift build -c "$CONFIGURATION" --product "$AI_REPORTER_NAME"
BIN_DIR="$(swift build -c "$CONFIGURATION" --show-bin-path)"
BINARY="$BIN_DIR/$APP_NAME"
RECOVERY_BINARY="$BIN_DIR/$RECOVERY_NAME"
ADAPTER_RUNNER_BINARY="$BIN_DIR/$ADAPTER_RUNNER_NAME"
AI_REPORTER_BINARY="$BIN_DIR/$AI_REPORTER_NAME"

if [[ ! -x "$BINARY" ]]; then
    echo "Build produced no executable at $BINARY" >&2
    exit 1
fi
if [[ ! -x "$RECOVERY_BINARY" ]]; then
    echo "Build produced no recovery executable at $RECOVERY_BINARY" >&2
    exit 1
fi
if [[ ! -x "$ADAPTER_RUNNER_BINARY" ]]; then
    echo "Build produced no adapter runner at $ADAPTER_RUNNER_BINARY" >&2
    exit 1
fi
if [[ ! -x "$AI_REPORTER_BINARY" ]]; then
    echo "Build produced no AI reporter at $AI_REPORTER_BINARY" >&2
    exit 1
fi

echo "==> Assembling bundle"
rm -rf "$APP_DIR"
# Leaving a half-built staging bundle behind would be confusing and would also
# make the next run's `cp -R` land inside it.
APP_INTENTS_TEMP=""
cleanup_staging() {
    rm -rf "$APP_DIR"
    if [[ -n "$APP_INTENTS_TEMP" ]]; then
        rm -rf "$APP_INTENTS_TEMP"
    fi
}
trap cleanup_staging EXIT
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR" "$FRAMEWORKS_DIR"

cp "$BINARY" "$MACOS_DIR/$APP_NAME"
cp "$RECOVERY_BINARY" "$MACOS_DIR/$RECOVERY_NAME"
cp "$ADAPTER_RUNNER_BINARY" "$MACOS_DIR/$ADAPTER_RUNNER_NAME"
cp "$AI_REPORTER_BINARY" "$MACOS_DIR/notchshot-ai"
cp "$ROOT/Resources/Info.plist" "$CONTENTS/Info.plist"

# Stamp the bundle version. Sparkle's "is this newer?" decision reads
# CFBundleVersion and CFBundleShortVersionString from the *installed* app, so
# two releases that share the version in Resources/Info.plist are
# indistinguishable to the updater and no update is ever offered.
if [[ -n "$MARKETING_VERSION" ]]; then
    if [[ ! "$MARKETING_VERSION" =~ ^[0-9]+(\.[0-9]+)*(-[0-9A-Za-z.-]+)?$ ]]; then
        echo "--version must look like 1.2.0 or 1.2.0-beta.1." >&2
        exit 2
    fi
    plutil -replace CFBundleShortVersionString -string "$MARKETING_VERSION" "$CONTENTS/Info.plist"
fi
if [[ -n "$BUILD_VERSION" ]]; then
    if [[ ! "$BUILD_VERSION" =~ ^[0-9]+$ ]]; then
        echo "--build must be a monotonically increasing integer." >&2
        exit 2
    fi
    plutil -replace CFBundleVersion -string "$BUILD_VERSION" "$CONTENTS/Info.plist"
fi
cp "$ROOT/Resources/PrivacyInfo.xcprivacy" "$RESOURCES_DIR/PrivacyInfo.xcprivacy"
printf 'APPL????' > "$CONTENTS/PkgInfo"

# SwiftPM compiles the AppIntent types but does not run Xcode's metadata build
# phase for a hand-assembled .app. Compile the intent source with constant-value
# gathering enabled, then feed those compiler-owned inputs to the metadata
# processor shipped by this exact Xcode. This invocation is validated below by
# requiring a non-empty Metadata.appintents payload in the final bundle.
echo "==> Extracting App Intents metadata"
APP_INTENTS_TEMP="$(mktemp -d "${TMPDIR:-/tmp}/notchshot-appintents.XXXXXX")"
INTENT_SOURCE="$ROOT/Sources/NotchShotKit/Automation/NotchShotAppIntents.swift"
INTENT_PROTOCOLS="$APP_INTENTS_TEMP/protocols.json"
INTENT_SOURCE_LIST="$APP_INTENTS_TEMP/sources.list"
INTENT_CONST_LIST="$APP_INTENTS_TEMP/const-values.list"
INTENT_CONST_VALUES="$APP_INTENTS_TEMP/NotchShotAppIntents.swiftconstvalues"
INTENT_OBJECT="$APP_INTENTS_TEMP/NotchShotAppIntents.o"
cat > "$INTENT_PROTOCOLS" <<'JSON'
["AppIntent","EntityQuery","AppEntity","TransientEntity","AppEnum","AppShortcutProviding","AppShortcutsProvider","AnyResolverProviding","AppIntentsPackage","DynamicOptionsProvider"]
JSON
printf '%s\n' "$INTENT_SOURCE" > "$INTENT_SOURCE_LIST"
printf '%s\n' "$INTENT_CONST_VALUES" > "$INTENT_CONST_LIST"

SWIFTC="$(xcrun --find swiftc)"
SDK_ROOT="$(xcrun --sdk macosx --show-sdk-path)"
TOOLCHAIN_DIR="$(cd "$(dirname "$SWIFTC")/../.." && pwd)"
XCODE_BUILD_VERSION="$(xcodebuild -version | awk '/Build version/{print $3}')"
TARGET_TRIPLE="$(uname -m)-apple-macosx26.0"
"$SWIFTC" \
    -c "$INTENT_SOURCE" \
    -o "$INTENT_OBJECT" \
    -parse-as-library \
    -module-name NotchShotKit \
    -swift-version 6 \
    -target "$TARGET_TRIPLE" \
    -sdk "$SDK_ROOT" \
    -D NOTCHSHOT_METADATA_EXTRACTION \
    -emit-const-values-path "$INTENT_CONST_VALUES" \
    -Xfrontend -const-gather-protocols-file \
    -Xfrontend "$INTENT_PROTOCOLS"

xcrun appintentsmetadataprocessor \
    --output "$RESOURCES_DIR" \
    --toolchain-dir "$TOOLCHAIN_DIR" \
    --module-name NotchShotKit \
    --sdk-root "$SDK_ROOT" \
    --xcode-version "$XCODE_BUILD_VERSION" \
    --platform-family macOS \
    --deployment-target 26.0 \
    --target-triple "$TARGET_TRIPLE" \
    --source-file-list "$INTENT_SOURCE_LIST" \
    --swift-const-vals-list "$INTENT_CONST_LIST" \
    --force

APP_INTENTS_METADATA="$RESOURCES_DIR/Metadata.appintents"
if [[ ! -e "$APP_INTENTS_METADATA" || "$(du -sk "$APP_INTENTS_METADATA" | awk '{print $1}')" -le 0 ]]; then
    echo "Xcode produced no usable Metadata.appintents payload." >&2
    exit 1
fi

# A release feed is enabled only when both credentials are explicitly supplied.
# The EdDSA private key is never accepted here and must stay outside the build host.
if [[ -n "${NOTCHSHOT_SPARKLE_FEED_URL:-}" || -n "${NOTCHSHOT_SPARKLE_PUBLIC_KEY:-}" ]]; then
    if [[ ! "${NOTCHSHOT_SPARKLE_FEED_URL:-}" =~ ^https:// ]] || [[ -z "${NOTCHSHOT_SPARKLE_PUBLIC_KEY:-}" ]]; then
        echo "Sparkle requires an HTTPS feed URL and its 32-byte base64 public EdDSA key." >&2
        exit 2
    fi
    # SecureUpdateController refuses anything that is not exactly 32 decoded
    # bytes, and it refuses it at runtime with no visible symptom beyond an
    # updater that never checks. Fail the build instead.
    KEY_BYTES="$(printf '%s' "$NOTCHSHOT_SPARKLE_PUBLIC_KEY" \
        | base64 --decode 2>/dev/null | wc -c | tr -d ' ' || true)"
    if [[ "$KEY_BYTES" != "32" ]]; then
        echo "NOTCHSHOT_SPARKLE_PUBLIC_KEY must be base64 that decodes to exactly 32 bytes (got ${KEY_BYTES:-0})." >&2
        exit 2
    fi
    plutil -insert SUFeedURL -string "$NOTCHSHOT_SPARKLE_FEED_URL" "$CONTENTS/Info.plist"
    plutil -insert SUPublicEDKey -string "$NOTCHSHOT_SPARKLE_PUBLIC_KEY" "$CONTENTS/Info.plist"
fi

SPARKLE_FRAMEWORK="$BIN_DIR/Sparkle.framework"
if [[ ! -d "$SPARKLE_FRAMEWORK" || -L "$SPARKLE_FRAMEWORK" ]]; then
    echo "SwiftPM produced no safe Sparkle.framework at $SPARKLE_FRAMEWORK." >&2
    exit 1
fi
RESOLVED_SPARKLE_IDENTITY="$(plutil -extract pins.0.identity raw "$ROOT/Package.resolved")"
RESOLVED_SPARKLE_VERSION="$(plutil -extract pins.0.state.version raw "$ROOT/Package.resolved")"
FRAMEWORK_SPARKLE_VERSION="$(plutil -extract CFBundleShortVersionString raw "$SPARKLE_FRAMEWORK/Versions/B/Resources/Info.plist")"
if [[ "$RESOLVED_SPARKLE_IDENTITY" != "sparkle" || "$FRAMEWORK_SPARKLE_VERSION" != "$RESOLVED_SPARKLE_VERSION" ]]; then
    echo "Sparkle artifact mismatch: resolved $RESOLVED_SPARKLE_VERSION, found $FRAMEWORK_SPARKLE_VERSION." >&2
    exit 1
fi
cp -R "$SPARKLE_FRAMEWORK" "$FRAMEWORKS_DIR/Sparkle.framework"
# SwiftPM executables use @loader_path for command-line layouts. A real app
# bundle keeps embedded frameworks one level above Contents/MacOS.
APP_LOAD_COMMANDS="$(otool -l "$MACOS_DIR/$APP_NAME")"
if [[ "$APP_LOAD_COMMANDS" != *"@executable_path/../Frameworks"* ]]; then
    install_name_tool -add_rpath "@executable_path/../Frameworks" "$MACOS_DIR/$APP_NAME"
fi

if [[ -f "$ROOT/Resources/AppIcon.icns" ]]; then
    cp "$ROOT/Resources/AppIcon.icns" "$RESOURCES_DIR/AppIcon.icns"
    /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$CONTENTS/Info.plist" 2>/dev/null || true
fi

echo "==> Signing with identity: $IDENTITY"
# --options runtime enables the Hardened Runtime; the entitlements grant back
# the microphone, camera, and Apple Events integrations it would otherwise block.
TIMESTAMP_OPTION=(--timestamp=none)
APP_ENTITLEMENTS="$ROOT/Resources/NotchShot.entitlements"
if [[ "$IS_DEVELOPER_ID" == true ]]; then
    # Public Developer ID distribution needs Apple's secure timestamp. Local
    # self-signed and ad-hoc identities cannot obtain one.
    TIMESTAMP_OPTION=(--timestamp)
fi
if [[ "$IDENTITY" == "-" ]]; then
    # Hardened Runtime library validation identifies ad-hoc code by its code
    # hash. The app and embedded Sparkle framework therefore cannot share a
    # Team ID, and dyld rejects Sparkle unless this disposable fallback opts
    # out. Certificate-signed builds deliberately keep library validation on.
    APP_ENTITLEMENTS="$ROOT/Resources/NotchShot-AdHoc.entitlements"
fi
SPARKLE_VERSION_DIR="$FRAMEWORKS_DIR/Sparkle.framework/Versions/B"
# Sparkle contains nested code. Sign inside-out, preserving Downloader's
# entitlement, rather than using codesign --deep (which Sparkle warns against).
codesign --force --sign "$IDENTITY" --options runtime "${TIMESTAMP_OPTION[@]}" \
    "$SPARKLE_VERSION_DIR/XPCServices/Installer.xpc"
codesign --force --sign "$IDENTITY" --options runtime --preserve-metadata=entitlements \
    "${TIMESTAMP_OPTION[@]}" "$SPARKLE_VERSION_DIR/XPCServices/Downloader.xpc"
codesign --force --sign "$IDENTITY" --options runtime "${TIMESTAMP_OPTION[@]}" \
    "$SPARKLE_VERSION_DIR/Autoupdate"
codesign --force --sign "$IDENTITY" --options runtime "${TIMESTAMP_OPTION[@]}" \
    "$SPARKLE_VERSION_DIR/Updater.app"
codesign --force --sign "$IDENTITY" --options runtime "${TIMESTAMP_OPTION[@]}" \
    "$FRAMEWORKS_DIR/Sparkle.framework"
codesign \
    --force \
    --sign "$IDENTITY" \
    --options runtime \
    "${TIMESTAMP_OPTION[@]}" \
    "$MACOS_DIR/$RECOVERY_NAME"
codesign \
    --force \
    --sign "$IDENTITY" \
    --options runtime \
    "${TIMESTAMP_OPTION[@]}" \
    "$MACOS_DIR/$ADAPTER_RUNNER_NAME"
codesign \
    --force \
    --sign "$IDENTITY" \
    --options runtime \
    "${TIMESTAMP_OPTION[@]}" \
    "$MACOS_DIR/notchshot-ai"
codesign \
    --force \
    --sign "$IDENTITY" \
    --options runtime \
    --entitlements "$APP_ENTITLEMENTS" \
    "${TIMESTAMP_OPTION[@]}" \
    "$APP_DIR"

echo "==> Verifying"
codesign --verify --deep --strict --verbose=2 "$APP_DIR"

# Refuse to downgrade a permission-stable bundle into an ad-hoc one.
#
# A verified build is not automatically a build worth installing. Replacing an
# app signed with a real certificate by an ad-hoc one silently voids every TCC
# grant it holds: Screen Recording and Input Monitoring stay switched on in
# System Settings — the record belongs to the old designated requirement — while
# `CGPreflightScreenCaptureAccess` and the media-key tap both start returning
# false. The app then looks approved and broken at the same time, which is
# exactly the state this guard exists to prevent.
if [[ "$IDENTITY" == "-" && -d "$FINAL_APP_DIR" ]]; then
    PREVIOUS_TEAM="$(codesign -dvv "$FINAL_APP_DIR" 2>&1 \
        | sed -n 's/^TeamIdentifier=//p' || true)"
    if [[ -n "$PREVIOUS_TEAM" && "$PREVIOUS_TEAM" != "not set" ]]; then
        if [[ "$ALLOW_PERMISSION_LOSS" == true ]]; then
            BACKUP_APP_DIR="$ROOT/dist/$APP_NAME-signed-backup.app"
            rm -rf "$BACKUP_APP_DIR"
            cp -R "$FINAL_APP_DIR" "$BACKUP_APP_DIR"
            echo "==> Kept the signed bundle at $BACKUP_APP_DIR"
        else
            rm -rf "$APP_DIR"
            trap - EXIT
            cat >&2 <<WARN

Refusing to replace a signed NotchShot.app with an ad-hoc build.

The installed bundle is signed by team $PREVIOUS_TEAM. macOS keys Screen
Recording and Input Monitoring to that identity, so overwriting it ad-hoc would
leave both permissions switched on in System Settings but refused in the app —
screenshots fail, and the macOS volume and brightness overlay comes back.

Build with the certificate instead:
  ./Scripts/build_app.sh --release --identity "$(security find-identity -v -p codesigning 2>/dev/null | sed -n '1s/^[[:space:]]*1) \([[:xdigit:]]*\).*/\1/p')"

Or, if losing those permissions is intended, pass --allow-permission-loss.

WARN
            exit 3
        fi
    fi
fi

# Verification passed, so this bundle is worth replacing the previous one with.
# Swapping only now is what keeps a failed run from destroying a working app.
rm -rf "$FINAL_APP_DIR"
mv "$APP_DIR" "$FINAL_APP_DIR"
trap - EXIT
APP_DIR="$FINAL_APP_DIR"

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
