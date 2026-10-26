#!/usr/bin/env bash
# Runs ON THE TABLET (Linux, root). Boots the automated WinPE in QEMU against
# the real UFS LUN0, write-protected outside the esp/win partitions.
# Expects $T/winpe.img from build-media.sh (WinPE + \\woa\\install.wim etc).
#
#   T=/root/woa ESP_DEV=/dev/sda35 WIN_DEV=/dev/sda36 run-qemu-deploy.sh
set -euo pipefail
T="${T:-/root/woa}" ESP_DEV="${ESP_DEV:-/dev/sda35}" WIN_DEV="${WIN_DEV:-/dev/sda36}"
cd "$T"
[ "$(blkid -s PARTLABEL -o value "$ESP_DEV")" = esp ]
[ "$(blkid -s PARTLABEL -o value "$WIN_DEV")" = win ]
! grep -qE "^($ESP_DEV|$WIN_DEV) " /proc/mounts

# --- WinPE media: built by build-media.sh (writable: WinPE logs to \woa) ---
[ -f winpe.img ] || { echo "no winpe.img: run build-media.sh create" >&2; exit 1; }
"$(dirname "$0")/build-media.sh" umount     # never share a mounted FAT with QEMU

# --- export the real UFS LUN0, writable ONLY inside esp and win ---
# (A synthetic GPT spliced around the partitions with nbdkit-split failed:
# split refuses every write to a block-device member with ENOSPC.) Windows
# sees the true disk GUID, partition GUIDs and 4 KiB sectors, so the BCD that
# bcdboot writes is exactly what the native boot needs. The protect filter
# returns EPERM for any write outside the two partitions, so GPT, xbl/abl,
# modem, userdata (Linux) etc. cannot be touched.
SS=4096
DISK=/dev/$(basename "$(readlink -f "/sys/class/block/${ESP_DEV#/dev/}/..")")
[ "$DISK" = "/dev/$(basename "$(readlink -f "/sys/class/block/${WIN_DEV#/dev/}/..")")" ]
[ "$(blockdev --getss "$DISK")" = $SS ]
range() { local s z; s=$(cat "/sys/class/block/${1#/dev/}/start"); z=$(cat "/sys/class/block/${1#/dev/}/size"); echo $((s * 512)) $(((s + z) * 512 - 1)); }
read -r e0 e1 < <(range "$ESP_DEV"); read -r w0 w1 < <(range "$WIN_DEV")
[ $((e1 + 1)) = $w0 ]                         # esp and win are adjacent
dsz=$(blockdev --getsize64 "$DISK")
echo "[winpe] $DISK writable $e0-$w1 only (disk $dsz bytes)"

# --- serve it and boot WinPE (TCG: no KVM at EL1 under QHEE) ---
[ -f nbdkit.pid ] && kill "$(cat nbdkit.pid)" 2>/dev/null || true
rm -f nbd.sock nbdkit.pid serial.log gpt-head.img gpt-tail.img
prot=(protect=0-$((e0 - 1)))
[ $w1 -lt $((dsz - 1)) ] && prot+=(protect=$((w1 + 1))-$((dsz - 1)))
nbdkit -U nbd.sock -P nbdkit.pid file "$DISK" --filter=protect "${prot[@]}"
trap 'kill $(cat nbdkit.pid) 2>/dev/null || true' EXIT
echo "[winpe] QEMU start $(date +%T)"
rc=0
# cortex-a76, not "max": TCG emulation of max's pointer auth / SVE is so slow
# that edk2 never got past its banner in minutes; a76 reaches BDS in <90 s.
timeout 4h qemu-system-aarch64 -M virt -cpu cortex-a76 -smp 4 -m 3072 \
	-bios /usr/share/qemu-efi-aarch64/QEMU_EFI.fd \
	-display none -serial file:serial.log -device ramfb -nic none \
	-monitor unix:$PWD/mon.sock,server,nowait \
	-device qemu-xhci -device usb-storage,drive=pe,removable=on,bootindex=0 \
	-drive if=none,id=pe,file=winpe.img,format=raw \
	-drive if=none,id=tgt,file=nbd:unix:$PWD/nbd.sock,format=raw,cache=none \
	-device nvme,drive=tgt,serial=dagu-ufs,logical_block_size=$SS,physical_block_size=$SS \
	|| rc=$?
echo "[winpe] QEMU exit rc=$rc $(date +%T)"
