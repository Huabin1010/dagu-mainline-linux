#!/bin/sh
# Run a command in the Mu build container with the repo at /build.
#   ./mu-run.sh python3 build_uefi.py -d xiaomi-dagu -t DEBUG
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="${MU_REPO:-$HERE/mu_aloha_platforms}"
exec docker run --rm --network host \
	-u "$(id -u):$(id -g)" -e HOME=/tmp/home \
	-e CLANGPDB_BIN=/usr/bin/ -e CLANGPDB_AARCH64_PREFIX=aarch64-linux-gnu- \
	-e GCC5_AARCH64_PREFIX=aarch64-linux-gnu- \
	-v "$REPO:/build" -w /build mu-aloha:v1 \
	sh -c 'mkdir -p /tmp/home && git config --global --add safe.directory "*" && exec "$@"' sh "$@"
