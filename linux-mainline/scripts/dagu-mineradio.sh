#!/bin/sh
# dagu Mineradio: Electron / Ozone Wayland + ANGLE GLES.
# Same contract as dagu-chrome.sh: LINEAR GBM (dagu-linear-mod.c),
# dagu-mesa for Chrome-like LINEAR color, never into gnome-shell.
#
# Render path inside the app (see /opt/Mineradio/resources/app):
#   THREE.WebGLRenderer (r128, antialias:false, alpha:true) + ShaderMaterial
#   particles / lyric bloom, then CSS backdrop-filter glass, then DOM lyrics.
#   BrowserWindow is transparent. Same 270° LCD + fractional-DPR rules.
export ELECTRON_OZONE_PLATFORM_HINT=wayland
export FONTCONFIG_PATH="${FONTCONFIG_PATH:-/etc/fonts}"
export FREETYPE_PROPERTIES="${FREETYPE_PROPERTIES:-truetype:interpreter-version=40}"
if [ -f /usr/local/lib/dagu-mesa/libgallium-26.0.8-1ubuntu0.3.so ]; then
	export LD_LIBRARY_PATH="/usr/local/lib/dagu-mesa${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
fi
if [ -f /usr/local/lib/libdagu-linear-mod.so ]; then
	export LD_PRELOAD="/usr/local/lib/libdagu-linear-mod.so${LD_PRELOAD:+:$LD_PRELOAD}"
fi
# LINEAR store and LINEAR+FB_READ can GMEM (UCHE base=cbuf offset).
# Never FD_MESA_DEBUG=notile (CCU hang). Never into gnome-shell.
exec /opt/Mineradio/mineradio \
	--ozone-platform=wayland \
	--ozone-platform-hint=wayland \
	--in-process-gpu \
	--use-gl=angle \
	--use-angle=gles \
	--start-maximized \
	--enable-features=WaylandFractionalScaleV1,WaylandLinuxDrmSyncobj \
	--disable-lcd-text \
	--font-render-hinting=none \
	--disable-partial-swap \
	--disable-features=Vulkan,DefaultANGLEVulkan,VulkanFromANGLE,WaylandOverlayDelegation,PartialSwap \
	--no-sandbox \
	"$@"
