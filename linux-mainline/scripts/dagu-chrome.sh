#!/bin/sh
# dagu Chrome: native Wayland + GLES. GPU raster stays on.
# Ozone tags linux-dmabuf LINEAR; force GBM pixels LINEAR (dagu-linear-mod.c)
# and load dagu-mesa (unused-depth color sysmem; 3D with depth stays GMEM).
# Never into gnome-shell.
export FONTCONFIG_PATH="${FONTCONFIG_PATH:-/etc/fonts}"
if [ -f /usr/local/lib/dagu-mesa/libgallium-26.0.8-1ubuntu0.3.so ]; then
	export LD_LIBRARY_PATH="/usr/local/lib/dagu-mesa${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
fi
if [ -f /usr/local/lib/libdagu-linear-mod.so ]; then
	export LD_PRELOAD="/usr/local/lib/libdagu-linear-mod.so${LD_PRELOAD:+:$LD_PRELOAD}"
fi
exec /opt/google/chrome/chrome \
	--ozone-platform=wayland \
	--ozone-platform-hint=wayland \
	--in-process-gpu \
	--use-gl=angle \
	--use-angle=gles \
	--start-maximized \
	--enable-wayland-ime \
	--disable-gtk-ime \
	--wayland-text-input-version=3 \
	--enable-features=WaylandTextInputV3 \
	--disable-features=Vulkan,DefaultANGLEVulkan,VulkanFromANGLE,WaylandOverlayDelegation \
	"$@"
