#!/usr/bin/env python3
"""Grant xdg-desktop-portal Camera to Snapshot / Chromium / Chrome / wemeet.

Chrome getUserMedia on Wayland goes through portal Camera.AccessCamera.
wemeetapp is Qt/X11 V4L2-first, but the picker and some dialogs still
hit the portal; grant the same devices/camera=yes as Snapshot.
"""
import sys

try:
    import dbus
except ImportError as e:
    raise SystemExit(f"need python3-dbus: {e}")

APPS = (
    "",
    "org.gnome.Snapshot",
    "org.chromium.Chromium",
    "org.chromium.Chromium.desktop",
    "google-chrome",
    "com.google.Chrome",
    "chromium",
    "wemeetapp",
    "WemeetApp",
    "wemeet",
    "com.tencent.wemeet",
    "com.tencent.wemeetapp",
    "wechat",
    "com.tencent.wechat",
)

bus = dbus.SessionBus()
store = bus.get_object(
    "org.freedesktop.impl.portal.PermissionStore",
    "/org/freedesktop/impl/portal/PermissionStore",
)
iface = dbus.Interface(store, "org.freedesktop.impl.portal.PermissionStore")
for app in APPS:
    iface.SetPermission("devices", True, "camera", app, ["yes"])
    print(f"devices/camera {app or '(default)'} = yes")
lookup = iface.Lookup("devices", "camera")
print("lookup", lookup)
