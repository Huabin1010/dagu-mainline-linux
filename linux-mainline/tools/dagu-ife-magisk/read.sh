#!/system/bin/sh
# Load only while the front preview is streaming. The IFE clock is
# off when the camera is idle, and a register read then can stall.
pid=$(pidof android.hardware.camera.provider@2.4-service_64)
n=$(grep -c dmabuf /proc/$pid/maps)
echo "dmabuf=$n"
if [ "$n" -lt 20 ]; then
	echo "front preview is not streaming"
	exit 1
fi
before=$(grep " GICv3 499 " /proc/interrupts)
sleep 1
after=$(grep " GICv3 499 " /proc/interrupts)
echo "ife1 irq"
echo "$before"
echo "$after"
if [ "$after" = "$before" ]; then
	echo "IFE1 is not taking interrupts"
	exit 1
fi
insmod /data/adb/modules/dagu_ife_rd/dagu_ife_rd.ko
echo "insmod=$?"
dmesg | grep "dagu ife1" | tail -4
rmmod dagu_ife_rd
echo "rmmod=$?"
