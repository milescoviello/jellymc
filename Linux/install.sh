#!/bin/sh
# Builds jellymc for Linux and installs it for this user: the `jellymc` command, its
# launcher entry and its icon. PREFIX moves it (default ~/.local).
#
#   Linux/install.sh               build in release and install
#   Linux/install.sh --update      pull the latest, rebuild, reinstall, restart the app
#   Linux/install.sh --uninstall   remove what it installed (settings and downloads stay)
#
# SWIFT_BUILD_FLAGS is passed to `swift build`, for toolchains that need a linker flag
# (this repo's tools/swiftw explains the one a Gentoo box needs). Installing also adds
# `jellymc-update`, which runs --update with the same settings.
#
# Nothing here touches what the app keeps: settings, the sign-in, downloads and the
# outbox under ~/.local/share/jellymc, and the image cache under ~/.cache/jellymc.
set -eu

ID=com.milescoviello.jellymc
PREFIX=${PREFIX:-$HOME/.local}
ROOT=$(cd "$(dirname "$0")/.." && pwd)
SIZES="64 128 256 512"
CONFIG="$PREFIX/share/$ID/install.conf"

uninstall() {
    rm -f "$PREFIX/bin/jellymc" "$PREFIX/bin/jellymc-update" "$PREFIX/share/applications/$ID.desktop" "$CONFIG"
    for size in $SIZES; do rm -f "$PREFIX/share/icons/hicolor/${size}x$size/apps/$ID.png"; done
    refresh
    echo "Removed. Settings, the sign-in and downloads are still in ~/.local/share/jellymc."
}

refresh() {
    command -v update-desktop-database >/dev/null && update-desktop-database -q "$PREFIX/share/applications" 2>/dev/null || true
    # A changed folder is what tells a running desktop to look again. No icon cache is
    # written: one in ~/.local would hide icons that other apps add there later.
    touch "$PREFIX/share/icons/hicolor" 2>/dev/null || true
}

update=""
case "${1:-}" in
    --uninstall) uninstall; exit 0 ;;
    --update) update=1 ;;
    "") ;;
    *) sed -n '2,14s/^# \{0,1\}//p' "$0"; exit 0 ;;
esac

# What the build links against, by pkg-config name, with the packages that provide it.
missing=""
for module in gtk4 libadwaita-1 libsecret-1 mpv epoxy egl libsoup-3.0; do
    pkg-config --exists "$module" 2>/dev/null || missing="$missing $module"
done
if ! command -v swift >/dev/null; then
    echo "Swift 6 is needed: https://www.swift.org/install/linux/ (or Fedora's swift-lang)." >&2
    exit 1
fi
if [ -n "$missing" ]; then
    cat >&2 <<EOF
Missing development files for:$missing

  Fedora:         sudo dnf install gtk4-devel libadwaita-devel libsecret-devel mpv-devel libepoxy-devel mesa-libEGL-devel libsoup3-devel
  Debian, Ubuntu: sudo apt install libgtk-4-dev libadwaita-1-dev libsecret-1-dev libmpv-dev libepoxy-dev libegl-dev libsoup-3.0-dev
  Arch:           sudo pacman -S gtk4 libadwaita libsecret mpv libepoxy libsoup3
  Gentoo:         emerge gui-libs/gtk gui-libs/libadwaita app-crypt/libsecret media-video/mpv[libmpv] media-libs/libepoxy net-libs/libsoup:3.0
EOF
    exit 1
fi

cd "$ROOT"
if [ -n "$update" ]; then
    # Only a fast-forward: a checkout with work of its own in it is left alone, and the
    # build below uses what is there.
    if git rev-parse --abbrev-ref '@{upstream}' >/dev/null 2>&1; then
        git pull --ff-only || echo "Could not fast-forward; building what is checked out." >&2
    else
        echo "No upstream branch to pull from; building what is checked out." >&2
    fi
    prefs="$HOME/.local/share/jellymc/preferences.json"
    if [ -f "$prefs" ]; then cp -p "$prefs" "$prefs.bak"; fi
fi

# Swift.org toolchains can link the Swift runtime in, so the binary keeps working after
# a toolchain update; distribution packages ship it shared only.
static=""
toolchain=$(dirname "$(readlink -f "$(command -v swift)")")/..
if [ -e "$toolchain/lib/swift_static/linux/libswiftCore.a" ]; then
    static="--static-swift-stdlib"
fi

# The static runtime also wants the C++ library's development files; without them the
# link fails, and the shared runtime is what there is.
# shellcheck disable=SC2086
if [ -n "$static" ] && ! swift build -c release --product jellymc $static ${SWIFT_BUILD_FLAGS:-}; then
    echo "Linking the Swift runtime in failed (libstdc++'s development files?); linking it shared." >&2
    static=""
fi
if [ -z "$static" ]; then
    # shellcheck disable=SC2086
    swift build -c release --product jellymc ${SWIFT_BUILD_FLAGS:-}
fi
# shellcheck disable=SC2086
binary=$(swift build -c release --product jellymc $static ${SWIFT_BUILD_FLAGS:-} --show-bin-path)/jellymc

# A running copy is asked to quit first: it tells the server where playback stopped.
running=""
if pgrep -x jellymc >/dev/null 2>&1; then
    running=1
    pkill -TERM -x jellymc || true
    for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
        pgrep -x jellymc >/dev/null 2>&1 || break
        sleep 0.5
    done
fi

# Written beside, then moved into place, so nothing ever sees half a binary.
install -Dm755 "$binary" "$PREFIX/bin/jellymc.new"
mv -f "$PREFIX/bin/jellymc.new" "$PREFIX/bin/jellymc"
# The launcher entry names the binary by path: ~/.local/bin is not on every session's
# PATH. A machine whose toolchain needs a library path gets it in the entry too.
mkdir -p "$PREFIX/share/applications"
exec_line="$PREFIX/bin/jellymc"
if [ -n "${LD_LIBRARY_PATH:-}" ]; then exec_line="env LD_LIBRARY_PATH=$LD_LIBRARY_PATH $exec_line"; fi
sed "s|^Exec=jellymc$|Exec=$exec_line|" "Linux/Resources/$ID.desktop" > "$PREFIX/share/applications/$ID.desktop"
for size in $SIZES; do
    install -Dm644 "Linux/Resources/icons/hicolor/${size}x$size/apps/$ID.png" "$PREFIX/share/icons/hicolor/${size}x$size/apps/$ID.png"
done
refresh

# `jellymc-update` remembers where the source is and how this machine builds it.
mkdir -p "$(dirname "$CONFIG")"
{
    printf "ROOT='%s'\n" "$ROOT"
    printf "SWIFT_BUILD_FLAGS='%s'\n" "${SWIFT_BUILD_FLAGS:-}"
    printf "LD_LIBRARY_PATH='%s'\n" "${LD_LIBRARY_PATH:-}"
} > "$CONFIG"
cat > "$PREFIX/bin/jellymc-update" <<EOF
#!/bin/sh
# Pulls the latest jellymc, rebuilds and reinstalls it, and restarts it if it was open.
set -a
. "$CONFIG"
set +a
exec "\$ROOT/Linux/install.sh" --update
EOF
chmod 755 "$PREFIX/bin/jellymc-update"

if [ -n "$running" ]; then
    setsid sh -c "$exec_line" >/dev/null 2>&1 < /dev/null &
    echo "Updated and restarted $PREFIX/bin/jellymc."
else
    echo "Installed $PREFIX/bin/jellymc. Start it from the app launcher (jellymc), or run: $PREFIX/bin/jellymc"
fi
echo "To update later: jellymc-update"
