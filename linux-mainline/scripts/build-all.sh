#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
./scripts/setup-deps.sh
./scripts/setup-kernel.sh
./scripts/build-kernel.sh
./scripts/build-bootimg.sh
ls -lh out/Image.gz out/*.dtb out/boot-dagu.img
