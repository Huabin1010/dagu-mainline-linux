#!/bin/sh
# dagu Chrome: native Wayland + GLES. GPU raster stays on (SVG/tiles).
# Ozone tags linux-dmabuf LINEAR; force GBM pixels LINEAR (dagu-linear-mod.c)
# and load dagu-mesa (LINEAR GMEM destile per tile; tiled WebGL stays GMEM).
# Never into gnome-shell.
# PartialSwap stays ON. LINEAR destile is fixed, so damage rects can
# go out. GPU process is out-of-process (do not pass --in-process-gpu):
# the GPU thread no longer shares the browser process with input.
# Do not toggle GPU vs CPU raster to hide hitch or flower.
# Official google-chrome has no USE_V4L2_CODEC. HTML5 Venus is
# linux-mainline/scripts/dagu-chromium.sh (xtradeb/Debian arm64).
#
# Fonts at any Mutter scale (1.0 / 1.25 / 1.33 / 1.67 / 2.0):
#  - Enable WaylandFractionalScaleV1 so Skia rasters at the real DPR.
#    Integer-only raster + mutter up/downscale is what made 1.25 look
#    like garbled blur.
#  - --disable-lcd-text: this panel is scanned 1600x2560 and rotated
#    270°. LCD RGB is on the physical short axis; the logical desktop
#    is landscape, so subpixel AA becomes color-fringed "乱码" at every
#    scale (see the Restore-pages photo). Grayscale AA only.
profile="${HOME}/.config/google-chrome"
lock="$profile/SingletonLock"
if [ -L "$lock" ]; then
	hostpid=$(readlink "$lock")
	pid=${hostpid##*-}
	if [ -n "$pid" ] && ! kill -0 "$pid" 2>/dev/null; then
		rm -f "$profile/SingletonLock" "$profile/SingletonSocket" "$profile/SingletonCookie"
		rm -rf /tmp/com.google.Chrome.* /tmp/.com.google.Chrome.*
	fi
fi
export FONTCONFIG_PATH="${FONTCONFIG_PATH:-/etc/fonts}"
export FREETYPE_PROPERTIES="${FREETYPE_PROPERTIES:-truetype:interpreter-version=40}"
if [ -f /usr/local/lib/dagu-mesa/libgallium-26.0.8-1ubuntu0.3.so ]; then
	export LD_LIBRARY_PATH="/usr/local/lib/dagu-mesa${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
fi
# Flower contract torn: do not LD_PRELOAD libdagu-linear-mod.so.
# Official-152 reports the real GBM modifier; windows are QCOM_COMPRESSED.
# LINEAR store/restore and LINEAR+FD_GMEM_FB_READ can GMEM.
# a650 UCHE samples GMEM at cbuf offset 0 (not msm gmem_base).
# Do not export DAGU_LINEAR_SYSMEM=1 or DAGU_LINEAR_DESTILE=1.
# Never put this in gnome-shell (LINEAR+stencil sysmem blacked scanout).
# lcd-text-aa@2 = Disabled in chrome://flags, survives UI chrome paths
# that do not look at --disable-lcd-text.
if [ ! -e "$lock" ] && [ -f "$profile/Local State" ]; then
	python3 - "$profile/Local State" <<'PY' 2>/dev/null || true
import json, sys
p = sys.argv[1]
with open(p, "r", encoding="utf-8") as f:
    d = json.load(f)
labs = d.setdefault("browser", {}).setdefault("enabled_labs_experiments", [])
if not isinstance(labs, list):
    labs = []
    d["browser"]["enabled_labs_experiments"] = labs
changed = False
for drop in ("lcd-text-aa@1", "lcd-text-aa@0"):
    if drop in labs:
        labs.remove(drop)
        changed = True
if "lcd-text-aa@2" not in labs:
    labs.append("lcd-text-aa@2")
    changed = True
if changed:
    with open(p, "w", encoding="utf-8") as f:
        json.dump(d, f, separators=(",", ":"))
PY
fi
# AcceleratedVideoDecoder is kAcceleratedVideoDecodeLinux in 153
# media/mojo/services/gpu_mojo_media_client_linux.cc. Off → kUnknown → FFmpeg.
ENABLE_FEAT="WaylandTextInputV3,WaylandFractionalScaleV1,WaylandLinuxDrmSyncobj,AcceleratedVideoDecoder,AcceleratedVideoDecodeLinuxGL,AcceleratedVideoDecodeLinuxZeroCopyGL"
DISABLE_FEAT="Vulkan,DefaultANGLEVulkan,VulkanFromANGLE,WaylandOverlayDelegation"
ANGLE="gles"
# Video subsurface. Off by default: LINEAR chrome + DPU overlay flowers.
# Probe with DAGU_CHROME_VIDEO_OVERLAY=1; keep disable-direct-scanout.
if [ "${DAGU_CHROME_VIDEO_OVERLAY:-0}" = "1" ]; then
	ENABLE_FEAT="${ENABLE_FEAT},WaylandOverlayDelegation"
	DISABLE_FEAT="Vulkan,DefaultANGLEVulkan,VulkanFromANGLE"
fi
# Trial: ignore-gpu-blocklist + gpu-raster + zero-copy + Vulkan ANGLE.
# Ozone still warns Wayland+Vulkan; DefaultANGLEVulkan is a no-op if
# --use-angle=gles stays. DAGU_CHROME_VULKAN=1 switches ANGLE to vulkan.
if [ "${DAGU_CHROME_VULKAN:-0}" = "1" ]; then
	ENABLE_FEAT="${ENABLE_FEAT},Vulkan,DefaultANGLEVulkan,VulkanFromANGLE"
	DISABLE_FEAT="WaylandOverlayDelegation"
	ANGLE="vulkan"
	set -- --enable-gpu-rasterization --enable-zero-copy "$@"
fi
exec /opt/google/chrome/chrome \
	--ozone-platform=wayland \
	--ozone-platform-hint=wayland \
	--use-gl=angle \
	--use-angle="$ANGLE" \
	--start-maximized \
	--enable-wayland-ime \
	--disable-gtk-ime \
	--wayland-text-input-version=3 \
	--enable-features="$ENABLE_FEAT" \
	--disable-lcd-text \
	--font-render-hinting=none \
	--disable-features="$DISABLE_FEAT" \
	--ignore-gpu-blocklist \
	"$@"
