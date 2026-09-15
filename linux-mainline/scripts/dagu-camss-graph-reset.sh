#!/bin/sh
# Disable leftover mutable CAMSS links on /dev/media0.
#
# libcamera simple programs CSIPHY→CSID with MEDIA_IOC_SETUP_LINK.
# The kernel does not clear those links on fd close. SIGKILL of cam,
# a WirePlumber-only restart, or a crashed STREAMON leaves
# csiphyN→csid0 enabled. The next CameraManager then fails with
# EBUSY ("Failed to setup link msm_csiphy1 -> msm_csid0") and
# Snapshot / GNOME Camera show No Camera Found.
set -eu
MC="${DAGU_CAMSS_MEDIA:-/dev/media0}"
[ -e "$MC" ] || exit 0
command -v media-ctl >/dev/null || exit 0
media-ctl -d "$MC" -r >/dev/null 2>&1 || true
exit 0
