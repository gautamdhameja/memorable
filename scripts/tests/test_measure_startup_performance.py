from __future__ import annotations

import importlib.util
from pathlib import Path
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "measure_startup_performance.py"
SPEC = importlib.util.spec_from_file_location("measure_startup_performance", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class StartupPerformanceMeasurementTests(unittest.TestCase):
    def test_parses_latest_snapshot(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            log = Path(directory) / "launch.log"
            log.write_text(
                "[StartupSnapshot] app_launch_completed=1 semantic_search_ready=0 "
                "semantic_warmup_seconds=2.0 launch_to_shell_seconds=0.2 "
                "index_load_seconds=0.4\n"
                "[StartupSnapshot] app_launch_completed=1 semantic_search_ready=1 "
                "semantic_warmup_seconds=1.5 launch_to_shell_seconds=0.1 "
                "index_load_seconds=0.3\n",
                encoding="utf-8",
            )

            snapshot = MODULE.parse_snapshot(log)

            self.assertEqual(snapshot["semantic_search_ready"], 1)
            self.assertEqual(snapshot["semantic_warmup_seconds"], 1.5)

    def test_aggregates_medians_and_requires_all_launches_ready(self) -> None:
        snapshots = [
            {
                "app_launch_completed": 1.0,
                "semantic_search_ready": 1.0,
                "semantic_warmup_seconds": 2.0,
            },
            {
                "app_launch_completed": 1.0,
                "semantic_search_ready": 0.0,
                "semantic_warmup_seconds": 1.0,
            },
            {
                "app_launch_completed": 1.0,
                "semantic_search_ready": 1.0,
                "semantic_warmup_seconds": 1.5,
            },
        ]

        result = MODULE.aggregate(snapshots)

        self.assertEqual(result["semantic_warmup_seconds"], 1.5)
        self.assertEqual(result["semantic_search_ready"], 0)
        self.assertEqual(result["sample_count"], 3)


if __name__ == "__main__":
    unittest.main()
