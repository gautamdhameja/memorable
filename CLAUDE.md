# CLAUDE.md

## How you work

You are a senior engineer with 20 years of experience. You never guess. You never assume. You verify before you act.

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

## App Overview

**Memorable** -- on-device AI photo & video search for iOS. Uses SigLIP2 (Google, Apache 2.0 licensed) to encode photos/videos into embeddings, stores them in SQLite, and searches via cosine similarity. Photos never leave the device. AI models are bundled in-app. CLGeocoder is used for location name resolution (coordinates only, no photos or queries sent).

- Bundle ID: `com.blockdeep.memorable` (change for personal signing)
- Minimum: iOS 17.0, A14 chip
- Model: SigLIP2-base-patch16-224, 768-dim embeddings, 256k-token Gemma vocab, SentencePiece BPE tokenizer
- Freemium: 200 items free, Pro unlock via StoreKit 2 IAP (`com.blockdeep.memorable.pro`)

## Build & Run

Project uses XcodeGen. Always regenerate after changing `project.yml` or adding files:

```bash
xcodegen generate
xcodebuild -project Memorable.xcodeproj -scheme Memorable -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -quiet build
```

For device testing: set signing team in Xcode → Signing & Capabilities. Change bundle ID to match your team if needed.

StoreKit testing: set the StoreKit Configuration file (`Memorable/Store/MemorableProducts.storekit`) in Scheme → Run → Options.

## Dependencies

- **GRDB.swift 7.x** -- SQLite database
- **apple/swift-protobuf 1.28+** -- SentencePiece tokenizer model deserialization

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

## Critical Implementation Details

### Tokenizer -- SentencePiece BPE with Byte Fallback
The tokenizer loads a standard SentencePiece `.model` protobuf file (Gemma tokenizer, 256k vocab). It uses BPE with byte fallback -- unknown characters are encoded as UTF-8 byte tokens (`<0x00>`-`<0xFF>`), so every input is tokenizable. Text preprocessing: lowercase and collapse whitespace (punctuation is preserved as tokens, matching the model's training). No BOS token, EOS appended, padded with 0. First word has no `▁` prefix (`add_dummy_prefix=false`). Context length is 64 tokens. All vocab/score/special-token data is derived from the protobuf at init, not hardcoded.

### PHImageManager Fires Callbacks Twice
`requestImage` may call its handler multiple times (first degraded, then final). All `withCheckedContinuation` wrappers use a `hasResumed` flag to resume only once on the non-degraded callback. Without this, continuations resume on the nil/degraded first call and all thumbnails return nil.

### Simulator vs Device — Core ML Compute Units
Simulator lacks Neural Engine/GPU. Use `cpuOnly` on simulator, `.all` on device:
```swift
#if targetEnvironment(simulator)
config.computeUnits = .cpuOnly
#else
config.computeUnits = .all
#endif
```
Without this, the simulator hits `MpsGraph backend validation on incompatible OS` errors and falls back slowly.

### Database — No fatalError
`AppDatabase.init` uses an in-memory fallback if the on-disk database fails (disk full, corrupted). Never `fatalError` in production code — the app must always launch.

### Thread Safety — SearchEngine
`SearchEngine` uses `NSLock` with `defer { lock.unlock() }` for all read/write access to the embedding arrays. `loadIndex()` writes under lock; `hybridSearch()` and `findSimilar()` snapshot all arrays under lock then operate on local copies.

### Video Embeddings — Array Alignment
In `loadAllVideoEmbeddings()`, metadata (videoId, localId, date, position) must be appended AFTER the embedding size guard, not before. If appended before and the guard continues, the metadata arrays become misaligned with the embeddings array, causing wrong search results.

## Search Pipeline

```
User query
  → QueryParser (Foundation Models on iOS 26+, else NSDataDetector + NLTagger)
  → Extract: visual text, date range, location name, negative terms
  → Geocode location via CLGeocoder
  → Direct text encoding via SigLIP2 (no prompt templates, raw query only)
  → Dot product against all photo + video embeddings (vDSP, pointer arithmetic)
  → Location/time-of-day/OCR/scene-label boosts (additive, tuned for SigLIP2)
  → Negative term penalty (-30% of negative similarity)
  → Score threshold >= 0.10
  → Video dedup (best frame per video only)
  → Merge photo + video results, sort, return top 50
```

**Note on prompt templates:** SigLIP2 uses sigmoid loss and was trained on raw web captions. Unlike CLIP (softmax loss), "a photo of X" templates hurt retrieval quality by diluting compositional queries. The text encoder receives the raw visual query directly.

## Indexing Pipeline

Two-pass indexing: photos first, then videos.

**Pass 1 (Photos):** Fetch all media → filter photos → skip already indexed (in-memory Set lookup) → load 224×224 → encode → OCR for screenshots → batch insert (20 per transaction) → reload search index. Photos become searchable immediately.

**Pass 2 (Videos):** For each video → extract 2-5 frames based on duration (spread 10%-90%) → encode each frame → store video record + frame embeddings → reload index. Progress shows "Indexing videos" with "Photos ready — you can search now".

## Design System — Celestial Theme

Dark navy background (#070f17), sky-blue primary (#6fb1ff), defined in `Theme.swift`. Uses native iOS navigation (`.navigationTitle`, `.toolbar`) with system SF fonts. Custom elements: capsule search bar with glass morphism, rounded thumbnails, ultra-thin material badges.

## Freemium Gating

- `ProManager.shared.isPro` gates features
- In DEBUG builds: `isPro = true` (all features unlocked for testing)
- In RELEASE: `isPro = false` until StoreKit purchase verified
- Free tier: 200 indexed items, basic search only
- Pro: unlimited indexing, Find Similar, negative search, folder sources, smart query parsing, date/location boost
- Refund handling: `verifyEntitlement()` checks `revocationDate` on every launch
- `Transaction.updates` listener catches real-time refund events

## Security Decisions

- Database file protection: `.completeUnlessOpen` (encrypted at rest, writable during background indexing)
- Folder security-scoped resources: `start/stop` paired with `defer` in `performFolderIndexing`
- Bookmarks keyed by source UUID (not folder name) to prevent collision
- All SQL parameterized via GRDB's type-safe API
- Embedding data size validated (1536 bytes) before unsafe pointer access
- Search query capped at 500 characters before regex processing
- Folder display names stripped of control characters
- `isNetworkAccessAllowed = false` on all PHImageManager requests

## Performance Decisions

- Embeddings stored as Float16 (1536 bytes/photo), loaded as Float32 for search
- Dot products use `withUnsafeBufferPointer` pointer arithmetic — no per-iteration array allocation
- Batch DB inserts (20 per transaction) instead of per-photo transactions
- `allIndexedIdentifiers()` returns a Set for O(1) skip-check during indexing
- `reserveCapacity` on embeddings array before loading
- Tokenizer cache with 1000-entry eviction
- Debounced search (500ms) to avoid encoding on every keystroke
- DuplicateFinder runs on `Task.detached` to avoid blocking main thread
- OnThisDay filters in SQL (month/day/year) instead of loading all rows

## Error Handling Rules

- Never use `try?` for operations the user should know about (deletions, saves)
- Always log errors with `logger.error()` — the global `logger` is defined in `MemorableApp.swift`
- No `print()` calls in production — all logging uses `os.Logger`
- No `fatalError` — always provide a fallback or error UI
- `do/catch` with specific error messages, not silent swallowing

## Files That Don't Exist / Were Deleted

- `PhotoGridView.swift` — deleted (was unused placeholder)
- `IndexingProgressView.swift` — deleted (was unused placeholder)
- No Manrope font — removed custom font, uses system SF throughout
