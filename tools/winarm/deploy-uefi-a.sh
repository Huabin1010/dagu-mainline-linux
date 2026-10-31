#!/usr/bin/env bash
# Flash a new Mu UEFI payload into boot_a, starting from fastboot, using B-slot
# Linux as the workbench. Also re-installs the host's SSH key into Windows so
# the PowerShell tooling works again.
#
#   tools/winarm/deploy-uefi-a.sh [payload]   (default winarm/out/dagu-uefi-payload.raw)
#
# Precondition: tablet in fastboot (USB 18d1:d00d), e.g. power + volume-down.
# Steps:
#   1. set-active b, reboot -> B-slot Linux
#   2. dd the current boot_a back to the host (backup + repack base)
#   3. append ~/.ssh/id_rsa.pub to C:\ProgramData\ssh\administrators_authorized_keys
#      (appending through ntfs-3g keeps the file's ACL, which sshd checks)
#   4. repack: new payload into the dumped boot_a (tools/winarm/repack-uefi-boot.py)
#   5. Linux -> fastboot, flash boot_a, set-active a, reboot
# Rollback: flash the backup printed in step 2 back to boot_a.
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PAYLOAD="${1:-$REPO/winarm/out/dagu-uefi-payload.raw}"
FB="python3 $REPO/linux-mainline/scripts/fb-usb.py"
PW="${LINUX_PW:-dagu}"
BK="${BK_DIR:-$HOME/dagu-woa}"
SSHO=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=6)
stamp=$(date +%m%d-%H%M)

[ -f "$PAYLOAD" ] || { echo "no payload $PAYLOAD" >&2; exit 1; }
wait_usb() { for _ in $(seq 1 "${2:-60}"); do lsusb | grep -q "$1" && return 0; sleep 3; done; return 1; }

echo "[1] waiting for fastboot..."
wait_usb 18d1:d00d 200 || { echo "no fastboot" >&2; exit 1; }
$FB set-active b; timeout 5 $FB reboot || true
wait_usb 0525:a4a7 60 || { echo "B-slot Linux USB gadget did not appear" >&2; exit 1; }
IP=""
for _ in $(seq 1 20); do
	for c in ${LINUX_IP:-} 192.168.1.68; do
		sshpass -p "$PW" ssh "${SSHO[@]}" "root@$c" true 2>/dev/null && { IP=$c; break 2; }
	done
	sleep 5
done
[ -n "$IP" ] || IP=$("$REPO/tools/winarm/dagu-find-linux.sh" 2>/dev/null | sed -n 's/^FOUND //p')
[ -n "$IP" ] || { echo "Linux not reachable" >&2; exit 1; }
echo "    linux=$IP"
L() { sshpass -p "$PW" ssh "${SSHO[@]}" "root@$IP" "$@"; }

echo "[2] dump boot_a"
L 'dd if=/dev/disk/by-partlabel/boot_a of=/tmp/boot_a.img bs=4M status=none && sha256sum /tmp/boot_a.img'
mkdir -p "$BK"
sshpass -p "$PW" scp "${SSHO[@]}" "root@$IP:/tmp/boot_a.img" "$BK/boot_a-pre-$stamp.img"
echo "    backup: $BK/boot_a-pre-$stamp.img"

echo "[3] SSH key -> Windows administrators_authorized_keys"
sshpass -p "$PW" scp "${SSHO[@]}" "$HOME/.ssh/id_rsa.pub" "root@$IP:/tmp/host.pub"
L 'set -e; mkdir -p /mnt/w; mountpoint -q /mnt/w && umount /mnt/w
ntfsfix -d /dev/sda36 >/dev/null; ntfs-3g -o force,remove_hiberfile /dev/sda36 /mnt/w
AK=/mnt/w/ProgramData/ssh/administrators_authorized_keys
[ -f "$AK" ] || { echo "no $AK"; umount /mnt/w; exit 1; }
k=$(cut -d" " -f2 /tmp/host.pub)
if grep -q "$k" "$AK"; then echo "    key already present"; else
  tail -c1 "$AK" | od -An -c | grep -q "\\\\n" || printf "\r\n" >> "$AK"
  tr -d "\n" < /tmp/host.pub >> "$AK"; printf "\r\n" >> "$AK"; echo "    key appended"; fi
grep -c "ssh-" "$AK" | sed "s/^/    keys in file: /"
mkdir -p /mnt/e; mountpoint -q /mnt/e || mount /dev/sda35 /mnt/e
rm -f /mnt/e/dagu-no-gpu; cp -f /mnt/e/dagu-uefi-diag.txt /tmp/diag-prev.txt 2>/dev/null || true
sync; umount /mnt/e; umount /mnt/w'

echo "[4] repack"
python3 "$REPO/tools/winarm/repack-uefi-boot.py" --boot "$BK/boot_a-pre-$stamp.img" \
	--payload "$PAYLOAD" --out "$BK/boot_a-new-$stamp.img"

echo "[5] Linux -> fastboot -> flash boot_a -> slot a"
L "nohup sh -c 'sleep 1; python3 -c \"import ctypes;ctypes.CDLL(\\\"libc.so.6\\\").syscall(142,0xfee1dead,0x28121969,0xA1B2C3D4,b\\\"bootloader\\\")\"' >/dev/null 2>&1 &" || true
wait_usb 18d1:d00d 60 || { echo "no fastboot after Linux reboot" >&2; exit 1; }
$FB flash boot_a "$BK/boot_a-new-$stamp.img"
$FB set-active a
timeout 5 $FB reboot || true
echo "done. new=$BK/boot_a-new-$stamp.img backup=$BK/boot_a-pre-$stamp.img"
