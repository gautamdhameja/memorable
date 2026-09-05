# Home continuity during enrichment

Reproduced on the 2,006-photo simulator library by marking 400 existing derived rows for re-analysis, with the database backed up first.

Before: runtime snapshot 197 showed Today in Your Memories and Recent Searches. Snapshot 198 showed Adding photo details in the background and the empty search state; both home sections were absent despite 2,006 searchable items.

After: repeated the same 400-row pending-enrichment setup. Snapshot 202 contained Adding photo details in the background, Today in Your Memories, and Recent Searches together. After completion both home sections remained visible. Dog returned 161 results.

Removed the progress.isRunning guard from home-content availability and memory refresh. Index readiness, query state, initial indexing and reindexing slideshow rules remain intact. Reviewed both changed code paths. No new presentation state or abstraction.

Validation: Debug build/run succeeded; full simulator suite 884 passed, 0 failed, 1 opt-in dataset harness skipped. Live database check confirmed all 2,006 photos enriched and zero changed identifiers or embeddings against the backup. git diff --check passed. The active-enrichment regression was exercised through the real simulator UI; existing unit tests do not directly render that transition. The after screenshot was captured following completion; snapshot 202 is the active-enrichment evidence.
