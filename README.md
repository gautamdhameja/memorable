# Memorable - AI Photo Search

On-device AI photo and video search for iOS. Describe what you remember, find the exact photo.

<p align="center">
  <img src="Memorable/Assets.xcassets/AppIcon.appiconset/icon_180.png" width="90" alt="Memorable app icon" />
</p>

## What It Does

Type a natural language description and Memorable finds matching photos from your library:

- "sunset at the beach last summer"
- "birthday cake with candles"
- "my dog playing in the snow"
- "that hike with the waterfall"

Everything runs on-device. No cloud, no accounts, no tracking.

## How It Works

Memorable uses [MobileCLIP](https://arxiv.org/abs/2311.17049) (MobileCLIP2-S4) to encode photos into 768-dimensional CLIP embeddings, stores them in SQLite, and searches via cosine similarity. Text queries are encoded the same way, and the closest matches are returned.

**One-time setup:** The app scans your photo library and builds a search index. Photos become searchable immediately; videos are indexed in a second pass.

**Search pipeline:**
```
Query → Season/Date/Location extraction → Text encoding (3-prompt fusion)
     → GPU dot product (MPSGraph) → Date/Location/OCR boosting → Top 50 results
```

## Features

- **Natural language search** with multi-prompt fusion for accuracy
- **GPU-accelerated** similarity search via Metal Performance Shaders
- **Photo + video** indexing (2-5 frames per video)
- **Smart query parsing** — dates ("last summer"), locations ("in Paris"), negations ("dog -cat")
- **Season detection** — "beach this winter", "flowers in spring 2024"
- **OCR boost** — finds screenshots by text content
- **On This Day** — memories from this date in previous years
- **Duplicate finder** — GPU-accelerated near-duplicate detection with delete actions
- **Smart Albums** — save searches as auto-updating collections
- **Surprise Me** — discover random memories with validated queries
- **Slideshow** — CLIP-captioned photo slideshow during indexing and in Memories
- **Swipeable full-screen viewer** with pinch-to-zoom and share
- **Freemium** — 200 photos free, one-time Pro purchase via StoreKit 2

## Privacy

- All AI processing on-device (Core ML, Neural Engine)
- `isNetworkAccessAllowed = false` on all PHImageManager requests
- Database encrypted at rest (`.completeUnlessOpen`)
- Search history stored in encrypted SQLite, not UserDefaults
- No analytics, no telemetry, no network calls (except CLGeocoder for place names and one-time model download)
- Privacy manifest included (`PrivacyInfo.xcprivacy`)

## Requirements

- iOS 17.0+
- iPhone or iPad with A14 chip or later
- ~300 MB for AI models (downloaded once via On Demand Resources)

## Build

The project uses [XcodeGen](https://github.com/yonaskolb/XcodeGen). Install it first, then:

```bash
xcodegen generate
open Memorable.xcodeproj
```

Core ML models are not included in the repository (they're ~900 MB). They're downloaded at runtime via On Demand Resources. For local development, place the compiled `.mlmodelc` bundles in `Memorable/Models/`.

### Dependencies

- [GRDB.swift 7.x](https://github.com/groue/GRDB.swift) — SQLite database (only external dependency, resolved via SPM)

## Architecture

```
Core/                              Views/
├── Database.swift (protocol+impl) ├── SearchView.swift (main UI)
├── SearchEngine.swift             ├── ContentView.swift
├── IndexingService.swift          ├── OnboardingView.swift
├── ImageEncoder.swift             ├── FullScreenPhotoViewer.swift
├── TextEncoder.swift              ├── OnThisDayView.swift
├── Tokenizer.swift                ├── MoreView.swift
├── GPUSimilaritySearch.swift      ├── DuplicateFinderView.swift
├── QueryParser.swift              ├── SourceManagerView.swift
├── PhotoLibrary.swift             ├── UpgradeView.swift
├── DuplicateFinder.swift          ├── Theme.swift (Celestial design system)
├── SharedUtilities.swift          ├── MasonryGrid.swift
├── ContinuationGuard.swift        ├── GlassModifiers.swift
└── ProFeatures.swift              └── PhotoThumbnailView.swift
```

Key design decisions:
- **DatabaseProtocol** for dependency injection and testability
- **Float16 storage** with Float32 compute — halves memory with negligible accuracy loss
- **GPU search** via MPSGraph matrix multiplication with CPU fallback on simulator
- **Thread-safe** embedding access via NSLock with snapshot pattern
- **Memory pressure handling** — drops index on memory warning, reloads on next search
- **Timeout wrappers** on all PHImageManager calls to prevent hangs on corrupt assets

## License

All rights reserved.
