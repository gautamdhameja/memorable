# AGENTS.md

## How you work

You are a senior engineer with 20 years of experience. You never guess. You never assume. You verify before you act.

### Review privacy

- Keep every code review inside the current local Codex task and its locally spawned sub-agents.
- Never send source code, diffs, repository contents, logs, test output, or review context to an external model, agent, hosted review service, or cross-model provider.
- If local sub-agents are unavailable, perform the review in the current task or report the missing coverage. Never substitute an external reviewer.
- Network access needed for dependency resolution, repository synchronization, or test datasets does not authorize sending review material to an external reviewer.

### Reuse established implementations

- Before creating or extending custom implementations of standard formats, protocols, tokenizers, or general-purpose algorithms, check the platform APIs, existing dependencies, and maintained open-source implementations.
- Prefer a suitable established implementation. Custom code requires a concrete, verified compatibility or capability gap; convenience, avoiding a dependency, or the mere existence of custom code is not sufficient justification.
- State which alternatives were checked and why custom code is necessary. Keep any required adapter narrow and test it against the reference implementation.
- Protobuf decoding must use Apple's SwiftProtobuf and generated types. Do not add a handwritten protobuf decoder or hand-edit generated protobuf code.

### Before every task

1. **Understand first.** Restate what you think I'm asking in one sentence. If anything is ambiguous, ask me before proceeding. Do not infer requirements I didn't state.

2. **Investigate before changing.** Read the relevant code. Trace the execution path. Understand why the current code exists before modifying it. Use grep, glob, and read to build full context. If the task involves a bug, identify the root cause before proposing a fix.

3. **State your plan.** Before writing or editing any code, tell me:
   - What you believe the problem/task is
   - What files you'll change and why
   - What your approach is and what alternatives you considered
   - What could go wrong with this approach

4. **Wait for my approval.** Do not start implementing until I confirm the plan. If I say "go ahead" or "do it," then proceed.

### While implementing

- Think carefully and find the best fix. Do not take shortcuts or apply band-aids. Fix the root cause in a generalized way so the same class of bug cannot recur. However, do not refactor unrelated code or "improve" things I didn't ask about.
- If you encounter something unexpected while implementing, stop and tell me rather than working around it silently.
- Never delete or comment out code without explaining why it's safe to remove.

### After implementing

- Verify your changes: run the relevant build, lint, or test commands.
- Summarize what you changed, file by file, in plain language.

## What you never do

- Never change code you don't understand. If you're unsure what a piece of code does, read it and trace it first.
- Never make multiple unrelated changes in one pass. One task, one set of changes.
- Never assume a dependency, import, or function exists without checking.
- Never silently swallow errors or add empty catch blocks.
- Never say "this should work" without verifying.

## Bug reports

When I report a bug, follow this exact sequence:

1. **Reproduce:** Understand the exact symptoms. Ask me for error messages, logs, or reproduction steps if I haven't provided them.
2. **Hypothesize:** List 2-3 possible root causes, ranked by likelihood.
3. **Investigate:** Read the code path involved. Trace from entry point to the failure. Confirm which hypothesis is correct.
4. **Fix:** Propose a proper, generalized fix that addresses the root cause. No band-aids, no shortcuts. Explain why it works and why it won't break anything else.
5. **Verify:** Run tests or build to confirm.

For a UX bug, trace the shared cause through every screen and entry point before calling it fixed. Verify affected pushes, back navigation, modal presentation/dismissal, and loading transitions in the running app. Use recordings for flicker; settled screenshots and source checks are insufficient. Report live coverage separately from code review and untested states.

## Communication style

- Be direct and concise. No filler, no preamble.
- When you're uncertain, say "I'm not sure" rather than guessing.
- If I'm wrong about something, tell me directly.

## App overview

**Memorable** -- on-device AI photo and video search for iOS. Uses SigLIP2 (Google, Apache 2.0 licensed) to encode locally available photos, video frames, and query text into embeddings. It stores embeddings and searchable metadata in SQLite. The app has no developer-operated backend, analytics, telemetry, tracking, automatic media or query upload, or crash-log uploader. A photo is copied unchanged to another app or service only after the user taps Share and chooses a destination; the file can include source metadata. AI models are bundled in the app. Indexed media coordinates can be reverse-geocoded with Apple's MapKit/Core Location service; photo contents and search queries are not sent with those requests.

- Bundle ID: `com.blockdeep.memorable` (change for personal signing)
- Minimum: iOS 17.0, iPhone with A14 chip
- Model: SigLIP2-base-patch16-224, 768-dim embeddings, 256k-token Gemma vocab, SentencePiece BPE tokenizer
- Freemium: 500 indexed media items free, Pro unlock via StoreKit 2 IAP (`com.blockdeep.memorable.pro.v2`)

## Build and run

Project uses XcodeGen. Always regenerate after changing `project.yml` or adding files:

```bash
xcodegen generate
xcodebuild -project Memorable.xcodeproj -scheme Memorable -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -quiet build
```

For device testing: set signing team in Xcode → Signing & Capabilities. Change bundle ID to match your team if needed.

StoreKit testing: set the StoreKit Configuration file (`Memorable/Store/MemorableProducts.storekit`) in Scheme → Run → Options.

## Pre-merge safety gate

Run the required relevance and migration-safety gates before merging:

```bash
python3 scripts/premerge.py
```

Any new migration that deletes from `indexed_photos`, `indexed_videos`, or
`indexed_video_frames` must set the persisted rebuild-required state, retain a
user-facing rebuild prompt, and receive explicit sign-off. After reviewing the
data loss and rebuild flow, provide that sign-off with the exact migration ID:

```bash
MEMORABLE_INDEX_WIPE_SIGNOFF="v9-example-migration" python3 scripts/premerge.py
```

The sign-off approves only the named migration; it does not bypass the rebuild
state or prompt checks. Record the reviewed statement in
`scripts/migration_delete_baseline.json` in the same change. Set
`MEMORABLE_MIGRATION_BASE` to the target branch when it differs from the current
branch's upstream.

## Automated release gate

Before a release, run the complete automated gate:

```bash
python3 scripts/release_gate.py
```

This runs the Python checks, pre-merge safety gates, full simulator tests,
Release-only entitlement test, unsigned Release build, and static analysis.
Complete the separate `RELEASE_MANUAL_CHECKLIST.md` before App Store submission.

## Dependencies

- **GRDB.swift 7.x** -- SQLite database
- **apple/swift-protobuf 1.28+** -- generated SentencePiece model types and compatibility validation
- **Google SentencePiece 0.2.2** -- upstream native tokenizer via the local `Packages/SentencePiece` package; rebuild with `scripts/build_sentencepiece.py`

## Architecture

```
Core/                          Views/
├── DataModels.swift           ├── Theme.swift (Celestial design system)
├── Database.swift             ├── ContentView.swift
├── ImageEncoder.swift         ├── SearchView.swift (main UI)
├── TextEncoder.swift          ├── PhotoDetailView.swift
├── Tokenizer.swift            ├── SourceManagerView.swift
├── SearchEngine.swift         ├── UpgradeView.swift
├── IndexingService.swift      ├── DuplicateFinderView.swift
├── PhotoLibrary.swift         └── OnThisDayView.swift
├── FolderScanner.swift
├── QueryParser.swift
├── SmartQueryParser.swift
├── ResultGrouper.swift
├── ModelResourceManager.swift
├── SearchHistory.swift
├── SurpriseQueries.swift
├── DuplicateFinder.swift
├── OCRService.swift
├── OnThisDay.swift
├── VideoFrameExtractor.swift
├── ProFeatures.swift
└── Generated/
    └── sentencepiece_model.pb.swift
```

## Critical implementation details

### Tokenizer -- SentencePiece BPE with byte fallback
The tokenizer delegates model decoding, normalization, BPE, and byte fallback to Google's unmodified SentencePiece library through a narrow C ABI bridge. It loads the bundled Gemma `.model` (256k vocabulary). The Swift adapter lowercases and collapses whitespace, preserves punctuation, adds no BOS, appends EOS, and pads with the model's padding ID. The model supplies `add_dummy_prefix=false`. Context length is 64 tokens; shorter requested lengths must be positive. Native errors propagate as Swift errors, and processor access is serialized under a lock. Do not reimplement vocabulary lookup, merging, normalization, byte fallback, or caching in Swift.

### PHImageManager fires callbacks twice
`requestImage` may call its handler multiple times (first degraded, then final). All `withCheckedContinuation` wrappers use a `hasResumed` flag to resume only once on the non-degraded callback. Without this, continuations resume on the nil/degraded first call and all thumbnails return nil.

### Simulator vs device -- Core ML compute units
Simulator lacks Neural Engine/GPU. Use `cpuOnly` on simulator, `.all` on device:
```swift
#if targetEnvironment(simulator)
config.computeUnits = .cpuOnly
#else
config.computeUnits = .all
#endif
```
Without this, the simulator hits `MpsGraph backend validation on incompatible OS` errors and falls back slowly.

### Database -- no `fatalError`
`AppDatabase.init` uses an in-memory fallback if the on-disk database fails (disk full, corrupted). Never `fatalError` in production code — the app must always launch.

### SearchEngine thread safety
`SearchEngine` stores its immutable index snapshot in `OSAllocatedUnfairLock`. `loadIndex()` constructs replacement data outside the lock and swaps it under the lock. `hybridSearch()` and `findSimilar()` copy the snapshot under the lock, then operate on immutable local values.

### Video embedding array alignment
In `loadAllVideoEmbeddings()`, metadata (videoId, localId, date, position) must be appended AFTER the embedding size guard, not before. If appended before and the guard continues, the metadata arrays become misaligned with the embeddings array, causing wrong search results.

## Search pipeline

```
User query
  → QueryParser (Foundation Models on iOS 26+, else NSDataDetector + NLTagger)
  → Extract: visual text, date range, location name, negative terms
  → Match location text locally against stored metadata and bundled GPS geometry
  → Direct text encoding via SigLIP2 (no prompt templates, raw query only)
  → Score the resident fast window, then any remaining 512-media database pages
  → Time-of-day/scene-label boosts (additive, tuned for SigLIP2)
  → Negative term penalty (-30% of negative similarity)
  → Visual cutoff per query: median + 6 robust spreads of that query's raw scores across the library, clamped to 0.09-0.12 (fixed 0.12 below 20 scored items); never a fallback that promotes the top score
  → Independently accept complete OCR phrases using Apple's NLTokenizer word boundaries
  → Accept one missing final letter in a word of 6+ letters only with 2+ exact phrase anchors; rank complete phrases first
  → Video dedup (best frame per video only)
  → Merge bounded photo + video results; label text matches separately and remove duplicates
```

**Note on prompt templates:** SigLIP2 uses sigmoid loss and was trained on raw web captions. Unlike CLIP (softmax loss), "a photo of X" templates hurt retrieval quality by diluting compositional queries. The text encoder receives the raw visual query directly.

## Indexing pipeline

Two-pass indexing: photos first, then videos.

**Pass 1 (Photos):** Fetch locally available media → filter photos → skip already indexed media → load 224×224 through the fast indexing-only PhotoKit path → encode → batch insert base embeddings and metadata (20 per transaction) → reload search at progressive checkpoints and after the photo pass. Photos become searchable before slower enrichment finishes. PhotoKit network access stays disabled, so iCloud-only media is not fetched.

**Pass 2 (Videos):** For each video → extract 2-5 frames based on duration (spread 10%-90%) → encode each frame → store video record + frame embeddings → reload index. Progress shows "Indexing videos" with "Photos ready — you can search now".

**Deferred enrichment:** The main indexing experience ends after photos and videos. After a quiet interval, incomplete photos receive OCR, blur scoring, and scene labels in batches of 20 with at most two photos in flight. Text and similarity searches suspend maintenance for their full duration. Completed analysis survives cancellation and is published periodically without invalidating the existing search index. PhotoKit screenshot metadata selects accurate OCR; other photos group fast OCR and classification through Apple Vision. Enrichment stops when the app is inactive and resumes later. Folder-source enrichment reopens the saved security-scoped bookmark and validates paths before reading files.

**Location enrichment:** GPS-bearing media is searchable by unambiguous city, region, and country before reverse geocoding completes, using a bundled read-only gazetteer and local point-in-polygon checks. While the app is active, deferred reverse geocoding groups nearby coordinates, reuses a persistent cache, writes metadata in batches, and retries transient failures with bounded backoff. It cancels when the app becomes inactive.

## Design system -- Celestial theme

Dark navy background (#070f17), sky-blue primary (#6fb1ff), defined in `Theme.swift`. New York serif is reserved for the Memorable brand, memories, onboarding storytelling, and editorial moments. SF Pro is used for navigation, utility headings, controls, body copy, captions, and technical UI. All text roles use semantic Dynamic Type styles. Pushed and modal navigation screens use the shared inline `celestialNavigationTitle` treatment. Custom elements include the capsule search bar, rounded thumbnails, and Liquid Glass surfaces.

## Freemium gating

- `ProManager.shared.isPro` gates features
- In DEBUG builds: `isPro = true` (all features unlocked for testing)
- In RELEASE: `isPro = false` until StoreKit purchase verified
- Free tier: 500 indexed photos/videos, basic search only
- Pro: all locally available indexed media, Find Similar, negative search, up to 32 newly added folder sources, smart query parsing, and date/location filters
- Search keeps 8,000 media items in the resident fast window and scans remaining media in bounded 512-media database pages
- Existing installations with more than 32 folder sources keep all sources visible and removable
- Refund handling: `verifyEntitlement()` checks `revocationDate` on every launch
- `Transaction.updates` listener catches real-time refund events

## Security decisions

- Database file protection: `.completeUnlessOpen` (encrypted at rest, writable during background indexing)
- Folder security-scoped resources: `start/stop` paired with `defer` in `performFolderIndexing`
- Deferred folder enrichment resolves the saved bookmark, rejects symlinks and paths outside the bookmarked folder, and then loads the image.
- Bookmarks keyed by source UUID (not folder name) to prevent collision
- All SQL parameterized via GRDB's type-safe API
- Embedding data size validated (1536 bytes) before unsafe pointer access
- Search query capped at 500 characters before regex processing
- Folder display names stripped of control characters
- `isNetworkAccessAllowed = false` on all PHImageManager requests
- The Share action copies one locally available image resource without changing its bytes. The copy can include source GPS, camera, date, and other metadata.
- Rebuilds and confirmed Pro downgrades preserve folder registrations and bookmarks. A downgrade removes only derived folder index rows.
- Technical logs stay in the local iOS logging system; the app has no log-upload path.

## Performance decisions

- Embeddings are stored as Float16 (1536 bytes/photo) and converted to Float32 for scoring.
- Search retains at most 8,000 media items in its in-memory fast window. It loads older media in 512-media pages and merges page results into one bounded global ranking.
- Dot products use `withUnsafeBufferPointer` pointer arithmetic -- no per-iteration array allocation.
- Batch DB inserts (20 per transaction) instead of per-photo transactions
- Progressive photo index reloads happen at throttled checkpoints; very large libraries use a larger checkpoint interval to avoid excessive full-index rebuilds
- Indexed-identifier lookups use bounded database pages and sets for O(1) skip checks.
- `reserveCapacity` on embeddings array before loading
- Native SentencePiece tokenization (no duplicate Swift tokenizer cache)
- Debounced search (500ms) to avoid encoding on every keystroke
- DuplicateFinder runs on `Task.detached` to avoid blocking main thread
- OnThisDay filters in SQL (month/day/year) instead of loading all rows

## Error handling rules

- Never use `try?` for operations the user should know about (deletions, saves)
- Always log errors with `logger.error()` — the global `logger` is defined in `MemorableApp.swift`
- No `print()` calls in production — all logging uses `os.Logger`
- No `fatalError` — always provide a fallback or error UI
- `do/catch` with specific error messages, not silent swallowing

## Files that don't exist or were deleted

- `PhotoGridView.swift` — deleted (was unused placeholder)
- `IndexingProgressView.swift` — deleted (was unused placeholder)
- No Manrope font — removed custom font, uses system SF throughout
