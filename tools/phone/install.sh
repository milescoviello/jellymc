#!/bin/sh
# Installs the phone watcher (tools/phone/jellymc-phone-refresh) for this user and starts
# it: plugging the iPhone in installs the newest build, signed for another seven days.
#
#   tools/phone/install.sh               install, start at login (KDE autostart), start now
#   tools/phone/install.sh --uninstall   stop it and remove both
set -eu
BIN=$HOME/.local/bin/jellymc-phone-refresh
AUTOSTART=$HOME/.config/autostart/jellymc-phone-refresh.desktop

stop() {
    pid=$(pgrep -f "python3 $BIN" || true)
    [ -n "$pid" ] && kill $pid || true
}

if [ "${1:-}" = "--uninstall" ]; then
    stop
    rm -f "$BIN" "$AUTOSTART"
    echo "Removed. Its log stays in ~/.local/state/jellymc-phone-refresh."
    exit 0
fi

for tool in gh xtool idevice_id notify-send; do
    command -v "$tool" >/dev/null || { echo "$tool is needed" >&2; exit 1; }
done
install -Dm755 "$(dirname "$0")/jellymc-phone-refresh" "$BIN"
mkdir -p "$(dirname "$AUTOSTART")"
cat > "$AUTOSTART" <<ENTRY
[Desktop Entry]
Type=Application
Name=jellymc phone refresh
Comment=Installs and re-signs jellymc on the iPhone whenever it is plugged in
Exec=$BIN
Terminal=false
X-KDE-autostart-phase=2
NoDisplay=true
ENTRY
stop
setsid "$BIN" > /dev/null 2>&1 < /dev/null &
echo "Watching for the iPhone. Log: ~/.local/state/jellymc-phone-refresh/log.txt"
