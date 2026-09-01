from __future__ import annotations

import importlib.util
import io
from pathlib import Path
import tempfile
import unittest
from contextlib import redirect_stdout
from unittest.mock import patch


SCRIPT = Path(__file__).resolve().parents[1] / "measure_startup_performance.py"
SPEC = importlib.util.spec_from_file_location("measure_startup_performance", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class StartupPerformanceMeasurementTests(unittest.TestCase):
    @staticmethod
    def snapshot_line(
        *,
        app_launch_completed: int = 1,
        semantic_ready: int = 1,
        probe_available: int = 1,
        startup_seconds: float = 1.6,
    ) -> str:
        return (
            f"[StartupSnapshot] app_launch_completed={app_launch_completed} "
            f"semantic_search_ready={semantic_ready} "
            f"main_thread_probe_available={probe_available} "
            f"startup_to_semantic_seconds={startup_seconds} "
            "semantic_warmup_seconds=1.5 launch_to_shell_seconds=0.1 "
            "index_load_seconds=0.3 main_thread_stall_seconds=0.0\n"
        )

    def test_parses_single_snapshot(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            log = Path(directory) / "launch.log"
            log.write_text(self.snapshot_line(), encoding="utf-8")

            snapshot = MODULE.parse_snapshot(log)

            self.assertEqual(snapshot["semantic_search_ready"], 1)
            self.assertEqual(snapshot["semantic_warmup_seconds"], 1.5)
            self.assertEqual(snapshot["startup_to_semantic_seconds"], 1.6)

    def test_rejects_multiple_snapshots_in_one_log(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            log = Path(directory) / "launch.log"
            log.write_text(self.snapshot_line() * 2, encoding="utf-8")

            with self.assertRaisesRegex(ValueError, "exactly one"):
                MODULE.parse_snapshot(log)

    def test_rejects_unavailable_required_duration(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            log = Path(directory) / "launch.log"
            log.write_text(self.snapshot_line(startup_seconds=-1), encoding="utf-8")

            with self.assertRaisesRegex(ValueError, "unavailable durations"):
                MODULE.parse_snapshot(log)

    def test_aggregates_medians_and_requires_all_launches_ready(self) -> None:
        snapshots = [
            {
                "app_launch_completed": 1.0,
                "semantic_search_ready": 1.0,
                "main_thread_probe_available": 1.0,
                "semantic_warmup_seconds": 2.0,
            },
            {
                "app_launch_completed": 1.0,
                "semantic_search_ready": 0.0,
                "main_thread_probe_available": 1.0,
                "semantic_warmup_seconds": 1.0,
            },
            {
                "app_launch_completed": 1.0,
                "semantic_search_ready": 1.0,
                "main_thread_probe_available": 1.0,
                "semantic_warmup_seconds": 1.5,
            },
        ]

        result = MODULE.aggregate(snapshots)

        self.assertEqual(result["semantic_warmup_seconds"], 1.5)
        self.assertEqual(result["semantic_search_ready"], 0)
        self.assertEqual(result["sample_count"], 3)

    def test_main_fails_when_any_startup_gate_is_not_ready(self) -> None:
        failed_gate_arguments = {
            "app_launch_completed": {"app_launch_completed": 0},
            "semantic_search_ready": {"semantic_ready": 0},
            "main_thread_probe_available": {"probe_available": 0},
        }
        for expected_gate, arguments in failed_gate_arguments.items():
            with self.subTest(gate=expected_gate):
                with tempfile.TemporaryDirectory() as directory:
                    root = Path(directory)
                    log = root / "launch.log"
                    manifest = root / "manifest.txt"
                    log.write_text(self.snapshot_line(**arguments), encoding="utf-8")
                    manifest.write_text(f"{log}\n", encoding="utf-8")

                    output = io.StringIO()
                    with patch("sys.argv", [str(SCRIPT), "--manifest", str(manifest)]):
                        with redirect_stdout(output):
                            exit_code = MODULE.main()

                    self.assertEqual(exit_code, 1)
                    self.assertIn(f'"{expected_gate}": 0', output.getvalue())


if __name__ == "__main__":
    unittest.main()
