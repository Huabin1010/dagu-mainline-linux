#!/usr/bin/env bash
# Host packages for kernel + boot.img + arm64 rootfs.
set -euo pipefail

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
	exec sudo "$0" "$@"
fi

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y \
	gcc-aarch64-linux-gnu bc bison flex libssl-dev libelf-dev pahole \
	device-tree-compiler cpio gzip python3 mkbootimg \
	debootstrap e2fsprogs openssh-client autoconf \
	qemu-user qemu-user-binfmt || true
apt-get install -y qemu-user-hwe qemu-user-binfmt-hwe || true

echo "OK: aarch64-linux-gnu-gcc --version"
aarch64-linux-gnu-gcc --version | head -1
