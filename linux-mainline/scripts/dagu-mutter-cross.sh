#!/usr/bin/env bash
# Cross-build Ubuntu-compatible libmutter-18 for dagu (host x86_64, target aarch64).
# Does not flash the kernel. Does not install onto the tablet.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SRC="$ROOT/linux-mainline/out/mutter-50.1"
BUILD="$ROOT/linux-mainline/out/mutter-50.1-build"
SYSROOT="$ROOT/linux-mainline/out/mutter-sysroot"
CROSS="$ROOT/linux-mainline/out/dagu-mutter-aarch64-cross.ini"
UBUNTU_PATCH="$ROOT/linux-mainline/out/mutter-src-debian/patches/ubuntu/clutter-frame-clock-Don-t-skip-the-next-frame.patch"
if [[ ! -f "$UBUNTU_PATCH" ]]; then
  UBUNTU_PATCH="/tmp/mutter-src/debian/patches/ubuntu/clutter-frame-clock-Don-t-skip-the-next-frame.patch"
fi

if [[ ! -d "$SRC/src/wayland" ]]; then
  echo "missing mutter sources: $SRC" >&2
  exit 1
fi
if [[ ! -f "$SYSROOT/usr/lib/aarch64-linux-gnu/pkgconfig/glib-2.0.pc" && \
      ! -f "$SYSROOT/usr/lib/aarch64-linux-gnu/pkgconfig/gio-2.0.pc" ]]; then
  echo "sysroot incomplete, run: python3 $ROOT/linux-mainline/scripts/dagu-mutter-sysroot.py" >&2
  exit 1
fi
# usr-merge: GNU ld scripts look for /lib/ld-linux-aarch64.so.1 inside --sysroot
if [[ ! -e $SYSROOT/lib/ld-linux-aarch64.so.1 ]]; then
  mkdir -p "$SYSROOT/lib"
  ln -s aarch64-linux-gnu/ld-linux-aarch64.so.1 "$SYSROOT/lib/ld-linux-aarch64.so.1"
fi

if [[ -f "$UBUNTU_PATCH" ]]; then
  if ! grep -q 'while (next_presentation_time_us < now_us)' \
        "$SRC/clutter/clutter/clutter-frame-clock.c"; then
    patch -d "$SRC" -p1 --forward < "$UBUNTU_PATCH" || true
  fi
fi

REPEAT_PATCH="$ROOT/linux-mainline/patches/mutter-50-repeat-on-other-key-release.patch"
if [[ -f "$REPEAT_PATCH" ]] &&
   ! grep -q 'GNOME #4675 / Ubuntu' \
        "$SRC/src/backends/native/meta-seat-impl.c"; then
  patch -d "$SRC" -p1 --forward < "$REPEAT_PATCH"
fi

cat > "$CROSS" <<EOF
[binaries]
c = 'aarch64-linux-gnu-gcc'
cpp = 'aarch64-linux-gnu-g++'
ar = 'aarch64-linux-gnu-ar'
strip = 'aarch64-linux-gnu-strip'
pkg-config = 'pkg-config'
wayland-scanner = '/usr/bin/wayland-scanner'

[built-in options]
c_args = ['--sysroot=${SYSROOT}', '-I${SYSROOT}/usr/include', '-I${SYSROOT}/usr/include/aarch64-linux-gnu']
cpp_args = ['--sysroot=${SYSROOT}', '-I${SYSROOT}/usr/include', '-I${SYSROOT}/usr/include/aarch64-linux-gnu']
c_link_args = ['--sysroot=${SYSROOT}', '-L${SYSROOT}/usr/lib/aarch64-linux-gnu', '-L${SYSROOT}/lib/aarch64-linux-gnu']
cpp_link_args = ['--sysroot=${SYSROOT}', '-L${SYSROOT}/usr/lib/aarch64-linux-gnu', '-L${SYSROOT}/lib/aarch64-linux-gnu']

[properties]
sys_root = '${SYSROOT}'
pkg_config_libdir = '${SYSROOT}/usr/lib/aarch64-linux-gnu/pkgconfig:${SYSROOT}/usr/share/pkgconfig:${SYSROOT}/usr/lib/pkgconfig'

[host_machine]
system = 'linux'
cpu_family = 'aarch64'
cpu = 'aarch64'
endian = 'little'
EOF

export PATH="$ROOT/linux-mainline/out/mutter-host-bin:${PATH}"
export PKG_CONFIG_SYSROOT_DIR="$SYSROOT"
export PKG_CONFIG_LIBDIR="$SYSROOT/usr/lib/aarch64-linux-gnu/pkgconfig:$SYSROOT/usr/share/pkgconfig:$SYSROOT/usr/lib/pkgconfig"
export PKG_CONFIG_PATH=""
export LIBRARY_PATH="$SYSROOT/usr/lib/aarch64-linux-gnu:$SYSROOT/lib/aarch64-linux-gnu${LIBRARY_PATH:+:$LIBRARY_PATH}"
export LDFLAGS="-L$SYSROOT/usr/lib/aarch64-linux-gnu -L$SYSROOT/lib/aarch64-linux-gnu -Wl,-rpath-link,$SYSROOT/usr/lib/aarch64-linux-gnu -Wl,-rpath-link,$SYSROOT/lib/aarch64-linux-gnu ${LDFLAGS:-}"

mkdir -p "$BUILD"
if [[ ! -f "$BUILD/build.ninja" ]]; then
  meson setup "$BUILD" "$SRC" \
    --cross-file "$CROSS" \
    --prefix=/usr \
    --libdir=lib/aarch64-linux-gnu \
    -Dauto_features=enabled \
    -Degl_device=true \
    -Dremote_desktop=true \
    -Dwayland_eglstream=true \
    -Dprofiler=false \
    -Dintrospection=false \
    -Ddocs=false \
    -Dtests=disabled \
    -Dcogl_tests=false \
    -Dclutter_tests=false \
    -Dmutter_tests=false \
    -Dinstalled_tests=false \
    -Ddevkit=disabled \
    -Dbash_completion=false \
    -Dxwayland=true \
    -Dlibgnome_desktop=true \
    -Dbuildtype=debugoptimized
fi

meson configure "$BUILD" -Dbuildtype=debugoptimized -Ddocs=false >/dev/null
ninja -C "$BUILD" src/libmutter-18.so.0.0.0
aarch64-linux-gnu-strip --strip-unneeded "$BUILD/src/libmutter-18.so.0.0.0"
install -m0755 "$BUILD/src/libmutter-18.so.0.0.0" \
  "$ROOT/linux-mainline/out/libmutter-18.so.0.0.0-dagu"
echo "built: $BUILD/src/libmutter-18.so.0.0.0"
ls -l "$BUILD/src/libmutter-18.so.0.0.0" \
      "$BUILD/clutter/clutter/libmutter-clutter-18.so.0.0.0" \
      "$BUILD/cogl/cogl/libmutter-cogl-18.so.0.0.0" \
      "$BUILD/mtk/mtk/libmutter-mtk-18.so.0.0.0" 2>/dev/null || true
