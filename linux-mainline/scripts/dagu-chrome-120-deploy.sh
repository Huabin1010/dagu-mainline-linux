#!/bin/sh
# Host → tablet: official-152 chrome + lab page + identity helper.
# Do not use dagu-chromium-v4l2-encode-deploy.sh (it overwrites the wrapper).
# Large copy uses rsync --bwlimit so eMMC/sshd do not wedge again.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
KEY="${DAGU_SSH_KEY:-$ROOT/out/id_dagu}"
HOST="${DAGU_SSH_HOST:-192.168.7.2}"
BIN="$ROOT/out/chromium-v4l2-src/official-152/out/dagu/chrome"
BWLIMIT="${DAGU_SCP_BWLIMIT:-8192}"

ssh_c() {
	ssh -i "$KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
		-o ConnectTimeout=12 -o ServerAliveInterval=3 -o ServerAliveCountMax=4 \
		-o ControlMaster=no -o PreferredAuthentications=publickey -o BatchMode=yes \
		"root@$HOST" "$@"
}

echo "==> probe"
ssh_c 'echo ALIVE; df -h / | tail -1; ls -l /usr/lib/chromium/chromium'

echo "==> rsync chrome (${BWLIMIT} KB/s) → /tmp/chrome-dagu-120"
rsync -P --bwlimit="$BWLIMIT" -e "ssh -i $KEY -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ControlMaster=no" \
	"$BIN" "root@$HOST:/tmp/chrome-dagu-120"

echo "==> install chrome + scripts"
rsync -P -e "ssh -i $KEY -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ControlMaster=no" \
	"$ROOT/scripts/dagu-pipeline-tab.html" \
	"$ROOT/scripts/dagu-pipeline-lab.html" \
	"$ROOT/scripts/dagu-lab-identity-120.sh" \
	"$ROOT/scripts/dagu-chromium-native.sh" \
	"root@$HOST:/tmp/dagu-lab-up/"

ssh_c 'set -e
install -m755 /tmp/chrome-dagu-120 /usr/lib/chromium/chromium
install -d /usr/local/share/dagu-pipeline-lab /usr/local/sbin /usr/local/bin
install -m644 /tmp/dagu-lab-up/dagu-pipeline-tab.html /usr/local/share/dagu-pipeline-lab/dagu-pipeline-tab.html
install -m644 /tmp/dagu-lab-up/dagu-pipeline-lab.html /usr/local/share/dagu-pipeline-lab/dagu-pipeline-lab.html
install -m755 /tmp/dagu-lab-up/dagu-lab-identity-120.sh /usr/local/sbin/dagu-lab-identity-120.sh
install -m755 /tmp/dagu-lab-up/dagu-chromium-native.sh /usr/local/bin/dagu-chromium-native.sh
strings /usr/lib/chromium/chromium | grep -E "dagu panel rotate|V4L2StatefulVideoDecoder|SkipWaitAfterPresented" | head
ls -l /usr/lib/chromium/chromium
echo DEPLOY_OK
'
