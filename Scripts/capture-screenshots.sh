#!/bin/bash
#
# Captures the interface states the acceptance checklist calls for.
#
# Screenshotting a menu-bar popover cannot be fully automated: the popover is
# only alive while it is open, and several of the states below need a person to
# unplug something or deny a permission. This script therefore drives the parts
# it can and prompts for the parts it cannot, so the set comes out consistent
# rather than ad hoc.
#
set -euo pipefail

OUT="${OUT:-screenshots}"
mkdir -p "$OUT"

shot () {
    local name="$1" instruction="$2"
    echo
    echo "-----------------------------------------------------------------"
    echo "  $name"
    echo "-----------------------------------------------------------------"
    echo "  $instruction"
    echo
    read -r -p "  Press return, then click the Wave popover to capture it. "
    # -o omits the window shadow, which otherwise dominates a small popover.
    screencapture -o -w "$OUT/$name.png"
    echo "  saved $OUT/$name.png"
}

echo "Wave interface capture"
echo "Each state is captured twice, once per appearance."

for appearance in light dark; do
    echo
    echo "================================================================="
    echo "  Switch macOS to $appearance appearance now"
    echo "  (System Settings > Appearance)"
    echo "================================================================="
    read -r -p "  Press return when the system is in $appearance mode. "

    shot "01-permission-$appearance" \
         "Quit Wave, run: tccutil reset AudioCapture app.wave.mixer
   Relaunch Wave and open the popover. It should show the permission
   explanation and no mixer."

    shot "02-active-apps-$appearance" \
         "Grant permission. Start audio in at least two apps, set them to
   different volumes and devices, and open the popover with meters moving."

    shot "03-output-picker-$appearance" \
         "Open a row's output picker so the device list is showing."

    shot "04-disconnected-$appearance" \
         "Route an app to a removable device, then unplug it while it plays.
   Capture the row showing the fallback warning."

    shot "05-empty-$appearance" \
         "Stop all audio and forget all rules so the empty state shows."
done

echo
echo "Done. $(ls -1 "$OUT" | wc -l | tr -d ' ') files in $OUT/"
