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
GZ="$OUT/Image.gz"
GZDTB="$OUT/Image.gz-dtb"
CMDLINE="${CMDLINE:-clk_ignore_unused pd_ignore_unused fw_devlink=off fw_devlink.sync_state=disabled kpti=off console=tty0 ignore_loglevel loglevel=8 hung_task_panic=1 hung_task_timeout_secs=10 panic=5 reboot=panic_warm}"

[[ -f "$KERNEL_IMG" ]] || { echo "missing $KERNEL_IMG — build-kernel.sh" >&2; exit 1; }
[[ -f "$DTB" ]] || { echo "missing $DTB — build-kernel.sh" >&2; exit 1; }

"$ROOT/scripts/build-initramfs.sh"
[[ -f "$RAMDISK_GZ" ]] || { echo "missing ramdisk" >&2; exit 1; }

echo "==> gzip raw Image (pmOS / Armbian — no 2MiB stub pad)"
gzip -n -9 -c "$KERNEL_IMG" >"$GZ"

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
