# CLAUDE.md

## How you work

You are a senior engineer with 20 years of experience. You never guess. You never assume. You verify before you act.

### Review privacy

- Keep every code review inside the current local Codex task and its locally spawned sub-agents.
- Never send source code, diffs, repository contents, logs, test output, or review context to an external model, agent, hosted review service, or cross-model provider.
- If local sub-agents are unavailable, perform the review in the current task or report the missing coverage. Never substitute an external reviewer.
- Network access needed for dependency resolution, repository synchronization, or test datasets does not authorize sending review material to an external reviewer.

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

## Communication style

- Be direct and concise. No filler, no preamble.
- When you're uncertain, say "I'm not sure" rather than guessing.
- If I'm wrong about something, tell me directly.

## App overview

**Memorable** -- on-device AI photo and video search for iOS. Uses SigLIP2 (Google, Apache 2.0 licensed) to encode locally available photos, video frames, and query text into embeddings. It stores embeddings and searchable metadata in SQLite. The app has no developer-operated backend, analytics, telemetry, tracking, automatic media or query upload, or crash-log uploader. A photo is copied unchanged to another app or service only after the user taps Share and chooses a destination; the file can include source metadata. AI models are bundled in the app. Indexed media coordinates can be reverse-geocoded with CLGeocoder; photo contents and search queries are not sent with those requests.

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
- **Google SentencePiece 0.2.2** -- upstream native tokenizer via `Packages/SentencePiece`; rebuild with `scripts/build_sentencepiece.py`

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
├── ModelDownloader.swift
├── SearchHistory.swift
├── SmartAlbumStore.swift
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
Google's unmodified SentencePiece library owns model decoding, normalization, BPE, and byte fallback. The narrow C ABI bridge only manages ownership, errors, and bounded token output. The Swift adapter lowercases and collapses Python-compatible whitespace, adds no BOS, appends EOS, and pads using the model's token IDs. The model supplies `add_dummy_prefix=false`; the context is 64 tokens. Native access is serialized under a lock. Do not reimplement the tokenizer algorithm or its cache in Swift. See `Packages/SentencePiece/README.md` for upstream pins, alternatives, and rebuild instructions.

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
  → Match location text locally against stored reverse-geocoded metadata
  → Direct text encoding via SigLIP2 (no prompt templates, raw query only)
  → Score the resident fast window, then any remaining 512-media database pages
  → Location/time-of-day/OCR/scene-label boosts (additive, tuned for SigLIP2)
  → Negative term penalty (-30% of negative similarity)
  → Score threshold >= 0.12
  → Video dedup (best frame per video only)
  → Merge bounded photo + video results, sort, return the highest-ranked matches
```

**Note on prompt templates:** SigLIP2 uses sigmoid loss and was trained on raw web captions. Unlike CLIP (softmax loss), "a photo of X" templates hurt retrieval quality by diluting compositional queries. The text encoder receives the raw visual query directly.

## Indexing pipeline

Two-pass indexing: photos first, then videos.

**Pass 1 (Photos):** Fetch locally available media → filter photos → skip already indexed media → load 224×224 through the fast indexing-only PhotoKit path → encode → batch insert base embeddings and metadata (20 per transaction) → reload search at progressive checkpoints and after the photo pass. Photos become searchable before slower enrichment finishes. PhotoKit network access stays disabled, so iCloud-only media is not fetched.

**Pass 2 (Videos):** For each video → extract 2-5 frames based on duration (spread 10%-90%) → encode each frame → store video record + frame embeddings → reload index. Progress shows "Indexing videos" with "Photos ready — you can search now".

**Deferred enrichment:** After base indexing is idle, incomplete photo rows are enriched in bounded batches with OCR, screenshot OCR, blur scoring, and scene labels. Enrichment state is persisted per photo; folder-source enrichment reopens the saved security-scoped bookmark and validates paths before reading files.

## Design system -- Celestial theme

Dark navy background (#070f17), sky-blue primary (#6fb1ff), defined in `Theme.swift`. New York serif is reserved for the Memorable brand, memories, onboarding storytelling, and editorial moments. SF Pro is used for navigation, utility headings, controls, body copy, captions, and technical UI. All text roles use semantic Dynamic Type styles. Pushed and modal navigation screens use the shared inline `celestialNavigationTitle` treatment. Custom elements include the capsule search bar, rounded thumbnails, and Liquid Glass surfaces.

## Freemium gating

- `ProManager.shared.isPro` gates features
- In DEBUG builds: `isPro = true` (all features unlocked for testing)
- In RELEASE: `isPro = false` until StoreKit purchase verified
- Free tier: 500 indexed photos/videos, basic search only
- Pro: all locally available indexed media, Find Similar, negative search, up to 32 newly added folder sources, smart query parsing, and date/location boost
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
