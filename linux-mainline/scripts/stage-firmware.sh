#!/usr/bin/env bash
# Unpack dumped firmware into firmware/dagu/lib/firmware (gitignored blobs).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO="$(cd "$ROOT/.." && pwd)"
DEST="$ROOT/firmware/dagu"
LIB="$DEST/lib/firmware"
EXTRACT="$DEST/.extract"
DUMP_WL="$REPO/dumps/dagu-20260826-linux-bringup/wireless/blobs"
DUMP_FW="$REPO/dumps/dagu-20260826-linux-bringup/firmware"
GOLDEN_FW="$REPO/dumps/dagu-20260826-210700-root/firmware"
DSP="$LIB/qcom/sm8250/xiaomi/dagu"

mkdir -p "$LIB" "$EXTRACT" "$DSP"

WIFI_STAGED=0
if [[ -f "$LIB/ath11k/QCA6390/hw2.0/board.bin" ]]; then
	echo "wifi firmware already staged at $LIB"
	WIFI_STAGED=1
fi

unpack() {
	local tgz=$1
	[[ -f "$tgz" ]] || return 1
	tar -C "$EXTRACT" -xzf "$tgz"
}

if [[ "$WIFI_STAGED" -eq 0 ]]; then
	if unpack "$DUMP_WL/qca6390.tgz"; then
		echo "qca6390 OK"
	else
		echo "missing $DUMP_WL/qca6390.tgz (dumps/ is local-only)" >&2
	fi
	unpack "$DUMP_WL/bt-firmware.tgz" && echo "bt-firmware OK" || true
	unpack "$DUMP_WL/persist.tgz" && echo "persist cal OK" || true
	if unpack "$DUMP_WL/vendor-firmware.tgz"; then
		echo "vendor-firmware OK"
	elif unpack "$DUMP_FW/fw-linux.tgz"; then
		echo "fw-linux.tgz OK"
	fi
fi

copy_one() {
	local dest=$1
	shift
	local found
	found=$(find "$EXTRACT" -type f \( "$@" \) 2>/dev/null | head -1 || true)
	[[ -n "$found" ]] || return 1
	mkdir -p "$(dirname "$dest")"
	cp -f "$found" "$dest"
	echo "  $(basename "$dest") <- $found"
}

mkdir -p \
	"$LIB/ath11k/QCA6390/hw2.0" \
	"$LIB/qca" \
	"$DSP" \
	"$LIB/cirrus"

if [[ "$WIFI_STAGED" -eq 0 ]]; then
	# BDF: raw bd_l81a.elf as board.bin (not board-2.bin)
	copy_one "$LIB/ath11k/QCA6390/hw2.0/board.bin" -name 'bd_l81a.elf' || true
	copy_one "$LIB/ath11k/QCA6390/hw2.0/amss.bin" -name 'amss20.bin' || true
	copy_one "$LIB/ath11k/QCA6390/hw2.0/m3.bin" -name 'm3.bin' || true
	copy_one "$LIB/qca/htbtfw20.tlv" -name 'htbtfw20.tlv' || true
	copy_one "$LIB/qca/htnv20.bin" -name 'htnv20.bin' || true

	copy_one "$LIB/qcom/a650_gmu.bin" -name 'a650_gmu.bin' || true
	copy_one "$LIB/qcom/a650_sqe.fw" -name 'a650_sqe.fw' || true
	for f in a650_zap.mdt a650_zap.b00 a650_zap.b01 a650_zap.b02 a650_zap.elf; do
		copy_one "$DSP/$f" -name "$f" || true
	done
	if [[ -f "$DSP/a650_zap.mdt" && ! -f "$DSP/a650_zap.mbn" ]]; then
		cp -f "$DSP/a650_zap.mdt" "$DSP/a650_zap.mbn"
	fi

	find "$EXTRACT" -type f \( -name '*cs35l41*' -o -name 'TL-cs35l41*' -o -name 'TR-cs35l41*' \
		-o -name 'BL-cs35l41*' -o -name 'BR-cs35l41*' -o -name '*-music.txt' \
		-o -name '*-voice.txt' \) -exec cp -f {} "$LIB/cirrus/" \; 2>/dev/null || true
	# Mainline wm_adsp with cirrus,subsystem-id = "dagu":
	#   cs35l41-dsp1-spk-prot-dagu.wmfw + cs35l41-dsp1-spk-prot-dagu-{tl,tr,bl,br}.bin
	if [[ -f "$LIB/cirrus/cs35l41-dsp1-spk-prot.wmfw" ]]; then
		ln -sfn cs35l41-dsp1-spk-prot.wmfw "$LIB/cirrus/cs35l41-dsp1-spk-prot-dagu.wmfw"
	fi
	for p in tl tr bl br; do
		P=$(echo "$p" | tr '[:lower:]' '[:upper:]')
		src="$LIB/cirrus/${P}-cs35l41-dsp1-spk-prot.bin"
		[[ -f "$src" ]] && ln -sfn "${P}-cs35l41-dsp1-spk-prot.bin" \
			"$LIB/cirrus/cs35l41-dsp1-spk-prot-dagu-${p}.bin"
	done
	# Stock Android live dump: wmfw deltas + per-amp prot/cali bins.
	if [[ -d "$REPO/dumps/dagu-android-live/firmware/fw2" ]]; then
		cp -f "$REPO/dumps/dagu-android-live/firmware/fw2/"* "$LIB/cirrus/" 2>/dev/null || true
		echo "  cirrus <- dumps/dagu-android-live/firmware/fw2"
	fi

	copy_one "$DEST/wlan_mac.bin" -path '*/persist/wlan/wlan_mac.bin' || true
fi

# Remoteproc: on-device /vendor/firmware_mnt/image/{adsp,slpi,venus}.mdt
# DTS stays disabled until these blobs exist (missing firmware-name stalls ~60s).
stage_dsp() {
	local name=$1
	local dest_mbn="$DSP/${name}.mbn"
	[[ -f "$dest_mbn" ]] && { echo "  ${name} already staged"; return 0; }
	local found
	found=$(find "$EXTRACT" "$GOLDEN_FW" "$DUMP_FW" -type f \( -name "${name}.mdt" -o -name "${name}.mbn" \) 2>/dev/null | head -1 || true)
	if [[ -z "$found" ]]; then
		echo "  skip ${name}: no mdt/mbn in dumps (adb pull /vendor/firmware_mnt/image/${name}.mdt + .b*)"
		return 1
	fi
	local dir
	dir=$(dirname "$found")
	mkdir -p "$DSP"
	cp -f "$dir/${name}".mdt "$DSP/" 2>/dev/null || true
	cp -f "$dir/${name}".b* "$DSP/" 2>/dev/null || true
	if [[ "$found" == *.mbn ]]; then
		cp -f "$found" "$dest_mbn"
	elif [[ -f "$DSP/${name}.mdt" ]]; then
		cp -f "$DSP/${name}.mdt" "$dest_mbn"
	fi
	echo "  ${name} <- $found"
}

stage_dsp adsp || true
stage_dsp slpi || true
stage_dsp venus || true

# GENI SPI (Himax) needs QUPv3 SE firmware. Stock partition is already ELF.
QUPFW_SRC="$REPO/dumps/dagu-20260826-210700-root/images/qupfw_a.img"
QUPFW_DST="$DSP/qupv3fw.elf"
if [[ -f "$QUPFW_SRC" ]]; then
	mkdir -p "$DSP"
	cp -f "$QUPFW_SRC" "$QUPFW_DST"
	echo "  qupv3fw.elf <- $QUPFW_SRC"
else
	echo "  skip qupv3fw: missing $QUPFW_SRC"
fi

echo "==> $LIB"
find "$LIB" -type f | head -50
