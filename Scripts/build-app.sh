#!/bin/bash
#
# Assembles Wave.app from the SwiftPM build products.
#
# Wave is a SwiftPM package rather than an Xcode project so that the whole
# thing builds, tests and runs from one command with no generated project file
# to drift. SwiftPM cannot emit an .app, so this script does the (small) amount
# of bundling that a menu-bar app needs: the executable, an Info.plist with the
# audio-capture usage description, and a code signature.
#
# Code signing is not optional cosmetics here. macOS keys the System Audio
# Recording privilege to the app's signing identity, so an unsigned build
# cannot hold the permission: the prompt will not appear, and every tap will
# return success while delivering silence.
#
set -euo pipefail

CONFIGURATION="${CONFIGURATION:-release}"
BUILD_DIR="${BUILD_DIR:-build}"
APP_NAME="Wave"
APP="${BUILD_DIR}/${APP_NAME}.app"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

cd "$ROOT"

echo "==> Building ($CONFIGURATION)"
swift build -c "$CONFIGURATION" --product wave
swift build -c "$CONFIGURATION" --product wave-spike

BIN_PATH="$(swift build -c "$CONFIGURATION" --show-bin-path)"

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN_PATH/wave" "$APP/Contents/MacOS/$APP_NAME"
# The spike lives inside the bundle so that it runs under Wave's Info.plist and
# code signature, and therefore under Wave's TCC identity. Run outside the
# bundle it would be a different (unsigned, plist-less) principal and capture
# would be denied silently.
cp "$BIN_PATH/wave-spike" "$APP/Contents/MacOS/wave-spike"

cp Resources/Info.plist "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# Bundle any SwiftPM resource bundles that were produced.
for bundle in "$BIN_PATH"/*.bundle; do
    [ -e "$bundle" ] || continue
    cp -R "$bundle" "$APP/Contents/Resources/"
done

echo "==> Signing"
if [ -n "${CODESIGN_IDENTITY:-}" ]; then
    IDENTITY="$CODESIGN_IDENTITY"
    echo "    identity: $IDENTITY"
else
    # Prefer a real Apple Development identity when one exists: TCC remembers a
    # stable identity across rebuilds, whereas an ad-hoc signature changes every
    # time and macOS may re-prompt or silently drop the grant.
    IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
        | grep -E 'Apple Development|Developer ID Application' \
        | head -n1 \
        | sed -E 's/.*"(.*)"/\1/' || true)"
    if [ -z "$IDENTITY" ]; then
        IDENTITY="-"
        echo "    identity: ad-hoc (no Developer ID or Apple Development identity found)"
        echo "    WARNING: an ad-hoc signature is not stable across rebuilds. macOS may"
        echo "             forget the System Audio Recording grant every time you rebuild."
        echo "             Set CODESIGN_IDENTITY to a real identity to avoid that."
    else
        echo "    identity: $IDENTITY"
    fi
fi

codesign --force \
         --sign "$IDENTITY" \
         --options runtime \
         --entitlements Resources/Wave.entitlements \
         --timestamp=none \
         "$APP/Contents/MacOS/wave-spike"

codesign --force \
         --sign "$IDENTITY" \
         --options runtime \
         --entitlements Resources/Wave.entitlements \
         --timestamp=none \
         "$APP"

echo "==> Verifying"
codesign --verify --deep --strict --verbose=2 "$APP"

# The usage description is the single most common thing to get wrong, and
# getting it wrong produces a silent denial rather than an error, so check it.
if ! /usr/libexec/PlistBuddy -c "Print :NSAudioCaptureUsageDescription" "$APP/Contents/Info.plist" >/dev/null 2>&1; then
    echo "FATAL: NSAudioCaptureUsageDescription is missing from the bundled Info.plist." >&2
    echo "       macOS would deny audio capture without ever showing a prompt." >&2
    exit 1
fi

echo
echo "Built $APP"
echo
echo "  Run the app:    open $APP"
echo "  Run the spike:  $APP/Contents/MacOS/wave-spike list"
