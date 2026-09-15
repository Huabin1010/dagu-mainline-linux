#!/usr/bin/env python3
"""Download Ubuntu resolute arm64 -dev debs and extract a mutter cross sysroot."""

from __future__ import annotations

import argparse
import os
import re
import subprocess
import sys
import urllib.request
from pathlib import Path

MIRROR = "https://ports.ubuntu.com/ubuntu-ports"
INDEX_DIR = Path("/tmp/dagu-mutter-sysroot/var")

SEED = [
    "libc6-dev",
    "linux-libc-dev",
    "libgcc-15-dev",
    "libglib2.0-dev",
    "libgraphene-1.0-dev",
    "libglycin-2-dev",
    "libcairo2-dev",
    "libpixman-1-dev",
    "gsettings-desktop-schemas-dev",
    "libgtk-4-dev",
    "libadwaita-1-dev",
    "gnome-settings-daemon-dev",
    "libxkbcommon-dev",
    "libxkbregistry-dev",
    "libatk1.0-dev",
    "libcolord-dev",
    "liblcms2-dev",
    "libei-dev",
    "libeis-dev",
    "libdisplay-info-dev",
    "libdrm-dev",
    "libpango1.0-dev",
    "libpangocairo-1.0-0",
    "libwayland-dev",
    "wayland-protocols",
    "libgbm-dev",
    "libegl-dev",
    "libgles-dev",
    "libgl-dev",
    "libinput-dev",
    "libgudev-1.0-dev",
    "libudev-dev",
    "systemd-dev",
    "libwacom-dev",
    "libcanberra-dev",
    "libstartup-notification0-dev",
    "libpipewire-0.3-dev",
    "libgnome-desktop-4-dev",
    "libjson-glib-dev",
    "libsystemd-dev",
    "libx11-dev",
    "libx11-xcb-dev",
    "libxcomposite-dev",
    "libxcursor-dev",
    "libxdamage-dev",
    "libxext-dev",
    "libxfixes-dev",
    "libxi-dev",
    "libxinerama-dev",
    "libxrandr-dev",
    "libxrender-dev",
    "libxau-dev",
    "libxcb-res0-dev",
    "libice-dev",
    "libsm-dev",
    "libfribidi-dev",
    "libharfbuzz-dev",
    "libnvidia-egl-wayland-dev",
    "libsoup-3.0-dev",
    "libpam0g-dev",
    "libxkbcommon-x11-dev",
    "xkb-data",
    "libxcb1-dev",
    "libxcb-randr0-dev",
    "libxcb-shm0-dev",
    "libxcb-xfixes0-dev",
    "libegl1-mesa-dev",
    "mesa-common-dev",
    "libgles2-mesa-dev",
    "uuid-dev",
    "libmount-dev",
    "libffi-dev",
    "libpcre2-dev",
    "zlib1g-dev",
    "libpng-dev",
    "libjpeg-dev",
    "libfreetype-dev",
    "libfontconfig-dev",
    "libepoxy-dev",
    "libcloudproviders-dev",
    "libgraphene-1.0-0",
    "libcairo-gobject2",
    "libgdk-pixbuf-2.0-dev",
]

SKIP_PREFIX = (
    "python3",
    "perl",
    "debconf",
    "dpkg",
    "make",
    "gcc-",
    "g++-",
    "cpp-",
    "binutils",
    "build-essential",
    "meson",
    "ninja",
    "pkgconf",
    "pkg-config",
    "wayland-scanner",
    "manpages",
    "man-db",
    "ucf",
    "sensible-utils",
    "media-types",
    "iso-codes",
    "fonts-",
    "javascript-common",
    "libjs-",
    "nodejs",
    "npm",
    "gir1.2-",
    "gobject-introspection",
    "libgirepository",
    "gi-docgen",
    "gtk-doc",
    "docbook",
    "xml-core",
    "sgml",
)


def parse_index(path: Path) -> dict[str, dict[str, str]]:
    pkgs: dict[str, dict[str, str]] = {}
    cur: dict[str, str] = {}
    key = None
    with path.open(encoding="utf-8", errors="replace") as fh:
        for raw in fh:
            if raw == "\n":
                name = cur.get("Package")
                if name:
                    pkgs[name] = cur
                cur = {}
                key = None
                continue
            if raw.startswith(" ") and key:
                cur[key] += " " + raw.strip()
                continue
            if ":" in raw:
                key, val = raw.split(":", 1)
                cur[key] = val.strip()
    name = cur.get("Package")
    if name:
        pkgs[name] = cur
    return pkgs


def merge_indexes(paths: list[Path]) -> dict[str, dict[str, str]]:
    merged: dict[str, dict[str, str]] = {}
    for path in paths:
        merged.update(parse_index(path))
    return merged


def dep_names(field: str) -> list[str]:
    if not field:
        return []
    out = []
    for item in field.split(","):
        alt = item.split("|")[0].strip()
        name = re.split(r"[\s:(]", alt, 1)[0].strip()
        if name:
            out.append(name)
    return out


def should_skip(name: str) -> bool:
    return any(name == p or name.startswith(p) for p in SKIP_PREFIX)


def resolve(pkgs: dict[str, dict[str, str]], seeds: list[str]) -> list[str]:
    want = set(seeds)
    seen: set[str] = set()
    missing: list[str] = []
    while True:
        pending = [n for n in sorted(want) if n not in seen]
        if not pending:
            break
        for name in pending:
            seen.add(name)
            if should_skip(name):
                continue
            rec = pkgs.get(name)
            if not rec:
                missing.append(name)
                continue
            for key in ("Depends", "Pre-Depends"):
                for dep in dep_names(rec.get(key, "")):
                    if should_skip(dep):
                        continue
                    # Headers / .pc only. Runtime .so come from the tablet rsync.
                    if dep.endswith("-dev") or dep.endswith("-dev-bin") \
                       or dep in ("wayland-protocols", "xkb-data", "systemd-dev"):
                        want.add(dep)
    if missing:
        print("missing in index (ignored):", ", ".join(sorted(set(missing))[:40]), file=sys.stderr)
    return [n for n in sorted(seen) if n in pkgs and not should_skip(n)]


def download(url: str, dest: Path) -> None:
    dest.parent.mkdir(parents=True, exist_ok=True)
    if dest.exists() and dest.stat().st_size > 0:
        return
    tmp = dest.with_suffix(dest.suffix + ".part")
    print(f"GET {url}", flush=True)
    last_err = None
    for attempt in range(1, 6):
        try:
            subprocess.check_call(
                ["wget", "-q", "-O", str(tmp), "--timeout=30", "--tries=3", url]
            )
            tmp.rename(dest)
            return
        except (subprocess.CalledProcessError, OSError) as err:
            last_err = err
            print(f"  retry {attempt}/5: {err}", flush=True)
    raise RuntimeError(f"download failed: {url}") from last_err


def extract(deb: Path, root: Path) -> None:
    subprocess.check_call(["dpkg-deb", "-x", str(deb), str(root)])


def main() -> int:
    ap = argparse.ArgumentParser()
    default = Path(__file__).resolve().parent.parent / "out" / "mutter-sysroot"
    ap.add_argument("--root", default=str(default))
    ap.add_argument("--index-dir", default=str(INDEX_DIR))
    args = ap.parse_args()
    root = Path(args.root)
    index_dir = Path(args.index_dir)
    indexes = [
        index_dir / "Packages-main",
        index_dir / "Packages-universe",
        index_dir / "Packages-main-updates",
        index_dir / "Packages-universe-updates",
    ]
    pkgs = merge_indexes([p for p in indexes if p.exists()])
    names = resolve(pkgs, SEED)
    print(f"resolving {len(names)} packages")
    debdir = root / "var/debs"
    debdir.mkdir(parents=True, exist_ok=True)
    for i, name in enumerate(names, 1):
        rec = pkgs[name]
        filename = rec["Filename"]
        url = f"{MIRROR}/{filename}"
        dest = debdir / Path(filename).name
        print(f"[{i}/{len(names)}] {name}", flush=True)
        download(url, dest)
        extract(dest, root)
    print(f"sysroot ready: {root}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
