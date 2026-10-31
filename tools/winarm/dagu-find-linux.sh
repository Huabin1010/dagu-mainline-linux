#!/usr/bin/env bash
# 挂死后 B 槽 Linux 会用新的 DHCP 地址上线。救援脚本默认只认死 IP，一旦地址变了
# 就找不到。本脚本扫整个 /24，对每个响应的主机尝试用 root/dagu 登录并验证平板
# Linux 指纹（存在 /mnt 预期结构 + uname 含 aarch64），命中即打印地址。
#
# 用法: dagu-find-linux.sh [网段前缀]   默认 192.168.1
#   成功: 打印 "FOUND <ip>" 并退出 0
#   失败: 打印 "NOT_FOUND" 并退出 1
set -u
PREFIX="${1:-192.168.1}"
PW="${LINUX_PW:-dagu}"
WIN_IP="${WIN_IP:-192.168.1.250}"
SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
          -o LogLevel=ERROR -o ConnectTimeout=3 -o PreferredAuthentications=password
          -o PubkeyAuthentication=no)

probe() { # 判断某 IP 是不是平板 Linux
	local ip="$1"
	local out
	out=$(sshpass -p "$PW" ssh "${SSH_OPTS[@]}" "root@$ip" \
		'uname -m 2>/dev/null; test -e /dev/sda36 && echo HAS_SDA36' 2>/dev/null)
	echo "$out" | grep -q aarch64 && echo "$out" | grep -q HAS_SDA36
}

# 先 ping 扫一遍，收集活跃主机（并行），再逐个 SSH 指纹校验
echo "[find-linux] 扫描 ${PREFIX}.0/24 ..." >&2
alive=()
for i in $(seq 1 254); do
	ip="${PREFIX}.${i}"
	[ "$ip" = "$WIN_IP" ] && continue
	( ping -c1 -W1 "$ip" >/dev/null 2>&1 && echo "$ip" ) &
	# 限制并发
	if (( i % 64 == 0 )); then wait; fi
done >/tmp/dagu-alive.$$ 2>/dev/null
wait
mapfile -t alive </tmp/dagu-alive.$$; rm -f /tmp/dagu-alive.$$
echo "[find-linux] 活跃主机 ${#alive[@]} 个，逐个校验 SSH 指纹..." >&2
for ip in "${alive[@]}"; do
	if probe "$ip"; then
		echo "FOUND $ip"
		exit 0
	fi
done
echo "NOT_FOUND"
exit 1
