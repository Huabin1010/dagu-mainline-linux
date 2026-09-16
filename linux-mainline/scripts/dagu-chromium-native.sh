#!/bin/sh
# Tear-contract Chromium: no libdagu-linear-mod.so. GBM keeps TILE/UBWC.
# Venus flags stay on. Do not put this into gnome-shell.
#
# DAGU_STOCK_MESA=1   skip dagu-mesa (distro Freedreno / Turnip)
# DAGU_CHROME_VULKAN=1 ANGLE --use-angle=vulkan
# DAGU_CHROME_OVERLAY=1 WaylandOverlayDelegation + HardwareOverlays
# DAGU_TEAR_CONTRACT=1 stock Mesa + Vulkan + overlay
# DAGU_GBM_TRACE=1     log-only libdagu-gbm-trace.so
# DAGU_CHROME_WAYLAND_BFS=1  enable WaylandExternalBeginFrameSource
#   (default OFF in 152; couples Chrome to Mutter frame callbacks —
#   likely worse for WaitForSwap vs idle clock. A/B only.)
# DAGU_CHROME_NO_SYNCOBJ=1  drop WaylandLinuxDrmSyncobj (A/B only).
#   Mutter 50.1 handle_release_points bails when
#   cogl_context_get_latest_sync_fd() is -1 (skipped paint / idle),
#   so the timeline never signals and Chrome WaitForSwap sits 80–180 ms.
#   Daily keeps syncobj; libdagu-cogl-syncfd.so did not remove the 4 holes.
# DAGU_CHROME_NO_CHECKERBOARD_WAIT=1  disable NewContentForCheckerboardedScrolls
#   (A/B only). 090601 still had 6 slow holes (language bar also up).
# DAGU_CHROME_PANEL_ROTATE=270  GPU-rotate the aura tree into the physical
#   1600x2560 wl_buffer (Linux GLES ignores SetDisplayTransformHint).
#   Mutter MUST be transform 0 (set-normal-temp) or the UI double-rotates.
#   Daily stays transform 3 without this env. Use
#   linux-mainline/scripts/dagu-lab-identity-120.sh for the 120fps lab.
# There is no --max-pending-swaps switch. Do not add
# --double-buffer-compositing (shrinks the queue to 1).
profile="${HOME}/.config/chromium"
lock="$profile/SingletonLock"
if [ -L "$lock" ]; then
	hostpid=$(readlink "$lock")
	pid=${hostpid##*-}
	if [ -n "$pid" ] && ! kill -0 "$pid" 2>/dev/null; then
		rm -f "$profile/SingletonLock" "$profile/SingletonSocket" "$profile/SingletonCookie"
	fi
fi
export FONTCONFIG_PATH="${FONTCONFIG_PATH:-/etc/fonts}"
export FREETYPE_PROPERTIES="${FREETYPE_PROPERTIES:-truetype:interpreter-version=40}"

STOCK="${DAGU_STOCK_MESA:-0}"
VULKAN="${DAGU_CHROME_VULKAN:-0}"
OVERLAY="${DAGU_CHROME_OVERLAY:-0}"
if [ "${DAGU_TEAR_CONTRACT:-0}" = "1" ]; then
	STOCK=1
	VULKAN=1
	OVERLAY=1
fi

# Never load libdagu-linear-mod.so. Identity getenv hook is Chrome-only.
unset LD_PRELOAD
if [ -f /run/user/1001/dagu-identity ] &&
   [ -f /usr/local/lib/libdagu-chrome-getenv.so ]; then
	export LD_PRELOAD=/usr/local/lib/libdagu-chrome-getenv.so
	export DAGU_CHROME_PANEL_ROTATE="${DAGU_CHROME_PANEL_ROTATE:-270}"
fi
if [ "$STOCK" != "1" ] && [ -f /usr/local/lib/dagu-mesa/libgallium-26.0.8-1ubuntu0.3.so ]; then
	export LD_LIBRARY_PATH="/usr/local/lib/dagu-mesa${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
else
	export LD_LIBRARY_PATH="${LD_LIBRARY_PATH:-}"
	# Drop dagu-mesa if a parent exported it.
	LD_LIBRARY_PATH=$(printf '%s' "$LD_LIBRARY_PATH" | sed 's|/usr/local/lib/dagu-mesa:||;s|:/usr/local/lib/dagu-mesa||;s|^/usr/local/lib/dagu-mesa$||')
	export LD_LIBRARY_PATH
fi
if [ "${DAGU_GBM_TRACE:-0}" = "1" ] && [ -f /usr/local/lib/libdagu-gbm-trace.so ]; then
	export LD_PRELOAD=/usr/local/lib/libdagu-gbm-trace.so
fi

# Debian /usr/bin/chromium is a wrapper that drops unknown env
# (DAGU_CHROME_PANEL_ROTATE never reaches official-152). Always exec
# the binary we deploy.
CHROME_BIN=/usr/lib/chromium/chromium
[ -x "$CHROME_BIN" ] || CHROME_BIN=/usr/bin/chromium
# GNOME 50 matches Wayland app_id org.chromium.Chromium to this .desktop.
export CHROME_DESKTOP="${CHROME_DESKTOP:-org.chromium.Chromium.desktop}"
if [ -f /run/user/1001/dagu-identity ]; then
	export DAGU_CHROME_PANEL_ROTATE="${DAGU_CHROME_PANEL_ROTATE:-270}"
fi
ENABLE_FEAT="WaylandTextInputV3,WaylandFractionalScaleV1,WaylandLinuxDrmSyncobj,AcceleratedVideoDecoder,AcceleratedVideoDecodeLinuxGL,AcceleratedVideoDecodeLinuxZeroCopyGL,AcceleratedVideoEncoder,AcceleratedVideoEncodeLinux,MediaRecorderHEVCSupport"
DISABLE_FEAT="Vulkan,DefaultANGLEVulkan,VulkanFromANGLE,WaylandOverlayDelegation,Translate,TranslateUI"
ANGLE="gles"
if [ "$OVERLAY" = "1" ]; then
	ENABLE_FEAT="${ENABLE_FEAT},WaylandOverlayDelegation,HardwareOverlays"
	DISABLE_FEAT="Vulkan,DefaultANGLEVulkan,VulkanFromANGLE"
fi
if [ "$VULKAN" = "1" ]; then
	ENABLE_FEAT="${ENABLE_FEAT},Vulkan,DefaultANGLEVulkan,VulkanFromANGLE"
	if [ "$OVERLAY" = "1" ]; then
		DISABLE_FEAT=""
	else
		DISABLE_FEAT="WaylandOverlayDelegation"
	fi
	ANGLE="vulkan"
	set -- --enable-gpu-rasterization --enable-zero-copy "$@"
fi
if [ "${DAGU_CHROME_WAYLAND_BFS:-0}" = "1" ]; then
	ENABLE_FEAT="${ENABLE_FEAT},WaylandExternalBeginFrameSource"
fi
if [ "${DAGU_CHROME_NO_SYNCOBJ:-0}" = "1" ]; then
	ENABLE_FEAT=$(printf '%s' "$ENABLE_FEAT" | sed 's/WaylandLinuxDrmSyncobj,//;s/,WaylandLinuxDrmSyncobj//;s/^WaylandLinuxDrmSyncobj$//')
	DISABLE_FEAT="${DISABLE_FEAT},WaylandLinuxDrmSyncobj"
fi
if [ "${DAGU_CHROME_NO_CHECKERBOARD_WAIT:-0}" = "1" ]; then
	DISABLE_FEAT="${DISABLE_FEAT},NewContentForCheckerboardedScrolls"
fi
set -- --enable-features="$ENABLE_FEAT" "$@"
if [ -n "$DISABLE_FEAT" ]; then
	set -- --disable-features="$DISABLE_FEAT" "$@"
fi
# GNOME Wayland: mutter text-input-v3 → IBus (fcitx5). GTK_IM_MODULE=fcitx
# plus --disable-gtk-ime leaves Chromium with no IME.
unset GTK_IM_MODULE
exec "$CHROME_BIN" \
	--ozone-platform=wayland \
	--ozone-platform-hint=wayland \
	--use-gl=angle \
	--use-angle="$ANGLE" \
	--start-maximized \
	--enable-wayland-ime \
	--disable-gtk-ime \
	--wayland-text-input-version=3 \
	--disable-lcd-text \
	--font-render-hinting=none \
	--ignore-gpu-blocklist \
	--hide-crash-restore-bubble \
	"$@"
