#!/usr/bin/env python3
"""Run Memorable's required pre-merge safety gates."""

from __future__ import annotations

from pathlib import Path
import subprocess
import sys


ROOT = Path(__file__).resolve().parent.parent


def run(command: list[str]) -> None:
    print(f"\n=== {' '.join(command)} ===", flush=True)
    subprocess.run(command, cwd=ROOT, check=True)


def main() -> int:
    try:
        run([sys.executable, "scripts/migration_guard.py"])
        run([sys.executable, "scripts/relevance.py", "run"])
    except subprocess.CalledProcessError as error:
        print(f"premerge: gate failed with exit status {error.returncode}", file=sys.stderr)
        return error.returncode or 1
    print("\nAll pre-merge gates passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
