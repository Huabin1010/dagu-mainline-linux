#!/bin/sh
# dagu Chrome: GPU compositing so the window maps; software raster to
# limit Freedreno tile/UBWC snow. Wayland text-input-v3 (not GTK IM)
# notifies mutter so GNOME OSK / ibus appear on omnibox focus.
export TU_DEBUG=noubwc,sysmem
export FD_MESA_DEBUG=noubwc,sysmem
export MESA_VK_WSI_DEBUG=linear
export MESA_EXTENSION_OVERRIDE="-EGL_KHR_swap_buffers_with_damage;-EGL_EXT_swap_buffers_with_damage;-EGL_KHR_partial_update;-EGL_EXT_image_dma_buf_import_modifiers"
export FONTCONFIG_PATH="${FONTCONFIG_PATH:-/etc/fonts}"
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
	--disable-gpu-rasterization \
	--disable-accelerated-2d-canvas \
	--disable-partial-swap \
	--disable-lcd-text \
	--disable-font-subpixel-positioning \
	--disable-gpu-memory-buffer-compositor-resources \
	--disable-zero-copy \
	--enable-features=WaylandTextInputV3 \
	--disable-features=Vulkan,DefaultANGLEVulkan,VulkanFromANGLE,SkiaGraphite,CanvasOopRasterization,WaylandOverlayDelegation,VaapiVideoDecoder,AcceleratedVideoDecodeLinuxGL,UseMultiPlaneFormatForHardwareVideo \
	"$@"
