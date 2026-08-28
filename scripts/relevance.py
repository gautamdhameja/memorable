#!/usr/bin/env python3
"""Prepare and run Memorable's isolated real-model relevance evaluation."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import urllib.parse
import urllib.request


ROOT = Path(__file__).resolve().parent.parent
MANIFEST = ROOT / "MemorableRelevanceTests/Fixtures/coco-caption-2017.json"
CACHE = ROOT / ".relevance-cache/coco-caption-2017"
IMAGES = CACHE / "images"
APP_CONSTANTS = ROOT / "Memorable/Core/AppConstants.swift"
DATASET = "LIME-DATA/COCO-Caption2017"
REVISION = "b14474455722b8c56eb7cdeb3f6be76fca1bba7a"
CONFIG = "default"
SPLIT = "train"
ROW_COUNT = 50
DESTINATION = "platform=iOS Simulator,name=iPhone 17 Pro"


class RelevanceError(RuntimeError):
    pass


def request_json(url: str) -> dict:
    request = urllib.request.Request(url, headers={"User-Agent": "Memorable-Relevance/1"})
    try:
        with urllib.request.urlopen(request, timeout=60) as response:
            return json.load(response)
    except Exception as error:
        raise RelevanceError(f"request failed for {url}: {error}") from error


def current_revision() -> str:
    encoded = urllib.parse.quote(DATASET, safe="/")
    metadata = request_json(f"https://huggingface.co/api/datasets/{encoded}")
    sha = metadata.get("sha")
    if sha != REVISION:
        raise RelevanceError(
            f"Hub revision mismatch: expected {REVISION}, current revision is {sha!r}"
        )
    return sha


def dataset_rows() -> list[dict]:
    query = urllib.parse.urlencode(
        {
            "dataset": DATASET,
            "config": CONFIG,
            "split": SPLIT,
            "offset": 0,
            "length": ROW_COUNT,
        }
    )
    payload = request_json(f"https://datasets-server.huggingface.co/rows?{query}")
    rows = payload.get("rows", [])
    if len(rows) != ROW_COUNT:
        raise RelevanceError(f"expected {ROW_COUNT} Dataset Viewer rows, got {len(rows)}")
    return rows


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def load_manifest() -> dict:
    try:
        payload = json.loads(MANIFEST.read_text(encoding="utf-8"))
    except FileNotFoundError as error:
        raise RelevanceError(f"fixture manifest is missing: {MANIFEST}") from error
    if payload.get("dataset", {}).get("revision") != REVISION:
        raise RelevanceError("fixture manifest does not use the required pinned revision")
    entries = payload.get("entries", [])
    if len(entries) != ROW_COUNT:
        raise RelevanceError(f"fixture manifest must contain exactly {ROW_COUNT} entries")
    if [entry.get("rowIndex") for entry in entries] != list(range(ROW_COUNT)):
        raise RelevanceError("fixture manifest rows must be the deterministic range 0...49")
    return payload


def validate_manifest_rows(manifest: dict, rows: list[dict]) -> None:
    expected_dataset = {
        "repository": DATASET,
        "revision": REVISION,
        "config": CONFIG,
        "split": SPLIT,
        "license": "apache-2.0",
    }
    if manifest.get("dataset") != expected_dataset:
        raise RelevanceError("fixture manifest dataset metadata is not the approved pinned source")

    for entry, viewer_row in zip(manifest["entries"], rows):
        row = viewer_row["row"]
        expected_asset_id = Path(row["question_id"]).stem
        checks = {
            "rowIndex": viewer_row["row_idx"],
            "rowId": row["id"],
            "questionId": row["question_id"],
            "expectedAssetIds": [expected_asset_id],
            "cocoUrl": row["coco_url"],
            "licenseCode": row["license"],
            "pinnedRevision": REVISION,
            "localFilename": row["question_id"],
        }
        for key, expected in checks.items():
            if entry.get(key) != expected:
                raise RelevanceError(
                    f"manifest row {viewer_row['row_idx']} {key} mismatch: "
                    f"expected {expected!r}, got {entry.get(key)!r}"
                )
        answers = row.get("answer", [])
        if not answers or entry.get("query") != answers[0]:
            raise RelevanceError(
                f"manifest row {viewer_row['row_idx']} query is not the first human answer caption"
            )


def download(url: str, destination: Path) -> None:
    temporary = destination.with_suffix(destination.suffix + ".partial")
    request = urllib.request.Request(url, headers={"User-Agent": "Memorable-Relevance/1"})
    try:
        with urllib.request.urlopen(request, timeout=120) as response, temporary.open("wb") as output:
            while chunk := response.read(1024 * 1024):
                output.write(chunk)
        temporary.replace(destination)
    except Exception:
        temporary.unlink(missing_ok=True)
        raise


def prepare() -> None:
    current_revision()
    manifest = load_manifest()
    rows = dataset_rows()
    validate_manifest_rows(manifest, rows)
    IMAGES.mkdir(parents=True, exist_ok=True)

    for entry, viewer_row in zip(manifest["entries"], rows):
        image_path = IMAGES / entry["localFilename"]
        if not image_path.exists() or sha256(image_path) != entry["imageSha256"]:
            download(viewer_row["row"]["image"]["src"], image_path)
        actual_hash = sha256(image_path)
        if actual_hash != entry["imageSha256"]:
            raise RelevanceError(
                f"image integrity failure for {entry['localFilename']}: "
                f"expected {entry['imageSha256']}, got {actual_hash}"
            )
    print(f"Verified {ROW_COUNT} pinned fixture rows and image SHA-256 hashes in {IMAGES}")


def xcodebuild(environment: dict[str, str] | None = None) -> None:
    subprocess.run(["xcodegen", "generate"], cwd=ROOT, check=True)
    command = [
        "xcodebuild",
        "-project",
        "Memorable.xcodeproj",
        "-scheme",
        "MemorableRelevanceTests",
        "-destination",
        DESTINATION,
        "test",
    ]
    command.extend(f"{key}={value}" for key, value in (environment or {}).items())
    print("Running isolated simulator relevance tests...", flush=True)
    result = subprocess.run(
        command,
        cwd=ROOT,
        env={**os.environ, **(environment or {})},
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
    )
    metric_lines = [line for line in result.stdout.splitlines() if line.startswith("RELEVANCE ")]
    for line in metric_lines:
        print(line)
    if result.returncode:
        failure_lines = [
            line for line in result.stdout.splitlines()
            if "Relevance regression" in line or "TEST FAILED" in line or "error:" in line
        ]
        for line in failure_lines[-30:]:
            print(line, file=sys.stderr)
        raise subprocess.CalledProcessError(result.returncode, command)
    print("Relevance gate passed.")


def run(perturbation: str | None = None, skip_baseline: bool = False) -> None:
    prepare()
    environment = {}
    if perturbation:
        environment["MEMORABLE_RELEVANCE_PERTURBATION"] = perturbation
    if skip_baseline:
        environment["MEMORABLE_RELEVANCE_SKIP_BASELINE"] = "1"
    xcodebuild(environment)


def parse_assignment(text: str) -> tuple[str, list[str]]:
    if "=" not in text:
        raise RelevanceError("sweep must be NAME=value1,value2,...")
    name, raw_values = text.split("=", 1)
    if not re.fullmatch(r"[A-Za-z][A-Za-z0-9]*", name):
        raise RelevanceError(f"invalid SearchConfig constant name: {name!r}")
    values = [value.strip() for value in raw_values.split(",") if value.strip()]
    if not values or any(not re.fullmatch(r"-?[0-9]+(?:\.[0-9]+)?", value) for value in values):
        raise RelevanceError("sweep values must be comma-separated numeric literals")
    return name, values


def sweep(assignment: str) -> None:
    name, values = parse_assignment(assignment)
    if subprocess.run(["git", "diff", "--quiet", "--", str(APP_CONSTANTS)], cwd=ROOT).returncode:
        raise RelevanceError("AppConstants.swift must be clean before a sweep")

    original = APP_CONSTANTS.read_bytes()
    original_hash = hashlib.sha256(original).hexdigest()
    source = original.decode("utf-8")
    pattern = re.compile(
        rf"(^\s*static let {re.escape(name)}(?:\s*:\s*[A-Za-z0-9<>]+)?\s*=\s*)(-?[0-9]+(?:\.[0-9]+)?)(\s*(?://.*)?$)",
        re.MULTILINE,
    )
    if len(pattern.findall(source)) != 1:
        raise RelevanceError(f"expected exactly one numeric SearchConfig constant named {name}")

    previous_handlers = {}
    def interrupted(signum: int, _frame: object) -> None:
        raise KeyboardInterrupt(f"received signal {signum}")

    for signum in (signal.SIGINT, signal.SIGTERM):
        previous_handlers[signum] = signal.signal(signum, interrupted)

    try:
        prepare()
        for value in values:
            replacement = pattern.sub(rf"\g<1>{value}\g<3>", source)
            APP_CONSTANTS.write_text(replacement, encoding="utf-8")
            print(f"\n=== SearchConfig.{name} = {value} ===", flush=True)
            xcodebuild(
                {
                    "MEMORABLE_RELEVANCE_SKIP_BASELINE": "1",
                }
            )
    finally:
        APP_CONSTANTS.write_bytes(original)
        for signum, handler in previous_handlers.items():
            signal.signal(signum, handler)
        restored_hash = sha256(APP_CONSTANTS)
        clean = subprocess.run(
            ["git", "diff", "--quiet", "--", str(APP_CONSTANTS)], cwd=ROOT
        ).returncode == 0
        if restored_hash != original_hash or not clean:
            raise RelevanceError("AppConstants.swift restoration validation failed")
    print("Sweep complete; AppConstants.swift restored byte-for-byte and remains clean.")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    subparsers.add_parser("prepare", help="verify source metadata and populate the ignored cache")
    subparsers.add_parser("run", help="prepare fixtures and run the real-model baseline gate")
    subparsers.add_parser("perturb", help="run with a deliberate vertical image flip; expected to fail")
    sweep_parser = subparsers.add_parser("sweep", help="measure one SearchConfig constant at a time")
    sweep_parser.add_argument("assignment", help="NAME=value1,value2,...")
    args = parser.parse_args()

    try:
        if args.command == "prepare":
            prepare()
        elif args.command == "run":
            run()
        elif args.command == "perturb":
            run(perturbation="vertical-flip")
        elif args.command == "sweep":
            sweep(args.assignment)
    except (RelevanceError, subprocess.CalledProcessError, KeyboardInterrupt) as error:
        print(f"relevance: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
