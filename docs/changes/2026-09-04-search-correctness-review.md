# Search correctness and codebase review

Follow-up: the custom tokenizer described in finding #14 below has since been
replaced with Google's upstream SentencePiece. See the
[tokenizer replacement and 2,006-image simulator report](2026-09-04-upstream-tokenizer-and-simulator-validation.md)
for the final implementation and updated verification results.

Reviewed **v2** at `4d5efcc9fb6369988aef3bcc2d8d652b29a08a97` on 4 September 2026. **18 confirmed issues fixed: one P1 and 17 P2.** Changes are local and uncommitted. No confirmed finding remains open.

The user authorized review of the entire branch, with search as the priority, and immediate fixes. All review and validation stayed in this local task and its local sub-agents. No repository material was sent to an external review service or model provider.

## Findings and fixes

Numbers #1–#15 are the original independently validated findings. #16–#18 were confirmed during the parent and implementation review. Links point to the corrected code; the machine-readable run artifact retains original evidence and anchors.

### #1 — P1 — Memory pressure allowed active paged searches to refill the cache after it had been cleared.

Check generation before and after page reads; serialize generation-aware cache insertion and invalidation. Applies to text search and Find Similar. [Corrected code](/Users/gautam/code/memorable/Memorable/Core/SearchEngine.swift:1337)

Verification: Suspension during gated page reads, stale cache inserts, both search modes.

### #2 — P2 — Substring matches such as “knight” and excluded “night” incorrectly added positive time intent.

Match complete words/phrases, prioritize longer phrases, and use positive fallback intent in smart parsing. [Corrected code](/Users/gautam/code/memorable/Memorable/Core/AppConstants.swift:243)

Verification: Substring, phrase precedence, and negative-time parser cases.

### #3 — P2 — A changed file at an already indexed path kept its old embedding and metadata.

Compare validated file modification times; encode first, then atomically replace the existing row and reset enrichment. [Corrected code](/Users/gautam/code/memorable/Memorable/Core/FolderIndexingWorker.swift:320)

Verification: Freshness policy, source-scoped version reads, replacement rollback.

### #4 — P2 — Equal library/index counts could hide an offline deletion plus addition or an edited asset.

Check bounded pages of asset identities and modification dates before declaring indexing complete. [Corrected code](/Users/gautam/code/memorable/Memorable/Core/IndexingService.swift:1958)

Verification: Equal-count/different-ID and newer-modification cases.

### #5 — P2 — Refreshing a saved folder did not schedule OCR/scene enrichment and geocoding.

Schedule the existing enrichment and geocoding jobs after successful folder refresh; new folders also schedule geocoding. [Corrected code](/Users/gautam/code/memorable/Memorable/Core/IndexingService.swift:874)

Verification: Existing indexing/job suite; final scheduling path inspected.

### #6 — P2 — PhotoKit changedObjects were ignored, leaving edited photos and videos searchable using old content.

Coalesce edit IDs, detect offline edits, atomically replace photo/video data with stable IDs, and invalidate search/suggestion/asset caches. Retained free-tier items can refresh without consuming another slot. [Corrected code](/Users/gautam/code/memorable/Memorable/Core/PhotoLibraryChangeTracking.swift:356)

Verification: Photo/video rollback, no resurrection, stable IDs, event merging, free-tier policy, and cancellation after commit.

### #7 — P2 — Relative week arithmetic assumed Monday even when the active calendar starts on Sunday.

Use the calendar’s actual week start and derive weekend days consistently. [Corrected code](/Users/gautam/code/memorable/Memorable/Core/QueryParser.swift:697)

Verification: Fixed Sunday-first and Monday-first calendar cases.

### #8 — P2 — New Year resolution used the day of month without correctly accounting for the month, selecting the wrong year on later months’ first days.

Resolve the cutoff using both month and day. [Corrected code](/Users/gautam/code/memorable/Memorable/Core/QueryParser.swift:891)

Verification: January boundaries and the first days of later months.

### #9 — P2 — Partial month/year matches could consume explicit dates; old/future month, season, and holiday years were not consistently honored.

Resolve complete ISO/named dates first, reject invalid explicit dates, and build year-qualified patterns from years present in the query. [Corrected code](/Users/gautam/code/memorable/Memorable/Core/QueryParser.swift:590)

Verification: Old/future dates, leap dates, invalid dates, month/season/holiday years.

### #10 — P2 — The tail-cache budget omitted variable-sized OCR, labels, paths, and location strings.

Conservatively account for allocated arrays and actual UTF-8/UTF-16 string payloads before retention. [Corrected code](/Users/gautam/code/memorable/Memorable/Core/SearchEngine.swift:256)

Verification: Long multibyte metadata and cache-budget rejection.

### #11 — P2 — Dropping the index could reuse a generation and allow an obsolete load to install stale data.

Advance the generation on invalidation and distinguish in-flight loads by generation. [Corrected code](/Users/gautam/code/memorable/Memorable/Core/SearchEngine.swift:526)

Verification: Blocked old load, replacement load, and active-search invalidation.

### #12 — P2 — Pure date/place filters bypassed negative-term scoring.

Route filtered queries with exclusions through the existing scoring path with a neutral baseline, retaining their hard filters. [Corrected code](/Users/gautam/code/memorable/Memorable/Core/SearchEngine.swift:677)

Verification: Date/place exclusions across resident and paged data, synchronous and asynchronous entry points.

### #13 — P2 — Cancelled warmup could hang a retry when a loader threw a generic error; ignored cancellation could also report success.

Finish cancellation/drain state before task completion, remove the generation spin loop, and recheck cancellation after loading. [Corrected code](/Users/gautam/code/memorable/Memorable/Core/SemanticSearchRuntime.swift:189)

Verification: Generic error, ignored cancellation, immediate retry, and a second memory warning withdrawing retry.

### #14 — P2 — Grapheme-cluster iteration and Swift String canonical equality produced incorrect SentencePiece IDs for combining marks and joined emoji.

Start BPE with Unicode scalars and use exact UTF-8 keys for vocabulary and cache identity. [Corrected code](/Users/gautam/code/memorable/Memorable/Core/Tokenizer.swift:195)

Verification: Golden IDs generated locally with SentencePiece 0.2.1 and the bundled model, including Hindi, emoji, composed/decomposed text, Hangul, and byte fallback.

### #15 — P2 — Independent text/similarity tasks could overwrite newer requests and retain stale filters, fallback results, or screenshot state.

Give both request types one generation/task lifecycle and publish a complete fresh similarity-result state. [Corrected code](/Users/gautam/code/memorable/Memorable/Views/SearchViewModel.swift:261)

Verification: Both completion orders, clear, entitlement revocation, memory pressure, filter reset, screenshot refresh, and empty results.

### #16 — P2 — “Earlier this year” created an inverted date range during the first quarter.

Use the beginning of the current year through now. [Corrected code](/Users/gautam/code/memorable/Memorable/Core/QueryParser.swift:767)

Verification: Deterministic first-quarter parsing.

### #17 — P2 — Inclusive comparisons admitted the next day’s midnight, while year ranges ending at 23:59:59 omitted fractional final seconds.

Use exclusive next-period boundaries for parsed calendar ranges; preserve inclusive semantics for direct DateRange callers. Update the engine and dataset harness to use contains. [Corrected code](/Users/gautam/code/memorable/Memorable/Core/QueryParser.swift:148)

Verification: Resident/paged year boundaries, fractional final seconds, next-midnight rejection, and inclusive equal start/end.

### #18 — P2 — Date-filter labels called every 2–35-day range a whole month and could display an exclusive end as included.

Abbreviate only complete calendar months/years; otherwise display the actual included dates. [Corrected code](/Users/gautam/code/memorable/Memorable/Core/SearchEngine.swift:1867)

Verification: Partial and cross-month ranges, full periods, exclusive midnight, and exact instants.

## File-by-file changes

| Production file | Change |
|---|---|
| [AppConstants.swift](/Users/gautam/code/memorable/Memorable/Core/AppConstants.swift) | Whole-word and longest-phrase time detection. |
| [AppDatabase+MediaMaintenance.swift](/Users/gautam/code/memorable/Memorable/Core/AppDatabase+MediaMaintenance.swift) | Atomic video/frame replacement, validated embeddings, reset location retry state. |
| [AppDatabase+PhotoStore.swift](/Users/gautam/code/memorable/Memorable/Core/AppDatabase+PhotoStore.swift) | Bounded version lookups, atomic photo replacement, reset enrichment/location state, content revisions that notice older-row replacement. |
| [Database.swift](/Users/gautam/code/memorable/Memorable/Core/Database.swift) | Media-version/freshness contract and safe replacement capabilities. |
| [FolderIndexingWorker.swift](/Users/gautam/code/memorable/Memorable/Core/FolderIndexingWorker.swift) | Detect modified indexed files and preserve stable identity during refresh. |
| [FolderScanner.swift](/Users/gautam/code/memorable/Memorable/Core/FolderScanner.swift) | Read modification dates through existing validated descriptors and source-boundary checks. |
| [IndexingService.swift](/Users/gautam/code/memorable/Memorable/Core/IndexingService.swift) | Carry pending edit IDs, invalidate caches after replacement, recover committed replacements after cancellation, schedule folder enrichment/geocoding, and check launch completeness by identity. |
| [PhotoLibraryChangeTracking.swift](/Users/gautam/code/memorable/Memorable/Core/PhotoLibraryChangeTracking.swift) | Track/coalesce edited assets and compare current asset versions in bounded pages. |
| [PhotoLibraryIndexingWorker.swift](/Users/gautam/code/memorable/Memorable/Core/PhotoLibraryIndexingWorker.swift) | Refresh retained photos/videos without spending free-tier slots; keep pass-start timestamps and observe committed replacements after cancellation. Explicitly isolate mutable Session state to MainActor, including Release builds. |
| [QueryParser.swift](/Users/gautam/code/memorable/Memorable/Core/QueryParser.swift) | Explicit-date precedence, supplied calendar/time test seams, year-qualified temporal patterns, correct relative/holiday ranges, and exclusive parsed endpoints. |
| [SearchEngine.swift](/Users/gautam/code/memorable/Memorable/Core/SearchEngine.swift) | Generation-safe loads and cache retention, conservative cache accounting, exclusions with pure filters, correct date comparisons and labels. |
| [SemanticSearchRuntime.swift](/Users/gautam/code/memorable/Memorable/Core/SemanticSearchRuntime.swift) | Deterministic warmup drain/cancellation and retry ownership. |
| [SmartQueryParser.swift](/Users/gautam/code/memorable/Memorable/Core/SmartQueryParser.swift) | Use deterministic positive time intent. |
| [Tokenizer.swift](/Users/gautam/code/memorable/Memorable/Core/Tokenizer.swift) | Unicode scalar BPE with exact UTF-8 vocabulary/cache keys. |
| [SearchView.swift](/Users/gautam/code/memorable/Memorable/Views/SearchView.swift) | Delegate similarity request ownership to the view model. |
| [SearchViewModel.swift](/Users/gautam/code/memorable/Memorable/Views/SearchViewModel.swift) | Unify text/similarity task generations and refresh result-related UI state. |

Added **35 test methods** across existing test files. No new Xcode source file or database migration was required.

| Test file | Coverage added or updated |
|---|---|
| [DatabaseTests.swift](/Users/gautam/code/memorable/MemorableTests/DatabaseTests.swift) | Stable replacement identities, reset metadata, transaction rollback, no resurrection, content revisions, and chunked/source-scoped version reads. |
| [IndexingPolicyTests.swift](/Users/gautam/code/memorable/MemorableTests/IndexingPolicyTests.swift) | Identity/timestamp completeness, free-tier refresh, edits during encoding, edit-event coalescing, and cancellation after committed replacement. |
| [QueryParserTests.swift](/Users/gautam/code/memorable/MemorableTests/QueryParserTests.swift) | Word/phrase time intent and exclusion cases. |
| [SearchEngineTests.swift](/Users/gautam/code/memorable/MemorableTests/SearchEngineTests.swift) | Generations, page-cache retention/budgets, exclusions, calendar boundaries, and date labels. |
| [SearchViewModelTests.swift](/Users/gautam/code/memorable/MemorableTests/SearchViewModelTests.swift) | Text/similarity ordering, invalidation, and fresh result state. |
| [SemanticSearchRuntimeTests.swift](/Users/gautam/code/memorable/MemorableTests/SemanticSearchRuntimeTests.swift) | Cancelled loaders throwing generic errors or ignoring cancellation, and withdrawn retries. |
| [SimulatorDatasetHarnessTests.swift](/Users/gautam/code/memorable/MemorableTests/SimulatorDatasetHarnessTests.swift) | Use the same date-range containment contract as production. |
| [SmartQueryParserConcurrencyTests.swift](/Users/gautam/code/memorable/MemorableTests/SmartQueryParserConcurrencyTests.swift) | Positive time intent and exclusive deterministic year ranges. |
| [TemporalParserTests.swift](/Users/gautam/code/memorable/MemorableTests/TemporalParserTests.swift) | Explicit dates/years, calendar weeks/weekends, holidays, early-year ranges, and date endpoints. |
| [TokenizerModelParserTests.swift](/Users/gautam/code/memorable/MemorableTests/TokenizerModelParserTests.swift) | SentencePiece golden IDs across Unicode scalar and normalization cases. |

## Verification

- Baseline full simulator suite: 833 passed, zero failures, one skipped.
- Final full simulator suite after the Release isolation correction: **868 passed, zero failures, one skipped**.
- Release entitlement lifecycle test: **one passed**.
- Unsigned **Release build and static analysis passed**, with no diagnostics reported by XcodeBuildMCP.
- Python script tests: **31 passed**.
- Pre-merge gates passed: signing hygiene, bundled-model integrity, migration safety, and pinned relevance evaluation.
- Pinned relevance: 50 queries; recall@10 **0.960000**, recall@50 **0.960000**, MRR **0.853333**, fallback rate **0.160000**, matching the earlier run.
- `git diff --check` passed. Xcode generation produced no tracked project-file changes.

The skipped test is the opt-in simulator dataset mutation harness (`MEMORABLE_DATASET_HARNESS=1`). The pinned relevance evaluation ran separately and passed. The Release-only compilation failure found during verification was fixed with an explicit `@MainActor` annotation; both Release and the final Debug suite then passed.

## Coverage and limits

The search pass traced parsing, tokenizer/text encoding, feature enforcement, resident and paged ranking, negative scoring, date/location filters, video deduplication, similarity search, cache ownership, cancellation, and UI publication. The indexing pass covered persistence, refresh/reconciliation, enrichment scheduling, and metadata freshness. The parent also examined application lifecycle, database recovery/migrations, permissions and file access, sharing, StoreKit gating, image encoding, saved searches/albums, memories, captions, and supporting views.

The three initial reviewer reports produced 15 findings; the independent local validation pass confirmed all 15. No findings were discarded for low confidence or malformed evidence. The parent reviewed the combined implementation and added three confirmed date defects. No additional confirmed security or purchase-entitlement defect was found in the inspected paths. There was no separate plan whose requirements needed a completeness verdict.

This is not proof that every possible defect is absent. Remaining verification limits:

- Physical-device GPU/Neural Engine behavior and real memory pressure need hardware testing; simulator tests cover cancellation and generation interleavings through deterministic seams.
- Real PhotoKit edit notifications, folder-provider behavior, and production Foundation Models output require device/integration exercise.
- Freshness comparisons rely on reported modification timestamps. A file replaced externally while preserving or backdating that timestamp is not detectable by this policy.
- Generated protobuf and binary assets were not manually reviewed line by line; parser tests and bundled integrity verification passed.
- `RTK.md`, referenced by the repository instructions, was absent. The available repository instructions were applied.

The pre-existing untracked `.xcodebuildmcp/` directory was preserved. No commits, pushes, source-file removals, schema migrations, or index wipes were performed. Video refresh deletes obsolete derived frame rows only inside the same transaction that inserts their validated replacements; rollback retains the previous video and frames.

## Verdict

**Ready with fixes applied locally. Actionable findings: none.** Device-only verification remains outside this simulator-based review. The complete local evidence and verification metadata are in `/tmp/memorable-code-review-20260904/review.json`.
