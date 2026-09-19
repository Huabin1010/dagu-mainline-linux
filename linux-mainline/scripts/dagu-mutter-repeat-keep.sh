#!/bin/sh
# Keep mutter 50.1 compositor hold-repeat (GNOME #4675 / Ubuntu #2150377).
# apt libmutter-18-0 must not restore stock any-release cancel.
set -e
WANT=/usr/local/lib/dagu-mutter/libmutter-18.so.0.0.0
LIVE=/usr/lib/aarch64-linux-gnu/libmutter-18.so.0.0.0
[ -f "$WANT" ] || exit 0
[ -f "$LIVE" ] || exit 0
want_id=$(readelf -n "$WANT" 2>/dev/null | awk '/Build ID/{print $NF; exit}')
live_id=$(readelf -n "$LIVE" 2>/dev/null | awk '/Build ID/{print $NF; exit}')
[ -n "$want_id" ] && [ "$want_id" = "$live_id" ] && exit 0
install -m 0644 "$WANT" "$LIVE"
ln -sfn libmutter-18.so.0.0.0 /usr/lib/aarch64-linux-gnu/libmutter-18.so.0
ldconfig
echo "dagu-mutter-repeat-keep: restored $want_id onto $LIVE"
