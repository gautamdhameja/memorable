#!/usr/bin/env python3
"""Verify every bundled Core ML artifact without using the network."""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import re
import sys


REPOSITORY_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_MANIFEST = Path("scripts/model_manifest.json")


class ModelVerificationError(RuntimeError):
    pass


def _inside(root: Path, candidate: Path) -> bool:
    try:
        candidate.relative_to(root)
        return True
    except ValueError:
        return False


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def verify_models(
    root: Path,
    manifest_path: Path,
    packaged_models_root: Path | None = None,
) -> None:
    root = root.resolve()
    manifest_path = manifest_path if manifest_path.is_absolute() else root / manifest_path
    document = json.loads(manifest_path.read_text(encoding="utf-8"))
    if document.get("version") != 1:
        raise ModelVerificationError("model manifest version must be 1")

    identity = document.get("model_identity")
    if not isinstance(identity, dict):
        raise ModelVerificationError("model manifest must define model_identity")
    source_revision = identity.get("source_revision")
    conversion = identity.get("conversion")
    required_conversion_fields = {
        "date",
        "coremltools_version",
        "torch_version",
        "source_dialect",
        "minimum_deployment_target",
        "storage_precision",
        "compute_precision",
        "image_input",
        "image_output",
        "text_input",
        "text_output",
    }
    if not isinstance(source_revision, str) or re.fullmatch(r"[0-9a-f]{40}", source_revision) is None:
        raise ModelVerificationError("model source_revision must be a pinned 40-character commit")
    if not isinstance(conversion, dict) or not required_conversion_fields.issubset(conversion):
        raise ModelVerificationError("model manifest must define complete conversion provenance")

    models_root_value = document.get("models_root")
    entries = document.get("files")
    if not isinstance(models_root_value, str) or not isinstance(entries, list) or not entries:
        raise ModelVerificationError("model manifest must define models_root and a non-empty files list")

    source_models_root = (root / models_root_value).resolve()
    if not _inside(root, source_models_root):
        raise ModelVerificationError("models_root must stay inside the repository")
    models_root = (
        packaged_models_root.resolve()
        if packaged_models_root is not None
        else source_models_root
    )
    if not models_root.is_dir():
        raise ModelVerificationError("models_root must be an existing directory")

    scan_roots = [models_root]
    if packaged_models_root is not None:
        bundle_names: set[str] = set()
        for entry in entries:
            if not isinstance(entry, dict) or not isinstance(entry.get("path"), str):
                continue
            try:
                packaged_relative = Path(entry["path"]).relative_to(Path(models_root_value))
            except ValueError:
                continue
            if packaged_relative.parts:
                bundle_names.add(packaged_relative.parts[0])
        scan_roots = [models_root / name for name in sorted(bundle_names)]

    unsafe_links = sorted(
        str(path.relative_to(models_root))
        for scan_root in scan_roots
        for path in scan_root.rglob("*")
        if path.is_symlink()
    )
    if unsafe_links:
        raise ModelVerificationError("symbolic links are not allowed: " + ", ".join(unsafe_links))

    expected_paths: set[Path] = set()
    for entry in entries:
        if not isinstance(entry, dict):
            raise ModelVerificationError("every model file entry must be an object")
        relative = entry.get("path")
        size = entry.get("size")
        expected_hash = entry.get("sha256")
        if not isinstance(relative, str) or not isinstance(size, int) or not isinstance(expected_hash, str):
            raise ModelVerificationError("every model file needs path, integer size, and sha256")
        if size < 0 or len(expected_hash) != 64 or any(
            character not in "0123456789abcdef" for character in expected_hash
        ):
            raise ModelVerificationError(f"invalid size or sha256 for {relative}")
        try:
            relative_to_models = Path(relative).relative_to(Path(models_root_value))
        except ValueError as error:
            raise ModelVerificationError(
                f"model path escapes models_root: {relative}"
            ) from error
        path = (models_root / relative_to_models).resolve()
        if not _inside(models_root, path):
            raise ModelVerificationError(f"model path escapes models_root: {relative}")
        if path in expected_paths:
            raise ModelVerificationError(f"duplicate model path: {relative}")
        expected_paths.add(path)
        if not path.is_file() or path.is_symlink():
            raise ModelVerificationError(f"missing or unsafe model file: {relative}")
        actual_size = path.stat().st_size
        if actual_size != size:
            raise ModelVerificationError(
                f"wrong size for {relative}: expected {size}, found {actual_size}"
            )
        actual_hash = _sha256(path)
        if actual_hash != expected_hash:
            raise ModelVerificationError(f"hash mismatch for {relative}")

    actual_paths = {
        path.resolve()
        for scan_root in scan_roots
        for path in scan_root.rglob("*")
        if path.is_file()
    }
    extras = sorted(str(path.relative_to(models_root)) for path in actual_paths - expected_paths)
    if extras:
        raise ModelVerificationError("unmanifested model files: " + ", ".join(extras))


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=REPOSITORY_ROOT)
    parser.add_argument("--manifest", type=Path, default=DEFAULT_MANIFEST)
    parser.add_argument(
        "--packaged-models-root",
        type=Path,
        help="Verify the model bundles copied into an app resource directory.",
    )
    args = parser.parse_args(argv)
    try:
        verify_models(args.root, args.manifest, args.packaged_models_root)
    except (OSError, json.JSONDecodeError, ModelVerificationError) as error:
        print(f"model verification failed: {error}", file=sys.stderr)
        return 1
    print("Bundled model verification passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
