#!/usr/bin/env bash
# Sync full tracked repo from Windows -> WSL workspace (keeps edk2-msm/vendor local).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/wsl-workspace-lib.sh"

WIN="$(resolve_win_repo_path)" || {
  echo "[sync-repo-to-wsl] win repo not found" >&2
  exit 1
}

mkdir -p "${WSL_WORKSPACE}"
echo "[sync-repo-to-wsl] ${WIN} -> ${WSL_WORKSPACE} (exclude edk2-msm vendor artifacts logs dumps)"

rsync -a --delete \
  --exclude '.git/' \
  --exclude 'edk2-msm/' \
  --exclude 'vendor/' \
  --exclude 'artifacts/' \
  --exclude 'logs/' \
  --exclude 'dumps/' \
  --exclude 'backups/golden/*' \
  --exclude '.wsl-layer/' \
  --exclude 'tools/platform-tools/' \
  --exclude 'tools/mi-unlock-cn/' \
  --exclude 'tools/downloads/' \
  --exclude '__pycache__/' \
  --exclude '*.pyc' \
  "${WIN}/" "${WSL_WORKSPACE}/"

find "${WSL_WORKSPACE}/tools" -type f \( -name '*.sh' -o -name '*.lib.sh' \) -exec sed -i 's/\r$//' {} +

if [[ -d "${WSL_WORKSPACE}/edk2-msm/.git" ]]; then
  bash "${WSL_WORKSPACE}/tools/apply-dagu-port.sh"
fi

echo "[sync-repo-to-wsl] OK"
