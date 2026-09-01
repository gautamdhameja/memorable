from __future__ import annotations

from pathlib import Path
import subprocess
import sys
import unittest
from unittest import mock


SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))

import release_gate  # noqa: E402


class ReleaseGateTests(unittest.TestCase):
    def test_command_contract_covers_every_automated_release_check(self) -> None:
        commands = release_gate.release_commands("simulator-destination", "python")

        self.assertEqual(len(commands), 6)
        self.assertEqual(
            commands[0],
            ["python", "-m", "unittest", "discover", "-s", "scripts/tests"],
        )
        self.assertEqual(commands[1], ["python", "scripts/premerge.py"])
        self.assertIn("Memorable", commands[2])
        self.assertIn("test", commands[2])
        self.assertIn("MemorableReleaseTests", commands[3])
        self.assertIn("test", commands[3])
        self.assertIn("Release", commands[4])
        self.assertIn("build", commands[4])
        self.assertIn("Release", commands[5])
        self.assertIn("analyze", commands[5])
        for command in commands[2:4]:
            self.assertIn("simulator-destination", command)

    @mock.patch("release_gate.run")
    def test_main_runs_every_command(self, run: mock.Mock) -> None:
        with mock.patch.dict(
            release_gate.os.environ,
            {"MEMORABLE_TEST_DESTINATION": "chosen-simulator"},
        ), mock.patch("builtins.print"):
            result = release_gate.main()

        self.assertEqual(result, 0)
        self.assertEqual(run.call_count, 6)
        for call in run.call_args_list[2:4]:
            self.assertIn("chosen-simulator", call.args[0])

    @mock.patch("release_gate.run")
    def test_main_stops_after_the_first_failed_command(self, run: mock.Mock) -> None:
        run.side_effect = subprocess.CalledProcessError(65, ["xcodebuild"])

        with mock.patch("builtins.print"):
            result = release_gate.main()

        self.assertEqual(result, 65)
        self.assertEqual(run.call_count, 1)


if __name__ == "__main__":
    unittest.main()
