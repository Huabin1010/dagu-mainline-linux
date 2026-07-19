#!/usr/bin/env bash
# WSL workspace path resolution (native ext4 only).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

WSL_WORKSPACE="${WSL_WORKSPACE:-$HOME/projects/xiaomi-pad870-win11-arm}"

if [[ -f "${REPO_ROOT}/wsl-layer.json" ]]; then
  _ws="$(python3 - "${REPO_ROOT}/wsl-layer.json" <<'PY'
import json, sys
from pathlib import Path
data = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
print(data.get("wsl_workspace") or data.get("initial_cwd") or "")
PY
)"
  if [[ -n "${_ws}" ]]; then
    WSL_WORKSPACE="${_ws/#\~/$HOME}"
  fi
fi

export WSL_WORKSPACE REPO_ROOT

# Resolve Windows repo path (for publishing artifacts back to E:\...)
resolve_win_repo_path() {
  local win="${WIN_REPO:-}"
  if [[ -z "${win}" && -f "${REPO_ROOT}/wsl-layer.json" ]]; then
    win="$(python3 - "${REPO_ROOT}/wsl-layer.json" <<'PY'
import json, sys
from pathlib import Path
data = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
w = data.get("win_repo_path", "")
if w and len(w) >= 3 and w[1] == ":":
    drive = w[0].lower()
    rest = w[2:].lstrip("/\\").replace("\\", "/")
    print(f"/mnt/{drive}/{rest}")
elif w:
    print(w.replace("\\", "/"))
PY
)"
  fi
  if [[ -n "${win}" && -d "${win}" ]]; then
    printf '%s\n' "${win}"
    return 0
  fi
  return 1
}

publish_boot_artifact_to_win() {
  local src_img="$1"
  local win_repo=""
  local win_artifacts=""
  local stamp_file=""

  if [[ ! -f "${src_img}" ]]; then
    echo "[publish-artifacts] missing source image: ${src_img}" >&2
    return 1
  fi

  if ! win_repo="$(resolve_win_repo_path)"; then
    echo "[publish-artifacts] skip (win_repo_path not available)"
    return 0
  fi

  win_artifacts="${win_repo}/artifacts"
  mkdir -p "${win_artifacts}"
  cp -fv "${src_img}" "${win_artifacts}/$(basename "${src_img}")"
  cp -fv "${src_img}" "${win_artifacts}/boot-dagu-latest.img"

  stamp_file="${win_artifacts}/boot-dagu-latest.stamp"
  {
    echo "source=${src_img}"
    echo "bytes=$(stat -c%s "${src_img}" 2>/dev/null || wc -c < "${src_img}")"
    echo "published_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "wsl_workspace=${WSL_WORKSPACE}"
  } > "${stamp_file}"

  echo "[publish-artifacts] OK -> ${win_artifacts}/boot-dagu-latest.img"
}
