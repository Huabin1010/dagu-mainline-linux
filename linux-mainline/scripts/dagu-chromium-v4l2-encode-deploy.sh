#!/bin/sh
# Copy the patched official-152 arm64 chrome onto the tablet, replacing
# /usr/lib/chromium/chromium in place. Stage on tablet /tmp (tmpfs ~2.5G).
# Do not keep a second copy: userdata root is ~968MB free.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
TREE="${DAGU_CHROMIUM_TREE:-$ROOT/out/chromium-v4l2-src/official-152/out/dagu}"
KEY="${DAGU_SSH_KEY:-$ROOT/out/id_dagu}"
HOST="${DAGU_SSH_HOST:-192.168.7.2}"
SSH="ssh -i $KEY -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
SCP="scp -i $KEY -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"

chrome="$TREE/chrome"
[ -x "$chrome" ] || { echo "no $chrome — ninja not finished"; exit 1; }

if ! grep -a -q V4L2VideoEncodeAccelerator "$chrome"; then
	echo "binary has no V4L2VideoEncodeAccelerator — refuse to deploy"
	exit 1
fi

echo "==> size $(du -h "$chrome" | awk '{print $1}')"
$SCP "$ROOT/scripts/dagu-chromium.sh" "root@$HOST:/tmp/dagu-chromium.sh"
$SSH "root@$HOST" 'mkdir -p /tmp/dagu-chromium-new; rm -rf /tmp/dagu-chromium-new/*'
# Only ship files that exist. Official chrome always has the binary;
# paks/locales appear at the end of the chrome target. Keep Debian
# sidecars on the tablet if a pak is missing.
files="$chrome"
for f in chrome_sandbox chrome_100_percent.pak chrome_200_percent.pak \
	resources.pak icudtl.dat snapshot_blob.bin v8_context_snapshot.bin \
	libEGL.so libGLESv2.so libffmpeg.so libvk_swiftshader.so libvulkan.so.1 \
	chrome_crashpad_handler; do
	[ -e "$TREE/$f" ] && files="$files $TREE/$f"
done
# shellcheck disable=SC2086
$SCP $files "root@$HOST:/tmp/dagu-chromium-new/"
# Do not scp official-152 locales (~120MB, thousands of .pak). That
# saturates sshd on the tablet. Debian /usr/lib/chromium/locales stays.

$SSH "root@$HOST" 'set -eu
pkill -u dagu -f "chrome|chromium" || true
sleep 1
dest=/usr/lib/chromium
install -m755 /tmp/dagu-chromium-new/chrome "$dest/chromium"
install -m4755 /tmp/dagu-chromium-new/chrome_sandbox "$dest/chrome-sandbox"
for f in chrome_100_percent.pak chrome_200_percent.pak resources.pak icudtl.dat snapshot_blob.bin v8_context_snapshot.bin libEGL.so libGLESv2.so libffmpeg.so; do
	[ -f /tmp/dagu-chromium-new/$f ] && install -m644 /tmp/dagu-chromium-new/$f "$dest/$f"
done
if [ -d /tmp/dagu-chromium-new/locales ]; then
	mkdir -p "$dest/locales"
	cp -a /tmp/dagu-chromium-new/locales/. "$dest/locales/"
fi
rm -rf /tmp/dagu-chromium-new
install -m755 /tmp/dagu-chromium.sh /usr/local/bin/dagu-chromium
test -x /usr/local/bin/dagu-chromium
"$dest/chromium" --version
echo deployed
ls -l "$dest/chromium"
python3 - <<"PY"
from pathlib import Path
p=Path("/usr/lib/chromium/chromium").read_bytes()
print("V4L2VideoEncodeAccelerator", p.find(b"V4L2VideoEncodeAccelerator")>=0)
print("V4L2StatefulVideoDecoder", p.find(b"V4L2StatefulVideoDecoder")>=0)
PY
'
