#!/usr/bin/env bash
set -euo pipefail
cd /home/hhb1010/projects/xiaomi-pad870-win11-arm
rm -f .git
git init
git config core.autocrlf input
git config user.email "dagu@local"
git config user.name "dagu-wsl"
git add -A
git commit -m "WSL workspace snapshot (aligned with Windows 3071cb8)." \
  -m "Native ext4 build tree; edk2-msm/vendor/artifacts gitignored locally."
git status
git log -1 --oneline
