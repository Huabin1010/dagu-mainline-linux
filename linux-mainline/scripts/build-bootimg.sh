#!/usr/bin/env bash
# Repack *stock* HyperOS v3 boot + vendor_boot with magiskboot.
# ABL rejected from-scratch mkbootimg (v2/v3, Image.gz). Stock kernel is raw Image.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/env.sh
source "$ROOT/scripts/env.sh"

OUT="$ROOT/out"
DUMP="$ROOT/../dumps/dagu-20260826-210700-root/images"
STOCK_BOOT="$DUMP/boot_a.img"
STOCK_VBOOT="$DUMP/vendor_boot_a.img"
KERNEL_IMG="${KERNEL_IMG:-$KBUILD_OUTPUT/arch/arm64/boot/Image}"
DTB="$OUT/$DTB_NAME"
RAMDISK_GZ="$OUT/initramfs.cpio.gz"
BOOTIMG="${BOOTIMG:-$OUT/boot-dagu.img}"
VBOOT="${VBOOT:-$OUT/vendor_boot-dagu.img}"
MAGISKBOOT="${MAGISKBOOT:-$ROOT/../tools/downloads/dagu-android/magisk-patch/magiskboot}"

# Dump live FDT bootargs use kpti=off. Do not pass nokaslr: 7.0 takes the
# 0x80000 physical misalignment as the low KASLR bits (map_kernel.c) so
# ABL's 0xa0080000 load still 2MB-block-maps.
# regulator_ignore_unused joins clk/pd: regulator_init_complete() otherwise
# drops the panel rails at late_initcall_sync and blanks the splash buffer
# fbcon is drawing into. TER16x32 keeps 1600x2560 down to 80 readable rows.
#
# cpuidle.off=1: CPU6 took a PSCI power-collapse idle state and never came
# back (hard LOCKUP at ~24s, no NMI response, "failed to stop secondary
# CPUs"). QHEE on this HyperOS chain wants downstream lpm-levels to program
# the RPMh sleep/wake sets first, so plain WFI until that path is ported.
#
# arm-smmu.disable_bypass=0 belongs with the ignore_unused trio: apps_smmu
# probes 26ms after fbcon takes over and resets every S2CR. QHEE hands the
# display stream over as TRANS, so nothing gets pinned ("preserved 0 boot
# mappings") and the default FAULT policy aborts MDP's scanout of
# cont_splash_region — panel black, backlight still on. Belt to the
# ARM_SMMU_DISABLE_BYPASS_BY_DEFAULT=n suspenders in dagu-usb.fragment.
CMDLINE_EXTRA="${CMDLINE_EXTRA:-clk_ignore_unused pd_ignore_unused regulator_ignore_unused cpuidle.off=1 arm-smmu.disable_bypass=0 fw_devlink=off fw_devlink.sync_state=disabled kpti=off msm.dpu_use_virtual_planes=1 console=ttyGS0,115200 console=tty0 fbcon=font:TER16x32 ignore_loglevel loglevel=8}"

[[ -x "$MAGISKBOOT" ]] || { echo "missing magiskboot: $MAGISKBOOT" >&2; exit 1; }
[[ -f "$STOCK_BOOT" && -f "$STOCK_VBOOT" ]] || { echo "missing stock images in $DUMP" >&2; exit 1; }
[[ -f "$KERNEL_IMG" ]] || { echo "missing $KERNEL_IMG — build-kernel.sh" >&2; exit 1; }
[[ -f "$DTB" ]] || { echo "missing $DTB — build-kernel.sh" >&2; exit 1; }

"$ROOT/scripts/build-initramfs.sh"
[[ -f "$RAMDISK_GZ" ]] || { echo "missing ramdisk" >&2; exit 1; }

repack_boot() {
	local work=$OUT/repack-boot
	rm -rf "$work"
	mkdir -p "$work"
	# Stock HyperOS v3 boot_a: raw Image with text_offset=0x80000, no embedded
	# FDT. Plain 7.0 Image is text_offset=0 with a d00dfeed blob — mismatch.
	# BOOTIMG_RAW=1: verbatim Image. BOOTIMG_STUB_PAD=1: old 2MiB−0x80000 pad.
	(
		cd "$work"
		"$MAGISKBOOT" unpack -h "$STOCK_BOOT"
		rm -f kernel_dtb dtb extra
		local prepared=$OUT/Image-v3-prepared
		if [[ "${BOOTIMG_RAW:-}" == 1 ]]; then
			cp -f "$KERNEL_IMG" kernel
			echo "verbatim Image kernel $(stat -c%s kernel) bytes (BOOTIMG_RAW=1)"
		elif [[ "${BOOTIMG_STUB_PAD:-}" == 1 ]]; then
			prepared=$OUT/Image-text-offset
			python3 - "$KERNEL_IMG" "$prepared" <<'PY'
import struct, sys
from pathlib import Path
src, dst = Path(sys.argv[1]), Path(sys.argv[2])
inner = bytearray(src.read_bytes())
if inner[56:60] != b"ARM\x64":
    raise SystemExit(f"{src} is not an ARM64 Image")
code0, code1 = struct.unpack_from("<II", inner, 0)
branch = code1 if (code1 & 0xFC000000) == 0x14000000 else code0
if (branch & 0xFC000000) != 0x14000000:
    raise SystemExit(f"no B primary_entry in header code0={code0:#x} code1={code1:#x}")
struct.pack_into("<I", inner, 0, branch)
struct.pack_into("<I", inner, 4, 0)
n = 0
off = 0
while True:
    i = inner.find(b"\xd0\x0d\xfe\xed", off)
    if i < 0:
        break
    inner[i : i + 4] = b"\x00\x00\x00\x00"
    n += 1
    off = i + 4
print(f"scrambled {n} embedded FDT magic(s)")
struct.pack_into("<Q", inner, 8, 0)
inner_size = struct.unpack_from("<Q", inner, 16)[0]
text_off = 0x80000
pad = 0x200000 - text_off
hdr = bytearray(pad)
def b_imm(delta):
    return 0x14000000 | ((delta >> 2) & 0x3FFFFFF)
struct.pack_into("<I", hdr, 0, b_imm(pad))
struct.pack_into("<I", hdr, 4, 0)
struct.pack_into("<Q", hdr, 8, text_off)
struct.pack_into("<Q", hdr, 16, pad + inner_size)
hdr[24:32] = inner[24:32]
hdr[56:60] = b"ARM\x64"
struct.pack_into("<I", hdr, text_off, b_imm(pad - text_off))
dst.write_bytes(bytes(hdr) + bytes(inner))
print(
    f"2MiB stub pad={pad:#x} file {src.stat().st_size} -> {dst.stat().st_size} "
    f"outer_text_off={text_off:#x} image_size={pad + inner_size:#x}"
)
PY
			cp -f "$prepared" kernel
		else
			python3 - "$KERNEL_IMG" "$prepared" <<'PY'
import struct, sys
from pathlib import Path
src, dst = Path(sys.argv[1]), Path(sys.argv[2])
inner = bytearray(src.read_bytes())
if inner[56:60] != b"ARM\x64":
    raise SystemExit(f"{src} is not an ARM64 Image")
text_off = struct.unpack_from("<Q", inner, 8)[0]
n = 0
off = 0
while True:
    i = inner.find(b"\xd0\x0d\xfe\xed", off)
    if i < 0:
        break
    inner[i : i + 4] = b"\x00\x00\x00\x00"
    n += 1
    off = i + 4
if n:
    print(f"scrambled {n} embedded FDT magic(s)")
pad = 0x80000
if text_off == pad:
    dst.write_bytes(inner)
    print(f"already text_offset={pad:#x}, size {len(inner)}")
else:
    inner_size = len(inner)
    hdr = bytearray(pad)

    def b_imm(delta):
        return 0x14000000 | ((delta >> 2) & 0x3FFFFFF)

    struct.pack_into("<I", hdr, 0, b_imm(pad))
    struct.pack_into("<I", hdr, 4, 0)
    struct.pack_into("<Q", hdr, 8, pad)
    struct.pack_into("<Q", hdr, 16, pad + inner_size)
    hdr[24:56] = inner[24:56]
    hdr[56:60] = b"ARM\x64"
    dst.write_bytes(bytes(hdr) + bytes(inner))
    print(
        f"stock text_offset={pad:#x}: {inner_size} -> {pad + inner_size} "
        f"(was text_offset={text_off:#x})"
    )
PY
			cp -f "$prepared" kernel
		fi
		gzip -dc "$RAMDISK_GZ" >ramdisk.cpio
		# Keep stock os_version / patch level in header.
		PATCHVBMETAFLAG=true "$MAGISKBOOT" repack "$STOCK_BOOT" "$BOOTIMG"
	)
}

repack_vendor_boot() {
	local work=$OUT/repack-vboot
	rm -rf "$work"
	mkdir -p "$work"
	(
		cd "$work"
		"$MAGISKBOOT" unpack -h "$STOCK_VBOOT" || true
		# Stock kona v2.1 blob is msm-id <0x164 0x20001> board-id <0 0>.
		# A 4-way concat made ABL Load Error (instant fastboot) even with
		# the stock kernel. Ship one blob with those exact ids.
		python3 - "$DTB" dtb <<'PY'
import subprocess, sys
from pathlib import Path
src, dst = Path(sys.argv[1]), Path(sys.argv[2])
p = Path("/tmp/dagu-dtb-abl.dtb")
p.write_bytes(src.read_bytes())
subprocess.check_call(["fdtput", "-tx", str(p), "/", "qcom,msm-id", "0x164", "0x20001"])
subprocess.check_call(["fdtput", "-tx", str(p), "/", "qcom,board-id", "0x0", "0x0"])
dst.write_bytes(p.read_bytes())
print(f"vendor DTB {dst.stat().st_size} msm-id=0x164,0x20001 board-id=0,0")
PY
		if [[ -f header ]]; then
			if grep -q '^cmdline=' header; then
				sed -i "s/^cmdline=/cmdline=${CMDLINE_EXTRA} /" header
			else
				echo "cmdline=${CMDLINE_EXTRA}" >>header
			fi
			# panic_warm turns a kernel panic into an instant fastboot bounce.
			sed -i 's/ reboot=panic_warm//' header
		fi
		PATCHVBMETAFLAG=true "$MAGISKBOOT" repack "$STOCK_VBOOT" "$VBOOT"
	)
}

echo "==> magiskboot repack stock v3 boot (stock text_offset=0x80000; BOOTIMG_RAW=1 / BOOTIMG_STUB_PAD=1 for A/B)"
repack_boot
work_verify=$OUT/verify-boot-kernel
rm -rf "$work_verify"
mkdir -p "$work_verify"
(
	cd "$work_verify"
	"$MAGISKBOOT" unpack -h "$BOOTIMG" >/dev/null
	k_sz=$(stat -c%s kernel)
	dtb_sz=0
	[[ -f kernel_dtb ]] && dtb_sz=$(stat -c%s kernel_dtb)
	payload=$((k_sz + dtb_sz))
	ref_sz=$(stat -c%s "$KERNEL_IMG")
	echo "boot kernel+kernel_dtb=${payload} bytes (build Image: ${ref_sz})"
	if [[ "${BOOTIMG_RAW:-}" == 1 ]]; then
		[[ "$payload" -eq "$ref_sz" ]] || {
			echo "ERROR: BOOTIMG_RAW=1 but boot payload != source Image" >&2
			exit 1
		}
	elif [[ "${BOOTIMG_STUB_PAD:-}" == 1 ]]; then
		[[ "$payload" -gt "$ref_sz" ]] || {
			echo "ERROR: BOOTIMG_STUB_PAD=1 but boot payload not larger than Image" >&2
			exit 1
		}
	else
		# stock layout: 0x80000 header + verbatim inner Image
		[[ "$payload" -eq "$((ref_sz + 0x80000))" ]] || {
			echo "ERROR: expected stock 0x80000 layout (payload != Image+0x80000)" >&2
			exit 1
		}
	fi
)
echo "==> magiskboot repack stock vendor_boot (mainline DTB)"
repack_vendor_boot

# magiskboot pads to dump partition size. USB now reports 768MiB max-download,
# so keep full 192/96 MiB images (Magisk-shaped). Truncating AVB used to be
# required only when getvar hung and max-download looked like 0.
if [[ "${TRIM_BOOTIMG:-}" == 1 ]]; then
python3 - "$BOOTIMG" "$VBOOT" <<'PY'
from pathlib import Path
import sys
for p in map(Path, sys.argv[1:]):
    b = p.read_bytes()
    avb = b.rfind(b"AVB0")
    if avb < 0:
        raise SystemExit(f"no AVB0 in {p}")
    extra = 1024 * 1024 if "boot-dagu" in p.name else 256 * 1024
    n = (avb + extra + 4095) // 4096 * 4096
    p.write_bytes(b[:n])
    print(f"truncated {p.name}: {len(b)} -> {n}")
PY
fi

python3 "$ROOT/scripts/build-chain-extras.py"
ls -lh "$BOOTIMG" "$VBOOT" "$OUT/dtbo-stub.img" "$OUT/vbmeta-disabled.img"
"$MAGISKBOOT" unpack -h "$BOOTIMG" 2>&1 | head -16 || true
echo "Flash both slots: ./scripts/flash-boot.sh flash"
