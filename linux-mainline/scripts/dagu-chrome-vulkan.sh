#!/bin/sh
# Turnip ANGLE + native UBWC. Ozone logs a Wayland+Vulkan warning but
# still creates VulkanImplementationWayland; WebGL is Turnip.
export DAGU_TEAR_CONTRACT=1
if [ -x /usr/local/bin/dagu-chromium-native ]; then
	exec /usr/local/bin/dagu-chromium-native "$@"
fi
exec /usr/local/bin/dagu-chrome "$@"
