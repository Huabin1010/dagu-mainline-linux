#!/usr/bin/env bash
# Deploy Windows 11 ARM64 onto dagu's UFS from the tablet's own Linux.
#
# No Windows PC is involved: every step that touches the Windows partitions
# runs in WinPE inside QEMU (TCG) on the tablet, with Windows' own tools
# (diskpart format, DISM /Apply-Image, DISM /Add-Driver, bcdboot). QEMU sees
# the real UFS LUN0 through nbdkit with the protect filter, so only the esp and
# win partitions are writable and the BCD references the real disk/partition
# GUIDs.
#
# Do NOT prepare the NTFS with mkntfs + wimlib from Linux: Windows later
# allocated clusters that wimlib had already used (DISM's hive writes landed
# inside OSProvider.dll and ~500 other files).
#
# Prerequisites (see docs/woa-dagu-kona-port.md):
#   - LUN0 partitions sda35 "esp" and sda36 "win" (userdata shrunk to 48 GiB)
#   - winarm/out/iso/ extracted from the Win11 ARM64 ISO
#   - winarm/drivers/windows_qcom_platforms (+ components/QC8250 submodule)
#   - a root shell on the tablet: SSH (DAGU_HOST), or set TCMD to a command
#     that runs its argument on the tablet (e.g. tools/winarm/serial-cmd.py
#     over the USB console) and TPUSH to "cmd LOCAL REMOTE" for file copies.
#
#   tools/winarm/deploy-windows.sh media    # WinPE + install.wim + drivers
#   tools/winarm/deploy-windows.sh run      # QEMU WinPE deploy
#   tools/winarm/deploy-windows.sh log      # print \woa\deploy.log
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
W="$ROOT/winarm" ISO="$ROOT/winarm/out/iso" PE="$ROOT/tools/winarm/winpe"
QCP="$W/drivers/windows_qcom_platforms"
DEF="$QCP/definitions/Desktop/ARM64/Internal/mtp865.xml"
HOST="${DAGU_HOST:-192.168.1.158}" SSHK="$ROOT/linux-mainline/out/id_dagu"
WIMBIN="$ROOT/tools/downloads/win11-arm64/.bin/root/usr"
T=/root/woa
ssh_t() { ssh -i "$SSHK" -o IdentitiesOnly=yes -o StrictHostKeyChecking=no \
	-o UserKnownHostsFile=/dev/null -o LogLevel=ERROR root@"$HOST" "$@"; }
tcmd() { if [ -n "${TCMD:-}" ]; then $TCMD "$*"; else ssh_t "$*"; fi; }
tpush() { if [ -n "${TPUSH:-}" ]; then $TPUSH "$1" "$2"; else ssh_t "cat > '$2'" <"$1"; fi; }
wimlib() { LD_LIBRARY_PATH="$WIMBIN/lib/x86_64-linux-gnu" "$WIMBIN/bin/wimlib-imagex" "$@"; }

stage_drivers() {
	# Driver set = the maintainers' MTP865 definition (their tested Kona set).
	python3 - "$QCP" "$DEF" "$1/drivers" <<'PY'
import os, re, shutil, sys
root, xml, dst = sys.argv[1], open(sys.argv[2], encoding="utf-8").read(), sys.argv[3]
n = 0
for path, name in re.findall(r'Path="\$\(mspackageroot\)\\([^"]+)" Name="([^"]+)"', xml):
    src = os.path.join(root, path.replace("\\", "/"))
    if not os.path.isfile(os.path.join(src, name)):
        alt = src.replace("/components/QC8150/", "/components/QC8250/")  # upstream typo
        if not os.path.isfile(os.path.join(alt, name)):
            print("skip (not in BSP):", path, name); continue
        src = alt
    shutil.copytree(src, os.path.join(dst, os.path.relpath(src, root)), dirs_exist_ok=True)
    n += 1
print(n, "driver packages staged")
PY
	# OOBE: local admin "dagu", no online-account/network pages.
	sed 's/>Kona</>dagu</g' "$QCP/components/Devices/Kona/Setup/DesktopSetup/Unattend.xml" \
		>"$1/unattend.xml"
}

cmd_media() {
	local s; s="$(mktemp -d)"
	# WinPE = boot.wim index 1 + our startnet.cmd (CRLF for cmd.exe)
	sed 's/\r*$/\r/' "$PE/startnet.cmd" >"$s/startnet.cmd"
	wimlib export "$ISO/sources/boot.wim" 1 "$s/boot.wim" --boot >/dev/null
	printf 'add %s /Windows/System32/startnet.cmd\n' "$s/startnet.cmd" | wimlib update "$s/boot.wim" 1 >/dev/null
	mkdir -p "$s/pe/sources" "$s/pe/boot"; cp -r "$ISO/efi" "$s/pe/"
	cp "$ISO/boot/boot.sdi" "$s/pe/boot/"; mv "$s/boot.wim" "$s/pe/sources/"
	stage_drivers "$s"
	tar -C "$s" -cf "$s/pe.tar" pe; tar -C "$s" -cJf "$s/woa.tar.xz" drivers unattend.xml
	tcmd "mkdir -p $T"
	for f in build-media.sh run-qemu-deploy.sh qemu-shot.py; do tpush "$PE/$f" "$T/$f"; done
	tpush "$s/pe.tar" "$T/pe.tar"; tpush "$s/woa.tar.xz" "$T/woa.tar.xz"
	tcmd "cd $T && chmod +x *.sh *.py && rm -rf pe && tar -xf pe.tar && rm pe.tar && ./build-media.sh create && tar -C /mnt/woa-pe/woa --no-same-owner -xJf woa.tar.xz && rm woa.tar.xz"
	tpush "$ISO/sources/install.wim" /mnt/woa-pe/woa/install.wim
	tcmd "$T/build-media.sh umount"
	rm -rf "$s"
}

cmd_run() {
	tcmd "systemctl reset-failed woa-deploy 2>/dev/null; systemd-run --unit=woa-deploy \
	  --property=StandardOutput=truncate:$T/run.log --property=StandardError=append:$T/run.log \
	  $T/run-qemu-deploy.sh"
	echo "[run] started; QEMU TCG takes ~70 min (apply ~50, drivers ~8). Poll with:"
	echo "      tcmd 'systemctl is-active woa-deploy; tail -1 $T/run.log'"
}

cmd_log() {
	tcmd "$T/build-media.sh mount && iconv -f GBK -t UTF-8 /mnt/woa-pe/woa/deploy.log | tr -d '\r'; $T/build-media.sh umount"
}

case "${1:-}" in
	media) cmd_media;; run) cmd_run;; log) cmd_log;;
	*) echo "usage: $0 {media|run|log}"; exit 1;;
esac
