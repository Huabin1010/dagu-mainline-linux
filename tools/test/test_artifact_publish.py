#!/usr/bin/env python3
"""Build/publish pipeline tests — ensure Windows gets the WSL-built boot image."""
from __future__ import annotations

import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


class TestArtifactPublishPipeline(unittest.TestCase):
    def test_build_script_publishes_to_windows(self) -> None:
        text = (ROOT / "tools/build-dagu-uefi.sh").read_text(
            encoding="utf-8", errors="replace"
        )
        self.assertIn("publish_boot_artifact_to_win", text)

    def test_wsl_lib_has_publish_helper(self) -> None:
        text = (ROOT / "tools/wsl-workspace-lib.sh").read_text(
            encoding="utf-8", errors="replace"
        )
        self.assertIn("resolve_win_repo_path", text)
        self.assertIn("publish_boot_artifact_to_win", text)
        self.assertIn("win_repo_path", text)

    def test_publish_script_exists(self) -> None:
        path = ROOT / "tools/publish-artifacts-to-win.sh"
        self.assertTrue(path.is_file())
        self.assertIn("publish_boot_artifact_to_win", path.read_text(encoding="utf-8"))


if __name__ == "__main__":
    raise SystemExit(unittest.main())
