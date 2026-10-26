#!/usr/bin/env bash
# dagu Windows-on-ARM bring-up: reboot/log loop with automatic return-to-Linux.
#
# Safe-slot model:
#   boot_b = mainline Linux  (home base; SSH over Wi-Fi; our remote shell)
#   boot_a = UEFI experiment (Project-Aloha KonaPkg dagu build)
# The PC keeps a USB cable to the tablet. Recovery rules:
#   - If the device drops to fastboot (18d1:d00d), we set active=b and reboot
#     it back to Linux over USB — fully remote.
#   - If UEFI comes up and idles (no fastboot, no Linux), or hard-hangs, only a
#     physical button press (or the ABL retry counter) returns it. The user has
#     agreed to power-cycle in that case.
#
# Subcommands:
#   flash     reboot Linux->fastboot, flash UEFI to boot_a, set active a, reboot
#   watch     poll USB + SSH, timestamp every state change into logs/winarm/<ts>
#   recover   from fastboot (or force): set active b, reboot to Linux
#   readlog   over SSH on Linux-b, dump + decode the UEFI PStore serial ring
#   run       flash, then watch, and recover/readlog automatically
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
LM="$ROOT/linux-mainline"
# ABL only accepts the magiskboot-repacked stock v3 pair (winarm/build-dagu-uefi.sh step 6).
IMG="${IMG:-$ROOT/winarm/out/boot-dagu-uefi-v3.img}"
VBOOT_IMG="${VBOOT_IMG:-$ROOT/winarm/out/vendor_boot-dagu-uefi.img}"
SSHK="$LM/out/id_dagu"
HOST="${DAGU_HOST:-192.168.1.158}"
# Inside the stock disp_rdump_region (reserved no-map in the dagu Linux DT).
PSTORE_ADDR="${PSTORE_ADDR:-0xB0400000}"
PSTORE_SIZE="${PSTORE_SIZE:-0x200000}"
FBUSB="python3 $LM/scripts/fb-usb.py"
TS="$(date +%Y%m%d-%H%M%S)"
LOG="$ROOT/logs/winarm/$TS"; mkdir -p "$LOG"
ssh_b() { ssh -i "$SSHK" -o IdentitiesOnly=yes -o StrictHostKeyChecking=no \
	-o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=6 \
	root@"$HOST" "$@"; }
usb_state() {
	local l; l="$(lsusb 2>/dev/null)"
	echo "$l" | grep -q 18d1:d00d && { echo fastboot; return; }
	echo "$l" | grep -q 0525:a4a7 && { echo linux-gadget; return; }
	ssh_b true 2>/dev/null && { echo linux-ssh; return; }
	echo none
}
cmd_flash() {
	[ -f "$IMG" ] || { echo "no image: $IMG (run winarm/build-dagu-uefi.sh)" >&2; exit 1; }
	echo "[flash] rebooting Linux -> fastboot"
	ssh_b 'sync; systemd-run --no-block --on-active=2 /usr/sbin/reboot bootloader' || true
	for i in $(seq 1 60); do [ "$(usb_state)" = fastboot ] && break; sleep 2; done
	[ "$(usb_state)" = fastboot ] || { echo "no fastboot" >&2; exit 1; }
	# dtbo_a (stub) and vbmeta_a (disabled) were flashed once at setup and stay.
	echo "[flash] vendor_boot_a <- $(basename "$VBOOT_IMG"), boot_a <- $(basename "$IMG")"
	$FBUSB flash vendor_boot_a "$VBOOT_IMG"
	$FBUSB flash boot_a "$IMG"
	$FBUSB set-active a
	echo "[flash] active=a; rebooting into UEFI"
	timeout 3 $FBUSB reboot || true
}
cmd_recover() {
	for i in $(seq 1 30); do [ "$(usb_state)" = fastboot ] && break; sleep 2; done
	[ "$(usb_state)" = fastboot ] || { echo "[recover] not in fastboot; needs a physical reboot to fastboot" >&2; return 1; }
	$FBUSB set-active b; timeout 3 $FBUSB reboot || true
	for i in $(seq 1 60); do [ "$(usb_state)" = linux-ssh ] && { echo "[recover] back on Linux"; return 0; }; sleep 3; done
	echo "[recover] Linux did not return in time" >&2; return 1
}
cmd_watch() {
	local prev="" now t0=$SECONDS
	echo "[watch] logging to $LOG/usb-timeline.txt (Ctrl-C to stop)"
	while :; do
		now="$(usb_state)"
		if [ "$now" != "$prev" ]; then
			printf '%5ds  %s\n' "$((SECONDS-t0))" "$now" | tee -a "$LOG/usb-timeline.txt"
			prev="$now"
			[ "$now" = fastboot ] && $FBUSB getvar all >"$LOG/fastboot-getvar.txt" 2>&1 || true
		fi
		sleep 2
	done
}
cmd_readlog() {
	echo "[readlog] dumping $PSTORE_ADDR (+$PSTORE_SIZE) from Linux-b"
	# The region is reserved no-map in the boot_b DT, so it is not "System RAM"
	# and CONFIG_STRICT_DEVMEM=y still allows /dev/mem access. read() returns
	# EFAULT there (no linear mapping on arm64), so mmap() it instead.
	ssh_b "python3 -c 'import mmap,os,sys; fd=os.open(\"/dev/mem\",os.O_RDONLY|os.O_SYNC); \
sys.stdout.buffer.write(mmap.mmap(fd,$PSTORE_SIZE,mmap.MAP_SHARED,mmap.PROT_READ,offset=$PSTORE_ADDR)[:])'" \
		>"$LOG/pstore.bin" 2>"$LOG/pstore.err" || true
	python3 - "$LOG/pstore.bin" "$LOG/uefi.log" <<'PY'
import sys
# FrameBufferInMemorySerialPortLib ring: data in [0, len-8), write offset
# (UINTN) in the last 8 bytes. PrePi zeroes the region on every boot.
d = open(sys.argv[1], "rb").read()
if len(d) < 4096:
    sys.exit("pstore read failed (see pstore.err)")
size = len(d) - 8
off = int.from_bytes(d[-8:], "little")
if not 0 <= off < size:
    sys.exit(f"no UEFI ring here (offset {off:#x}); DDR not retained or wrong address")
log = (d[off:size] + d[:off]).replace(b"\x00", b"")
open(sys.argv[2], "wb").write(log)
sys.stdout.write(log[-6000:].decode("utf-8", "replace"))
PY
	echo "[readlog] saved $LOG/pstore.bin"
}
cmd_run() { cmd_flash; cmd_watch; }
case "${1:-}" in
	flash) cmd_flash;; watch) cmd_watch;; recover) cmd_recover;;
	readlog) cmd_readlog;; run) cmd_run;;
	*) echo "usage: $0 {flash|watch|recover|readlog|run}"; exit 1;;
esac
