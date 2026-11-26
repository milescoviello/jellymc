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
# The scripts are written for an iPhone held upright. An unfolded iPhone Duo is wider and
# shorter (about 951 x 669 points), so there a point past its edge is moved onto it.
SW=0; SH=0
if [ -n "${HINGE:-}" ]; then
  read -r SW SH < <(axe describe-ui --udid "$UDID" 2>/dev/null | python3 -c 'import json,sys
d=json.load(sys.stdin); n=d[0] if isinstance(d,list) else d; f=n.get("frame") or {}
print(int(f.get("width",0)), int(f.get("height",0)))' || echo "0 0")
fi
cx() { [ "$SW" -gt 0 ] && [ "$1" -ge "$SW" ] && echo $((SW - 2)) || echo "$1"; }
cy() { [ "$SH" -gt 0 ] && [ "$1" -ge "$SH" ] && echo $((SH - 2)) || echo "$1"; }
tap() { step "tap $1 $2"; axe tap -x "$(cx "$1")" -y "$(cy "$2")" --udid "$UDID"; }
# By accessibility label; a miss is logged and the script goes on, so the shots say what happened.
tapl() { step "tap '$1'"; axe tap --label "$1" --udid "$UDID" || step "  no '$1' on screen"; }
typ() { step "type '$1'"; axe type "$1" --udid "$UDID"; }
ret() { axe key 40 --udid "$UDID"; }
swipe() { step "swipe $*"; axe swipe --start-x "$(cx "$1")" --start-y "$(cy "$2")" --end-x "$(cx "$3")" --end-y "$(cy "$4")" --duration "${5:-0.5}" --udid "$UDID"; }
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
