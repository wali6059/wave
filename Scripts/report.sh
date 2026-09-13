#!/bin/bash
#
# Collects everything needed to diagnose a failed build in one file.
#
# Run this on the Mac and hand over the resulting file. It captures the
# environment, the full build and test output, and (if the build got far
# enough) what Wave can actually see on this machine.
#
# It never touches audio and never asks for a permission. Nothing here leaves
# your machine unless you send the file yourself.
#
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

OUT="${1:-wave-report.txt}"
: > "$OUT"

section () { { echo; echo "======== $1 ========"; } >> "$OUT"; }

section "environment"
{
    sw_vers
    echo
    swift --version 2>&1
    echo
    xcodebuild -version 2>&1 | head -2
    echo
    echo "SDK: $(xcrun --show-sdk-version 2>&1) at $(xcrun --show-sdk-path 2>&1)"
    echo "arch: $(uname -m)"
} >> "$OUT" 2>&1

section "codesigning identities"
# Names only. Hashes are omitted: they are not needed to diagnose a build and
# there is no reason to put them in a file you might paste somewhere.
security find-identity -v -p codesigning 2>&1 \
    | sed -E 's/^ *[0-9]+\) [0-9A-F]+ /  /' >> "$OUT" 2>&1

section "swift build (debug)"
swift build 2>&1 >> "$OUT"
BUILD_STATUS=$?
echo "exit status: $BUILD_STATUS" >> "$OUT"

if [ $BUILD_STATUS -eq 0 ]; then
    section "swift build (warnings as errors)"
    swift build -Xswiftc -warnings-as-errors -Xcc -Werror 2>&1 >> "$OUT"
    echo "exit status: $?" >> "$OUT"

    section "swift test"
    swift test 2>&1 >> "$OUT"
    echo "exit status: $?" >> "$OUT"

    section "app bundle"
    ./Scripts/build-app.sh 2>&1 >> "$OUT"
    echo "exit status: $?" >> "$OUT"

    if [ -x build/Wave.app/Contents/MacOS/wave-spike ]; then
        section "wave-spike list"
        ./build/Wave.app/Contents/MacOS/wave-spike list 2>&1 >> "$OUT"

        section "wave-spike permission"
        ./build/Wave.app/Contents/MacOS/wave-spike permission 2>&1 >> "$OUT"
    fi
fi

echo
echo "Wrote $OUT ($(wc -l < "$OUT" | tr -d ' ') lines)."
if [ $BUILD_STATUS -ne 0 ]; then
    echo
    echo "The build failed. First few errors:"
    grep -E "error:" "$OUT" | head -10
    echo
    echo "Total errors: $(grep -c "error:" "$OUT")"
fi
