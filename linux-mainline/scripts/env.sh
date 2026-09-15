#!/usr/bin/env bash
# Source before building: source scripts/env.sh
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

export ARCH=arm64
export CROSS_COMPILE="${CROSS_COMPILE:-aarch64-linux-gnu-}"
export KBUILD_OUTPUT="${KBUILD_OUTPUT:-$ROOT/out/kernel}"
export KERNEL_SRC="${KERNEL_SRC:-$ROOT/linux}"
export DTB_NAME="${DTB_NAME:-sm8250-xiaomi-dagu.dtb}"
export KERNEL_TAG="${KERNEL_TAG:-v7.0}"
export PATH="$HOME/.local/bin:$PATH"
