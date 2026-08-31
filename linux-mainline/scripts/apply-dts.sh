#!/usr/bin/env bash
# Copy dagu DTS into the kernel tree and register it in the qcom Makefile.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/env.sh
source "$ROOT/scripts/env.sh"

DTS_DIR="$KERNEL_SRC/arch/arm64/boot/dts/qcom"
MAKEFILE="$DTS_DIR/Makefile"
SRC="$ROOT/dts/sm8250-xiaomi-dagu.dts"

[[ -f "$SRC" ]] || { echo "missing $SRC" >&2; exit 1; }
[[ -d "$DTS_DIR" ]] || { echo "run setup-kernel.sh first" >&2; exit 1; }

cp -f "$SRC" "$DTS_DIR/sm8250-xiaomi-dagu.dts"

if ! grep -q 'sm8250-xiaomi-dagu.dtb' "$MAKEFILE"; then
	# Keep next to the other SM8250 Xiaomi tablets.
	if grep -q 'sm8250-xiaomi-pipa.dtb' "$MAKEFILE"; then
		sed -i '/sm8250-xiaomi-pipa.dtb/a dtb-$(CONFIG_ARCH_QCOM)\t+= sm8250-xiaomi-dagu.dtb' \
			"$MAKEFILE"
	else
		echo 'dtb-$(CONFIG_ARCH_QCOM)	+= sm8250-xiaomi-dagu.dtb' >>"$MAKEFILE"
	fi
fi

# ABL applies DTBO via phandle __fixups__. Stock CAF DTB is built with -@;
# mainline qcom dtbs are not, so overlay apply Load Errors (~3s fastboot).
if ! grep -q 'DTC_FLAGS_sm8250-xiaomi-dagu' "$MAKEFILE"; then
	echo 'DTC_FLAGS_sm8250-xiaomi-dagu := -@' >>"$MAKEFILE"
fi

echo "==> installed $DTS_DIR/sm8250-xiaomi-dagu.dts"
grep 'sm8250-xiaomi-dagu' "$MAKEFILE"
