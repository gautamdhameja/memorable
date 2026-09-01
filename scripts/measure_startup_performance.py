#!/usr/bin/env python3
"""Aggregate machine-readable Memorable startup snapshots from local logs."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import re
import statistics


SNAPSHOT_PREFIX = "[StartupSnapshot]"
PAIR_PATTERN = re.compile(r"([a-z_]+)=(-?\d+(?:\.\d+)?)")
REQUIRED_GATE_FIELDS = {
    "app_launch_completed",
    "semantic_search_ready",
    "main_thread_probe_available",
}
REQUIRED_DURATION_FIELDS = {
    "startup_to_semantic_seconds",
    "semantic_warmup_seconds",
    "launch_to_shell_seconds",
    "index_load_seconds",
    "main_thread_stall_seconds",
}
REQUIRED_FIELDS = REQUIRED_GATE_FIELDS | REQUIRED_DURATION_FIELDS


def parse_snapshot(log_path: Path) -> dict[str, float]:
    snapshots: list[dict[str, float]] = []
    for line in log_path.read_text(encoding="utf-8", errors="replace").splitlines():
        if SNAPSHOT_PREFIX not in line:
            continue
        snapshots.append({key: float(value) for key, value in PAIR_PATTERN.findall(line)})
    if not snapshots:
        raise ValueError(f"no startup snapshot in {log_path}")
    if len(snapshots) != 1:
        raise ValueError(
            f"expected exactly one startup snapshot in {log_path}, found {len(snapshots)}"
        )
    snapshot = snapshots[0]
    missing = REQUIRED_FIELDS.difference(snapshot)
    if missing:
        raise ValueError(f"startup snapshot in {log_path} is missing: {sorted(missing)}")
    invalid_gates = {
        key: snapshot[key]
        for key in REQUIRED_GATE_FIELDS
        if snapshot[key] not in {0, 1}
    }
    if invalid_gates:
        raise ValueError(f"startup snapshot in {log_path} has invalid gates: {invalid_gates}")
    negative_durations = {
        key: snapshot[key]
        for key in REQUIRED_DURATION_FIELDS
        if snapshot[key] < 0
    }
    if negative_durations:
        raise ValueError(
            f"startup snapshot in {log_path} has unavailable durations: {negative_durations}"
        )
    return snapshot


def aggregate(snapshots: list[dict[str, float]]) -> dict[str, float | int]:
    if not snapshots:
        raise ValueError("manifest did not contain any startup logs")
    keys = set.intersection(*(set(snapshot) for snapshot in snapshots))
    result: dict[str, float | int] = {}
    for key in sorted(keys):
        values = [snapshot[key] for snapshot in snapshots]
        if key in REQUIRED_GATE_FIELDS:
            result[key] = int(all(value == 1 for value in values))
        else:
            result[key] = statistics.median(values)
    result["sample_count"] = len(snapshots)
    return result


def load_manifest(manifest_path: Path) -> list[Path]:
    paths: list[Path] = []
    for raw_line in manifest_path.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        paths.append(Path(line).expanduser())
    return paths


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--manifest", type=Path, required=True)
    args = parser.parse_args()
    try:
        snapshots = [parse_snapshot(path) for path in load_manifest(args.manifest)]
        result = aggregate(snapshots)
        print(json.dumps(result, sort_keys=True))
    except (OSError, ValueError) as error:
        print(json.dumps({
            "app_launch_completed": 0,
            "semantic_search_ready": 0,
            "error": str(error),
        }, sort_keys=True))
        return 1
    return 0 if all(result[field] == 1 for field in REQUIRED_GATE_FIELDS) else 1


if __name__ == "__main__":
    raise SystemExit(main())
