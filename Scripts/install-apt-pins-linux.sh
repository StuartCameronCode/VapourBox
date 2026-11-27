#!/bin/bash
# Install the apt packages the Linux deps build bundles or compiles against,
# at the versions in Scripts/pins/apt-linux.txt (task #114). Ubuntu 24.04
# (noble) only; needs sudo. build-deps-linux.yml runs it; run it yourself
# before ./Scripts/download-deps-linux.sh, which refuses other versions.
#
# The versions come from Ubuntu's snapshot of the archive at the file's
# `snapshot` time (https://snapshot.ubuntu.com), so one that noble-updates has
# since replaced still installs. The snapshot is added as one more source, and
# each listed package is pinned to its version (priority 1001), so apt takes
# that version, its exact-version dependencies included, and nothing else
# changes. If the snapshot cannot be reached, the install fails as soon as a
# pinned version is no longer in the live archive; it never falls back to
# another version, and download-deps-linux.sh checks every one.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PINS="$SCRIPT_DIR/pins/apt-linux.txt"

SNAPSHOT=$(awk '$1 == "snapshot" {print $2}' "$PINS")
if ! [[ "$SNAPSHOT" =~ ^[0-9]{8}T[0-9]{6}Z$ ]]; then
    echo "ERROR: $PINS has no 'snapshot YYYYMMDDTHHMMSSZ' line" >&2
    exit 1
fi
if [ "$(. /etc/os-release && echo "${VERSION_CODENAME:-}")" != "noble" ]; then
    echo "ERROR: the pinned packages are Ubuntu 24.04 (noble)'s; this is $(. /etc/os-release && echo "$PRETTY_NAME")" >&2
    exit 1
fi

# <package> <version> <role> lines.
mapfile -t PINNED < <(awk '!/^#/ && NF == 3 {print $1, $2, $3}' "$PINS")

sudo tee /etc/apt/sources.list.d/vapourbox-snapshot.sources >/dev/null <<EOF
# Added by Scripts/install-apt-pins-linux.sh (VapourBox deps, task #114).
Types: deb
URIs: https://snapshot.ubuntu.com/ubuntu/$SNAPSHOT/
Suites: noble noble-updates noble-security
Components: main universe
Architectures: $(dpkg --print-architecture)
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg
Targets: Packages
EOF

{
    echo "# Added by Scripts/install-apt-pins-linux.sh (VapourBox deps, task #114)."
    for line in "${PINNED[@]}"; do
        read -r pkg version _ <<<"$line"
        printf 'Package: %s\nPin: version %s\nPin-Priority: 1001\n\n' "$pkg" "$version"
    done
} | sudo tee /etc/apt/preferences.d/vapourbox-deps-pins >/dev/null

# Only the Packages indexes from the snapshot: apt needs nothing else to
# install by version, and the runner's apt fails the whole update on any index
# it cannot fetch (a 503 on the snapshot's command-not-found metadata failed
# the first arm64 build). Retries cover the snapshot's transient 503s.
sudo apt-get update -o Acquire::Retries=5
WANT=()
for line in "${PINNED[@]}"; do
    read -r pkg version role <<<"$line"
    [ "$role" = dep ] || WANT+=("$pkg=$version")
done
sudo apt-get install -y "${WANT[@]}"

# Every listed package that is installed must be at its pin.
bad=0
for line in "${PINNED[@]}"; do
    read -r pkg version role <<<"$line"
    got=$(dpkg-query -W -f='${db:Status-Abbrev} ${Version}' "$pkg" 2>/dev/null || true)
    case "$got" in
        "ii  $version") ;;
        "ii "*) echo "ERROR: $pkg is ${got#ii  }, pinned $version" >&2; bad=1 ;;
        *) [ "$role" = dep ] || { echo "ERROR: $pkg is not installed" >&2; bad=1; } ;;
    esac
done
[ "$bad" = 0 ] || exit 1
echo "Installed the pinned packages from snapshot $SNAPSHOT"
