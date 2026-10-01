#!/usr/bin/env python3
"""Fail when tracked files contain signing credentials or local overrides."""

from __future__ import annotations

from pathlib import Path
import subprocess
import sys


ROOT = Path(__file__).resolve().parent.parent
SENSITIVE_SUFFIXES = (
    ".p12",
    ".cer",
    ".certSigningRequest",
    ".mobileprovision",
    ".p8",
)
SENSITIVE_BASENAMES = {
    "ExportOptions.plist",
    ".env",
}
LOCAL_CONFIG_PATH = "Config/Local.xcconfig"


def tracked_files(root: Path = ROOT) -> list[str]:
    result = subprocess.run(
        ["git", "ls-files", "-z"],
        cwd=root,
        check=True,
        capture_output=True,
    )
    return [
        path.decode("utf-8", errors="surrogateescape")
        for path in result.stdout.split(b"\0")
        if path
    ]


def is_sensitive_path(path: str) -> bool:
    file_name = Path(path).name
    return (
        path == LOCAL_CONFIG_PATH
        or file_name in SENSITIVE_BASENAMES
        or file_name.endswith(SENSITIVE_SUFFIXES)
    )


def local_config_is_ignored(root: Path = ROOT) -> bool:
    result = subprocess.run(
        ["git", "check-ignore", "--quiet", "--no-index", LOCAL_CONFIG_PATH],
        cwd=root,
        check=False,
    )
    return result.returncode == 0


def validation_errors(root: Path = ROOT) -> list[str]:
    errors: list[str] = []
    sensitive_tracked = sorted(filter(is_sensitive_path, tracked_files(root)))
    if sensitive_tracked:
        errors.append(
            "tracked signing credentials or local configuration: "
            + ", ".join(sensitive_tracked)
        )
    if not local_config_is_ignored(root):
        errors.append(f"{LOCAL_CONFIG_PATH} is not ignored")
    return errors


def main() -> int:
    try:
        errors = validation_errors()
    except subprocess.CalledProcessError as error:
        print(
            f"Signing hygiene check could not inspect tracked files: {error}",
            file=sys.stderr,
        )
        return error.returncode or 1

    if errors:
        for error in errors:
            print(f"Signing hygiene failure: {error}", file=sys.stderr)
        return 1

    print("Signing hygiene gate passed; no credentials or local signing overrides are tracked.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
