#!/usr/bin/env bash
# Turns a fresh distro-matrix Kubuntu 26.04 desktop into a jellymc test machine: the Swift
# toolchain, the GTK/libadwaita/libmpv/libsecret headers, Docker for the test server.
# Runs on the VM, as tester (sudo is passwordless there). Idempotent.
#
#   (from the laptop) tools/vm/push && tools/vm/run provision
set -euo pipefail

SWIFT_VERSION=6.3.1
SWIFT_DIR="$HOME/swift"

sudo DEBIAN_FRONTEND=noninteractive apt-get update -qq
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
    binutils git gnupg2 libc6-dev libcurl4-openssl-dev libedit2 libpython3-dev libsqlite3-0 \
    libstdc++-14-dev libxml2-dev libncurses-dev libz3-dev pkg-config tzdata unzip zlib1g-dev \
    libgtk-4-dev libadwaita-1-dev libmpv-dev libsecret-1-dev libegl-dev \
    docker.io ffmpeg jq curl rsync mpv >/dev/null
sudo usermod -aG docker "$USER"

if [ ! -x "$SWIFT_DIR/usr/bin/swift" ]; then
    name="swift-$SWIFT_VERSION-RELEASE-ubuntu24.04"
    curl -fsSL "https://download.swift.org/swift-$SWIFT_VERSION-release/ubuntu2404/swift-$SWIFT_VERSION-RELEASE/$name.tar.gz" -o /tmp/swift.tar.gz
    mkdir -p "$SWIFT_DIR"
    tar -xzf /tmp/swift.tar.gz -C "$SWIFT_DIR" --strip-components=1
    rm /tmp/swift.tar.gz
fi

# The 24.04 toolchain links libxml2.so.2; 26.04 may ship only the newer soname.
if ! { ldconfig -p || true; } | grep -q "libxml2.so.2 "; then
    mkdir -p "$HOME/.local/lib/swift-compat"
    target=$({ ldconfig -p || true; } | awk '/libxml2.so.[0-9]+ / {print $NF}' | head -n1 || true)
    ln -sfn "$target" "$HOME/.local/lib/swift-compat/libxml2.so.2"
fi

"$SWIFT_DIR/usr/bin/swift" --version
echo "provisioned"
