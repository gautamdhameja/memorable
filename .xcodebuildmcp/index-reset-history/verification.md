# Search history follows index reset

The existing reset regression failed before the fix because recent history remained in the database after resetIndexedMedia(). The fixed transaction deletes history and embedded preview metadata together with derived media rows. Saved albums, sources, and bookmarks are preserved.

Both manual reset and incompatible-index rebuild use the same reset operation. It cancels active searches and preview backfills before the transaction, blocks new searches during it, and clears the screen's cached history only after a successful commit. A committed reset publishes its outcome before cancellation can stop subsequent indexing.

Verification:
- Database reset, rollback, search cancellation and stale history-load checks passed.
- Full simulator suite: 888 passed, 0 failed, 1 opt-in dataset harness skipped.
- All pre-merge gates passed. Relevance recall@10 and recall@50: 0.96; MRR: 0.853333.
- Actual Re-index Library action displayed the updated history-deletion confirmation and immediately reduced stored history to zero.
- Rebuilt all 2,006 seeded photos. History remained zero throughout and the normal home screen returned with memories and no Recent Searches section. Snapshot 216 also showed background enrichment alongside memories, exercising the preceding home-continuity fix.
- Optional enrichment continued after all 2,006 photos were searchable; completing that analysis was not a condition for search readiness.
- git diff --check passed. Changes remain local and uncommitted.
