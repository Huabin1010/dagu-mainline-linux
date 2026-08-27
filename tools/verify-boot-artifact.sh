#!/usr/bin/env bash
# Verify artifacts/boot-dagu-latest.img matches its stamp.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

IMG="${1:-${ROOT}/artifacts/boot-dagu-latest.img}"
STAMP="${IMG%.img}.stamp"

fail() {
  echo "[verify-artifact] ERROR: $*" >&2
  exit 1
}

[[ -f "${IMG}" ]] || fail "missing image: ${IMG}"

bytes="$(stat -c%s "${IMG}" 2>/dev/null || wc -c < "${IMG}")"
[[ "${bytes}" -ge 1048576 ]] || fail "image too small (${bytes} bytes): ${IMG}"

sha256="$(sha256sum "${IMG}" | awk '{print $1}')"
[[ -f "${STAMP}" ]] || fail "missing stamp (rebuild with ./tools/build-dagu-uefi.sh): ${STAMP}"

stamp_bytes="$(grep -E '^bytes=' "${STAMP}" | cut -d= -f2- || true)"
stamp_sha="$(grep -E '^sha256=' "${STAMP}" | cut -d= -f2- || true)"

[[ -n "${stamp_bytes}" && "${stamp_bytes}" == "${bytes}" ]] \
  || fail "stamp bytes=${stamp_bytes} != file bytes=${bytes}"

if [[ -n "${stamp_sha}" ]]; then
  [[ "${stamp_sha}" == "${sha256}" ]] \
    || fail "stamp sha256 != file sha256"
else
  echo "[verify-artifact] WARN: stamp has no sha256 (legacy); updating stamp"
  {
    grep -E '^source=' "${STAMP}" || echo "source=${IMG}"
    echo "bytes=${bytes}"
    echo "sha256=${sha256}"
    grep -E '^published_at=' "${STAMP}" || echo "published_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  } > "${STAMP}.tmp"
  mv "${STAMP}.tmp" "${STAMP}"
fi

echo "[verify-artifact] OK: ${IMG} (${bytes} bytes, sha256=${sha256:0:12}...)"
