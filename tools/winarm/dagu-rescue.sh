#!/usr/bin/env bash
# dagu 双槽救援：Windows（A 槽）起不来时，从 B 槽 Linux 离线改注册表并切回 A 槽。
#
# 背景：平板是 Android A/B 槽。A 槽是 Windows，B 槽是 Linux。A 槽连续启动失败后，
# 引导程序会自动回落到 B 槽，所以 Windows 挂掉以后平板会自己进 Linux，而 Linux 有
# Wi-Fi 和 ssh，整个回滚可以不用人工碰设备。
#
# 用法：
#   dagu-rescue.sh status                     查看哪个槽在跑
#   dagu-rescue.sh wait [秒]                  等任意一侧上线（默认 300 秒）
#   dagu-rescue.sh rm-dsdt                    从 Linux 删掉 DSDT 覆盖表
#   dagu-rescue.sh set-pep <0|1|3|4>          从 Linux 改 qcpep 的 Start
#   dagu-rescue.sh disable-pep0               从 Linux 把 PEP0 设备设为禁用（保留 ACPI 节点）
#   dagu-rescue.sh disable-qcdx               从 Linux 把 GPU 驱动服务 QCDX 设为禁用
#   dagu-rescue.sh to-win                     进 fastboot，切 A 槽，重启
#   dagu-rescue.sh auto                       等上线；若落到 Linux 就删覆盖表并切回 A
#   dagu-rescue.sh hive-run <本地脚本>        把脚本推到 Linux 上以 root 执行
#
# 环境变量：WIN_IP（默认 192.168.1.250）、LINUX_IP（默认 192.168.1.75）、
#           LINUX_PW（默认 dagu）、WIN_PART（默认 /dev/sda36）。
set -u

WIN_IP="${WIN_IP:-192.168.1.250}"
LINUX_IP="${LINUX_IP:-192.168.1.75}"
LINUX_PW="${LINUX_PW:-dagu}"
WIN_PART="${WIN_PART:-/dev/sda36}"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
          -o LogLevel=ERROR -o ConnectTimeout=8)

win_up() { ping -c1 -W2 "$WIN_IP" >/dev/null 2>&1; }
# 只 ping 会把局域网里占用同一地址的别的设备误判为平板，所以用 ssh 实际登录一次
linux_up() {
	sshpass -p "$LINUX_PW" ssh "${SSH_OPTS[@]}" -o ConnectTimeout=4 "root@$LINUX_IP" true >/dev/null 2>&1
}

lsh() { # 在平板 Linux 上以 root 跑一条命令
	sshpass -p "$LINUX_PW" ssh "${SSH_OPTS[@]}" "root@$LINUX_IP" "$@"
}

lpush() { # 把本地文件推到平板 Linux
	sshpass -p "$LINUX_PW" scp "${SSH_OPTS[@]}" "$1" "root@$LINUX_IP:$2"
}

cmd_status() {
	win_up && echo "windows: up ($WIN_IP)" || echo "windows: down"
	linux_up && echo "linux:   up ($LINUX_IP)" || echo "linux:   down"
}

cmd_wait() {
	local limit="${1:-300}" waited=0
	while [ "$waited" -lt "$limit" ]; do
		if win_up; then echo "windows"; return 0; fi
		if linux_up; then echo "linux"; return 0; fi
		sleep 5
		waited=$((waited + 5))
	done
	echo "none"
	return 1
}

# 在平板 Linux 上挂载 Windows 分区（崩溃后 NTFS 是脏的，要先 ntfsfix）
mount_win() {
	lsh "set -e
mkdir -p /mnt/w
mountpoint -q /mnt/w && umount /mnt/w || true
which hivexsh >/dev/null 2>&1 || (apt-get -qq update && apt-get -qq install -y libhivex-bin >/dev/null)
# 卷是脏的时候 ntfs-3g 会退回只读挂载且返回 0，之后 hivexsh commit 会失败。
# 所以直接先 ntfsfix，再强制读写挂载，最后实测能否写入。
ntfsfix -d '$WIN_PART' >/dev/null
ntfs-3g -o force,remove_hiberfile '$WIN_PART' /mnt/w
touch /mnt/w/.rescue-rw && rm -f /mnt/w/.rescue-rw || { echo 'NTFS 只读挂载，放弃' >&2; umount /mnt/w; exit 1; }
mountpoint -q /mnt/w && echo MOUNT_OK"
}

unmount_win() { lsh "sync; umount /mnt/w 2>/dev/null; echo UMOUNT_DONE"; }

cmd_rm_dsdt() {
	linux_up || { echo "Linux 不在线，无法离线改注册表" >&2; return 1; }
	mount_win || return 1
	lsh "H=/mnt/w/Windows/System32/config/SYSTEM
cp -f \"\$H\" /root/SYSTEM.bak-\$(date +%H%M%S)
printf 'cd ControlSet001\\\\Services\\\\ACPI\\\\Parameters\\\\DSDT\\\\QCOMM_\\\\SM8250_\\\\00000004\ndel\ncommit\n' > /tmp/rm.txt
hivexsh -w -f /tmp/rm.txt \"\$H\" 2>&1 && echo DSDT_OVERRIDE_REMOVED
printf 'cd ControlSet001\\\\Services\\\\ACPI\\\\Parameters\\\\DSDT\\\\QCOMM_\\\\SM8250_\nls\n' > /tmp/ls.txt
echo \"剩余子键: \$(hivexsh -f /tmp/ls.txt \"\$H\" 2>&1 | tr '\n' ' ')\""
	unmount_win
}

cmd_set_pep() {
	local v="${1:?用法: set-pep <0|1|3|4>}"
	linux_up || { echo "Linux 不在线" >&2; return 1; }
	mount_win || return 1
	# hivexsh 的 setval 会覆盖整个键，所以必须把 qcpep 的所有值一起写回
	lsh "H=/mnt/w/Windows/System32/config/SYSTEM
cp -f \"\$H\" /root/SYSTEM.bak-pep-\$(date +%H%M%S)
cat > /tmp/pep.txt <<'EOF'
cd ControlSet001\\Services\\qcpep
setval 6
Start
dword:0000000$v
Type
dword:00000001
ErrorControl
dword:00000001
Group
string:Base
ImagePath
expandstring:\\SystemRoot\\System32\\DriverStore\\FileRepository\\qcpep.wd8250.inf_arm64_5946bbfc6d49db89\\qcpep8250.sys
DisplayName
string:Qualcomm(R) System Manager Power Engine Plug-in Device
commit
EOF
hivexsh -w -f /tmp/pep.txt \"\$H\" 2>&1 && echo PEP_START_SET=$v
for k in Start Type Group ImagePath; do printf '  %s=%s\n' \"\$k\" \"\$(hivexget \"\$H\" 'ControlSet001\\Services\\qcpep' \$k)\"; done"
	unmount_win
}

# 离线把 PEP0 这个 PnP 设备设为禁用（ConfigFlags=1），这样开机时 PnP 不会加载 qcpep，
# 但 ACPI 里的 PEP0 节点仍然保留，便于下次在系统跑起来之后再手动启用。
cmd_disable_pep0() {
	linux_up || { echo "Linux 不在线" >&2; return 1; }
	mount_win || return 1
	lsh "H=/mnt/w/Windows/System32/config/SYSTEM
cp -f \"\$H\" /root/SYSTEM.bak-cfg-\$(date +%H%M%S)
K='ControlSet001\\Enum\\ACPI\\QCOM2519\\2&daba3ff&0'
cat > /tmp/cfg.txt <<'EOF'
cd ControlSet001\\Enum\\ACPI\\QCOM2519\\2&daba3ff&0
setval 3
ConfigFlags
dword:00000001
Service
string:qcpep
Driver
string:{4d36e97d-e325-11ce-bfc1-08002be10318}\\0025
commit
EOF
hivexsh -w -f /tmp/cfg.txt \"\$H\" 2>&1 && echo PEP0_DISABLED
echo \"  ConfigFlags=\$(hivexget \"\$H\" \"\$K\" ConfigFlags)\""
	unmount_win
}

# 离线把 GPU 驱动服务 QCDX 设为禁用（Start=4）。qcdxkm8250.sys 初始化卡死时，
# Windows 停在启动阶段且不蓝屏，只能这样回滚。下面的值取自活系统（2026-10-30），
# hivexsh 的 setval 会覆盖整个键的值（子键不受影响），所以全部写回。
cmd_disable_qcdx() {
	linux_up || { echo "Linux 不在线" >&2; return 1; }
	mount_win || return 1
	local tmp
	tmp="$(mktemp)"
	cat > "$tmp" <<'EOF'
cd ControlSet001\Services\QCDX
setval 6
Type
dword:00000001
Start
dword:00000004
ErrorControl
dword:00000000
ImagePath
expandstring:\SystemRoot\System32\DriverStore\FileRepository\qcdx8250.inf_arm64_a5505ccbf9897acf\qcdxkm8250.sys
DisplayName
string:@oem80.inf,%ServiceName%;Qualcomm(R) Adreno(TM) 640 GPU
Owners
hex:7:6f,00,65,00,6d,00,38,00,30,00,2e,00,69,00,6e,00,66,00,00,00,00,00
commit
EOF
	lpush "$tmp" /tmp/qcdx.txt >/dev/null
	rm -f "$tmp"
	lsh "H=/mnt/w/Windows/System32/config/SYSTEM
cp -f \"\$H\" /root/SYSTEM.bak-qcdx-\$(date +%H%M%S)
hivexsh -w -f /tmp/qcdx.txt \"\$H\" 2>&1 && echo QCDX_DISABLED
echo \"  Start=\$(hivexget \"\$H\" 'ControlSet001\\Services\\QCDX' Start)\""
	unmount_win
}

cmd_hive_run() {
	local script="${1:?用法: hive-run <本地脚本>}"
	linux_up || { echo "Linux 不在线" >&2; return 1; }
	lpush "$script" /tmp/rescue-run.sh >/dev/null
	lsh "chmod +x /tmp/rescue-run.sh && /tmp/rescue-run.sh"
}

cmd_to_win() {
	if linux_up; then
		# 从 Linux 直接进 fastboot（reboot bootloader）
		lsh "nohup sh -c 'sleep 1; python3 -c \"import ctypes;ctypes.CDLL(\\\"libc.so.6\\\").syscall(142,0xfee1dead,0x28121969,0xA1B2C3D4,b\\\"bootloader\\\")\"' >/dev/null 2>&1 &" || true
		sleep 20
	fi
	for i in $(seq 1 20); do
		lsusb 2>/dev/null | grep -q '18d1:d00d' && break
		sleep 3
	done
	lsusb | grep -q '18d1:d00d' || { echo "没进 fastboot" >&2; return 1; }
	python3 "$REPO/linux-mainline/scripts/fb-usb.py" set-active a
	python3 "$REPO/linux-mainline/scripts/fb-usb.py" reboot
	echo "已切到 A 槽并重启"
}

cmd_auto() {
	local who
	who="$(cmd_wait "${1:-300}")"
	echo "上线: $who"
	case "$who" in
		windows) echo "Windows 正常，无需救援"; return 0 ;;
		linux)
			echo "落到 Linux，说明 Windows 启动失败。开始救援。"
			cmd_rm_dsdt
			cmd_to_win
			cmd_wait 300
			;;
		*) echo "两侧都没上线" >&2; return 1 ;;
	esac
}

case "${1:-status}" in
	status)   cmd_status ;;
	wait)     cmd_wait "${2:-300}" ;;
	rm-dsdt)  cmd_rm_dsdt ;;
	set-pep)  cmd_set_pep "${2:-}" ;;
	disable-pep0) cmd_disable_pep0 ;;
	disable-qcdx) cmd_disable_qcdx ;;
	to-win)   cmd_to_win ;;
	auto)     cmd_auto "${2:-300}" ;;
	hive-run) cmd_hive_run "${2:-}" ;;
	*) sed -n '2,25p' "$0"; exit 2 ;;
esac
