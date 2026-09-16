#!/usr/bin/env bash
# HMCL JavaFX 25 ships libprism_es2.so linked to libGL/libX11 (X11GLFactory).
# Native Wayland Glass has no GLX display → Prism falls to SWPipeline and
# HMCL warns 正在使用软件渲染. Attach Xwayland + GDK x11 so ES2 hits
# Mesa msm / FD650 (Turnip), not llvmpipe.
set -euo pipefail

uid=$(id -u)
runtime="${XDG_RUNTIME_DIR:-/run/user/${uid}}"
export XDG_RUNTIME_DIR="$runtime"

if [ -z "${DISPLAY:-}" ]; then
	export DISPLAY=:0
fi
if [ -z "${XAUTHORITY:-}" ]; then
	for f in "${runtime}"/.mutter-Xwaylandauth.*; do
		if [ -f "$f" ]; then
			export XAUTHORITY="$f"
			break
		fi
	done
fi
if [ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ] && [ -S "${runtime}/bus" ]; then
	export DBUS_SESSION_BUS_ADDRESS="unix:path=${runtime}/bus"
fi

# Glass and Prism must share the X11/GLX path. Do not leave GTK on Wayland.
export GDK_BACKEND=x11
unset LIBGL_ALWAYS_SOFTWARE
unset MESA_LOADER_DRIVER_OVERRIDE

_prism_gpu='-Dprism.order=es2 -Dprism.forceGPU=true'
if [ -n "${HMCL_JAVA_OPTS+x}" ]; then
	case " ${HMCL_JAVA_OPTS} " in
	*' -Dprism.order='*|*' -Dprism.forceGPU='*) ;;
	*) export HMCL_JAVA_OPTS="${HMCL_JAVA_OPTS} ${_prism_gpu}" ;;
	esac
else
	export HMCL_JAVA_OPTS="-XX:MinHeapFreeRatio=5 -XX:MaxHeapFreeRatio=15 ${_prism_gpu}"
fi

if [ -z "${HMCL_USER_HOME:-}" ]; then
	if [ -z "${XDG_DATA_HOME:-}" ]; then
		export HMCL_USER_HOME="${HOME}/.local/share/hmcl"
	else
		export HMCL_USER_HOME="${XDG_DATA_HOME}/hmcl"
	fi
fi
if [ -z "${HMCL_LOCAL_HOME:-}" ]; then
	export HMCL_LOCAL_HOME="${HMCL_USER_HOME}/local-stable"
fi
if [ -z "${HMCL_DEPENDENCIES_DIR:-}" ]; then
	export HMCL_DEPENDENCIES_DIR="${HMCL_USER_HOME}/dependencies"
fi

hmcl_jar=""
for c in /usr/share/java/hmcl/HMCL-*.sh; do
	[ -f "$c" ] && hmcl_jar=$c
done
if [ -z "$hmcl_jar" ]; then
	echo "dagu-hmcl: HMCL jar not found under /usr/share/java/hmcl" >&2
	exit 1
fi
cd "${HOME}"
exec "$hmcl_jar" "$@"
