#!/usr/bin/env bash
# elish/pmOS-style boot.img for dagu: header 0 + Image.gz-dtb.
# Does not touch vendor_boot. See docs/elish-abl-legacy-boot-path.md.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/env.sh
source "$ROOT/scripts/env.sh"

OUT="$ROOT/out"
KERNEL_IMG="${KERNEL_IMG:-$KBUILD_OUTPUT/arch/arm64/boot/Image}"
DTB="$OUT/$DTB_NAME"
RAMDISK_GZ="$OUT/initramfs.cpio.gz"
BOOTIMG="${BOOTIMG:-$OUT/boot-dagu-legacy.img}"
PADDED="$OUT/Image-text-offset"
GZ="$OUT/Image-text-offset.gz"
GZDTB="$OUT/Image.gz-dtb"
CMDLINE="${CMDLINE:-clk_ignore_unused pd_ignore_unused fw_devlink=off fw_devlink.sync_state=disabled kpti=off console=tty0 androidboot.usbcontroller=a600000.dwc3}"

[[ -f "$KERNEL_IMG" ]] || { echo "missing $KERNEL_IMG — build-kernel.sh" >&2; exit 1; }
[[ -f "$DTB" ]] || { echo "missing $DTB — build-kernel.sh" >&2; exit 1; }

"$ROOT/scripts/build-initramfs.sh"
[[ -f "$RAMDISK_GZ" ]] || { echo "missing ramdisk" >&2; exit 1; }

echo "==> 2MiB stub pad (same as magiskboot v3 path)"
python3 - "$KERNEL_IMG" "$PADDED" <<'PY'
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
print(f"scrambled {n} embedded FDT magic(s) inside Image")
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
print(f"padded {src.stat().st_size} -> {dst.stat().st_size}")
PY

echo "==> gzip padded Image (ABL is_gzip_package + decompress → DtbOffset)"
gzip -n -9 -c "$PADDED" >"$GZ"

echo "==> fdtput msm-id/board-id, concat FDT after gzip"
python3 - "$DTB" "$GZ" "$GZDTB" <<'PY'
import subprocess, sys
from pathlib import Path
dtb_src, gz, out = map(Path, sys.argv[1:])
p = Path("/tmp/dagu-legacy.dtb")
p.write_bytes(dtb_src.read_bytes())
subprocess.check_call(["fdtput", "-tx", str(p), "/", "qcom,msm-id", "0x164", "0x20001"])
subprocess.check_call(["fdtput", "-tx", str(p), "/", "qcom,board-id", "0x33", "0x0"])
dtb = p.read_bytes()
if dtb[:4] != b"\xd0\x0d\xfe\xed":
    raise SystemExit("DTB missing FDT magic")
blob = gz.read_bytes() + dtb
if blob[:2] != b"\x1f\x8b":
    raise SystemExit("kernel payload is not gzip")
out.write_bytes(blob)
print(f"Image.gz-dtb {out.stat().st_size} gzip={gz.stat().st_size} dtb={len(dtb)}")
PY

echo "==> mkbootimg header 0 (no --header_version, no vendor_boot)"
mkbootimg \
	--kernel "$GZDTB" \
	--ramdisk "$RAMDISK_GZ" \
	--base 0x00000000 \
	--kernel_offset 0x00008000 \
	--ramdisk_offset 0x01000000 \
	--second_offset 0x00f00000 \
	--tags_offset 0x00000100 \
	--pagesize 4096 \
	--cmdline "$CMDLINE" \
	-o "$BOOTIMG"

python3 - "$BOOTIMG" <<'PY'
import struct, sys
from pathlib import Path
p = Path(sys.argv[1])
d = p.read_bytes()
magic = d[:8]
page, hdr_ver = struct.unpack_from("<II", d, 36)
ksize = struct.unpack_from("<I", d, 8)[0]
print(f"{p.name} magic={magic!r} page_size={page} header_version={hdr_ver} kernel={ksize} file={p.stat().st_size}")
if magic != b"ANDROID!":
    raise SystemExit("not ANDROID!")
if hdr_ver != 0:
    raise SystemExit(f"expected header 0, got {hdr_ver}")
if page != 4096:
    raise SystemExit(f"page_size {page}")
kern = d[page : page + ksize]
if kern[:2] != b"\x1f\x8b":
    raise SystemExit("kernel payload not gzip")
if b"\xd0\x0d\xfe\xed" not in kern:
    raise SystemExit("no FDT after gzip in kernel payload")
print("verify: gzip + FDT inside kernel payload OK")
PY

python3 "$ROOT/scripts/build-chain-extras.py"
ls -lh "$BOOTIMG" "$OUT/vbmeta-disabled.img"
echo "Flash B slot only: ./scripts/flash-boot-legacy.sh"
