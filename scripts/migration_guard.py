#!/usr/bin/env python3
"""Reject unreviewed index-wiping database migrations.

The guard compares migration SQL in the working tree with the merge-base of the
branch under review. Historical migrations are therefore not re-litigated, and
database maintenance code outside a registered migration is out of scope.
"""

from __future__ import annotations

import argparse
from collections import Counter
from dataclasses import dataclass
import json
import os
from pathlib import Path
import re
import subprocess
import sys


ROOT = Path(__file__).resolve().parent.parent
DATABASE_PATH = Path("Memorable/Core/Database.swift")
BASELINE_PATH = Path("scripts/migration_delete_baseline.json")
VIEWS_PATH = Path("Memorable/Views")
SIGNOFF_ENV = "MEMORABLE_INDEX_WIPE_SIGNOFF"
BASE_ENV = "MEMORABLE_MIGRATION_BASE"


class MigrationGuardError(RuntimeError):
    pass


@dataclass(frozen=True)
class MigrationDelete:
    migration_id: str
    table: str
    statement: str


@dataclass(frozen=True)
class MigrationBlock:
    migration_id: str
    body: str


MIGRATION_START = re.compile(
    r"\bmigrator\s*\.\s*registerMigration\s*\(\s*\"([^\"]+)\"\s*\)\s*\{"
)
DELETE_START = re.compile(
    r"\bDELETE\s+FROM\s+(?:[A-Za-z_][A-Za-z0-9_]*\s*\.\s*)?"
    r'["`\[]?(indexed_photos|indexed_videos|indexed_video_frames)["`\]]?\b',
    re.IGNORECASE,
)
UNRESOLVED_DELETE_START = re.compile(r"\bDELETE\s+FROM\s*(?:\\\(|$)", re.IGNORECASE)
REBUILD_STATE = re.compile(
    r"\bsetAppState\s*\(\s*indexRebuildStateKey\s*,\s*value\s*:\s*\"true\"",
    re.DOTALL,
)


def _scan_balanced_braces(source: str, opening_brace: int) -> int:
    """Return the matching closing brace, ignoring strings and comments."""
    depth = 0
    index = opening_brace
    state = "code"
    while index < len(source):
        if state == "code":
            if source.startswith('"""', index):
                state = "multiline_string"
                index += 3
                continue
            if source.startswith("//", index):
                state = "line_comment"
                index += 2
                continue
            if source.startswith("/*", index):
                state = "block_comment"
                index += 2
                continue
            character = source[index]
            if character == '"':
                state = "string"
            elif character == "{":
                depth += 1
            elif character == "}":
                depth -= 1
                if depth == 0:
                    return index
        elif state == "string":
            if source[index] == "\\":
                index += 2
                continue
            if source[index] == '"':
                state = "code"
        elif state == "multiline_string":
            if source.startswith('"""', index):
                state = "code"
                index += 3
                continue
        elif state == "line_comment":
            if source[index] == "\n":
                state = "code"
        elif state == "block_comment":
            if source.startswith("*/", index):
                state = "code"
                index += 2
                continue
        index += 1
    raise MigrationGuardError("unterminated registerMigration closure")


def migration_blocks(source: str) -> list[MigrationBlock]:
    blocks: list[MigrationBlock] = []
    search_from = 0
    while match := MIGRATION_START.search(source, search_from):
        opening_brace = source.find("{", match.start(), match.end())
        closing_brace = _scan_balanced_braces(source, opening_brace)
        blocks.append(MigrationBlock(match.group(1), source[opening_brace + 1 : closing_brace]))
        search_from = closing_brace + 1
    return blocks


def swift_string_literals(source: str) -> list[str]:
    """Extract ordinary and multiline Swift string contents."""
    strings: list[str] = []
    index = 0
    while index < len(source):
        if source.startswith('"""', index):
            end = source.find('"""', index + 3)
            if end < 0:
                raise MigrationGuardError("unterminated multiline Swift string")
            strings.append(source[index + 3 : end])
            index = end + 3
            continue
        if source[index] == '"':
            start = index + 1
            index = start
            while index < len(source):
                if source[index] == "\\":
                    index += 2
                    continue
                if source[index] == '"':
                    strings.append(source[start:index])
                    index += 1
                    break
                index += 1
            else:
                raise MigrationGuardError("unterminated Swift string")
            continue
        index += 1
    return strings


def _normalize_sql(statement: str) -> str:
    return " ".join(statement.lower().split()).rstrip(";")


def migration_deletes(source: str) -> list[MigrationDelete]:
    deletes: list[MigrationDelete] = []
    for block in migration_blocks(source):
        for literal in swift_string_literals(block.body):
            matches = list(DELETE_START.finditer(literal))
            if UNRESOLVED_DELETE_START.search(literal) and not matches:
                raise MigrationGuardError(
                    f"migration {block.migration_id} constructs DELETE SQL dynamically; "
                    "use a static SQL literal so protected-table deletes can be reviewed"
                )
            for position, match in enumerate(matches):
                statement_end = literal.find(";", match.end())
                next_delete = matches[position + 1].start() if position + 1 < len(matches) else len(literal)
                if statement_end < 0 or statement_end > next_delete:
                    statement_end = next_delete
                statement = _normalize_sql(literal[match.start() : statement_end])
                deletes.append(
                    MigrationDelete(
                        migration_id=block.migration_id,
                        table=match.group(1).lower(),
                        statement=statement,
                    )
                )
    return deletes


def newly_introduced_deletes(baseline_source: str, current_source: str) -> list[MigrationDelete]:
    return introduced_from_approved_baseline(
        migration_deletes(baseline_source),
        current_source,
    )


def load_delete_baseline(payload: str) -> list[MigrationDelete]:
    try:
        document = json.loads(payload)
        if document.get("version") != 1 or not isinstance(document.get("deletes"), list):
            raise ValueError("expected version 1 with a deletes array")
        return [MigrationDelete(**item) for item in document["deletes"]]
    except (json.JSONDecodeError, TypeError, ValueError) as error:
        raise MigrationGuardError(f"invalid migration delete baseline: {error}") from error


def introduced_from_approved_baseline(
    approved: list[MigrationDelete], current_source: str
) -> list[MigrationDelete]:
    historical = Counter(approved)
    introduced: list[MigrationDelete] = []
    for deletion in migration_deletes(current_source):
        if historical[deletion] > 0:
            historical[deletion] -= 1
        else:
            introduced.append(deletion)
    return introduced


def has_user_facing_rebuild_prompt(view_sources: list[str]) -> bool:
    combined = "\n".join(view_sources)
    literals = swift_string_literals(combined)
    return (
        "indexingService.indexRebuildRequired" in combined
        and re.search(r"\brebuildRequiredIndex\s*\(", combined) is not None
        and any("rebuild" in literal.lower() for literal in literals)
    )


def validate_new_deletes(
    baseline_source: str,
    current_source: str,
    view_sources: list[str],
    signoff: str | None,
) -> list[MigrationDelete]:
    introduced = newly_introduced_deletes(baseline_source, current_source)
    return _validate_introduced(introduced, current_source, view_sources, signoff)


def _validate_introduced(
    introduced: list[MigrationDelete],
    current_source: str,
    view_sources: list[str],
    signoff: str | None,
) -> list[MigrationDelete]:
    if not introduced:
        if signoff and signoff.strip():
            raise MigrationGuardError(
                f"{SIGNOFF_ENV} is set but no new index-wiping migration was found"
            )
        return []

    blocks = {block.migration_id: block.body for block in migration_blocks(current_source)}
    migration_ids = sorted({deletion.migration_id for deletion in introduced})
    missing_state = [
        migration_id
        for migration_id in migration_ids
        if not REBUILD_STATE.search(blocks.get(migration_id, ""))
    ]
    if missing_state:
        raise MigrationGuardError(
            "new index-wiping migrations must set indexRebuildStateKey to true: "
            + ", ".join(missing_state)
        )

    if not has_user_facing_rebuild_prompt(view_sources):
        raise MigrationGuardError(
            "new index-wiping migrations require a user-facing rebuild prompt wired to "
            "indexRebuildRequired and rebuildRequiredIndex()"
        )

    approved = sorted(
        migration_id.strip()
        for migration_id in (signoff or "").split(",")
        if migration_id.strip()
    )
    if approved != migration_ids:
        expected = ",".join(migration_ids)
        raise MigrationGuardError(
            "explicit index-wipe sign-off is required; rerun with "
            f'{SIGNOFF_ENV}="{expected}" after reviewing the data loss and rebuild flow'
        )
    return introduced


def validate_against_approved_baseline(
    approved: list[MigrationDelete],
    current_source: str,
    view_sources: list[str],
    signoff: str | None,
) -> list[MigrationDelete]:
    return _validate_introduced(
        introduced_from_approved_baseline(approved, current_source),
        current_source,
        view_sources,
        signoff,
    )


def _git(repo: Path, *arguments: str) -> str:
    result = subprocess.run(
        ["git", *arguments],
        cwd=repo,
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    if result.returncode:
        detail = result.stderr.strip() or "git command failed"
        raise MigrationGuardError(detail)
    return result.stdout.strip()


def _git_file_at_commit(repo: Path, commit: str, path: Path) -> str | None:
    result = subprocess.run(
        ["git", "show", f"{commit}:{path.as_posix()}"],
        cwd=repo,
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    if result.returncode == 0:
        return result.stdout
    if "exists on disk, but not in" in result.stderr or "does not exist in" in result.stderr:
        return None
    raise MigrationGuardError(result.stderr.strip() or "could not read baseline from Git")


def bootstrap_approved_deletes(repo: Path, baseline_commit: str) -> list[MigrationDelete]:
    addition_commits = _git(
        repo,
        "log",
        "--diff-filter=A",
        "--format=%H",
        "HEAD",
        "--",
        BASELINE_PATH.as_posix(),
    ).splitlines()
    if addition_commits:
        guard_parent = _git(repo, "rev-parse", f"{addition_commits[-1]}^")
        source = _git_file_at_commit(repo, guard_parent, DATABASE_PATH) or ""
    else:
        source = _git_file_at_commit(repo, baseline_commit, DATABASE_PATH) or ""
    return migration_deletes(source)


def resolve_baseline(repo: Path, requested: str | None) -> str:
    reference = requested or os.environ.get(BASE_ENV)
    if not reference:
        result = subprocess.run(
            ["git", "rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}"],
            cwd=repo,
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
        )
        if result.returncode == 0:
            reference = result.stdout.strip()
    if not reference:
        try:
            reference = _git(repo, "symbolic-ref", "--short", "refs/remotes/origin/HEAD")
        except MigrationGuardError as error:
            raise MigrationGuardError(
                f"could not determine the migration baseline; pass --base or set {BASE_ENV}"
            ) from error
    return _git(repo, "merge-base", "HEAD", reference)


def repository_view_sources(repo: Path) -> list[str]:
    root = repo / VIEWS_PATH
    return [path.read_text(encoding="utf-8") for path in sorted(root.rglob("*.swift"))]


def check_repository(repo: Path, base: str | None, signoff: str | None) -> list[MigrationDelete]:
    baseline_commit = resolve_baseline(repo, base)
    current_baseline = load_delete_baseline(
        (repo / BASELINE_PATH).read_text(encoding="utf-8")
    )
    approved_payload = _git_file_at_commit(repo, baseline_commit, BASELINE_PATH)
    if approved_payload is not None:
        approved = load_delete_baseline(approved_payload)
    else:
        # Bootstrap only: trust migrations that predate the commit which first
        # added the guard baseline, never the mutable working-copy baseline.
        approved = bootstrap_approved_deletes(repo, baseline_commit)
    current_source = (repo / DATABASE_PATH).read_text(encoding="utf-8")
    current_deletes = Counter(migration_deletes(current_source))
    stale_entries = Counter(current_baseline) - current_deletes
    if stale_entries:
        raise MigrationGuardError(
            f"{BASELINE_PATH} contains entries not present in registered migrations"
        )
    candidate_introduced = Counter(migration_deletes(current_source)) - Counter(approved)
    introduced = validate_against_approved_baseline(
        approved,
        current_source,
        repository_view_sources(repo) if candidate_introduced else [],
        signoff,
    )
    missing_current_entries = Counter(introduced) - Counter(current_baseline)
    if missing_current_entries:
        migrations = ", ".join(sorted({item.migration_id for item in missing_current_entries}))
        raise MigrationGuardError(
            f"reviewed migration deletes must be recorded in {BASELINE_PATH}: {migrations}"
        )
    return introduced


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base", help=f"target ref; defaults to {BASE_ENV}, then branch upstream")
    parser.add_argument("--repo", type=Path, default=ROOT, help=argparse.SUPPRESS)
    args = parser.parse_args()
    try:
        introduced = check_repository(
            args.repo.resolve(),
            args.base,
            os.environ.get(SIGNOFF_ENV),
        )
    except (MigrationGuardError, OSError) as error:
        print(f"migration-guard: {error}", file=sys.stderr)
        return 1

    if introduced:
        migrations = ", ".join(sorted({item.migration_id for item in introduced}))
        print(f"Migration safety gate passed with explicit sign-off: {migrations}")
    else:
        print("Migration safety gate passed; no new protected-table migration deletes.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
