#!/usr/bin/env bash
# Shallow-clone Linux. Source is gitignored (same as Kernel-Build).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/env.sh
source "$ROOT/scripts/env.sh"

TAG="${KERNEL_TAG:-v7.0}"

if [[ -d "$KERNEL_SRC/.git" ]]; then
	echo "kernel already at $KERNEL_SRC"
	git -C "$KERNEL_SRC" describe --tags --always
	exit 0
fi

echo "==> clone Linux $TAG (shallow)"
git clone --depth 1 --branch "$TAG" \
	https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git \
	"$KERNEL_SRC"

echo "==> upstream already has elish/pipa; dagu is added by apply-dts.sh"
ls -l "$KERNEL_SRC/arch/arm64/boot/dts/qcom/sm8250-xiaomi-"* || true
