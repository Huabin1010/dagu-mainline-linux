#!/usr/bin/env bash
# Runs ON THE TABLET as root. One-shot WinPE in QEMU that repairs the
# Windows volume after the 2026-11-11 qcdx 0xA with Windows' own NTFS and
# reg.exe (no ntfs-3g writes), sets QCDX Start=4 and drops the new package
# into C:\dagu-gpu. See tools/winarm/winpe/fix-qcdx-startnet.cmd.
set -euo pipefail
SRC=/root/fix-1111
W=/root/fixpe
export T=$W IMG=$W/winpe.img SIZE=700M

for m in /mnt/w /mnt/esp /mnt/woa-pe; do
	if mountpoint -q "$m"; then
		systemctl stop "$(systemd-escape -p --suffix=mount "$m")" 2>/dev/null || umount "$m"
	fi
done
! grep -qE '^/dev/sda3[56] ' /proc/mounts

rm -rf "$W"; mkdir -p "$W"
cp -al /root/woa/pe "$W/pe"
rm "$W/pe/sources/boot.wim"
cp /root/woa/pe/sources/boot.wim "$W/pe/sources/boot.wim"
wimlib-imagex update "$W/pe/sources/boot.wim" 1 \
	--command "add $SRC/startnet.cmd /Windows/System32/startnet.cmd" >/dev/null
want=$(md5sum <"$SRC/startnet.cmd")
got=$(wimextract "$W/pe/sources/boot.wim" 1 /Windows/System32/startnet.cmd --to-stdout | md5sum)
[ "$want" = "$got" ] || { echo "boot.wim startnet mismatch" >&2; exit 1; }

bash "$SRC/build-media.sh" create
cp -r "$SRC/pkg" /mnt/woa-pe/woa/pkg
: >/mnt/woa-pe/woa/fixqcdx
bash "$SRC/build-media.sh" umount

cp /root/woa/run-qemu-deploy.sh "$W/run-qemu-deploy.sh"
cp "$SRC/build-media.sh" "$W/build-media.sh"
cd "$W"
bash ./run-qemu-deploy.sh >"$W/run.log" 2>&1 || echo "run-qemu-deploy rc=$?" >>"$W/run.log"

bash "$SRC/build-media.sh" mount
cp /mnt/woa-pe/woa/fix.log "$W/fix.log" 2>/dev/null || echo "no fix.log" >"$W/fix.log"
bash "$SRC/build-media.sh" umount
echo FIXPE_DONE >>"$W/run.log"
