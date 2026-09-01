#!/usr/bin/env python3
"""Run Memorable's complete automated release-readiness gate."""

from __future__ import annotations

import os
from pathlib import Path
import subprocess
import sys


ROOT = Path(__file__).resolve().parent.parent
DEFAULT_SIMULATOR_DESTINATION = "platform=iOS Simulator,name=iPhone 17 Pro"


def release_commands(
    simulator_destination: str,
    python_executable: str = sys.executable,
) -> list[list[str]]:
    project = ["-project", "Memorable.xcodeproj"]
    return [
        [python_executable, "-m", "unittest", "discover", "-s", "scripts/tests"],
        [python_executable, "scripts/premerge.py"],
        [
            "xcodebuild",
            *project,
            "-scheme",
            "Memorable",
            "-destination",
            simulator_destination,
            "-quiet",
            "test",
        ],
        [
            "xcodebuild",
            *project,
            "-scheme",
            "MemorableReleaseTests",
            "-destination",
            simulator_destination,
            "-quiet",
            "test",
        ],
        [
            "xcodebuild",
            *project,
            "-scheme",
            "Memorable",
            "-configuration",
            "Release",
            "-destination",
            "generic/platform=iOS Simulator",
            "CODE_SIGNING_ALLOWED=NO",
            "-quiet",
            "build",
        ],
        [
            "xcodebuild",
            *project,
            "-scheme",
            "Memorable",
            "-configuration",
            "Release",
            "-destination",
            "generic/platform=iOS Simulator",
            "CODE_SIGNING_ALLOWED=NO",
            "-quiet",
            "analyze",
        ],
    ]


def run(command: list[str]) -> None:
    print(f"\n=== {' '.join(command)} ===", flush=True)
    subprocess.run(command, cwd=ROOT, check=True)


def main() -> int:
    destination = os.environ.get(
        "MEMORABLE_TEST_DESTINATION",
        DEFAULT_SIMULATOR_DESTINATION,
    )
    try:
        for command in release_commands(destination):
            run(command)
    except FileNotFoundError as error:
        print(f"release gate: required tool not found: {error.filename}", file=sys.stderr)
        return 127
    except subprocess.CalledProcessError as error:
        print(
            f"release gate: command failed with exit status {error.returncode}",
            file=sys.stderr,
        )
        return error.returncode or 1

    print("\nAll automated release gates passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
