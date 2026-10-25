#!/usr/bin/env python3
"""Overlay gnome-shell quick-settings Wi-Fi status code.

NetworkManager RequestScan returns when the scan is queued. The stock
menu waits forever for lastScan to change, and an exception skips
Spinner.stop(). The overlay stops the Wi-Fi spinner when the scan
finishes or when NetworkManager's activated rate-limit window has
elapsed with no last-scan update.

Bluetooth uses the stock bluetooth.js. Device1.Connect returns on its
own: about 5 s (Page Timeout) for a classic keyboard that is asleep,
30 s for an LE device that is not advertising. An older overlay that
cancelled a pending Connect after 20 s is removed here.
"""
import subprocess
import sys
from pathlib import Path

OVERLAY = Path("/usr/local/share/dagu/gnome-shell-overlay")
SCAN_OLD = """    async _scanDevice(device) {
        const {lastScan} = device;
        await device.request_scan_async(null);

        // Wait for the lastScan property to update, which
        // indicates the end of the scan
        return new Promise(resolve => {
            GLib.timeout_add(GLib.PRIORITY_DEFAULT, 1500, () => {
                if (device.lastScan === lastScan)
                    return GLib.SOURCE_CONTINUE;

                resolve();
                return GLib.SOURCE_REMOVE;
            });
        });
    }

    async _scanDevices() {
        if (!this._client.wireless_enabled)
            return;

        this._scanningSpinner.play();

        const devices = [...this._items.keys()];
        await Promise.all(
            devices.map(d => this._scanDevice(d)));

        this._scanningSpinner.stop();
    }
"""

SCAN_NEW = """    async _scanDevice(device) {
        const lastScan = device.lastScan;
        try {
            await device.request_scan_async(null);
        } catch (e) {
            console.debug(`Wi-Fi scan ${device.get_iface?.() ?? ''}: ${e.message}`);
            return;
        }

        // RequestScan returns when NetworkManager has queued the scan.
        // lastScan moves when that scan finishes. While associated, the
        // daemon rate-limits for 8s and then scans; if lastScan is still
        // the captured value after that window, the request was dropped
        // (supplicant missing, or a kickoff that did not schedule a retry).
        const deadline = GLib.get_monotonic_time() + 10 * GLib.TIME_SPAN_SECOND;
        await new Promise(resolve => {
            GLib.timeout_add(GLib.PRIORITY_DEFAULT, 500, () => {
                if (device.lastScan !== lastScan ||
                    GLib.get_monotonic_time() >= deadline) {
                    resolve();
                    return GLib.SOURCE_REMOVE;
                }
                return GLib.SOURCE_CONTINUE;
            });
        });
    }

    async _scanDevices() {
        if (!this._client.wireless_enabled)
            return;

        const generation = (this._scanGeneration = (this._scanGeneration || 0) + 1);
        this._scanningSpinner.play();
        try {
            const devices = [...this._items.keys()];
            await Promise.all(
                devices.map(d => this._scanDevice(d)));
        } finally {
            if (generation === this._scanGeneration)
                this._scanningSpinner.stop();
        }
    }
"""

STOP_OLD = """    _stopScanning() {
        if (this._scanTimeoutId)
            GLib.source_remove(this._scanTimeoutId);
        delete this._scanTimeoutId;
    }
"""

STOP_NEW = """    _stopScanning() {
        this._scanGeneration = (this._scanGeneration || 0) + 1;
        if (this._scanTimeoutId)
            GLib.source_remove(this._scanTimeoutId);
        delete this._scanTimeoutId;
        this._scanningSpinner?.stop();
    }
"""


def gresource() -> Path:
    candidates = [
        Path("/usr/lib/gnome-shell/libshell-18.so"),
        Path("/usr/lib/gnome-shell/gnome-shell-theme.gresource"),
        Path("/usr/lib/gnome-shell/libshell-17.so"),
    ]
    for path in candidates:
        if path.is_file():
            return path
    raise SystemExit("gnome-shell gresource not found")


def extract(resource: Path, name: str) -> str:
    out = subprocess.run(
        ["gresource", "extract", str(resource), f"/org/gnome/shell/ui/status/{name}"],
        check=True,
        capture_output=True,
    )
    return out.stdout.decode()


def patch(text: str, old: str, new: str, label: str) -> str:
    if new in text:
        return text
    if old not in text:
        raise SystemExit(f"{label} anchor not found")
    return text.replace(old, new, 1)


def main() -> None:
    resource = gresource()
    network = extract(resource, "network.js")
    network = patch(network, SCAN_OLD, SCAN_NEW, "wifi scan")
    network = patch(network, STOP_OLD, STOP_NEW, "wifi stop")
    if "10 * GLib.TIME_SPAN_SECOND" not in network:
        raise SystemExit("wifi overlay missing")
    dest_net = OVERLAY / "ui/status/network.js"
    dest_net.parent.mkdir(parents=True, exist_ok=True)
    dest_net.write_text(network)
    (OVERLAY / "ui/status/bluetooth.js").unlink(missing_ok=True)
    print(f"overlay {dest_net} from {resource}")


if __name__ == "__main__":
    try:
        main()
    except subprocess.CalledProcessError as exc:
        sys.exit(exc.stderr.decode() or str(exc))
