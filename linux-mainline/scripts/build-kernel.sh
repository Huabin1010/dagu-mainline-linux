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

# Never inject PSCI SYSTEM_RESET into primary_entry (instant fastboot).
export DAGU_PRIMARY_ENTRY_PROBE="${DAGU_PRIMARY_ENTRY_PROBE:-0}"

"$ROOT/scripts/apply-dts.sh"
"$ROOT/scripts/apply-overlays.sh"
if grep -q 'dagu bringup: SMC-first primary_entry probe' "$KERNEL_SRC/arch/arm64/kernel/head.S"; then
	die "primary_entry still has the SYSTEM_RESET probe — kernel would bounce to fastboot"
fi

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
if [[ "${DAGU_USB:-1}" == 1 ]]; then
	echo "==> merge dagu-usb.fragment (HS g_serial UDC)"
	"$KERNEL_SRC/scripts/kconfig/merge_config.sh" -m -O "$KBUILD_OUTPUT" \
		"$KBUILD_OUTPUT/.config" "$ROOT/config/dagu-usb.fragment"
fi
# Last, so it can turn FB_SIMPLE back off after dagu-bringup.fragment set it.
if [[ "${DAGU_DISPLAY:-0}" == 1 ]]; then
	echo "==> merge dagu-display.fragment (DRM_MSM + L81A panel)"
	"$KERNEL_SRC/scripts/kconfig/merge_config.sh" -m -O "$KBUILD_OUTPUT" \
		"$KBUILD_OUTPUT/.config" "$ROOT/config/dagu-display.fragment"
fi
# After display: Kprobes + BTF for BCC/bpftrace. Needs pahole >= 1.22.
# Keep FUNCTION_TRACER off — a nop at every function perturbs 120 Hz DSC.
command -v pahole >/dev/null || die "pahole missing — apt install pahole (v1.22+ for CONFIG_DEBUG_INFO_BTF)"
echo "==> merge dagu-bpf.fragment (kprobes + BTF, no FUNCTION_TRACER)"
"$KERNEL_SRC/scripts/kconfig/merge_config.sh" -m -O "$KBUILD_OUTPUT" \
	"$KBUILD_OUTPUT/.config" "$ROOT/config/dagu-bpf.fragment"
make O="$KBUILD_OUTPUT" olddefconfig

# Do not embed QUP firmware and do not put firmware-name on &qupv3_id_0.
# uart6 loads stock qupv3fw.elf from its own firmware-name (SE RAM only).

cfg="$KBUILD_OUTPUT/.config"
need_y() {
	grep -q "^$1=y" "$cfg" || die "$1 is not =y after olddefconfig (fragment lost?)"
}
need_m() {
	grep -q "^$1=m" "$cfg" || die "$1 is not =m after olddefconfig (fragment lost?)"
}
need_y CONFIG_SM_GCC_8250
need_y CONFIG_ARM64_VA_BITS_39
need_y CONFIG_QCOM_WDT
need_y CONFIG_PSTORE_CONSOLE
need_y CONFIG_DETECT_HUNG_TASK
grep -qE '^CONFIG_BOOTPARAM_HUNG_TASK_PANIC=[1-9]' "$cfg" && \
	die "HUNG_TASK_PANIC still on — UFS D-state would panic the desktop"
if ! grep -q 'dagu: skip UFSHCD_CAP_CLK_SCALING' "$KERNEL_SRC/drivers/ufs/host/ufs-qcom.c"; then
	die "ufs-qcom.c still has CLK_SCALING — apply-overlays.sh missed the UFS patch"
fi
grep -q '^CONFIG_ARM64_VA_BITS_52=y' "$cfg" && die "VA_BITS_52 still on — Kryo 585 has no FEAT_LVA"
grep -q '^CONFIG_ARM64_VA_BITS_48=y' "$cfg" && die "VA_BITS_48 still on — dump 4.19 is VA_BITS_39 / 3-level"
grep -q '^CONFIG_KVM=y' "$cfg" && die "KVM still on — dump 4.19 has no hypervisor stub"
grep -q '^CONFIG_POWER_RESET_MSM=y' "$cfg" && die "POWER_RESET_MSM still on — would bounce to fastboot on panic"
need_y CONFIG_KPROBES
need_y CONFIG_KPROBE_EVENTS
need_y CONFIG_BPF_SYSCALL
need_y CONFIG_BPF_EVENTS
need_y CONFIG_DEBUG_INFO_BTF
need_y CONFIG_IKHEADERS
grep -q '^CONFIG_DEBUG_INFO_REDUCED=y' "$cfg" && \
	die "DEBUG_INFO_REDUCED still on — CONFIG_DEBUG_INFO_BTF depends on it being off"
grep -q '^CONFIG_FUNCTION_TRACER=y' "$cfg" && \
	die "FUNCTION_TRACER still on — would perturb 120 Hz DSC capture"
if [[ "${DAGU_DISPLAY:-0}" == 1 ]]; then
	need_y CONFIG_DRM_MSM
	need_y CONFIG_DRM_PANEL_XIAOMI_DAGU_L81A
	need_y CONFIG_DRM_FBDEV_EMULATION
	need_y CONFIG_SM_DISPCC_8250
	need_y CONFIG_PINCTRL_SM8250
	need_y CONFIG_REGULATOR_QCOM_REFGEN
	need_y CONFIG_SCSI_UFS_QCOM
	need_y CONFIG_PHY_QCOM_QMP_UFS
	grep -q '^CONFIG_SPI_QCOM_GENI=y' "$cfg" && \
		die "SPI_QCOM_GENI still on — GENI SPI hangs this QHEE"
	need_y CONFIG_SPI_GPIO
	need_y CONFIG_TOUCHSCREEN_HIMAX_DAGU
	need_y CONFIG_SM_GPUCC_8250
	need_y CONFIG_ARM_QCOM_CPUFREQ_HW
	need_y CONFIG_QCOM_TSENS
	need_y CONFIG_PCIE_QCOM
	need_y CONFIG_PHY_QCOM_QMP_PCIE
	need_y CONFIG_ATH11K_PCI
	need_y CONFIG_POWER_SEQUENCING_QCOM_WCN
	need_y CONFIG_SERIAL_QCOM_GENI
	need_y CONFIG_BT_HCIUART_QCA
	need_y CONFIG_BT_LE
	need_y CONFIG_BT_HIDP
	need_y CONFIG_UHID
	need_y CONFIG_HIDRAW
	need_y CONFIG_I2C_GPIO
	need_y CONFIG_SND_SOC_CS35L41_I2C
	need_y CONFIG_SND_SOC_SM8250
	need_y CONFIG_SND_SOC_WCD938X_SDW
	need_y CONFIG_PINCTRL_SM8250_LPASS_LPI
	need_y CONFIG_QCOM_Q6V5_PAS
	need_y CONFIG_QCOM_PD_MAPPER
	need_y CONFIG_QRTR_SMD
	need_y CONFIG_I2C_QCOM_CCI
	need_y CONFIG_VIDEO_QCOM_CAMSS
	need_m CONFIG_VIDEO_QCOM_VENUS
	need_y CONFIG_SM_VIDEOCC_8250
	need_y CONFIG_QCOM_MDT_LOADER
	need_y CONFIG_QCOM_SMEM
	need_y CONFIG_V4L2_MEM2MEM_DEV
	need_y CONFIG_VIDEOBUF2_DMA_CONTIG
	need_y CONFIG_V4L2_H264
	need_y CONFIG_V4L2_VP9
	need_y CONFIG_VIDEO_S5KJN1
	need_y CONFIG_VIDEO_IMX596_DAGU
	need_y CONFIG_UDMABUF
	need_m CONFIG_VIDEO_V4L2LOOPBACK_DAGU
	need_y CONFIG_SM_CAMCC_8250
	grep -q '^CONFIG_INTERCONNECT_QCOM_SM8250=y' "$cfg" && \
		die "INTERCONNECT_QCOM_SM8250 still on — BCM vote hangs this QHEE"
	if ! grep -q 'dagu: ICC video-mem stubbed' \
		"$KERNEL_SRC/drivers/media/platform/qcom/venus/core.c"; then
		die "venus core.c missing ICC stub — apply-overlays.sh missed the patch"
	fi
	need_y CONFIG_BATTERY_BQ27XXX_I2C
	need_y CONFIG_CHARGER_BQ2597X_DAGU
	need_y CONFIG_CHARGER_PM8150B_DAGU
	need_y CONFIG_CHARGER_P9418_DAGU
	need_y CONFIG_BATTERY_XIAOMI_DUAL_FG
	need_y CONFIG_TYPEC_QCOM_PMIC
	need_y CONFIG_TYPEC_TCPM
	need_y CONFIG_LEDS_QCOM_FLASH
	need_y CONFIG_REGULATOR_USERSPACE_CONSUMER
	need_y CONFIG_INPUT_PM8XXX_VIBRATOR
	need_y CONFIG_KEYBOARD_GPIO
	need_y CONFIG_USB_DWC3_DUAL_ROLE
	need_y CONFIG_USB_XHCI_HCD
	need_y CONFIG_USB_STORAGE
	need_y CONFIG_USB_HID
	need_y CONFIG_REGULATOR_QCOM_USB_VBUS
	grep -q '^CONFIG_I2C_QCOM_GENI=y' "$cfg" && \
		die "I2C_QCOM_GENI still on — GENI I2C hangs this QHEE like SPI"
	grep -q '^CONFIG_FB_SIMPLE=y' "$cfg" && \
		die "FB_SIMPLE still on — it would fight DRM fbdev over fbcon"
fi
if [[ "${DAGU_MINIMAL:-}" != 1 ]]; then
	need_y CONFIG_USB_CONFIGFS
	need_y CONFIG_USB_G_SERIAL
	need_y CONFIG_U_SERIAL_CONSOLE
	need_y CONFIG_USB_CONFIGFS_ACM
	need_y CONFIG_USB_U_SERIAL
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
	need_y CONFIG_FTRACE
	need_y CONFIG_SCHED_TRACER
	need_y CONFIG_TRACING
	need_y CONFIG_EVENT_TRACING
	grep -q '^CONFIG_FUNCTION_TRACER=y' "$cfg" && \
		die "FUNCTION_TRACER still on — would perturb 120 Hz DSC capture"
	need_y CONFIG_DRM_KMS_HELPER
	need_y CONFIG_DRM_MSM
	need_y CONFIG_DRM_PANEL_XIAOMI_DAGU_L81A
	grep -q '^CONFIG_POWER_RESET_SYSCON=y' "$cfg" && echo "note: POWER_RESET_SYSCON still on" >&2
	grep -q '^CONFIG_ARM_SBSA_WATCHDOG=y' "$cfg" && echo "note: ARM_SBSA_WATCHDOG still on" >&2
	need_y CONFIG_TOUCHSCREEN_HIMAX_DAGU
	need_y CONFIG_USB_PS5169_DAGU
	need_y CONFIG_KEYBOARD_NANOSIC_DAGU
	need_y CONFIG_HID_MULTITOUCH
	need_y CONFIG_CHARGER_BQ2597X_DAGU
	need_y CONFIG_CHARGER_PM8150B_DAGU
	need_y CONFIG_CHARGER_P9418_DAGU
	need_y CONFIG_BATTERY_XIAOMI_DUAL_FG
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
"${CROSS_COMPILE}readelf" -S "$KBUILD_OUTPUT/vmlinux" | grep -q ' \.BTF' \
	|| die "vmlinux has no .BTF — pahole failed; /sys/kernel/btf/vmlinux would be missing"

if [[ "${DAGU_DISPLAY:-0}" == 1 ]] && grep -q '^CONFIG_VIDEO_QCOM_VENUS=m' "$cfg"; then
	echo "==> venus modules (not autoloaded)"
	# Do not use make M= — that is the external-module path and breaks
	# in-tree linking. Build the three .ko as in-tree targets.
	[[ -f "$KBUILD_OUTPUT/vmlinux.symvers" ]] \
		|| die "vmlinux.symvers missing — Image.gz did not finish"
	cp -f "$KBUILD_OUTPUT/vmlinux.symvers" "$KBUILD_OUTPUT/Module.symvers"
	make O="$KBUILD_OUTPUT" -j"$JOBS" \
		drivers/media/platform/qcom/venus/venus-core.ko \
		drivers/media/platform/qcom/venus/venus-dec.ko \
		drivers/media/platform/qcom/venus/venus-enc.ko
	mkdir -p "$OUT/modules/venus"
	cp -f "$KBUILD_OUTPUT/drivers/media/platform/qcom/venus/"venus-*.ko \
		"$OUT/modules/venus/"
	for ko in \
		"$KBUILD_OUTPUT/drivers/media/common/videobuf2/videobuf2-dma-contig.ko" \
		"$KBUILD_OUTPUT/drivers/media/v4l2-core/v4l2-mem2mem.ko"
	do
		[[ -f "$ko" ]] && cp -f "$ko" "$OUT/modules/venus/"
	done
	ls -lh "$OUT/modules/venus"
	[[ -f "$OUT/modules/venus/venus-core.ko" ]] || die "venus-core.ko missing"
fi

cp -f "$KBUILD_OUTPUT/arch/arm64/boot/Image.gz" "$OUT/Image.gz"
cp -f "$KBUILD_OUTPUT/arch/arm64/boot/dts/qcom/$DTB_NAME" "$OUT/$DTB_NAME"

echo "==> done"
ls -lh "$OUT/Image.gz" "$OUT/$DTB_NAME"
