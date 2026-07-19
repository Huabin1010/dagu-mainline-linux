#!/usr/bin/env bash
# Bootstrap WSL-native project workspace via git clone (no /mnt rsync).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/wsl-workspace-lib.sh"

PROJECT_REPO_URL="${PROJECT_REPO_URL:-${1:-}}"
EDK2_URL="${EDK2_URL:-https://github.com/edk2-porting/edk2-msm.git}"
VENDOR_DT_URL="${VENDOR_DT_URL:-https://github.com/MiCode/kernel_devicetree.git}"
VENDOR_DT_BRANCH="${VENDOR_DT_BRANCH:-dagu-s-oss}"

usage() {
  cat <<EOF
Usage:
  bootstrap-wsl-workspace.sh [project-git-url]

Environment:
  PROJECT_REPO_URL   Git URL (required on first clone)

Target directory:
  ${WSL_WORKSPACE}
EOF
}

clone_project() {
  if [[ -d "${WSL_WORKSPACE}/.git" ]]; then
    echo "[bootstrap] project repo exists, pulling ..."
    git -C "${WSL_WORKSPACE}" pull --ff-only
    return
  fi

  if [[ -z "${PROJECT_REPO_URL}" ]]; then
    usage >&2
    echo "[bootstrap] ERROR: set PROJECT_REPO_URL or pass git URL" >&2
    exit 2
  fi

  rm -rf "${WSL_WORKSPACE}"
  echo "[bootstrap] git clone ${PROJECT_REPO_URL}"
  git clone "${PROJECT_REPO_URL}" "${WSL_WORKSPACE}"
}

clone_upstream() {
  cd "${WSL_WORKSPACE}"

  if [[ ! -d edk2-msm/.git ]]; then
    echo "[bootstrap] git clone --recursive ${EDK2_URL}"
    git clone --recursive "${EDK2_URL}" edk2-msm
  else
    git -C edk2-msm pull --ff-only || true
    git -C edk2-msm submodule update --init --recursive
  fi

  if [[ ! -d vendor/kernel_devicetree/.git ]]; then
    mkdir -p vendor
    echo "[bootstrap] git clone -b ${VENDOR_DT_BRANCH} ${VENDOR_DT_URL}"
    git clone -b "${VENDOR_DT_BRANCH}" "${VENDOR_DT_URL}" vendor/kernel_devicetree
  else
    git -C vendor/kernel_devicetree pull --ff-only || true
  fi

  mkdir -p artifacts dumps
  bash tools/apply-dagu-port.sh

  python3 - <<PY
import json
from datetime import datetime, timezone
from pathlib import Path
root = Path("${WSL_WORKSPACE}")
(root / ".wsl-workspace").write_text(
    json.dumps(
        {
            "role": "wsl-native-root",
            "project": "xiaomi-pad870-win11-arm",
            "updated_at": datetime.now(timezone.utc).isoformat(),
        },
        indent=2,
    )
    + "\n",
    encoding="utf-8",
)
PY
}

main() {
  [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && usage && exit 0
  clone_project
  clone_upstream
  echo "[bootstrap] OK: ${WSL_WORKSPACE}"
  echo "  cd ${WSL_WORKSPACE}"
  echo "  ./tools/build-dagu-uefi.sh"
}

main "$@"
