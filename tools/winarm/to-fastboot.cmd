@echo off
rem dagu: reboot Windows straight into fastboot (bootloader).
rem Run as Administrator. Drops a flag on the ESP that DaguPlatDxe sees on the
rem next boot (as each filesystem mounts) and cold-resets into fastboot.
mountvol S: /S
break > S:\dagu-fastboot
mountvol S: /D
echo Rebooting into fastboot...
shutdown /r /t 0
