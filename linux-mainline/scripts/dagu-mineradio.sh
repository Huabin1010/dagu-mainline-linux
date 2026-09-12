#!/bin/sh
# dagu Mineradio: native Wayland + GLES. GPU raster stays on.
# Ozone tags linux-dmabuf LINEAR; force GBM pixels LINEAR (dagu-linear-mod.c)
# and load dagu-mesa (LINEAR GMEM destile per tile; tiled WebGL stays GMEM).
# Never into gnome-shell.
export ELECTRON_OZONE_PLATFORM_HINT=wayland
if [ -f /usr/local/lib/dagu-mesa/libgallium-26.0.8-1ubuntu0.3.so ]; then
	export LD_LIBRARY_PATH="/usr/local/lib/dagu-mesa${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
fi
if [ -f /usr/local/lib/libdagu-linear-mod.so ]; then
	export LD_PRELOAD="/usr/local/lib/libdagu-linear-mod.so${LD_PRELOAD:+:$LD_PRELOAD}"
fi
exec /opt/Mineradio/mineradio \
	--ozone-platform=wayland \
	--ozone-platform-hint=wayland \
	--in-process-gpu \
	--use-gl=angle \
	--use-angle=gles \
	--disable-features=Vulkan,DefaultANGLEVulkan,VulkanFromANGLE,WaylandOverlayDelegation \
	--no-sandbox \
	"$@"
