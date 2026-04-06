# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## App Overview

**Memorable** — on-device AI photo & video search for iOS. Uses MobileCLIP2-S4 to encode photos/videos into CLIP embeddings, stores them in SQLite, and searches via cosine similarity. Everything runs on-device. No cloud, no analytics, no network (except CLGeocoder for place name resolution and one-time ODR model download).

- Bundle ID: `com.blockdeep.memorable` (change for personal signing)
- Minimum: iOS 17.0, A14 chip
- Model: MobileCLIP2-S4, 768-dim embeddings, 49408-token vocab
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

- **GRDB.swift 7.x** — SQLite database (only external dependency)

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
└── ProFeatures.swift
```

## Critical Implementation Details

### Tokenizer — Vocab Size Must Be 49408
The BPE vocab file (`bpe_simple_vocab_16e6.txt`) has 262,144 merges but the model's embedding table is only 49,408 tokens. Only the first 48,894 merges are used: `256 bytes + 256 bytes</w> + 48894 merges + 2 special = 49408`. Using all merges produces token IDs beyond the embedding table and garbage search results. This was a critical bug that caused completely wrong search results.

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
  → encodeQueryWithFusion (3 variations averaged: raw, "a photo of X", "a picture of X")
  → Dot product against all photo + video embeddings (vDSP, pointer arithmetic)
  → Date boost (±20% for in/out of range)
  → Location boost (1.5x within 5km, 1.3x within 25km, 1.1x within 100km)
  → Negative term penalty (-30% of negative similarity)
  → OCR text boost (+15% if query words match screenshot text)
  → Score threshold ≥ 0.18
  → Video dedup (best frame per video only)
  → Merge photo + video results, sort, return top 50
```

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
- Tokenizer BPE cache with 1000-entry eviction
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
