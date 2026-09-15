#!/usr/bin/env bash
# Tear the LINEAR flower contract on the tablet and capture evidence.
# Does NOT flip the daily default. Stages:
#   gles-nolinear  drop libdagu-linear-mod.so, keep dagu-mesa
#   gles-stock     drop interceptor + dagu-mesa (distro Freedreno)
#   vk-overlay     DAGU_TEAR_CONTRACT=1 + TU_DEBUG (Turnip + overlay flags)
#
# Mutter still has disable-direct-scanout unless DAGU_MUTTER_OVERLAY=1
# (that restarts gnome-shell and is opt-in).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOST="${DAGU_SSH_HOST:-192.168.7.2}"
KEY="${DAGU_SSH_KEY:-$ROOT/out/id_dagu}"
STAGE="${1:-all}"
OUT="$ROOT/out/display-stress"
SSH=(ssh -i "$KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
	-o ConnectTimeout=12 "root@$HOST")
SCP=(scp -i "$KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null)

mkdir -p "$OUT"

deploy() {
	aarch64-linux-gnu-gcc -O2 -shared -fPIC \
		-o "$OUT/libdagu-gbm-trace.so" \
		"$ROOT/scripts/dagu-gbm-trace.c" -ldl
	"${SCP[@]}" \
		"$ROOT/scripts/dagu-chromium-native.sh" \
		"$ROOT/scripts/dagu-gnome-screenshot.sh" \
		"$OUT/libdagu-gbm-trace.so" \
		"root@$HOST:/tmp/"
	"${SSH[@]}" 'install -m755 /tmp/dagu-chromium-native.sh /usr/local/bin/dagu-chromium-native
		install -m755 /tmp/dagu-gnome-screenshot.sh /usr/local/sbin/dagu-gnome-screenshot.sh
		install -m755 /tmp/libdagu-gbm-trace.so /usr/local/lib/libdagu-gbm-trace.so
		grep -q "Never load libdagu-linear-mod" /usr/local/bin/dagu-chromium-native
		echo native-wrapper-ok'
}

shot() {
	local name="$1"
	"${SSH[@]}" "/usr/local/sbin/dagu-gnome-screenshot.sh --local /tmp/dagu-ubwc-${name}.png"
	"${SCP[@]}" "root@$HOST:/tmp/dagu-ubwc-${name}.png" "$OUT/ubwc-${name}.png"
	echo "shot $OUT/ubwc-${name}.png"
}

kms_fb() {
	"${SSH[@]}" 'python3 - <<"PY"
import re
p=open("/sys/kernel/debug/dri/0/state").read()
print("".join(l+"\n" for l in p.splitlines() if "fb=" in l or "modifier=" in l or "format=" in l)[:2000])
PY'
}

run_stage() {
	local name="$1"
	shift
	echo "==== stage $name $* ===="
	rm -f "$OUT/ubwc-${name}.png" "$OUT/ubwc-${name}-gbm.log" "$OUT/ubwc-${name}-chrome.log"
	"${SSH[@]}" "pkill -u dagu -f 'chrome|chromium' || true
		rm -f /tmp/dagu-gbm-trace.log /tmp/dagu-ubwc-${name}-chrome.log
		sleep 1
		sudo -u dagu env \
			XDG_RUNTIME_DIR=/run/user/1001 \
			WAYLAND_DISPLAY=wayland-0 \
			DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1001/bus \
			HOME=/home/dagu USER=dagu LOGNAME=dagu \
			DAGU_GBM_TRACE=1 \
			$* \
			/usr/local/bin/dagu-chromium-native \
			--user-data-dir=/tmp/dagu-chrome-jank-profile \
			--remote-debugging-port=9222 \
			--remote-debugging-address=127.0.0.1 \
			--remote-allow-origins=* \
			--no-first-run \
			--hide-crash-restore-bubble \
			chrome://gpu \
			>/tmp/dagu-ubwc-${name}-chrome.log 2>&1 &
		for i in \$(seq 1 40); do
			ss -ltn | grep -q ':9222' && break
			sleep 0.5
		done
		sleep 4
		echo --- environ ---
		pid=\$(pgrep -u dagu -n -f '/usr/lib/chromium/chromium --show-component' || pgrep -u dagu -n chromium || true)
		echo pid=\$pid
		if [ -n \"\$pid\" ]; then
			tr '\\0' '\\n' < /proc/\$pid/environ | grep -E 'LD_PRELOAD|LD_LIBRARY|DAGU_|TU_DEBUG|VK_' || true
			echo --- gpu ---
			pgrep -a -u dagu -f 'type=gpu-process' | head -3
		fi"
	sleep 2
	"${SSH[@]}" "cat > /tmp/ubwc-hello.html <<'HTML'
<!doctype html><html><head><meta charset=utf-8><title>UBWC hello</title></head>
<body style='background:#122;color:#eee;font:72px/1.3 sans-serif;padding:48px'>
<h1>DAGU $name</h1><p>The quick brown fox 1234567890</p><p>小米平板 Adreno 650</p>
</body></html>
HTML
python3 - <<'PY'
import json, urllib.request, asyncio, base64, os
tabs=json.load(urllib.request.urlopen('http://127.0.0.1:9222/json', timeout=5))
page=next((t for t in tabs if t.get('type')=='page'), None)
import websockets
async def shot():
    async with websockets.connect(page['webSocketDebuggerUrl'], max_size=40_000_000, open_timeout=10) as ws:
        mid=0
        async def send(meth, par=None):
            nonlocal mid
            mid += 1
            await ws.send(json.dumps({'id':mid,'method':meth,'params':par or {}}))
            while True:
                raw=json.loads(await asyncio.wait_for(ws.recv(), 25))
                if raw.get('id')==mid:
                    return raw
        await send('Page.enable')
        await send('Page.navigate', {'url':'file:///tmp/ubwc-hello.html'})
        await asyncio.sleep(2)
        ev=await send('Runtime.evaluate', {'expression':'document.body.innerText','returnByValue':True})
        print('dom', ev.get('result',{}).get('result',{}).get('value'))
        got=await send('Page.captureScreenshot', {'format':'png','fromSurface':True})
        open('/tmp/dagu-ubwc-hello-cdp.png','wb').write(base64.b64decode(got['result']['data']))
        print('cdp', os.path.getsize('/tmp/dagu-ubwc-hello-cdp.png'))
asyncio.run(shot())
PY"
	"${SCP[@]}" "root@$HOST:/tmp/dagu-ubwc-hello-cdp.png" "$OUT/ubwc-${name}-hello-cdp.png" || true
	shot "$name"
	kms_fb || true
	"${SCP[@]}" "root@$HOST:/tmp/dagu-gbm-trace.log" "$OUT/ubwc-${name}-gbm.log" || true
	"${SCP[@]}" "root@$HOST:/tmp/dagu-ubwc-${name}-chrome.log" "$OUT/ubwc-${name}-chrome.log" || true
	if [ -f "$OUT/ubwc-${name}-gbm.log" ]; then
		echo "--- modifiers $name ---"
		grep -E "params.add|with_modifiers|gbm_bo_create " "$OUT/ubwc-${name}-gbm.log" | tail -40 || true
	fi
}

deploy
case "$STAGE" in
gles-nolinear)
	run_stage gles-nolinear DAGU_NATIVE_UBWC=1
	;;
gles-stock)
	run_stage gles-stock DAGU_NATIVE_UBWC=1 DAGU_STOCK_MESA=1
	;;
vk-overlay)
	run_stage vk-overlay DAGU_TEAR_CONTRACT=1 TU_DEBUG=binner,startup,ubwc,log
	;;
all)
	run_stage gles-nolinear DAGU_NATIVE_UBWC=1
	run_stage gles-stock DAGU_NATIVE_UBWC=1 DAGU_STOCK_MESA=1
	run_stage vk-overlay DAGU_TEAR_CONTRACT=1 TU_DEBUG=binner,startup,ubwc,log
	;;
*)
	echo "usage: $0 [all|gles-nolinear|gles-stock|vk-overlay]" >&2
	exit 2
	;;
esac
echo "done. screenshots in $OUT/ubwc-*.png"
