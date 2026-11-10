#!/usr/bin/env bash
# 从 B 槽 Linux 备份 A 槽 ESP（EFI System Partition，EFI 系统分区）上的 BCD
# （Boot Configuration Data，启动配置数据），不改启动项。
# 平板需在 fastboot，或已经在 B 槽 Linux。
# 备份写到 ESP 的 EFI/Microsoft/Boot/BCD.dagu-safe-<日期>，并拉回主机 ~/dagu-woa。
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FB="python3 $REPO/linux-mainline/scripts/fb-usb.py"
PW="${LINUX_PW:-dagu}"
BK="${BK_DIR:-$HOME/dagu-woa}"
SSHO=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=6)
stamp=$(date +%Y%m%d)

wait_usb() { for _ in $(seq 1 "${2:-60}"); do lsusb | grep -q "$1" && return 0; sleep 3; done; return 1; }

if lsusb | grep -q 18d1:d00d; then
	echo "[1] fastboot -> B 槽 Linux"
	$FB set-active b
	timeout 5 $FB reboot || true
	wait_usb 0525:a4a7 90 || { echo "B 槽 Linux 的 USB 设备没有出现" >&2; exit 1; }
fi

IP=""
for _ in $(seq 1 20); do
	for c in ${LINUX_IP:-} $(cat "${XDG_CACHE_HOME:-$HOME/.cache}/dagu-linux-ip" 2>/dev/null); do
		sshpass -p "$PW" ssh "${SSHO[@]}" "root@$c" true 2>/dev/null && { IP=$c; break 2; }
	done
	sleep 3
done
[ -n "$IP" ] || IP=$("$REPO/tools/winarm/dagu-find-linux.sh" 2>/dev/null | sed -n 's/^FOUND //p')
[ -n "$IP" ] || { echo "Linux 连不上" >&2; exit 1; }
echo "    linux=$IP"
L() { sshpass -p "$PW" ssh "${SSHO[@]}" "root@$IP" "$@"; }

echo "[2] 备份 BCD"
L "set -e
mkdir -p /mnt/e
mountpoint -q /mnt/e || mount /dev/sda35 /mnt/e
bcd=/mnt/e/EFI/Microsoft/Boot/BCD
[ -f \"\$bcd\" ] || { echo 'no BCD'; exit 1; }
cp -a \"\$bcd\" \"\$bcd.dagu-safe-$stamp\"
sha256sum \"\$bcd\" \"\$bcd.dagu-safe-$stamp\"
sync
"
mkdir -p "$BK"
sshpass -p "$PW" scp "${SSHO[@]}" "root@$IP:/mnt/e/EFI/Microsoft/Boot/BCD" "$BK/BCD.dagu-safe-$stamp"
sshpass -p "$PW" scp "${SSHO[@]}" "root@$IP:/mnt/e/EFI/Microsoft/Boot/BCD.dagu-safe-$stamp" "$BK/BCD.dagu-safe-$stamp.esp"
echo "    host: $BK/BCD.dagu-safe-$stamp"
echo "    esp:  EFI/Microsoft/Boot/BCD.dagu-safe-$stamp"
