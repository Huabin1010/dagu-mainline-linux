#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/env.sh
source "$ROOT/scripts/env.sh"

JOBS="${JOBS:-$(nproc)}"
FRAGMENT="$ROOT/config/dagu.fragment"
OUT="$ROOT/out"

die() { echo "error: $*" >&2; exit 1; }

[[ -d "$KERNEL_SRC" ]] || die "run scripts/setup-kernel.sh"
command -v "${CROSS_COMPILE}gcc" >/dev/null || die "run scripts/setup-deps.sh"

"$ROOT/scripts/apply-dts.sh"
"$ROOT/scripts/apply-overlays.sh"

mkdir -p "$KBUILD_OUTPUT" "$OUT"
cd "$KERNEL_SRC"

if [[ ! -f "$KBUILD_OUTPUT/.config" ]]; then
	echo "==> defconfig"
	make O="$KBUILD_OUTPUT" defconfig
fi

echo "==> merge dagu.fragment"
"$KERNEL_SRC/scripts/kconfig/merge_config.sh" -m -O "$KBUILD_OUTPUT" \
	"$KBUILD_OUTPUT/.config" "$FRAGMENT"
if [[ "${DAGU_MINIMAL:-}" == 1 ]]; then
	echo "==> merge dagu-bringup.fragment (PID1 / no peripherals)"
	"$KERNEL_SRC/scripts/kconfig/merge_config.sh" -m -O "$KBUILD_OUTPUT" \
		"$KBUILD_OUTPUT/.config" "$ROOT/config/dagu-bringup.fragment"
fi
make O="$KBUILD_OUTPUT" olddefconfig

cfg="$KBUILD_OUTPUT/.config"
need_y() {
	grep -q "^$1=y" "$cfg" || die "$1 is not =y after olddefconfig (fragment lost?)"
}
need_y CONFIG_SM_GCC_8250
need_y CONFIG_ARM64_VA_BITS_39
need_y CONFIG_QCOM_WDT
need_y CONFIG_PSTORE_CONSOLE
grep -q '^CONFIG_ARM64_VA_BITS_52=y' "$cfg" && die "VA_BITS_52 still on — Kryo 585 has no FEAT_LVA"
grep -q '^CONFIG_ARM64_VA_BITS_48=y' "$cfg" && die "VA_BITS_48 still on — dump 4.19 is VA_BITS_39 / 3-level"
grep -q '^CONFIG_KVM=y' "$cfg" && die "KVM still on — dump 4.19 has no hypervisor stub"
grep -q '^CONFIG_POWER_RESET_MSM=y' "$cfg" && die "POWER_RESET_MSM still on — would bounce to fastboot on panic"
if [[ "${DAGU_MINIMAL:-}" != 1 ]]; then
	need_y CONFIG_USB_CONFIGFS
	need_y CONFIG_SCSI_UFS_QCOM
	need_y CONFIG_PHY_QCOM_QUSB2
	need_y CONFIG_PHY_QCOM_USB_SNPS_FEMTO_V2
	need_y CONFIG_PHY_QCOM_QMP_UFS
	grep -q '^CONFIG_FB_SIMPLE=y' "$cfg" && die "FB_SIMPLE still on — splash @ 0x9c000000 never showed"
	grep -q '^CONFIG_DRM_SIMPLEDRM=y' "$cfg" && die "DRM_SIMPLEDRM still on — splash path is dead"
	need_y CONFIG_TYPEC_QCOM_PMIC
	need_y CONFIG_TYPEC_TCPM
	need_y CONFIG_POWER_RESET_QCOM_PON
	need_y CONFIG_USB_DWC3
	need_y CONFIG_USB_DWC3_QCOM
	grep -q '^CONFIG_WATCHDOG_HANDLE_BOOT_ENABLED=y' "$cfg" && \
		die "WATCHDOG_HANDLE_BOOT_ENABLED still on — kernel would pet WDT forever"
	need_y CONFIG_DRM
	need_y CONFIG_DRM_KMS_HELPER
	need_y CONFIG_DRM_MSM
	need_y CONFIG_DRM_PANEL_XIAOMI_DAGU_L81A
	grep -q '^CONFIG_POWER_RESET_SYSCON=y' "$cfg" && echo "note: POWER_RESET_SYSCON still on" >&2
	grep -q '^CONFIG_ARM_SBSA_WATCHDOG=y' "$cfg" && echo "note: ARM_SBSA_WATCHDOG still on" >&2
	need_y CONFIG_TOUCHSCREEN_HIMAX_DAGU
	need_y CONFIG_USB_PS5169_DAGU
	need_y CONFIG_KEYBOARD_NANOSIC_DAGU
	need_y CONFIG_CHARGER_BQ2597X_DAGU
	need_y CONFIG_CHARGER_P9418_DAGU
	need_y CONFIG_PHY_QCOM_QMP_COMBO
	need_y CONFIG_CFG80211
	need_y CONFIG_ATH11K_PCI
	need_y CONFIG_BATTERY_BQ27XXX_I2C
	need_y CONFIG_ARM_QCOM_CPUFREQ_HW
	need_y CONFIG_QCOM_TSENS
	need_y CONFIG_SND_SOC_CS35L41_I2C
fi

echo "==> Image.gz + $DTB_NAME ($JOBS jobs)"
make O="$KBUILD_OUTPUT" -j"$JOBS" Image.gz dtbs

test -f "$KBUILD_OUTPUT/arch/arm64/boot/dts/qcom/$DTB_NAME" \
	|| die "dtb not built — apply-dts.sh / Makefile?"

cp -f "$KBUILD_OUTPUT/arch/arm64/boot/Image.gz" "$OUT/Image.gz"
cp -f "$KBUILD_OUTPUT/arch/arm64/boot/dts/qcom/$DTB_NAME" "$OUT/$DTB_NAME"

echo "==> done"
ls -lh "$OUT/Image.gz" "$OUT/$DTB_NAME"
