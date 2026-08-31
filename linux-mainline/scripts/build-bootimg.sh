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
CMDLINE_EXTRA="${CMDLINE_EXTRA:-clk_ignore_unused pd_ignore_unused fw_devlink=off fw_devlink.sync_state=disabled kpti=off console=tty0}"

[[ -x "$MAGISKBOOT" ]] || { echo "missing magiskboot: $MAGISKBOOT" >&2; exit 1; }
[[ -f "$STOCK_BOOT" && -f "$STOCK_VBOOT" ]] || { echo "missing stock images in $DUMP" >&2; exit 1; }
[[ -f "$KERNEL_IMG" ]] || { echo "missing $KERNEL_IMG — build-kernel.sh" >&2; exit 1; }
[[ -f "$DTB" ]] || { echo "missing $DTB — build-kernel.sh" >&2; exit 1; }

"$ROOT/scripts/build-initramfs.sh"
[[ -f "$RAMDISK_GZ" ]] || { echo "missing ramdisk" >&2; exit 1; }

repack_boot() {
	local work=$OUT/repack-boot
	local padded=$OUT/Image-text-offset
	rm -rf "$work"
	mkdir -p "$work"
	# Qualcomm ABL (dump iomem Kernel code @ 0xa0080000) loads Image at
	# 2MB-aligned 0xa0000000 + 0x80000. Linux 7.0 needs Image[0] 2MB-aligned.
	# Lore workaround: pad (2MiB - 0x80000) so the real Image sits at
	# 0xa0200000. Trampolines at file+0 and file+0x80000 cover both
	# "jump to Image[0]" and "jump to load+text_offset" ABL variants.
	python3 - "$KERNEL_IMG" "$padded" <<'PY'
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
# Stock 4.19 Image has no d00dfeed. ABL may pass the first FDT magic as x0.
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
# inner kernel is placed on a 2MB boundary; keep its own text_offset=0
struct.pack_into("<Q", inner, 8, 0)
inner_size = struct.unpack_from("<Q", inner, 16)[0]
text_off = 0x80000
pad = 0x200000 - text_off  # 0x180000
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
	(
		cd "$work"
		"$MAGISKBOOT" unpack -h "$STOCK_BOOT"
		rm -f kernel_dtb dtb extra
		cp -f "$padded" kernel
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

echo "==> magiskboot repack stock v3 boot (raw Image, not Image.gz)"
repack_boot
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
