#!/bin/sh
# Enable libcamera simple + Software ISP on dagu after UDMABUF is present.
# Do not use meson -Dipmbs (that option does not exist).
set -eu

log() { printf 'dagu-libcamera-softisp: %s\n' "$*"; }

if [ ! -e /dev/udmabuf ]; then
	log "no /dev/udmabuf — rebuild with CONFIG_UDMABUF=y and flash B slot"
	exit 1
fi

insert_props() {
	file=$1
	[ -f "$file" ] || return 0
	if grep -q '"s5kjn1"' "$file"; then
		log "sensor properties already mention s5kjn1"
		return 0
	fi
	python3 - "$file" <<'PY'
from pathlib import Path
import sys

p = Path(sys.argv[1])
text = p.read_text()
needle = '{ "imx219",'
block = '''	{ "s5kjn1", {
		.unitCellSize = { 640, 640 },
	} },
	{ "imx596", {
		.unitCellSize = { 800, 800 },
	} },
	{ "imx596-dagu", {
		.unitCellSize = { 800, 800 },
	} },
'''
if needle not in text:
    sys.exit("imx219 needle missing")
p.write_text(text.replace(needle, block + "\t" + needle, 1))
print("inserted s5kjn1/imx596 sensor properties")
PY
}

src="${LIBCAMERA_SRC:-/usr/src/libcamera}"
if [ -f "$src/src/libcamera/camera_sensor_properties.cpp" ]; then
	insert_props "$src/src/libcamera/camera_sensor_properties.cpp"
	log "meson if you rebuild: meson setup build -Dpipelines=simple"
	log "then ninja -C build && ninja -C build install"
else
	log "no libcamera source at $src; distro SoftISP is enough if UDMABUF works"
fi

if command -v cam >/dev/null; then
	log "cam --list-cameras"
	cam --list-cameras || true
fi
