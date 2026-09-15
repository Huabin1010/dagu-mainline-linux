#!/usr/bin/env bash
# Capture the GNOME session after UBWC scanout. Do not mmap the KMS fb
# (linux-mainline/scripts/dagu-kms-land-crop.py is LINEAR-only).
#
# Mutter destiles UBWC through GL when the screenshot portal asks.
# From the host:
#   ./scripts/dagu-gnome-screenshot.sh [local.png]
# On the tablet as root:
#   ./scripts/dagu-gnome-screenshot.sh --local /tmp/out.png
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOST="${DAGU_SSH_HOST:-192.168.7.2}"
KEY="${DAGU_SSH_KEY:-$ROOT/out/id_dagu}"
OUT="${1:-$ROOT/out/display-stress/gnome-screenshot.png}"

on_device() {
	dest=${1:-/tmp/dagu-gnome-screenshot.png}
	export XDG_RUNTIME_DIR=/run/user/1001
	export WAYLAND_DISPLAY=wayland-0
	export DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1001/bus
	sudo -u dagu env XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" \
		WAYLAND_DISPLAY="$WAYLAND_DISPLAY" \
		DBUS_SESSION_BUS_ADDRESS="$DBUS_SESSION_BUS_ADDRESS" \
		HOME=/home/dagu python3 - "$dest" <<'PY'
import os, sys, time
from pathlib import Path

dest = Path(sys.argv[1])
try:
    import dbus
    from dbus.mainloop.glib import DBusGMainLoop
    from gi.repository import GLib
except ImportError as e:
    raise SystemExit(f"need python3-dbus + gi: {e}")

DBusGMainLoop(set_as_default=True)
bus = dbus.SessionBus()

# Remember unsandboxed screenshot so later runs are silent.
try:
    store = bus.get_object(
        "org.freedesktop.impl.portal.PermissionStore",
        "/org/freedesktop/impl/portal/PermissionStore",
    )
    store.SetPermission(
        "screenshot",
        True,
        "screenshot",
        "",
        ["yes"],
        dbus_interface="org.freedesktop.impl.portal.PermissionStore",
    )
except Exception as exc:
    print(f"permission-store: {exc}", file=sys.stderr)

portal = bus.get_object(
    "org.freedesktop.portal.Desktop", "/org/freedesktop/portal/desktop"
)
token = f"dagu{int(time.time())}"
sender = bus.get_unique_name()[1:].replace(".", "_")
req_path = f"/org/freedesktop/portal/desktop/request/{sender}/{token}"
loop = GLib.MainLoop()
result = {}


def on_response(code, values):
    result["code"] = int(code)
    result["values"] = dict(values)
    loop.quit()


bus.add_signal_receiver(
    on_response,
    signal_name="Response",
    dbus_interface="org.freedesktop.portal.Request",
    path=req_path,
)
GLib.timeout_add_seconds(20, loop.quit)
portal.Screenshot(
    "",
    {"interactive": False, "handle_token": token},
    dbus_interface="org.freedesktop.portal.Screenshot",
)
loop.run()
if result.get("code") != 0:
    raise SystemExit(f"portal Screenshot failed: {result}")
uri = str(result["values"].get("uri", ""))
if not uri.startswith("file://"):
    raise SystemExit(f"no file uri in {result}")
src = Path(uri[7:])
dest.parent.mkdir(parents=True, exist_ok=True)
dest.write_bytes(src.read_bytes())
print(dest, dest.stat().st_size)
PY
}

if [[ "${1:-}" == "--local" ]]; then
	on_device "${2:-/tmp/dagu-gnome-screenshot.png}"
	exit 0
fi

SSH=(ssh -i "$KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
     -o ConnectTimeout=12 "root@$HOST")
SCP=(scp -i "$KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null)
"${SCP[@]}" "$ROOT/scripts/dagu-gnome-screenshot.sh" "root@$HOST:/usr/local/sbin/dagu-gnome-screenshot.sh"
"${SSH[@]}" "chmod +x /usr/local/sbin/dagu-gnome-screenshot.sh
	/usr/local/sbin/dagu-gnome-screenshot.sh --local /tmp/dagu-gnome-screenshot.png"
mkdir -p "$(dirname "$OUT")"
"${SCP[@]}" "root@$HOST:/tmp/dagu-gnome-screenshot.png" "$OUT"
ls -l "$OUT"
