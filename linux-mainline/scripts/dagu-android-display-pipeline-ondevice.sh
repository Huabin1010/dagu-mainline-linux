#!/system/bin/sh
# Runs on the Android extract tablet as root. Write-only under /data/local/tmp.
set -e
OUT=/data/local/tmp/dagu-disp-pipeline
rm -rf "$OUT"
mkdir -p "$OUT/prop" "$OUT/sys" "$OUT/dt" "$OUT/proc"

getprop >"$OUT/prop/getprop.txt"
getprop | grep -iE 'surface_flinger|debug\.sf|vendor\.display|persist\.vendor\.display|debug\.mdp|hwc|vsync|refresh|qdcm|composer|idle|kickoff|prefill|qos|sf\.|displayfeature' \
	>"$OUT/prop/display-getprop.txt" || true

echo "=== DSI-1 ===" >"$OUT/sys/dsi1.txt"
for f in panel_info hw_vsync_info dynamic_fps smart_fps_value disp_param disp_count \
	complete_commit_time doze_brightness modes enabled dpms status \
	disp_pcc fod_ui_ready oled_pmic_id wp_info thermal_hbm_disabled
do
	echo "----- $f -----" >>"$OUT/sys/dsi1.txt"
	cat "/sys/class/drm/card0-DSI-1/$f" >>"$OUT/sys/dsi1.txt" 2>/dev/null || echo "(unreadable)" >>"$OUT/sys/dsi1.txt"
	echo >>"$OUT/sys/dsi1.txt"
done

echo "=== sde-crtc-0 ===" >"$OUT/sys/crtc0.txt"
for f in fps_periodicity_ms measured_fps vsync_event retire_frame_event
do
	echo "----- $f -----" >>"$OUT/sys/crtc0.txt"
	cat "/sys/class/drm/sde-crtc-0/$f" >>"$OUT/sys/crtc0.txt" 2>/dev/null || true
	echo >>"$OUT/sys/crtc0.txt"
done

echo "=== drm connectors ===" >"$OUT/sys/drm-ls.txt"
ls -l /sys/class/drm >>"$OUT/sys/drm-ls.txt" 2>/dev/null || true

echo "=== msm_drm parameters ===" >"$OUT/sys/msm_drm-params.txt"
for f in /sys/module/msm_drm/parameters/*
do
	echo "----- $f -----" >>"$OUT/sys/msm_drm-params.txt"
	cat "$f" >>"$OUT/sys/msm_drm-params.txt" 2>/dev/null || echo "(denied)" >>"$OUT/sys/msm_drm-params.txt"
	echo >>"$OUT/sys/msm_drm-params.txt"
done

echo "=== mdss_mdp sysfs ===" >"$OUT/sys/mdss_mdp-ls.txt"
ls -l /sys/devices/platform/soc/ae00000.qcom,mdss_mdp >>"$OUT/sys/mdss_mdp-ls.txt" 2>/dev/null || true

cat /proc/interrupts >"$OUT/proc/interrupts.txt"
ps -A >"$OUT/proc/ps.txt"

{
	echo "=== cpuset ==="
	ls -l /dev/cpuset 2>/dev/null || ls -l /sys/fs/cgroup/cpuset 2>/dev/null || true
	echo "=== display pids ==="
	for p in $(pidof surfaceflinger vendor.qti.hardware.display.composer-service vendor.xiaomi.hardware.displayfeature@1.0-service displayfeature 2>/dev/null)
	do
		echo "----- pid $p comm=$(cat /proc/$p/comm) -----"
		grep -E 'Name|Cpus_allowed|Cpus_allowed_list|PPid|Threads' /proc/$p/status
		echo -n "oom_score_adj="; cat /proc/$p/oom_score_adj 2>/dev/null
		echo
		ls /proc/$p/task 2>/dev/null | while read t
		do
			echo -n "  task $t comm=$(cat /proc/$t/comm 2>/dev/null) "
			grep Cpus_allowed_list /proc/$t/status 2>/dev/null
		done
		echo
	done
} >"$OUT/proc/composer-affinity.txt"

{
	echo "=== mdss/sde/disp irq lines ==="
	grep -iE 'mdss|sde|disp|dpu|dsi' /proc/interrupts || true
} >"$OUT/proc/display-irqs.txt"

MDP='/sys/firmware/devicetree/base/soc/qcom,mdss_mdp@ae00000'
{
	echo "=== mdss_mdp property names ==="
	ls "$MDP"
	echo
	for p in \
		qcom,sde-has-idle-pc qcom,sde-panic-per-pipe qcom,sde-has-cdp \
		qcom,sde-has-src-split qcom,sde-qos-cpu-mask \
		qcom,sde-qos-cpu-dma-latency qcom,sde-qos-cpu-irq-latency \
		qcom,sde-max-bw-low-kbps qcom,sde-max-bw-high-kbps \
		qcom,sde-min-core-ib-kbps qcom,sde-min-dram-ib-kbps \
		qcom,sde-min-llcc-ib-kbps qcom,sde-dram-channels \
		qcom,sde-ubwc-version qcom,sde-highest-bank-bit \
		qcom,sde-danger-lut qcom,sde-safe-lut-macrotile \
		qcom,sde-qos-lut-macrotile qcom,sde-cdp-setting \
		qcom,sde-vbif-qos-rt-remap qcom,sde-uidle-off qcom,sde-uidle-size \
		clock-rate clock-max-rate clock-names
	do
		echo "----- $p -----"
		if [ -e "$MDP/$p" ]; then
			od -An -tx1 "$MDP/$p"
		else
			echo "(missing)"
		fi
	done
} >"$OUT/dt/mdp-key-props.txt"

PANEL="$MDP/qcom,mdss_dsi_l81a_42_04_0a_dual_dphy_video"
{
	echo "=== L81A panel properties ==="
	ls "$PANEL"
	echo
	echo "=== timings@0 ==="
	ls "$PANEL/qcom,mdss-dsi-display-timings/timing@0" 2>/dev/null || true
	echo
	T="$PANEL/qcom,mdss-dsi-display-timings/timing@0"
	for p in \
		qcom,mdss-dsi-panel-name qcom,mdss-dsi-panel-type \
		qcom,mdss-dsi-panel-count qcom,mdss-dsi-traffic-mode \
		qcom,mdss-dsi-mdp-trigger qcom,mdss-dsi-dma-trigger \
		qcom,mdss-dsi-pan-fps-update qcom,dsi-supported-dfps-list \
		qcom,adjust-timer-wakeup-ms qcom,mdss-dsi-bllp-power-mode \
		qcom,mdss-dsi-bllp-eof-power-mode qcom,mdss-dsi-lp11-init \
		qcom,cmd-sync-wait-broadcast qcom,mdss-dsi-panel-broadcast-mode
	do
		echo "----- panel $p -----"
		if [ -e "$PANEL/$p" ]; then
			# strings for text, hex for cells
			od -An -tx1 "$PANEL/$p"
			echo -n "ascii="; cat "$PANEL/$p"; echo
		else
			echo "(missing)"
		fi
	done
	for p in \
		qcom,mdss-dsi-panel-framerate qcom,mdss-dsi-panel-width \
		qcom,mdss-dsi-panel-height qcom,mdss-dsi-h-pulse-width \
		qcom,mdss-dsi-h-back-porch qcom,mdss-dsi-h-front-porch \
		qcom,mdss-dsi-v-pulse-width qcom,mdss-dsi-v-back-porch \
		qcom,mdss-dsi-v-front-porch qcom,mdss-dsc-version \
		qcom,mdss-dsc-slice-height qcom,mdss-dsc-slice-width \
		qcom,mdss-dsc-slice-per-pkt qcom,mdss-dsc-bit-per-component \
		qcom,mdss-dsc-bit-per-pixel qcom,compression-mode \
		qcom,display-topology qcom,mdss-dsi-panel-phy-timings
	do
		echo "----- timing $p -----"
		if [ -e "$T/$p" ]; then
			od -An -tx1 "$T/$p"
			echo -n "ascii="; cat "$T/$p"; echo
		else
			echo "(missing)"
		fi
	done
} >"$OUT/dt/l81a-panel-props.txt"

uname -a >"$OUT/proc/uname.txt"
cat /proc/uptime >"$OUT/proc/uptime.txt"
echo "ondevice dump done" >"$OUT/DONE"
