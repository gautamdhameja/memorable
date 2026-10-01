# End-to-end review — September 8, 2026

Branch: `v2`, working tree based on `54408e3`. Review and fixes stayed inside this Codex task and its built-in agents. No external model or review service received repository material. Existing navigation and thumbnail corrections were preserved; `docs/ideation/` was untouched.

## Findings fixed

| Finding | Change | Evidence |
| --- | --- | --- |
| Confirming duplicate deletion crashed before Photos could show its permission prompt. | `IndexingService.deletePhotoAsset` is nonisolated and uses Apple's async `performChanges` with an explicitly Sendable changes closure. Removed the continuation wrapper and unused rejection error. | Reproduced `EXC_BREAKPOINT` on `com.apple.PHPhotoLibrary.changes`, with `swift_task_checkIsolatedSwift` entering the old closure. Repeated denial and confirmed deletion after the fix; no crash. |
| Background-task expiration had the same unannotated callback boundary inside a MainActor type. | Marked the outer expiration callback Sendable; retained its existing main-thread delivery. | SDK and source review. Controller policy tests pass. Actual system expiration remains a device check. |
| Similarity labels and edited drafts could be saved as text-search albums. | `SearchViewModel` exposes only the successful query associated with current results; `SearchView` uses it to display and execute Save. | Async tests cover drafts, pending/failed/empty searches and Find Similar. Live text save/reopen/delete and similarity-save absence verified. |
| Selecting a folder while indexing started silently discarded the selection. | Service reports the rejection. Source controls disable during foreground indexing but remain available during interruptible enrichment. | Busy-state regression covers photo, video and preparation phases and retained active progress. Picker presentation/cancellation tested live. |
| Source-loading failure replaced existing sources with an apparently empty list. | Retain existing data and show an error. | Source review and successful live source loading. Read-failure injection not completed. |
| Duplicate-scan failure reported a completed empty scan. | Show an error and retain the retryable initial state. | Catch path reviewed; live successful scan and cancellation tested. Database-failure injection not completed. |
| Failed local image requests left permanent spinners. | Thumbnail, Memories and full-photo loaders distinguish loading from unavailable; full photo offers a manual retry. | Production-renderer tests cover unavailable states and stable layout at standard/accessibility sizes. Live successful loads exercised; missing-file failure not injected. |
| Memories labeled neighboring dates as “On this day.” | Database query matches the exact local month/day from earlier years. | Boundary test covers midnight edges and excludes neighboring dates/current year. Seeded UI now shows six September 8 photos across three years; opened photo is September 8, 2025. |
| Built-in “flowers in bloom” suggestion triggered a false Pro place-filter upsell. | Added `bloom` to the parser's existing visual-word guard. | Tests cover every built-in candidate, the free-tier restriction, Berlin and Bloomington. Final Debug and Release live queries retain the flower result without the false upsell. |

The earlier empty-band and navigation fixes remain in the same pending working tree. Visual previews fill a stable canvas; OCR previews preserve full text. The Search navigation bar remains visible through pushes.

## Simulator coverage

Used iOS 26.5 with the existing **2,010-photo plus one-video** simulator, and a disposable iPhone 17 simulator for fresh installation and mutations. The disposable library began with 66 items (60 copied fixtures plus six simulator defaults), then received incremental fixtures. No original seeded photos were deleted. Duplicate deletion affected only the disposable copy.

| Flow | Live result |
| --- | --- |
| Cold launch, preparation, normal home and recent searches | Passed in Debug and Release. |
| Onboarding, denied photo access, Open Settings, permission recovery | Denied screen and Settings action verified. Permission changed with simulator privacy tooling, then full access approved in the system prompt; indexing started. Did not manually toggle Settings' photo-access selector. |
| Fresh indexing, rebuild, interrupted rebuild and resume | Recorded slideshow before completion and after relaunch. Interrupted at 18%; relaunch resumed the initial experience. Rebuild removed previous search history. |
| Incremental indexing after completion | Added 20 fixtures, relaunched; normal home and progress remained, without slideshow or Build Search Index. Completed count increased. |
| Deferred enrichment and location work | Normal home/search available while status appeared. |
| Visual search | People: three results; portrait/landscape previews fill tiles. Mountains: photo, OCR and video results. |
| OCR | Pulse heart centre: two text results; opened complete image and used Copy text, which changed to Copied. |
| Result filters/sort and video | All/Videos filter and native video playback/dismissal verified. Recent/Relevance sorting also checked in the preceding thumbnail verification. |
| Find Similar | Long-pressed a result, received 50 results; Save Album absent. Full-view similarity path checked in preceding verification. |
| Smart albums | Saved QA People, reopened to People/three results, then deleted the test album. |
| Memories | Home push, More entry, full photo, Around This Time (populated and empty), slideshow and back/dismissal verified across the review. Final home push inspected in frame sequence; no late vertical correction observed. |
| Sharing | Opened system sheet containing the selected JPEG, cancelled, returned to the same photo. No external destination selected. |
| Duplicates | 2,011-item Debug scan remained responsive but was cancelled before completion. Small-library scan completed with nine pairs. Denied deletion retained 67 searchable items; approved retry removed one copy and its pair, leaving 66 items/eight pairs. |
| Photo Sources | Counts loaded, folder picker opened and cancelled. Actual bookmark registration/refresh/removal not exercised live. |
| More, Privacy and Licenses | Opened each, including license detail, and navigated back. |
| Release Pro screen | Opened upgrade; Restore invoked system Apple Account sign-in. Cancelled and saw Request Canceled. Final Find Similar (Pro) correctly opened Upgrade and closed back to results. No purchase or restore completed. |

## Automated verification

- Final full Debug suite: **961 passed, 0 failed, 1 skipped**. The skipped test is the explicitly opt-in dataset mutation harness.
- Relevance suite: **4 passed, 0 failed**.
- Release entitlement suite: **1 passed, 0 failed**.
- Python unit checks: **31 passed**; signing hygiene, bundled-model integrity and migration guard passed.
- Debug and Release simulator builds passed. `git diff --check` passed.
- No new dependency, schema migration or custom format implementation was added.

The full automated release wrapper/static analysis was not run in this review; individual checks above must not be described as that complete gate.

## Evidence and limits

Recordings are under `/Users/gautam/.codex/visualizations/2026/09/04/01a06e2b-eecb-7083-9e8b-7e013209c675/e2e-review/`:

- `navigation-before-fixes.mp4`
- `memories-and-duplicate-cancellation.mp4`
- `fresh-index-lifecycle.mp4`
- `duplicate-deletion-reproduction-and-fix.mp4`
- `resume-and-incremental.mp4`
- `final-seeded-search-and-memories.mp4`
- `final-release-search.mp4`

`test-results.json` records final summaries and log/result-bundle paths. Temporary test-product packages and the disposable simulator were removed after verification; logs, result bundles and recordings were retained. The test-created QA People album was removed from the original simulator.

This is a broad simulator review, not proof that every device state is bug-free. Unverified: physical-device debugger-only startup error, actual BGTaskScheduler expiration/suspension, device memory/thermal pressure, iCloud-only and unavailable-file fault paths, folder bookmark lifecycle, completed StoreKit transaction/refund, AirPlay/Picture in Picture, VoiceOver interaction and older supported iOS versions. Layout renderer tests include accessibility sizes, but a full large-text UI walkthrough was not performed.

The duplicate crash demonstrates the prior coverage gap: mocked deletion/index reconciliation did not execute PhotoKit's real callback queue. Keep the destructive-flow checks on a disposable library in the manual release checklist. A green build and settled screenshots alone are insufficient.
