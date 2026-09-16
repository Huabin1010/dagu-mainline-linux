#!/usr/bin/env bash
# Copy dagu DTS into the kernel tree and register it in the qcom Makefile.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/env.sh
source "$ROOT/scripts/env.sh"

DTS_DIR="$KERNEL_SRC/arch/arm64/boot/dts/qcom"
MAKEFILE="$DTS_DIR/Makefile"
SRC="$ROOT/dts/sm8250-xiaomi-dagu.dts"
STOCK_RM="$ROOT/dts/dagu-reserved-memory-stock.dtsi"
LOCAL_ADDR="$ROOT/dts/local-addresses.dtsi"
LOCAL_EXAMPLE="$ROOT/dts/local-addresses.dtsi.example"

[[ -f "$SRC" ]] || { echo "missing $SRC" >&2; exit 1; }
[[ -f "$STOCK_RM" ]] || { echo "missing $STOCK_RM" >&2; exit 1; }
[[ -d "$DTS_DIR" ]] || { echo "run setup-kernel.sh first" >&2; exit 1; }

if [[ ! -f "$LOCAL_ADDR" ]]; then
	[[ -f "$LOCAL_EXAMPLE" ]] || { echo "missing $LOCAL_EXAMPLE" >&2; exit 1; }
	cp -f "$LOCAL_EXAMPLE" "$LOCAL_ADDR"
	echo "==> created $LOCAL_ADDR from example (fill persist MAC locally; do not commit)"
fi

cp -f "$SRC" "$DTS_DIR/sm8250-xiaomi-dagu.dts"
cp -f "$STOCK_RM" "$DTS_DIR/dagu-reserved-memory-stock.dtsi"
cp -f "$LOCAL_ADDR" "$DTS_DIR/local-addresses.dtsi"

# Product DTS includes these names. CS35L41 SE1/SE3, BQ27Z561 SE0/SE13,
# KTZ8866 SE11/SE9, Nanosic SE2, BQ25970 SE15/SE16, Himax SPI SE4:
# per-SE IRAM + skip-wrapper, never wrapper CSR / ICC / GPI. Empty stubs
# stay in-tree for restore-a gpio fallback; they are not the build.
copy_geni_on() {
	local on="$1" dest="$2"
	[[ -f "$on" ]] || { echo "missing $on" >&2; exit 1; }
	grep -q 'qcom,skip-wrapper-fw-init' "$on" || {
		echo "$on missing skip-wrapper-fw-init" >&2
		exit 1
	}
	grep -q 'firmware-name' "$on" || {
		echo "$on missing SE firmware-name" >&2
		exit 1
	}
	cp -f "$on" "$dest"
	echo "==> GENI product DT $dest"
}

copy_geni_on "$ROOT/dts/dagu-geni-i2c-experiment.on.dtsi" \
	"$DTS_DIR/dagu-geni-i2c-experiment.dtsi"
copy_geni_on "$ROOT/dts/dagu-geni-spi-experiment.on.dtsi" \
	"$DTS_DIR/dagu-geni-spi-experiment.dtsi"

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
