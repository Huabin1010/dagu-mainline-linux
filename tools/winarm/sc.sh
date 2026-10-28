#!/bin/bash
# Serial-cmd wrapper for the relay machine the tablet is plugged into. Runs
# serial-cmd.py against the tablet's serial gadget with sudo (the login user
# is not in dialout). The serial command text is read from STDIN so there is
# zero ssh-quoting trouble; the sudo password is fed separately, so sudo never
# consumes the piped command.
#   echo 'CMD'        | ssh ... 'bash ~/dagu-touch/sc.sh cmd <timeout>'
#   printf 'KEYS'     | ssh ... 'bash ~/dagu-touch/sc.sh raw <timeout>'
#                       ssh ... 'bash ~/dagu-touch/sc.sh push <local> <remote>'
# The sudo password comes from $DAGU_SUDO_PW or ~/dagu-touch/.sudo-pw (never
# stored in the repository).
D="${DAGU_TOUCH_DIR:-$HOME/dagu-touch}"
PW="${DAGU_SUDO_PW:-$(cat "$D/.sudo-pw" 2>/dev/null)}"
# After a tablet reboot the serial gadget may re-enumerate as a higher ttyACM
# node (stale node lingers). Always target the highest-numbered one.
DEV="$(ls /dev/ttyACM* 2>/dev/null | sort -V | tail -1)"
[ -n "$DEV" ] || DEV=/dev/ttyACM0
mode="$1"; shift
case "$mode" in
  raw) to="$1"; c="$(cat)"; echo "$PW" | sudo -S python3 "$D/serial-cmd.py" --dev "$DEV" --raw --timeout "$to" "$c" ;;
  cmd) to="$1"; c="$(cat)"; echo "$PW" | sudo -S python3 "$D/serial-cmd.py" --dev "$DEV" --timeout "$to" "$c" ;;
  push) echo "$PW" | sudo -S python3 "$D/serial-cmd.py" --dev "$DEV" --push "$1" "$2" ;;
  dev) echo "$DEV" ;;
  *) echo "usage: sc.sh raw|cmd|push|dev ..." >&2; exit 2 ;;
esac
