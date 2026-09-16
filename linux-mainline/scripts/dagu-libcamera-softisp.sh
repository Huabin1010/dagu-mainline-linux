#!/bin/sh
# Enable libcamera simple + Software ISP on dagu after UDMABUF is present.
# Do not use meson -Dipmbs (that option does not exist).
#
# Viewfinder must not CPU-demosaic 4080×3060 at 30 fps: generateConfiguration
# used to default every role to the sensor max. StillCapture stays full
# frame. DebayerCpu center-crops when output < input; dagu switches that
# to Bayer skip so FOV is preserved.
set -eu

log() { printf 'dagu-libcamera-softisp: %s\n' "$*"; }

if [ ! -e /dev/udmabuf ]; then
	log "no /dev/udmabuf — rebuild with CONFIG_UDMABUF=y and flash B slot"
	exit 1
fi

ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
CFG_SRC="$ROOT/libcamera/configuration.yaml"
for dest in /etc/libcamera /usr/share/libcamera; do
	if [ -f "$CFG_SRC" ]; then
		mkdir -p "$dest"
		cp "$CFG_SRC" "$dest/configuration.yaml"
		log "installed $dest/configuration.yaml (software_isp.threads=2)"
		break
	fi
done
IPA_SIMPLE="$ROOT/libcamera/ipa/simple"
if [ -d "$IPA_SIMPLE" ]; then
	mkdir -p /usr/share/libcamera/ipa/simple
	for y in imx596.yaml s5kjn1.yaml; do
		if [ -f "$IPA_SIMPLE/$y" ]; then
			cp "$IPA_SIMPLE/$y" "/usr/share/libcamera/ipa/simple/$y"
			log "installed /usr/share/libcamera/ipa/simple/$y (no gray-world Awb)"
		fi
	done
fi

insert_props() {
	file=$1
	[ -f "$file" ] || return 0
	if grep -q '"s5kjn1"' "$file"; then
		log "sensor properties already mention s5kjn1"
		return 0
	fi
	python3 - "$file" <<'PY'
from pathlib import Path
import sys

p = Path(sys.argv[1])
text = p.read_text()
needle = '{ "imx219",'
block = '''	{ "s5kjn1", {
		.unitCellSize = { 640, 640 },
	} },
	{ "imx596", {
		.unitCellSize = { 800, 800 },
	} },
	{ "imx596-dagu", {
		.unitCellSize = { 800, 800 },
	} },
'''
if needle not in text:
    sys.exit("imx219 needle missing")
p.write_text(text.replace(needle, block + "\t" + needle, 1))
print("inserted s5kjn1/imx596 sensor properties")
PY
}

patch_viewfinder_bin() {
	python3 - "$1" <<'PY'
from pathlib import Path
import sys

root = Path(sys.argv[1])
changed = []

simple = root / "src/libcamera/pipeline/simple/simple.cpp"
if simple.is_file():
    text = simple.read_text()
    old = """		cfg.pixelFormat = formats.begin()->first;
		cfg.size = formats.begin()->second[0].max;
"""
    new = """		cfg.pixelFormat = formats.begin()->first;
		{
			Size max = formats.begin()->second[0].max;
			/* dagu: Viewfinder must not default to 12MP SoftISP. */
			if (role == StreamRole::Viewfinder ||
			    role == StreamRole::VideoRecording) {
				/* /4 and /2 already applied in DebayerCpu::sizes(). */
				unsigned int div = max.width >= 3000 ? 4
						 : max.width >= 2000 ? 2 : 1;
				cfg.size = Size((max.width / div) & ~1U,
						(max.height / div) & ~1U);
			} else {
				cfg.size = max;
			}
		}
"""
    if "dagu: Viewfinder must not default" in text:
        print(f"{simple}: viewfinder size already patched")
    elif old not in text:
        sys.exit(f"{simple}: generateConfiguration size needle missing")
    else:
        simple.write_text(text.replace(old, new, 1))
        changed.append(str(simple))

hdr = root / "src/libcamera/software_isp/debayer_cpu.h"
if hdr.is_file():
    text = hdr.read_text()
    if "xSkip_" in text:
        print(f"{hdr}: xSkip_ already present")
    else:
        needle = "	unsigned int xShift_; /* Offset of 0/1 applied to window_.x */"
        insert = needle + "\n	unsigned int xSkip_ = 1;\n	unsigned int ySkip_ = 1;"
        if needle not in text:
            sys.exit(f"{hdr}: xShift_ needle missing")
        hdr.write_text(text.replace(needle, insert, 1))
        changed.append(str(hdr))

cpp = root / "src/libcamera/software_isp/debayer_cpu.cpp"
if cpp.is_file():
    text = cpp.read_text()
    win = """	window_.width = outputCfg.size.width;
	window_.height = outputCfg.size.height;
"""
    win_new = """	window_.width = outputCfg.size.width;
	window_.height = outputCfg.size.height;
	/* dagu: skip Bayer (keep phase) so a 1020×765 Viewfinder is full FOV,
	 * not a center crop of 4080×3060. StillCapture is ~1:1 (skip=1). */
	xSkip_ = 1;
	ySkip_ = 1;
	if (outputCfg.size.width > 0 && outputCfg.size.height > 0 &&
	    inputCfg.size.width >= outputCfg.size.width * 2 &&
	    inputCfg.size.height >= outputCfg.size.height * 2) {
		unsigned int xs = (inputCfg.size.width / outputCfg.size.width) & ~1U;
		unsigned int ys = (inputCfg.size.height / outputCfg.size.height) & ~1U;
		if (xs >= 2 && ys >= 2) {
			xSkip_ = xs;
			ySkip_ = ys;
			window_.x = 0;
			window_.y = 0;
		}
	}
"""
    if "dagu: skip Bayer" in text:
        print(f"{cpp}: skip already patched")
    elif win not in text:
        sys.exit(f"{cpp}: window size needle missing")
    else:
        text = text.replace(win, win_new, 1)

    sizes_old = """	return SizeRange(Size(patternSize.width, patternSize.height),
			 Size((inputSize.width - 2 * patternSize.width) & ~(patternSize.width - 1),
			      (inputSize.height - 2 * borderHeight) & ~(patternSize.height - 1)),
			 patternSize.width, patternSize.height);
"""
    sizes_new = """	Size max((inputSize.width - 2 * patternSize.width) & ~(patternSize.width - 1),
		 (inputSize.height - 2 * borderHeight) & ~(patternSize.height - 1));
	/* dagu: Android imx596 preview is IFE 1440x1080 full FOV @ 30fps, not
	 * 2592x1952. PipeWire still asks 1920x1080; that is skip 1x1 (~2MP
	 * CPU) and a center crop. Integer Bayer skip matches CamX FOV:
	 * s5kjn1 /4, imx596 /2 (~1296x976). StillCapture stays RAW full. */
	unsigned int div = inputSize.width >= 3000 ? 4u
			 : inputSize.width >= 2000 ? 2u : 1u;
	if (div > 1) {
		Size cap((inputSize.width / div) & ~(patternSize.width - 1),
			 (inputSize.height / div) & ~(patternSize.height - 1));
		if (max.width > cap.width)
			max = cap;
	}
	return SizeRange(Size(patternSize.width, patternSize.height),
			 max, patternSize.width, patternSize.height);
"""
    if "dagu: Android imx596 preview is IFE" in text:
        print(f"{cpp}: processed max already capped")
    elif sizes_old not in text:
        sys.exit(f"{cpp}: DebayerCpu::sizes needle missing")
    else:
        text = text.replace(sizes_old, sizes_new, 1)
        if str(cpp) not in changed:
            changed.append(str(cpp))

    buf_needles = [
        (
            """	lineBufferLength_ = debayer_->window_.width * inputConfig.bpp / 8 +
			    2 * lineBufferPadding_;
""",
            """	lineBufferLength_ = debayer_->window_.width * inputConfig.bpp / 8 +
			    2 * lineBufferPadding_;
	if (debayer_->xSkip_ > 1)
		lineBufferLength_ = inputConfig.stride + 2 * lineBufferPadding_;
""",
        ),
        (
            """	lineBufferLength_ = window_.width * inputConfig_.bpp / 8 +
			    2 * lineBufferPadding_;
""",
            """	lineBufferLength_ = window_.width * inputConfig_.bpp / 8 +
			    2 * lineBufferPadding_;
	{
		unsigned int packed =
			(inputCfg.size.width * inputConfig_.bpp + 7) / 8;
		if (inputConfig_.stride < packed)
			inputConfig_.stride = packed;
	}
	if (xSkip_ > 1)
		lineBufferLength_ = inputConfig_.stride + 2 * lineBufferPadding_;
	LOG(Debayer, Info) << "dagu skip " << xSkip_ << "x" << ySkip_
			   << " in " << inputCfg.size
			   << " stride " << inputCfg.stride
			   << " out " << outputCfg.size
			   << " lineBuf " << lineBufferLength_;
""",
        ),
    ]
    extra_y_needles = [
        (
            """		src += inputStride;
		dst += outputStride;
	}

	if (window.y == 0 && yEnd_ == window.height) {
""",
            """		src += inputStride;
		dst += outputStride;
		if (debayer_->ySkip_ > 1)
			src += inputStride * 2 * (debayer_->ySkip_ - 1);
	}

	if (window.y == 0 && yEnd_ == window.height) {
""",
        ),
        (
            """		src += inputConfig_.stride;
		dst += outputConfig_.stride;
	}

	if (window_.y == 0) {
""",
            """		src += inputConfig_.stride;
		dst += outputConfig_.stride;
		if (ySkip_ > 1)
			src += inputConfig_.stride * 2 * (ySkip_ - 1);
	}

	if (window_.y == 0) {
""",
        ),
    ]
    if "xSkip_ > 1" not in text:
        for old, new in buf_needles:
            if old in text:
                text = text.replace(old, new, 1)
                break
        else:
            sys.exit(f"{cpp}: lineBufferLength needle missing")

    if "ySkip_ > 1" not in text:
        for old, new in extra_y_needles:
            if old in text:
                text = text.replace(old, new, 1)
                break
        else:
            sys.exit(f"{cpp}: process2 stride needle missing")

    skip10 = """		/* Skip 5th src byte with 4 x 2 least-significant-bits */
		x++;
"""
    skip10_new = """		/* Skip 5th src byte with 4 x 2 least-significant-bits */
		x++;
		if (xSkip_ > 1) {
			int adv = 5 * static_cast<int>(xSkip_ - 1);
			prev += adv;
			curr += adv;
			next += adv;
		}
"""
    skip10_old = """		if (xSkip_ > 1)
			x += 5 * static_cast<int>(xSkip_ - 1);
"""
    skip10_ptr = """		if (xSkip_ > 1) {
			int adv = 5 * static_cast<int>(xSkip_ - 1);
			prev += adv;
			curr += adv;
			next += adv;
		}
"""
    if skip10_old in text:
        text = text.replace(skip10_old, skip10_ptr)
    elif "prev += adv" not in text:
        if skip10 not in text:
            sys.exit(f"{cpp}: packed RAW10 skip needle missing")
        text = text.replace(skip10, skip10_new)

    if "inputConfig_.stride < packed" not in text:
        stride_old = """	lineBufferPadding_ = inputConfig_.patternSize.width * inputConfig_.bpp / 8;
	lineBufferLength_ = window_.width * inputConfig_.bpp / 8 +
			    2 * lineBufferPadding_;
"""
        stride_new = """	lineBufferPadding_ = inputConfig_.patternSize.width * inputConfig_.bpp / 8;
	{
		unsigned int packed =
			(inputCfg.size.width * inputConfig_.bpp + 7) / 8;
		if (inputConfig_.stride < packed)
			inputConfig_.stride = packed;
	}
	lineBufferLength_ = window_.width * inputConfig_.bpp / 8 +
			    2 * lineBufferPadding_;
"""
        if stride_old not in text:
            sys.exit(f"{cpp}: stride packed needle missing")
        text = text.replace(stride_old, stride_new, 1)

    memcpy_old = """	for (unsigned int i = 0; i < patternHeight; i++) {
		memcpy(lineBuffers_[i].data(),
		       linePointers[i + 1] - lineBufferPadding_,
		       lineBufferLength_);
		linePointers[i + 1] = lineBuffers_[i].data() + lineBufferPadding_;
	}
"""
    memcpy_new = """	for (unsigned int i = 0; i < patternHeight; i++) {
		uint8_t *dst = lineBuffers_[i].data();
		if (window_.x == 0) {
			memcpy(dst + lineBufferPadding_, linePointers[i + 1],
			       lineBufferLength_ - 2 * lineBufferPadding_);
		} else {
			memcpy(dst, linePointers[i + 1] - lineBufferPadding_,
			       lineBufferLength_);
		}
		linePointers[i + 1] = dst + lineBufferPadding_;
	}
"""
    if "window_.x == 0" not in text and memcpy_old in text:
        text = text.replace(memcpy_old, memcpy_new, 1)
        next_old = """	memcpy(lineBuffers_[lineBufferIndex_].data(),
	       linePointers[patternHeight] - lineBufferPadding_,
	       lineBufferLength_);
	linePointers[patternHeight] = lineBuffers_[lineBufferIndex_].data() + lineBufferPadding_;
"""
        next_new = """	{
		uint8_t *dst = lineBuffers_[lineBufferIndex_].data();
		if (window_.x == 0) {
			memcpy(dst + lineBufferPadding_, linePointers[patternHeight],
			       lineBufferLength_ - 2 * lineBufferPadding_);
		} else {
			memcpy(dst, linePointers[patternHeight] - lineBufferPadding_,
			       lineBufferLength_);
		}
		linePointers[patternHeight] = dst + lineBufferPadding_;
	}
"""
        if next_old not in text:
            sys.exit(f"{cpp}: memcpyNextLine needle missing")
        text = text.replace(next_old, next_new, 1)

    if 'dagu skip' not in text:
        log_old = """	if (xSkip_ > 1)
		lineBufferLength_ = inputConfig_.stride + 2 * lineBufferPadding_;

	if (enableInputMemcpy_) {
"""
        log_new = """	if (xSkip_ > 1)
		lineBufferLength_ = inputConfig_.stride + 2 * lineBufferPadding_;
	LOG(Debayer, Info) << "dagu skip " << xSkip_ << "x" << ySkip_
			   << " in " << inputCfg.size
			   << " stride " << inputCfg.stride
			   << " out " << outputCfg.size
			   << " lineBuf " << lineBufferLength_;

	if (enableInputMemcpy_) {
"""
        if log_old in text:
            text = text.replace(log_old, log_new, 1)

    cpp.write_text(text)
    changed.append(str(cpp))

if changed:
    print("patched:\n " + "\n ".join(changed))
else:
    print("viewfinder bin: nothing to write")
PY
}

# Front imx596 viewfinder was magenta because IPASoft gray-world AWB sees
# near-black CFA (blackLevel 16 eats the residual) and slams B gain to 4.0.
# First frame also applied uninitialized DebayerParams (NaN/1e36).
patch_front_awb() {
	python3 - "$1" <<'PY'
from pathlib import Path
import sys

root = Path(sys.argv[1])
changed = []

awb = root / "src/ipa/simple/algorithms/awb.cpp"
if awb.is_file():
    text = awb.read_text()
    needle = """	const RGB<uint64_t> sum = stats->sum_.max(offset + minValid) - offset;

	/*
	 * Calculate red and blue gains for AWB.
"""
    insert = """	const RGB<uint64_t> sum = stats->sum_.max(offset + minValid) - offset;

	/*
	 * dagu: near-black stats (front imx596 residual after OB 16) make
	 * gray-world slam B to 4.0 and the whole preview is magenta.
	 */
	auto &gains = context.activeState.awb.gains;
	if (sum.r() < nPixels * 2 || sum.g() < nPixels * 2 ||
	    sum.b() < nPixels * 2) {
		gains = { { 1.0f, 1.0f, 1.0f } };
		return;
	}

	/*
	 * Calculate red and blue gains for AWB.
"""
    if "near-black stats" in text:
        print(f"{awb}: near-black AWB guard already present")
    elif needle not in text:
        sys.exit(f"{awb}: AWB sum needle missing")
    else:
        awb.write_text(text.replace(needle, insert, 1))
        changed.append(str(awb))

ipa = root / "src/ipa/simple/soft_simple.cpp"
if ipa.is_file():
    text = ipa.read_text()
    old = """		params_->gains = { { 1.0, 1.0, 1.0 } };
		/* combinedMatrix is reset for each frame. */
"""
    new = """		params_->gains = { { 1.0, 1.0, 1.0 } };
		params_->combinedMatrix = Matrix<float, 3, 3>::identity();
		/* combinedMatrix is reset for each frame. */
"""
    if "params_->combinedMatrix = Matrix" in text:
        print(f"{ipa}: combinedMatrix identity already present")
    elif old not in text:
        sys.exit(f"{ipa}: DebayerParams init needle missing")
    else:
        ipa.write_text(text.replace(old, new, 1))
        changed.append(str(ipa))

cpp = root / "src/libcamera/software_isp/debayer_cpu.cpp"
if cpp.is_file():
    text = cpp.read_text()
    if "#include <cmath>" not in text:
        text = text.replace("#include <algorithm>\n",
                            "#include <algorithm>\n#include <cmath>\n", 1)
        changed.append(str(cpp))
    if "dagu: reject insane DebayerParams" not in text:
        old = """void DebayerCpu::updateLookupTables(DebayerParams &params)
{
	const bool gammaUpdateNeeded =
"""
        new = """void DebayerCpu::updateLookupTables(DebayerParams &params)
{
	/* dagu: reject insane DebayerParams */
	{
		auto ok = [](float v, float lo, float hi) {
			return std::isfinite(v) && v >= lo && v <= hi;
		};
		if (!ok(params.gamma, 0.05f, 4.0f) ||
		    !ok(params.contrastExp, 0.05f, 8.0f) ||
		    !ok(params.gains.r(), 0.05f, 8.0f) ||
		    !ok(params.gains.g(), 0.05f, 8.0f) ||
		    !ok(params.gains.b(), 0.05f, 8.0f)) {
			params.gamma = 0.454545f;
			params.contrastExp = 1.0f;
			params.gains = { { 1.0f, 1.0f, 1.0f } };
			params.blackLevel = { { 16.0f / 255.0f, 16.0f / 255.0f,
						16.0f / 255.0f } };
			params.combinedMatrix = Matrix<float, 3, 3>::identity();
		}
	}
	const bool gammaUpdateNeeded =
"""
        if old not in text:
            sys.exit(f"{cpp}: updateLookupTables needle missing")
        text = text.replace(old, new, 1)
        cpp.write_text(text)
        if str(cpp) not in changed:
            changed.append(str(cpp))
    else:
        cpp.write_text(text)

if changed:
    print("patched:\n " + "\n ".join(changed))
else:
    print("front awb: nothing to write")
PY
}

src="${LIBCAMERA_SRC:-/usr/src/libcamera}"
props="$src/src/libcamera/camera_sensor_properties.cpp"
[ -f "$props" ] || props="$src/src/libcamera/sensor/camera_sensor_properties.cpp"
if [ -f "$props" ]; then
	insert_props "$props"
	patch_viewfinder_bin "$src"
	patch_front_awb "$src"
	log "meson if you rebuild: meson setup build -Dpipelines=simple"
	log "then ninja -C build && ninja -C build install"
	log "soname must be libcamera.so.0.7 -> libcamera.so.0.7.0 (not a leftover .dagu stub)"
else
	log "no libcamera source at $src; distro SoftISP is enough if UDMABUF works"
	log "Viewfinder 12MP cap needs source: apt-get source libcamera && LIBCAMERA_SRC=... $0"
fi

# meson/ldconfig must not leave soname on a leftover .dagu stub. PipeWire
# loads libcamera-base.so.0.7; a truncated ninja copy here makes the
# SPA plugin enumerate zero cameras → Snapshot "No Camera Found".
libdir=/usr/lib/aarch64-linux-gnu
mkdir -p /var/backups/dagu-libcamera
for stub in libcamera.so.0.7.0.dagu libcamera-base.so.0.7.0.dagu; do
	if [ -e "$libdir/$stub" ]; then
		mv -f "$libdir/$stub" /var/backups/dagu-libcamera/"$stub"
		log "moved $stub out of $libdir (ldconfig soname trap)"
	fi
done
if [ -e "$libdir/libcamera.so.0.7.0" ]; then
	ln -sfn libcamera.so.0.7.0 "$libdir/libcamera.so.0.7"
fi
if [ -e "$libdir/libcamera-base.so.0.7.0" ]; then
	ln -sfn libcamera-base.so.0.7.0 "$libdir/libcamera-base.so.0.7"
fi
ldconfig >/dev/null 2>&1 || true

if command -v cam >/dev/null; then
	log "cam --list-cameras"
	cam --list-cameras || true
fi
