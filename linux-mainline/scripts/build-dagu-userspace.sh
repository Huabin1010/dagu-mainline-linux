#!/usr/bin/env bash
# Cross-compile C daemons. Camera loopback needs libcamera — built in rootfs chroot.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/env.sh
source "$ROOT/scripts/env.sh"
CC="${CC:-${CROSS_COMPILE}gcc}"
make -C "$ROOT/userspace" CC="$CC" PREFIX="${PREFIX:-/usr/local}" "$@"
