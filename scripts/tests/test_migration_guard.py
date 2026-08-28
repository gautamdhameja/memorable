from __future__ import annotations

from pathlib import Path
import sys
import unittest


SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))

from migration_guard import (  # noqa: E402
    MigrationGuardError,
    MigrationDelete,
    introduced_from_approved_baseline,
    load_delete_baseline,
    migration_deletes,
    validate_new_deletes,
)


PROMPT = """
if indexingService.indexRebuildRequired {
    Text("Rebuild once to keep search results accurate.")
    Button(action: { indexingService.rebuildRequiredIndex() }) { Text("Rebuild") }
}
"""


def migration(identifier: str, sql: str, *, rebuild_state: bool = True) -> str:
    state = (
        'try setAppState(indexRebuildStateKey, value: "true", in: db)'
        if rebuild_state
        else ""
    )
    return f'''migrator.registerMigration("{identifier}") {{ db in
        {state}
        try db.execute(sql: """
            {sql}
        """)
    }}'''


class MigrationGuardTests(unittest.TestCase):
    def test_detects_multiline_sql_for_each_protected_table(self) -> None:
        source = migration(
            "v9-rebuild",
            """
            DELETE\nFROM indexed_photos\nWHERE embedding IS NOT NULL;
            delete from indexed_videos;
            DeLeTe FrOm indexed_video_frames
            """,
        )

        deletes = migration_deletes(source)

        self.assertEqual(
            [item.table for item in deletes],
            ["indexed_photos", "indexed_videos", "indexed_video_frames"],
        )

    def test_ignores_unrelated_operational_deletes_outside_migrations(self) -> None:
        source = '''
        func deleteAll() throws {
            try db.execute(sql: "DELETE FROM indexed_photos")
        }
        migrator.registerMigration("v9-unrelated") { db in
            try db.execute(sql: "DELETE FROM search_history")
        }
        '''

        self.assertEqual(migration_deletes(source), [])

    def test_rejects_new_wipe_without_rebuild_state(self) -> None:
        current = migration("v9-wipe", "DELETE FROM indexed_photos", rebuild_state=False)

        with self.assertRaisesRegex(MigrationGuardError, "indexRebuildStateKey"):
            validate_new_deletes("", current, [PROMPT], "v9-wipe")

    def test_rejects_new_wipe_without_user_facing_prompt(self) -> None:
        current = migration("v9-wipe", "DELETE FROM indexed_photos")

        with self.assertRaisesRegex(MigrationGuardError, "user-facing rebuild prompt"):
            validate_new_deletes("", current, ["struct SearchView {}"], "v9-wipe")

    def test_historical_baseline_does_not_require_signoff(self) -> None:
        historical = migration("v3-historical", "DELETE FROM indexed_photos")
        current = historical + "\nfunc deleteAll() {}"

        introduced = validate_new_deletes(historical, current, [PROMPT], None)

        self.assertEqual(introduced, [])

    def test_exact_explicit_override_accepts_reviewed_wipe(self) -> None:
        current = migration(
            "v9-wipe",
            "DELETE FROM indexed_video_frames; DELETE FROM indexed_videos",
        )

        introduced = validate_new_deletes("", current, [PROMPT], "v9-wipe")

        self.assertEqual(len(introduced), 2)

    def test_missing_or_broad_override_does_not_bypass_review(self) -> None:
        current = migration("v9-wipe", "DELETE FROM indexed_photos")

        for signoff in (None, "all", "v9-wipe,v10-other"):
            with self.subTest(signoff=signoff):
                with self.assertRaisesRegex(MigrationGuardError, "explicit index-wipe sign-off"):
                    validate_new_deletes("", current, [PROMPT], signoff)

    def test_changed_historical_delete_is_new_and_needs_signoff(self) -> None:
        baseline = migration("v8-cleanup", "DELETE FROM indexed_videos WHERE frameCount = 0")
        current = migration("v8-cleanup", "DELETE FROM indexed_videos")

        with self.assertRaisesRegex(MigrationGuardError, "explicit index-wipe sign-off"):
            validate_new_deletes(baseline, current, [PROMPT], None)

    def test_approved_baseline_comparison_still_detects_current_allowlist_addition(self) -> None:
        historical = MigrationDelete(
            migration_id="v3-historical",
            table="indexed_photos",
            statement="delete from indexed_photos",
        )
        current = migration("v3-historical", "DELETE FROM indexed_photos") + "\n" + migration(
            "v9-new", "DELETE FROM indexed_videos"
        )

        introduced = introduced_from_approved_baseline([historical], current)

        self.assertEqual([item.migration_id for item in introduced], ["v9-new"])

    def test_loads_versioned_historical_baseline(self) -> None:
        payload = '''{
          "version": 1,
          "deletes": [{
            "migration_id": "v3-historical",
            "table": "indexed_photos",
            "statement": "delete from indexed_photos"
          }]
        }'''

        baseline = load_delete_baseline(payload)

        self.assertEqual(baseline[0].migration_id, "v3-historical")


if __name__ == "__main__":
    unittest.main()
