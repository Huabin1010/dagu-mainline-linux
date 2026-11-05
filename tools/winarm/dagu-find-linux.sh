#!/usr/bin/env bash
# 找到 B 槽 Linux 当前的 IP。平板每次开机 DHCP 地址都会变（.51 / .60 / .75 / .106 …），
# 旧地址还可能被局域网里别的设备占用：ping 得通、SSH 被拒，看起来像平板没起来。
# Wi-Fi 网卡 wlp1s0 的 MAC 是固定的永久地址（NetworkManager 关了随机 MAC），所以按 MAC 找。
#
# 按快到慢依次尝试，每一步命中后都用 SSH 指纹（aarch64 + /dev/sda36）确认：
#   1. 缓存：上一次找到的地址（~/.cache/dagu-linux-ip）
#   2. ARP 表里 MAC 对应的地址
#   3. 并发 ping 整个 /24 刷新 ARP 表，再按 MAC 查（约 2 秒）
#   4. USB 串口 /dev/ttyACM0 直接问平板（要求串口控制台已登录 root）
#   5. 兜底：对所有活跃主机逐个试 SSH 指纹（慢，约 1 分钟）
#
# 用法: dagu-find-linux.sh [网段前缀]   默认 192.168.1
#   成功: 打印 "FOUND <ip>"，写缓存，退出 0
#   失败: 打印 "NOT_FOUND"，退出 1
# 环境变量: DAGU_MAC、LINUX_PW、WIN_IP、DAGU_SERIAL
set -u
PREFIX="${1:-192.168.1}"
MAC="${DAGU_MAC:-f0:6c:5d:71:3a:2b}"
PW="${LINUX_PW:-dagu}"
WIN_IP="${WIN_IP:-192.168.1.250}"
SERIAL="${DAGU_SERIAL:-/dev/ttyACM0}"
HERE="$(cd "$(dirname "$0")" && pwd)"
CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/dagu-linux-ip"
SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
          -o LogLevel=ERROR -o ConnectTimeout=3 -o PreferredAuthentications=password
          -o PubkeyAuthentication=no)

log() { echo "[find-linux] $*" >&2; }

probe() { # 判断某 IP 是不是平板 Linux
	local out
	out=$(sshpass -p "$PW" ssh "${SSH_OPTS[@]}" "root@$1" \
		'uname -m 2>/dev/null; test -e /dev/sda36 && echo HAS_SDA36' 2>/dev/null)
	echo "$out" | grep -q aarch64 && echo "$out" | grep -q HAS_SDA36
}

hit() {
	mkdir -p "$(dirname "$CACHE")"
	echo "$1" >"$CACHE"
	log "$2 命中 $1"
	echo "FOUND $1"
	exit 0
}

by_mac() { # ARP 表里 MAC 对应的 IPv4（可能有多个，过滤掉 FAILED/INCOMPLETE）
	ip -4 neigh show 2>/dev/null | awk -v m="$MAC" 'tolower($0) ~ m && $NF != "FAILED" {print $1}'
}

# 1. 缓存
if [ -f "$CACHE" ]; then
	ip=$(cat "$CACHE")
	[ -n "$ip" ] && probe "$ip" && hit "$ip" "缓存"
fi

# 2. 现有 ARP 表
for ip in $(by_mac); do probe "$ip" && hit "$ip" "ARP"; done

# 3. 并发 ping 全网段，刷新 ARP 后再按 MAC 查
log "ping 扫 ${PREFIX}.0/24 刷新 ARP ..."
for i in $(seq 1 254); do
	ping -c1 -W1 "${PREFIX}.${i}" >/dev/null 2>&1 &
done
wait
for ip in $(by_mac); do probe "$ip" && hit "$ip" "MAC"; done

# 4. USB 串口
if [ -e "$SERIAL" ] && [ -f "$HERE/serial-cmd.py" ]; then
	log "问串口 $SERIAL ..."
	out=$(timeout 10 python3 "$HERE/serial-cmd.py" --dev "$SERIAL" --timeout 6 \
		"ip -4 -o addr show scope global | grep -v docker" 2>/dev/null)
	for ip in $(echo "$out" | grep -oE "inet ${PREFIX//./\\.}\.[0-9]+" | awk '{print $2}'); do
		probe "$ip" && hit "$ip" "串口"
	done
fi

# 5. 兜底：逐个 SSH 指纹
log "按 MAC 没找到，逐个试 SSH 指纹（慢）..."
alive=$(for i in $(seq 1 254); do
	ip="${PREFIX}.${i}"
	[ "$ip" = "$WIN_IP" ] && continue
	( ping -c1 -W1 "$ip" >/dev/null 2>&1 && echo "$ip" ) &
done; wait)
for ip in $alive; do probe "$ip" && hit "$ip" "SSH 指纹"; done
echo "NOT_FOUND"
exit 1
