#!/usr/bin/env bash
# Compile port/dagu DSDT.aml on the host. Does not flash.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ACPI="${ROOT}/port/dagu/Platform/Xiaomi/sm8250/AcpiTables/dagu"
cd "${ACPI}"

IASL=""
for c in \
  "$(command -v iasl 2>/dev/null || true)" \
  "${ROOT}/tools/bin/iasl" \
  /usr/bin/iasl
do
  if [[ -n "${c}" && -x "${c}" ]]; then
    IASL="${c}"
    break
  fi
done

if [[ -z "${IASL}" ]]; then
  echo "[compile-dagu-acpi] iasl missing. Install acpica-tools." >&2
  exit 2
fi

"${IASL}" -ve Dsdt.asl
test -f DSDT.aml
echo "[compile-dagu-acpi] OK ${ACPI}/DSDT.aml ($(stat -c%s DSDT.aml) bytes)"
