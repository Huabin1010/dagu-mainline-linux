#!/usr/bin/env python3
"""Patch gnome-control-center 50 Wi-Fi so the spinner follows the scan.

The header spinner is forced visible on every device state change, so it
stays up after NetworkManager has finished. The scanning flag is cleared
only when last-scan changes, and RequestScan's async callback is NULL, so
a rejected or dropped scan leaves scanning true. The connection row shows
its spinner while the active connection is ACTIVATING, but the list never
subscribes to that object's notify::state, so the row stays on connecting
after the connection is already activated.
"""
import re
import sys
from pathlib import Path

PANEL_NEEDLE = "gtk_widget_set_visible (GTK_WIDGET (self->spinner), hotspot == NULL);"
PANEL_REPL = [
    "/* dagu: scanning binding owns visibility. Forcing the spinner",
    " * visible here turns it back on after the scan has finished.",
    " */",
    "if (hotspot != NULL)",
    "\tgtk_widget_set_visible (GTK_WIDGET (self->spinner), FALSE);",
]


def level_unit(indent: str) -> str:
    if "\t" in indent:
        return "\t"
    if indent and len(indent) % 8 == 0:
        return "        "
    return "  "


def replace_line(text: str, needle: str, new_lines: list[str], label: str) -> str:
    lines = text.splitlines(keepends=True)
    hit = None
    for i, line in enumerate(lines):
        if needle in line:
            if hit is not None:
                raise SystemExit(f"{label} ambiguous")
            hit = i
    if hit is None:
        raise SystemExit(f"{label} not found")
    indent = re.match(r"[ \t]*", lines[hit]).group(0)
    unit = level_unit(indent)
    out = []
    for item in new_lines:
        extra = ""
        if item.startswith("\t"):
            extra = unit
            item = item[1:]
        out.append(f"{indent}{extra}{item}\n")
    lines[hit] = "".join(out)
    return "".join(lines)


def patch_panel(text: str) -> str:
    if "scanning binding owns visibility" in text:
        return text
    return replace_line(text, PANEL_NEEDLE, PANEL_REPL, "header spinner")


def function_span(text: str, header: str) -> tuple[int, int, str]:
    match = re.search(header, text)
    if not match:
        raise SystemExit(f"function not found: {header!r}")
    brace = text.find("{", match.end())
    depth = 0
    for index in range(brace, len(text)):
        char = text[index]
        if char == "{":
            depth += 1
        elif char == "}":
            depth -= 1
            if depth == 0:
                end = index + 1
                if text[end : end + 1] == "\n":
                    end += 1
                body = re.match(r"\n([ \t]+)", text[brace + 1 :])
                indent = body.group(1) if body else "\t"
                return match.start(), end, indent
    raise SystemExit(f"unbalanced function: {header!r}")


def block(indent: str, lines: list[str]) -> str:
    unit = level_unit(indent)
    out = []
    for line in lines:
        level = 0
        while line.startswith(">"):
            level += 1
            line = line[1:]
        if line == "":
            out.append("\n")
        else:
            out.append(f"{indent}{unit * level}{line}\n")
    return "".join(out)


def patch_device(text: str) -> str:
    if "scan_deadline_us" not in text:
        match = re.search(r"^([ \t]*)guint\s+monitor_scanning_id;$", text, re.M)
        if not match:
            raise SystemExit("monitor_scanning_id not found")
        indent = match.group(1)
        text = (
            text[: match.end()]
            + f"\n{indent}gint64                   scan_deadline_us;"
            + text[match.end() :]
        )
    if "request_scan_cb" not in text:
        start, end, indent = function_span(
            text, r"static gboolean\nupdate_scanning \(gpointer user_data\)"
        )
        text = (
            text[:start]
            + "static void\nrequest_scan_cb (GObject      *source_object,\n"
            + "                 GAsyncResult *res,\n"
            + "                 gpointer      user_data)\n{\n"
            + block(
                indent,
                [
                    "NetDeviceWifi *self = user_data;",
                    "g_autoptr(GError) error = NULL;",
                    "",
                    "if (nm_device_wifi_request_scan_finish (NM_DEVICE_WIFI (source_object),",
                    ">res, &error))",
                    ">return;",
                    "",
                    "/* Cancel during finalize. The object is going away. */",
                    "if (g_error_matches (error, G_IO_ERROR, G_IO_ERROR_CANCELLED))",
                    ">return;",
                    "",
                    'g_debug ("Wi-Fi scan request failed: %s", error->message);',
                    "set_scanning (self, FALSE,",
                    ">nm_device_wifi_get_last_scan (NM_DEVICE_WIFI (self->device)));",
                    "if (self->monitor_scanning_id != 0) {",
                    ">g_source_remove (self->monitor_scanning_id);",
                    ">self->monitor_scanning_id = 0;",
                    "}",
                ],
            )
            + "}\n\n"
            + "static gboolean\nupdate_scanning (gpointer user_data)\n{\n"
            + block(
                indent,
                [
                    "NetDeviceWifi *self = user_data;",
                    "gint64 last_scan;",
                    "",
                    "last_scan = nm_device_wifi_get_last_scan (NM_DEVICE_WIFI (self->device));",
                    "",
                    "/* last-scan is the completion signal. NetworkManager returns from",
                    " * RequestScan when the work is queued, and while associated it",
                    " * rate-limits for 8s before scanning. If the timestamp is still the",
                    " * one captured at the request after that window, the kickoff dropped",
                    " * the scan and will not notify.",
                    " */",
                    "if (self->last_scan != last_scan ||",
                    ">g_get_monotonic_time () >= self->scan_deadline_us) {",
                    ">set_scanning (self, FALSE, last_scan);",
                    ">self->monitor_scanning_id = 0;",
                    ">return G_SOURCE_REMOVE;",
                    "}",
                    "",
                    "return G_SOURCE_CONTINUE;",
                ],
            )
            + "}\n"
            + text[end:]
        )
    if "request_scan_cb, self" not in text:
        match = re.search(
            r"([ \t]*)nm_device_wifi_request_scan_async \(NM_DEVICE_WIFI \(self->device\),\n"
            r"[ \t]*self->cancellable, NULL, NULL\);",
            text,
        )
        if not match:
            raise SystemExit("request_scan_async call not found")
        indent = match.group(1)
        text = (
            text[: match.start()]
            + f"{indent}self->scan_deadline_us = g_get_monotonic_time () + 10 * G_TIME_SPAN_SECOND;\n"
            + f"{indent}nm_device_wifi_request_scan_async (NM_DEVICE_WIFI (self->device),\n"
            + f"{indent}{level_unit(indent)}self->cancellable, request_scan_cb, self);"
            + text[match.end() :]
        )
    return text


def patch_list(text: str) -> str:
    if "watched_ac" not in text:
        match = re.search(r"^([ \t]*)NMConnection\s+\*last_active;$", text, re.M)
        if not match:
            raise SystemExit("last_active not found")
        indent = match.group(1)
        text = (
            text[: match.end()]
            + f"\n{indent}NMActiveConnection *watched_ac;\n{indent}gulong             ac_state_id;"
            + text[match.end() :]
        )
    if "dagu_watch_active_connection" not in text:
        anchor = "static void\non_device_state_changed_cb (CcWifiConnectionList *self,"
        at = text.find(anchor)
        if at < 0:
            raise SystemExit("on_device_state_changed_cb not found")
        _start, _end, indent = function_span(
            text, r"static void\non_device_state_changed_cb \(CcWifiConnectionList \*self,"
        )
        watch = (
            "static void on_device_state_changed_cb (CcWifiConnectionList *self,\n"
            "                                        GParamSpec           *pspec,\n"
            "                                        NMDeviceWifi         *device);\n\n"
            "static void\ndagu_ac_gone (gpointer data, GObject *where_the_object_was)\n{\n"
            + block(
                indent,
                [
                    "CcWifiConnectionList *self = data;",
                    "",
                    "if ((GObject *) self->watched_ac == where_the_object_was) {",
                    ">self->watched_ac = NULL;",
                    ">self->ac_state_id = 0;",
                    "}",
                ],
            )
            + "}\n\n"
            "static void\ndagu_watch_active_connection (CcWifiConnectionList *self)\n{\n"
            + block(
                indent,
                [
                    "NMActiveConnection *ac;",
                    "",
                    "ac = nm_device_get_active_connection (NM_DEVICE (self->device));",
                    "if (ac == self->watched_ac)",
                    ">return;",
                    "",
                    "if (self->watched_ac != NULL) {",
                    ">g_object_weak_unref (G_OBJECT (self->watched_ac), dagu_ac_gone, self);",
                    ">if (self->ac_state_id != 0)",
                    ">>g_signal_handler_disconnect (self->watched_ac, self->ac_state_id);",
                    ">self->watched_ac = NULL;",
                    ">self->ac_state_id = 0;",
                    "}",
                    "",
                    "if (ac == NULL)",
                    ">return;",
                    "",
                    "self->watched_ac = ac;",
                    "g_object_weak_ref (G_OBJECT (ac), dagu_ac_gone, self);",
                    'self->ac_state_id = g_signal_connect_object (ac, "notify::state",',
                    ">G_CALLBACK (on_device_state_changed_cb),",
                    ">self, G_CONNECT_SWAPPED);",
                ],
            )
            + "}\n\n"
        )
        text = text[:at] + watch + text[at:]
    if "dagu_watch_active_connection (self);" not in text:
        match = re.search(
            r"([ \t]*)ac = nm_device_get_active_connection \(NM_DEVICE \(self->device\)\);\n"
            r"[ \t]*if \(ac\)\n"
            r"[ \t]*connection = NM_CONNECTION \(nm_active_connection_get_connection \(ac\)\);",
            text,
        )
        if not match:
            raise SystemExit("active connection read not found")
        indent = match.group(1)
        text = (
            text[: match.start()]
            + f"{indent}dagu_watch_active_connection (self);\n\n"
            + text[match.start() :]
        )
    dispose_body = text.split("cc_wifi_connection_list_dispose", 1)[-1][:900]
    if "dagu_ac_gone, self);" not in dispose_body:
        match = re.search(
            r"(cc_wifi_connection_list_dispose \(GObject \*object\)\n\{\n)"
            r"([ \t]*CcWifiConnectionList \*self = \(CcWifiConnectionList \*\)object;\n)",
            text,
        )
        if not match:
            raise SystemExit("dispose prologue not found")
        indent = re.match(r"[ \t]*", match.group(2)).group(0)
        unit = level_unit(indent)
        text = (
            text[: match.end()]
            + f"{indent}if (self->watched_ac != NULL) {{\n"
            + f"{indent}{unit}g_object_weak_unref (G_OBJECT (self->watched_ac), dagu_ac_gone, self);\n"
            + f"{indent}{unit}if (self->ac_state_id != 0)\n"
            + f"{indent}{unit}{unit}g_signal_handler_disconnect (self->watched_ac, self->ac_state_id);\n"
            + f"{indent}{unit}self->watched_ac = NULL;\n"
            + f"{indent}{unit}self->ac_state_id = 0;\n"
            + f"{indent}}}\n"
            + text[match.end() :]
        )
    return text


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit(f"usage: {sys.argv[0]} panels/network/<file>")
    path = Path(sys.argv[1])
    text = path.read_text()
    name = path.name
    if name == "cc-wifi-panel.c":
        new = patch_panel(text)
    elif name == "net-device-wifi.c":
        new = patch_device(text)
    elif name == "cc-wifi-connection-list.c":
        new = patch_list(text)
    else:
        raise SystemExit(f"unsupported {name}")
    if new == text:
        print(f"already patched {path}")
        return
    path.write_text(new)
    print(f"patched {path}")


if __name__ == "__main__":
    main()
