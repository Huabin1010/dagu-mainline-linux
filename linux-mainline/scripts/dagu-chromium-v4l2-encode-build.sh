#!/bin/sh
# Cross-build Debian Chromium 152 for arm64 with Linux V4L2 encode
# (Venus /dev/video15) and HEVC decoder advertising.
#
# Host: x86_64, ~80G free recommended. Tablet rootfs is 968MB — do not
# build on the tablet. Official google-chrome cannot do this (USE_V4L2=0).
#
# This does not enable Vulkan / DPU scanout.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
OUT="$ROOT/out/chromium-v4l2-src"
VER=152.0.7977.82
DEB=1~deb13u1
MIRROR="${DAGU_CHROMIUM_MIRROR:-https://deb.debian.org/debian-security/pool/updates/main/c/chromium}"
JOBS="${DAGU_CHROMIUM_JOBS:-$(nproc)}"

mkdir -p "$OUT"
cd "$OUT"

orig="chromium_${VER}.orig.tar.xz"
deb="chromium_${VER}-${DEB}.debian.tar.xz"
dsc="chromium_${VER}-${DEB}.dsc"

need() {
	if [ ! -f "$1" ]; then
		echo "==> wget $1"
		wget -c "$MIRROR/$1"
	fi
}

need "$orig"
need "$deb"
need "$dsc"

if [ ! -d src ]; then
	echo "==> unpack (this is large)"
	mkdir -p src
	tar -C src --strip-components=1 -xf "$orig"
	tar -C src -xf "$deb"
fi

apply_encode() {
	f=src/media/gpu/v4l2/BUILD.gn
	[ -f "$f" ] || { echo "missing $f"; return 1; }
	python3 - "$f" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
t = p.read_text()
old = """  if (is_chromeos) {
    sources += [
      # TODO(crbug.com/901264): Encoders use hack for passing offset
      # within a DMA-buf, which is not supported upstream.
      "v4l2_video_encode_accelerator.cc",
      "v4l2_video_encode_accelerator.h",
    ]
  }
"""
new = """  sources += [
    # Linux + Venus: USERPTR/MMAP, not the ChromeOS dmabuf-offset hack
    # (crbug.com/901264). jpeg encode stays ChromeOS-only (camera deps).
    "v4l2_video_encode_accelerator.cc",
    "v4l2_video_encode_accelerator.h",
  ]
"""
# comment wrapping may differ; try a looser match
if old not in t:
    old = """  if (is_chromeos) {
    sources += [
      # TODO(crbug.com/901264): Encoders use hack for passing offset
      # within a DMA-buf, which is not supported upstream.
      "v4l2_video_encode_accelerator.cc",
      "v4l2_video_encode_accelerator.h",
    ]
  }"""
if old not in t:
    # 152 d04cdb24 wrapping
    start = t.find('  if (is_chromeos) {\n    sources += [\n      # TODO(crbug.com/901264)')
    if start < 0:
        start = t.find('v4l2_video_encode_accelerator.cc')
        if start < 0:
            raise SystemExit('BUILD.gn: encode sources not found')
        print('BUILD.gn already lists encode sources')
        raise SystemExit(0)
    # replace the is_chromeos block that only adds encode cc/h
    end = t.find('  }\n', start)
    block = t[start:end+4]
    if 'v4l2_video_encode_accelerator.cc' not in block:
        raise SystemExit('BUILD.gn: unexpected is_chromeos block')
    t = t[:start] + new + t[end+4:]
    p.write_text(t)
    print('patched', p, '(loose)')
else:
    p.write_text(t.replace(old, new, 1))
    print('patched', p)
PY

	f=src/media/gpu/gpu_video_encode_accelerator_factory.cc
	python3 - "$f" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
t = p.read_text()
old = """std::unique_ptr<VideoEncodeAccelerator> CreateV4L2VEA() {
#if BUILDFLAG(IS_CHROMEOS)
  // TODO(crbug.com/901264): Encoders use hack for passing offset within
  // a DMA-buf, which is not supported upstream.
  return base::WrapUnique<VideoEncodeAccelerator>(
      new V4L2VideoEncodeAccelerator(base::MakeRefCounted<V4L2Device>()));
#else
  return nullptr;
#endif
}
"""
new = """std::unique_ptr<VideoEncodeAccelerator> CreateV4L2VEA() {
  // Linux Venus: USERPTR/MMAP. Do not keep the ChromeOS-only nullptr.
  return base::WrapUnique<VideoEncodeAccelerator>(
      new V4L2VideoEncodeAccelerator(base::MakeRefCounted<V4L2Device>()));
}
"""
if old not in t:
    if 'new V4L2VideoEncodeAccelerator' in t and 'return nullptr;' not in t.split('CreateV4L2VEA')[1][:800]:
        print('factory already constructs VEA on all OS')
        raise SystemExit(0)
    raise SystemExit('factory.cc: CreateV4L2VEA block not found')
p.write_text(t.replace(old, new, 1))
print('patched', p)
PY

	# LOG(ERROR) in V4L2-only builds: vaapi_wrapper.h is not included.
	for hookcc in \
		src/media/gpu/sandbox/hardware_video_decoding_sandbox_hook_linux.cc \
		src/media/gpu/sandbox/hardware_video_encoding_sandbox_hook_linux.cc
	do
		[ -f "$hookcc" ] || continue
		python3 - "$hookcc" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
t = p.read_text()
if '#include "base/logging.h"' in t:
    print("logging.h already in", p.name)
    raise SystemExit(0)
for needle in (
    '#include "base/process/process_metrics.h"\n',
    '#include "base/strings/stringprintf.h"\n',
):
    if needle in t:
        p.write_text(t.replace(needle, '#include "base/logging.h"\n' + needle, 1))
        print("patched logging.h", p)
        raise SystemExit(0)
print("logging.h: no include anchor in", p)
PY
	done

	# GPU sandbox + Linux device nodes (Venus udev video-dec0 / video-enc0).
	hook=src/content/common/gpu_pre_sandbox_hook_linux.cc
	if [ -f "$hook" ]; then
		python3 - "$hook" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
t = p.read_text()
if "Desktop Linux + Venus" in t:
    print("gpu_pre_sandbox already patched")
    raise SystemExit(0)
old = """  AddStandardGpuPermissions(&permissions);
  return permissions;
}"""
new = """  AddStandardGpuPermissions(&permissions);
  // Desktop Linux + Venus: VEA/VDA run in the GPU process
  // (kUseOutOfProcessVideoEncoding is off). ChromeOS-only broker
  // permissions would EPERM /dev/video-dec0 and /dev/video-enc0.
  if (UseV4L2Codec(options)) {
    AddV4L2GpuPermissions(&permissions, options);
  }
  return permissions;
}"""
idx = t.rfind(old)
if idx < 0:
    raise SystemExit("gpu_pre_sandbox: FilePermissionsForGpu tail not found")
p.write_text(t[:idx] + new + t[idx + len(old):])
print("patched", p)
PY
	fi
	devcc=src/media/gpu/v4l2/v4l2_device.cc
	if [ -f "$devcc" ]; then
		python3 - "$devcc" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
t = p.read_text()
old = """#else
  static const std::string kDecoderDevicePattern = "/dev/video";
  static const std::string kEncoderDevicePattern = "/dev/video";
"""
new = """#else
  // Linux + Venus udev (video-dec0 / video-enc0). GPU sandbox only
  // brokers those ChromeOS prefixes, not /dev/video14.
  static const std::string kDecoderDevicePattern = "/dev/video-dec";
  static const std::string kEncoderDevicePattern = "/dev/video-enc";
"""
if "Linux + Venus udev" in t:
    print("v4l2_device already patched")
elif old in t:
    p.write_text(t.replace(old, new, 1))
    print("patched", p)
else:
    print("v4l2_device: linux patterns not found")
PY
	fi

	# Venus stateful HEVC must appear in chrome://gpu (not only HEVC_SLICE).
	u=src/media/gpu/v4l2/v4l2_utils.cc
	if [ -f "$u" ]; then
		python3 - "$u" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
t = p.read_text()
old = """#if BUILDFLAG(ENABLE_HEVC_PARSER_AND_HW_DECODER)
        {V4L2_PIX_FMT_HEVC_SLICE, V4L2_CID_MPEG_VIDEO_HEVC_PROFILE},
#endif  // BUILDFLAG(ENABLE_HEVC_PARSER_AND_HW_DECODER)
"""
new = """#if BUILDFLAG(ENABLE_HEVC_PARSER_AND_HW_DECODER)
        // Venus stateful reports V4L2_PIX_FMT_HEVC, not HEVC_SLICE.
        {V4L2_PIX_FMT_HEVC, V4L2_CID_MPEG_VIDEO_HEVC_PROFILE},
        {V4L2_PIX_FMT_HEVC_SLICE, V4L2_CID_MPEG_VIDEO_HEVC_PROFILE},
#endif  // BUILDFLAG(ENABLE_HEVC_PARSER_AND_HW_DECODER)
"""
if '{V4L2_PIX_FMT_HEVC, V4L2_CID_MPEG_VIDEO_HEVC_PROFILE}' in t:
    print('v4l2_utils HEVC stateful map already present')
elif old in t:
    t = t.replace(old, new, 1)
    print('patched HEVC map', p)
else:
    print('v4l2_utils: HEVC_SLICE map not found (ok if already patched)')
oldp = """#else
  constexpr char kVideoDevicePattern[] = "/dev/video";
  constexpr int kMaxDevices = 256;
  candidate_paths.reserve(kMaxDevices);
  for (int i = 0; i < kMaxDevices; ++i) {
    candidate_paths.push_back(
        base::StringPrintf("%s%d", kVideoDevicePattern, i));
  }
#endif"""
newp = """#else
  // Prefer udev /dev/video-dec* (sandbox-allowed). /dev/video* is
  // EPERM inside the GPU process on stock Linux.
  constexpr int kMaxDec = 5;
  constexpr int kMaxDevices = 256;
  candidate_paths.reserve(kMaxDec + kMaxDevices);
  for (int i = 0; i < kMaxDec; ++i) {
    candidate_paths.push_back(base::StringPrintf("/dev/video-dec%d", i));
  }
  for (int i = 0; i < kMaxDevices; ++i) {
    candidate_paths.push_back(base::StringPrintf("/dev/video%d", i));
  }
#endif"""
if "Prefer udev /dev/video-dec*" in t:
    print("v4l2_utils video-dec candidates already present")
elif oldp in t:
    t = t.replace(oldp, newp, 1)
    print("patched video-dec candidates", p)
p.write_text(t)
PY
	fi
}

apply_encode

# official-152 live tree: GMB/MSI → USERPTR (Venus is not ChromeOS dmabuf).
OFF_ADP="$OUT/official-152/media/video/video_encode_accelerator_adapter.cc"
if [ -f "$OFF_ADP" ]; then
	grep -q "Linux Venus is USERPTR/MMAP" "$OFF_ADP" && echo "official-152 adapter SHMEM already patched" || echo "official-152 adapter: patch missing"
fi
OFF_GNI="$OUT/official-152/media/media_options.gni"
if [ -f "$OFF_GNI" ]; then
	python3 - "$OFF_GNI" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
t = p.read_text()
old = "      enable_platform_hevc && (is_win || is_apple || is_android)"
new = "      enable_platform_hevc && (is_win || is_apple || is_android || is_linux)"
if "is_android || is_linux)" in t:
    print("official-152 HEVC encode platform already includes linux")
elif old in t:
    p.write_text(t.replace(old, new, 1))
    print("patched official-152 platform_has_optional_hevc_encode_support +linux")
else:
    print("official-152 media_options.gni: encode support line not found")
PY
fi
OFF_VEA="$OUT/official-152/media/gpu/v4l2/v4l2_video_encode_accelerator.cc"
if [ -f "$OFF_VEA" ]; then
	python3 - "$OFF_VEA" <<'VEA'
from pathlib import Path
import sys
p = Path(sys.argv[1])
t = p.read_text()
if "Linux Venus: USERPTR/MMAP like ffmpeg" in t and "Failed to map MSI frame for USERPTR" in t:
    print("official-152 VEA userptr already patched")
else:
    print("official-152 VEA: live tree should already be patched in-session; sentinel missing")
if "InitControlsHEVC" in t and "V4L2_PIX_FMT_HEVC" in t:
    print("official-152 VEA InitControlsHEVC already patched")
else:
    print("official-152 VEA: InitControlsHEVC missing — apply in-tree")
VEA
fi


# Debian arm64 already has use_v4l2_codec=true. Add HEVC advertise.
if [ -f src/debian/rules ]; then
	python3 - src/debian/rules <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
t = p.read_text()
needle = 'use_v4l2_codec=true use_vaapi=false'
extra = needle + ' enable_platform_hevc=true enable_hevc_parser_and_hw_decoder=true'
if extra in t:
    print('debian/rules HEVC already on')
elif needle in t:
    p.write_text(t.replace(needle, extra))
    print('patched debian/rules HEVC')
else:
    print('debian/rules: v4l2 line not found (ok if using GN args file)')
PY
fi

# Official lite tree: Chromium check_version.py wants exact Node v24.12.0.
OFFICIAL="$OUT/official-152"
if [ -d "$OFFICIAL/third_party/node" ]; then
	NODE_VER=v24.12.0
	NODE_DEST="$OFFICIAL/third_party/node/linux/node-linux-x64"
	if ! "$NODE_DEST/bin/node" -v 2>/dev/null | grep -qx "$NODE_VER"; then
		TARBALL="$OUT/node-${NODE_VER}-linux-x64.tar.xz"
		[ -f "$TARBALL" ] || wget -c -O "$TARBALL" "https://nodejs.org/dist/${NODE_VER}/node-${NODE_VER}-linux-x64.tar.xz"
		mkdir -p "$OUT/node-${NODE_VER}-linux-x64"
		tar -xJf "$TARBALL" -C "$OUT"
		mkdir -p "$NODE_DEST/bin"
		install -m755 "$OUT/node-${NODE_VER}-linux-x64/bin/node" "$NODE_DEST/bin/node"
		echo "==> installed $NODE_VER at $NODE_DEST/bin/node"
	fi
fi

echo "==> Debian tree ready at $OUT/src (unbundle; needs clang-22 + arm64 -dev)."
echo "    Preferred path already started: official lite tree"
echo "      $ROOT/out/chromium-v4l2-src/official-152/out/dagu"
echo "      ninja -C out/dagu chrome chrome_sandbox"
echo "    Node must be v24.12.0 (not host vfox 24.19). Cache:"
echo "      $ROOT/out/chromium-v4l2-src/node-v24.12.0-linux-x64.tar.xz"
echo "    Dawn tint needs Go at third_party/dawn/tools/golang/linux-amd64/bin/go"
echo "      $ROOT/out/chromium-v4l2-src/go  (go1.24.6 tarball)"
echo "    Deploy: $ROOT/scripts/dagu-chromium-v4l2-encode-deploy.sh"
echo "    Probe:  $ROOT/scripts/dagu-chrome-encode-probe.py --host"
echo "    Do not install a half-linked binary on the tablet."
