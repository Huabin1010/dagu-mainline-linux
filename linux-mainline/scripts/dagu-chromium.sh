#!/bin/sh
# Daily Chromium: native UBWC, no libdagu-linear-mod.so.
# Full tear (stock Mesa + Turnip + overlay flags): DAGU_TEAR_CONTRACT=1
# or /usr/local/bin/dagu-chromium-native with those env vars.
# Official google-chrome is VA-API-only. Venus is this binary.
if [ -x /usr/local/bin/dagu-chromium-native ]; then
	exec /usr/local/bin/dagu-chromium-native "$@"
fi
# Fallback if native wrapper is missing: still never preload linear-mod.
exec /usr/lib/chromium/chromium \
	--ozone-platform=wayland \
	--ozone-platform-hint=wayland \
	--use-gl=angle \
	--use-angle=gles \
	--ignore-gpu-blocklist \
	"$@"
