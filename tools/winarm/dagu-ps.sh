#!/usr/bin/env bash
# 在 dagu 的 Windows 上执行一段 PowerShell，避开 ssh 和 PowerShell 的双重引号问题。
# 用法：dagu-ps.sh '<PowerShell 脚本>'      或者   dagu-ps.sh - < script.ps1
# 脚本转成 UTF-16LE 后用 -EncodedCommand 传过去。ssh 断线（返回 255）时自动重试。
# 环境变量：DAGU_HOST（默认 dagu@192.168.1.250），SSH_AUTH_SOCK（默认 /tmp/dagu-agent.sock）。
set -u
export SSH_AUTH_SOCK="${SSH_AUTH_SOCK:-/tmp/dagu-agent.sock}"
HOST="${DAGU_HOST:-dagu@192.168.1.250}"
s="${1:?usage: dagu-ps.sh '<powershell>' | -}"
[ "$s" = - ] && s="$(cat)"
enc=$(printf '%s' "$s" | iconv -f utf-8 -t utf-16le | base64 -w0)
for i in 1 2 3 4 5 6 7 8; do
	ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
		-o ConnectTimeout=40 -o KexAlgorithms=curve25519-sha256 -o ServerAliveInterval=15 \
		"$HOST" "powershell -NoProfile -NonInteractive -EncodedCommand $enc" && exit 0
	rc=$?
	[ $rc -ne 255 ] && exit $rc
	echo "[ssh retry $i]" >&2
	sleep 3
done
exit 255
