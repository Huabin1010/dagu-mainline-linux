#!/system/bin/sh
# Front preview must already stream. Loads the read-only samplers once
# each and prints their lines. Usage: top.sh <dir with .ko> [full]
D=${1:-/data/local/tmp}
pid=$(pidof android.hardware.camera.provider@2.4-service_64)
n=$(grep -c dmabuf /proc/$pid/maps)
echo "dmabuf=$n"
[ "$n" -lt 20 ] && { echo "front preview is not streaming"; exit 1; }
b=$(grep " GICv3 499 " /proc/interrupts)
sleep 1
a=$(grep " GICv3 499 " /proc/interrupts)
[ "$a" = "$b" ] && { echo "IFE1 is not taking interrupts"; exit 1; }
echo "irq499 before: $b"
echo "irq499 after:  $a"
m="dagu mark $$-$RANDOM"
echo "$m" > /dev/kmsg
insmod $D/dagu_ife_top.ko; echo "insmod top=$?"
rmmod dagu_ife_top
if [ "$2" = full ]; then
	insmod $D/dagu_ife_full.ko; echo "insmod full=$?"
	rmmod dagu_ife_full
fi
dmesg | sed -n "/$m/,\$p" | grep -E "dagu (top|full)"
grep " GICv3 499 " /proc/interrupts
