#!/bin/sh
# dagu Chrome: native Wayland + GLES (Ozone cannot map Vulkan).
# Buffer layout: noubwc is not enough — a6xx TILE still snows when
# mutter imports the dmabuf as LINEAR (modifier 0, pitch=width*4).
export FONTCONFIG_PATH="${FONTCONFIG_PATH:-/etc/fonts}"
export TU_DEBUG="${TU_DEBUG:-noubwc}"
export FD_MESA_DEBUG="${FD_MESA_DEBUG:-noubwc,notile}"
export MESA_VK_WSI_DEBUG="${MESA_VK_WSI_DEBUG:-linear}"
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
	--disable-features=Vulkan,DefaultANGLEVulkan,VulkanFromANGLE \
	"$@"
