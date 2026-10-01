# Performance and concurrency review — 7 September 2026

Reviewed the local `v2` application at `ac136f7` and applied the fixes below. Review stayed in this Codex task; no project code, diffs, logs, or private context went to outside reviewers. Existing untracked ideation material was excluded.

## Findings and fixes

| Area | Trigger and original risk | Change |
| --- | --- | --- |
| Search history | Search completion, clear, and remove called synchronous SQLite APIs from the main actor. The shared database queue could be occupied by indexing. | Async storage calls using the existing detached-operation helper. Ordered writes, stable query selection for queued removal, and reset drains an active write before clearing the index and history. Late initial reads cannot restore old history. |
| Saved albums | Save and delete could wait for SQLite on the main actor. | Detached storage operations; guard concurrent mutations and reject stale initial album loads. UI changes only after persistence succeeds. |
| Viewer similarity | Find Similar inside a photo viewer bypassed the home search maintenance pause. | Pass the existing pause through the SwiftUI environment. Each viewer owns a request ID; one completion cannot release another request's pause. Release occurs after the operation drains, including cancellation. |
| Folder access | Saved bookmark resolution, bookmark creation, persistence, and rollback ran on the main actor. | Use the existing folder-read and detached-operation helpers; registration runs outside main-actor isolation. Keep security-scoped access and rollback order intact. |
| Photos changes and video taps | Change handling held a lock across PhotoKit work; stopping observation during memory pressure could wait for that lock on the main thread. Video taps also used a synchronous asset fetch. | Copy the fetch snapshot under a short lock, inspect changes outside it, then install only if its revision is current. Use the existing asynchronous coalescing asset resolver for playback, sharing, and duplicate deletion; remove the synchronous helper. |
| Share cancellation | The synchronous cancellation handler could wait for a file writer's lock on the cancelling UI thread. | Cancel the request immediately; drain the writer and remove its file on the asynchronous copy operation's executor before returning. |

## Review coverage

- Startup and model prewarming; foreground/background transitions; memory-pressure teardown and recovery.
- Text parsing, native SentencePiece, text/image inference, resident and paged search, OCR matching, result ranking, similarity and duplicate detection.
- Index-load coordination, snapshot/cache ownership, SQLite serialization and bounded queries, progressive indexing, folder scans and bookmarks.
- Deferred OCR/classification/sharpness, geocoding, orphan cleanup, suggestion validation, maintenance cancellation and retry scheduling.
- PhotoKit request continuations/timeouts, asset caching, thumbnail and viewer loading, slideshows, history, albums, sharing and video playback.
- Entitlement reconciliation, source deletion, duplicate deletion, index reset, StoreKit/background-task ownership, and error paths.

No scoring, threshold, tokenizer, model, database-schema, or indexing-capacity changes were needed. Kept the existing GRDB queue and bounded caches instead of adding a database pool, new scheduler, or speculative algorithm changes. Generated protobuf and upstream SentencePiece internals were not rewritten.

## Verification

- Full Debug simulator suite: **911 passed, 0 failed, 1 skipped**. The skipped test is the existing opt-in dataset mutation harness; this review did not reset or reseed the photo library.
- Added regression coverage for delayed history persistence, reset draining and invalidating queued writes, overlapping search maintenance pauses, folder persistence/rollback off the main thread, and stopping Photos observation during a blocked fetch. Existing sharing cancellation and file-lifetime tests also passed.
- Python checks: **31 passed** (`python3 -m unittest discover -s scripts/tests`).
- `python3 scripts/premerge.py`: all gates passed, including migration safety and relevance. Caption recall@10 and recall@50 were both 0.96; MRR was 0.853333 and fallback rate was 0.26.
- Runtime exercise on **Memorable Release 2K**, with **2,010 existing photos**, using the current Debug build: startup, OCR search for “Pulse heart centre,” scenic search for “Mountains and rivers,” viewer Find Similar, share preparation, and saved-album save/delete. OCR returned two matches; viewer similarity returned 50 results. The native share sheet prepared a 1.8 MB PNG; no destination was selected. The temporary QA album was removed after verification.

Observed timings on that simulator (single observations, not a benchmark):

| Measurement | Time |
| --- | ---: |
| Launch to usable shell | 0.134 s |
| Launch to semantic search readiness | 2.585 s |
| First OCR query, search engine duration | 1.846 s |
| Subsequent scenic query, search engine duration | 0.214 s |

The startup probe recorded no main-thread stall during startup. A later UI exercise recorded one approximately 0.275 s main-thread delay around the album-name interaction. Its cause was not established; this is not evidence of a stall-free app. The existing probe is sampled and does not replace Instruments profiling.

An initial simulator launch preflight failed before tests could run. Restarting that simulator without erasing it resolved the launch failure; the final full suite then passed. The default test simulator has six photos; the separate 2K simulator contains the seeded library. No photo data was removed. The test app was stopped and session defaults restored afterward.

Full-suite result bundle: `~/Library/Developer/XcodeBuildMCP/workspaces/memorable-677c76a4ffa5/result-bundles/test_sim_2026-09-07T15-23-12-143Z_pid74157_15df1b0c.xcresult`. Runtime logs are in the same workspace's `logs` directory with the `com.blockdeep.memorable_oslog_2026-09-07T15-25-01-326Z` prefix. Premerge output is `/private/tmp/memorable-performance-premerge.log`.

## Limits

Simulator CPU inference does not validate physical-device GPU/Neural Engine performance, thermal behavior, battery use, or file-provider latency. Existing deterministic concurrency tests cover scheduling and cancellation, but cannot establish that every possible device interleaving is safe. The seeded runtime library contained no video frames, so video playback was reviewed in code and covered by automated tests rather than exercised in that library. Release build, static analysis, Thread Sanitizer, and the full release gate were not run for this review.

## Reference guidance

- [Swift SE-0338: execution of non-actor-isolated async functions](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0338-clarify-execution-non-actor-async.md). This project uses Swift 6 without the upcoming caller-isolation default. Regression tests also verify that folder persistence leaves the main thread.
- [Apple: task cancellation handlers](https://developer.apple.com/documentation/swift/withtaskcancellationhandler(operation:oncancel:isolation:)). Handlers may run synchronously on the cancelling task's thread; they must not wait for file I/O.
