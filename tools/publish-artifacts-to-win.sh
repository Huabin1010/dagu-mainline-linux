#!/usr/bin/env bash
# Copy WSL-native boot-dagu-latest.img -> Windows repo artifacts/ (for fastboot on Win).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/wsl-workspace-lib.sh"

ROOT="${WSL_WORKSPACE:-$HOME/projects/xiaomi-pad870-win11-arm}"
SRC="${1:-${ROOT}/artifacts/boot-dagu-latest.img}"

if [[ ! -f "${SRC}" ]]; then
  echo "[publish-artifacts] not found: ${SRC}" >&2
  echo "[publish-artifacts] build first: cd ${ROOT} && ./tools/build-dagu-uefi.sh" >&2
  exit 1
fi

publish_boot_artifact_to_win "${SRC}"
