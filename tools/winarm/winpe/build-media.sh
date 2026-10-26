#!/usr/bin/env bash
# Runs ON THE TABLET. Builds the WinPE media disk image used by
# run-qemu-deploy.sh: GPT + one FAT32 partition "WINPE" (edk2 maps no
# filesystem on a bare superfloppy FAT image; type 0700, not EF00: Windows
# never gives an ESP a drive letter, and edk2 boots any FAT on removable media)
# holding
#   \efi, \boot\boot.sdi, \sources\boot.wim   (from $T/pe, ISO + our startnet)
#   \woa\install.wim, \woa\drivers, \woa\unattend.xml
#
#   build-media.sh create   # make + mount at /mnt/woa-pe, copy $T/pe/*
#   build-media.sh mount | umount
set -euo pipefail
T="${T:-/root/woa}" IMG="${IMG:-/root/woa/winpe.img}" MNT=/mnt/woa-pe
SIZE="${SIZE:-4800M}"
attach() { losetup -j "$IMG" | cut -d: -f1 | head -1; }
case "${1:-}" in
create)
	umount "$MNT" 2>/dev/null || true
	for l in $(losetup -j "$IMG" | cut -d: -f1); do losetup -d "$l"; done
	rm -f "$IMG"; truncate -s "$SIZE" "$IMG"
	sgdisk -o -n 1:2048:0 -t 1:0700 -c 1:WINPE "$IMG" >/dev/null
	lo=$(losetup -P -f --show "$IMG")
	mkfs.vfat -F 32 -n WINPE "${lo}p1" >/dev/null
	mkdir -p "$MNT"; mount -t vfat "${lo}p1" "$MNT"
	cp -r "$T/pe/." "$MNT/"; mkdir -p "$MNT/woa"
	df -h "$MNT" | tail -1
	;;
mount)
	lo=$(attach); [ -n "$lo" ] || lo=$(losetup -P -f --show "$IMG")
	mkdir -p "$MNT"; mountpoint -q "$MNT" || mount -t vfat "${lo}p1" "$MNT"
	;;
umount)
	sync; umount "$MNT" 2>/dev/null || true
	for l in $(losetup -j "$IMG" | cut -d: -f1); do losetup -d "$l"; done
	;;
*) echo "usage: $0 {create|mount|umount}"; exit 1;;
esac
