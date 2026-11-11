import importlib.util
import pathlib
import unittest

_P = pathlib.Path(__file__).with_name("smmuwt-verdict.py")
_spec = importlib.util.spec_from_file_location("smmuwt_verdict", _P)
sv = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(sv)


def _single(nn, pre, wr, rb, rs=None, rb2=None):
    return {
        "t%d_pre" % nn: pre, "t%d_wr" % nn: wr, "t%d_rb" % nn: rb,
        "t%d_rb2" % nn: rb if rb2 is None else rb2,
        "t%d_rs" % nn: pre if rs is None else rs,
    }


class ClassifyTest(unittest.TestCase):
    def test_stuck_when_readback_equals_write(self):
        self.assertEqual(sv.classify(1, 2, 2), "stuck")

    def test_reverted_when_readback_equals_previous(self):
        self.assertEqual(sv.classify(1, 2, 1), "reverted")

    def test_changed_when_readback_is_neither(self):
        self.assertEqual(sv.classify(1, 2, 3), "changed")

    def test_not_run_without_readback(self):
        self.assertEqual(sv.classify(1, 2, None), "not run")

    def test_equal_pre_and_write_counts_as_stuck(self):
        self.assertEqual(sv.classify(5, 5, 5), "stuck")


class WhereTest(unittest.TestCase):
    def test_finished(self):
        self.assertEqual(sv.where(0x6399), "programme finished")

    def test_missing_step(self):
        self.assertIn("never ran", sv.where(None))

    def test_single_phase(self):
        self.assertEqual(sv.where((32 << 8) | 0x20), "CB0.TCR: about to write")

    def test_combined_phase(self):
        self.assertEqual(sv.where(0x2807), "combined: after SCTLR.M=1")

    def test_power_gate(self):
        self.assertIn("nothing written", sv.where(0x01A2))

    def test_unknown_phase_is_shown_raw(self):
        self.assertEqual(sv.where(0x1F77), "CB0.TTBR1: phase 0x77")


class VerdictTest(unittest.TestCase):
    def test_all_stuck_and_cb0_enabled(self):
        # Arrange
        p = {"step": 0x6399}
        for nn in sv.SINGLE:
            p.update(_single(nn, 0, 7, 7))
        for f in sv.FIELDS:
            p["t40_p_" + f] = 0
            p["t40_g_" + f] = 1
        p.update({"t40_sync": 0, "t40_fsr": 0, "t40_fsr2": 0, "t40_sgfsr": 0, "t40_restored": 1})
        # Act
        lines = sv.verdict(p)
        # Assert
        self.assertIn("programme finished", lines[0])
        self.assertEqual(sum("  stuck" in l for l in lines), len(sv.SINGLE))
        self.assertIn("ENABLED", lines[-1])

    def test_reset_is_attributed_to_the_pending_write(self):
        # Arrange: TTBR1 and TCR done, reset flushed at MAIR0 "about to write"
        p = {"step": (34 << 8) | 0x20}
        p.update(_single(31, 0, 0x1000, 0x1000))
        p.update(_single(32, 0, 0xB5100080, 0xB5100080))
        p.update({"t34_pre": 0, "t34_wr": 0xF404FF44})
        # Act
        lines = sv.verdict(p)
        # Assert
        mair = next(l for l in lines if l.startswith("CB0.MAIR0"))
        self.assertIn("RESET during this write", mair)
        tcr2 = next(l for l in lines if l.startswith("CB0.TCR2"))
        self.assertIn("not run", tcr2)

    def test_reverted_sctlr_m_reports_not_enabled(self):
        p = {"step": 0x6399, "t40_g_sctlr": 0x32622100, "t40_p_sctlr": 0x32622100}
        lines = sv.verdict(p)
        self.assertIn("not enabled", lines[-1])

    def test_drift_and_failed_restore_are_flagged(self):
        p = {"step": 0x6399}
        p.update(_single(38, 0, 0x1F300, 0x1F300, rs=0x1F300, rb2=0))
        line = next(l for l in sv.verdict(p) if l.startswith("CBAR0"))
        self.assertIn("drifted to 0x0", line)
        self.assertIn("RESTORE FAILED", line)

    def test_reset_inside_combined(self):
        p = {"step": (40 << 8) | 0x07}
        for nn in sv.SINGLE:
            p.update(_single(nn, 0, 1, 1))
        lines = sv.verdict(p)
        self.assertIn("RESET at combined: after SCTLR.M=1", lines[-1])

    def test_empty_hive_values(self):
        lines = sv.verdict({})
        self.assertIn("never ran", lines[0])
        self.assertTrue(all("not run" in l for l in lines[1:]))

    def test_first_board_run_reports_skipped_combined(self):
        # Arrange: stage 24 run 1, CBAR stayed at the Linux value
        p = {"step": 0x6399, "single_fails": 1}
        p.update(_single(38, 0, 0x1F300, 0x1F300, rs=0x1F300))
        # Act
        lines = sv.verdict(p)
        # Assert
        self.assertIn("RESTORE FAILED", next(l for l in lines if l.startswith("CBAR0")))
        self.assertIn("skipped, 1 single write", lines[-1])

    def test_skip_because_cb0_in_use(self):
        lines = sv.verdict({"step": 0x6399, "combined_skip": 2})
        self.assertIn("already translates", lines[-1])


if __name__ == "__main__":
    unittest.main()
