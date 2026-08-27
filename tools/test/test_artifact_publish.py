#!/usr/bin/env python3
"""Build/artifact stamp pipeline tests — local Linux workspace only."""
from __future__ import annotations

import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


class TestArtifactStampPipeline(unittest.TestCase):
    def test_build_script_writes_local_stamp(self) -> None:
        text = (ROOT / "tools/build-dagu-uefi.sh").read_text(
            encoding="utf-8", errors="replace"
        )
        self.assertIn("write_boot_artifact_stamp", text)
        self.assertIn("sha256=", text)
        self.assertNotIn("publish_boot_artifact_to_win", text)
        self.assertNotIn("wsl-workspace-lib", text)

    def test_verify_script_is_local_only(self) -> None:
        text = (ROOT / "tools/verify-boot-artifact.sh").read_text(
            encoding="utf-8", errors="replace"
        )
        self.assertIn("sha256", text)
        self.assertNotIn("wsl-workspace-lib", text)
        self.assertNotIn("resolve_win_repo_path", text)
        self.assertNotIn("Windows", text)

    def test_wsl_pipeline_removed(self) -> None:
        self.assertFalse((ROOT / "tools/wsl-workspace-lib.sh").is_file())
        self.assertFalse((ROOT / "wsl-layer.json").is_file())
        self.assertFalse((ROOT / "tools/publish-artifacts-to-win.sh").is_file())
        self.assertFalse((ROOT / "tools/wsl-layer").is_dir())
        self.assertFalse((ROOT / "tools/bootstrap-wsl-workspace.sh").is_file())

    def test_bootstrap_workspace_exists(self) -> None:
        path = ROOT / "tools/bootstrap-workspace.sh"
        self.assertTrue(path.is_file())
        text = path.read_text(encoding="utf-8")
        self.assertIn("edk2-msm", text)
        self.assertIn("apply-dagu-port.sh", text)


if __name__ == "__main__":
    raise SystemExit(unittest.main())
