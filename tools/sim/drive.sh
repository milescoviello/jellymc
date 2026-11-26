#!/usr/bin/env bash
# Drives the iPhone app in a simulator, on CI (.github/workflows/ios-sim.yml), against the
# server on tape: a script from tools/sim/scripts, made of the steps below, with
# screenshots and accessibility dumps into $OUT.
#
#   UDID=… OUT=shots tools/sim/drive.sh tour
#
# Coordinates are the simulator's points. Taps and typing go through AXe.
set -euo pipefail
UDID=${UDID:?the simulator}
OUT=${OUT:-shots}
BUNDLE=com.milescoviello.jellymc
mkdir -p "$OUT"

step() { printf '%s  %s\n' "$(date +%T)" "$*"; }
# On a foldable (HINGE set, by the workflow) a plain simctl screenshot fails: hinge takes the
# screen that shows the app.
shot() {
  if [ -n "${HINGE:-}" ]; then sleep 1; HINGE_DEVICE=$UDID "$HINGE" screenshot "$OUT/$1.png" >/dev/null 2>&1 && step "shot $1"
  else xcrun simctl io "$UDID" screenshot --type=png "$OUT/$1.png" >/dev/null 2>&1 && step "shot $1"; fi
}
ui() { axe describe-ui --udid "$UDID" > "$OUT/$1.json" 2>&1 || true; step "ui $1"; }
tap() { step "tap $1 $2"; axe tap -x "$1" -y "$2" --udid "$UDID"; }
# By accessibility label; a miss is logged and the script goes on, so the shots say what happened.
tapl() { step "tap '$1'"; axe tap --label "$1" --udid "$UDID" || step "  no '$1' on screen"; }
typ() { step "type '$1'"; axe type "$1" --udid "$UDID"; }
ret() { axe key 40 --udid "$UDID"; }
swipe() { step "swipe $*"; axe swipe --start-x "$1" --start-y "$2" --end-x "$3" --end-y "$4" --duration "${5:-0.5}" --udid "$UDID"; }
pause() { sleep "$1"; }
launch() { step launch; xcrun simctl launch "$UDID" "$BUNDLE" >/dev/null; }
relaunch() { xcrun simctl terminate "$UDID" "$BUNDLE" >/dev/null 2>&1 || true; launch; }
rotate() { step "rotate $1"; axe button "$1" --udid "$UDID" 2>/dev/null || true; }
# The sign-in form starts in the address field; Return moves to the next.
signin() {
    pause 3
    typ "127.0.0.1:8096"; ret
    typ jellymc; ret
    typ jellymc; ret
    pause 5
}

script=${1:-tour}
# shellcheck source=/dev/null
. "tools/sim/scripts/$script.sh"
