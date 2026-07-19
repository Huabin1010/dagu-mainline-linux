#!/usr/bin/env bash
# Hybrid workflow: sync build-related paths from Windows repo -> WSL workspace (not full tree).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/wsl-workspace-lib.sh"

WIN="${WIN_REPO:-/mnt/e/Projects/xiaomi-pad870-win11-arm}"
if [[ -f "${REPO_ROOT}/wsl-layer.json" ]]; then
  _win="$(python3 - "${REPO_ROOT}/wsl-layer.json" <<'PY'
import json, sys
from pathlib import Path
p = Path(sys.argv[1])
d = json.loads(p.read_text(encoding="utf-8"))
w = d.get("win_repo_path", "")
if w and len(w) >= 3 and w[1] == ":":
    drive = w[0].lower()
    rest = w[2:].lstrip("/\\").replace("\\", "/")
    print(f"/mnt/{drive}/{rest}")
elif w:
    print(w)
PY
)"
  [[ -n "${_win}" ]] && WIN="${_win}"
fi

if [[ ! -d "${WIN}" ]]; then
  echo "[sync-build] Windows repo not found: ${WIN}" >&2
  exit 1
fi

mkdir -p "${WSL_WORKSPACE}/port" "${WSL_WORKSPACE}/tools"
echo "[sync-build] ${WIN} -> ${WSL_WORKSPACE} (port + tools only)"

rsync -a "${WIN}/port/" "${WSL_WORKSPACE}/port/"
rsync -a "${WIN}/tools/" "${WSL_WORKSPACE}/tools/"
rsync -a "${WIN}/wsl-layer.json" "${WSL_WORKSPACE}/wsl-layer.json"
rsync -a "${WIN}/.gitattributes" "${WSL_WORKSPACE}/.gitattributes"

find "${WSL_WORKSPACE}/tools" -type f \( -name '*.sh' -o -name '*.lib.sh' \) -exec sed -i 's/\r$//' {} +

if [[ -d "${WSL_WORKSPACE}/edk2-msm/.git" ]]; then
  bash "${WSL_WORKSPACE}/tools/apply-dagu-port.sh"
else
  echo "[sync-build] WARN: edk2-msm missing; run bootstrap-wsl-workspace.sh first"
fi

echo "[sync-build] OK"
