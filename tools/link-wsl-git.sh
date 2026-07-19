#!/usr/bin/env bash
# Link WSL workspace git to Windows repo and verify clean tree.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/wsl-workspace-lib.sh"

WIN="$(resolve_win_repo_path)" || {
  echo "[wsl-git-link] win repo path not found" >&2
  exit 1
}

if [[ ! -d "${WIN}/.git" ]]; then
  echo "[wsl-git-link] missing ${WIN}/.git — commit on Windows first" >&2
  exit 1
}

if [[ -e "${WSL_WORKSPACE}/.git" && ! -L "${WSL_WORKSPACE}/.git" ]]; then
  echo "[wsl-git-link] ${WSL_WORKSPACE}/.git exists and is not a symlink" >&2
  exit 1
fi

ln -sfn "${WIN}/.git" "${WSL_WORKSPACE}/.git"
echo "[wsl-git-link] OK -> ${WIN}/.git"

cd "${WSL_WORKSPACE}"
git status --short
git log -1 --oneline
