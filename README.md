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

Your photos never leave your device. No accounts, no tracking.

## How It Works

Memorable uses [SigLIP2](https://arxiv.org/abs/2502.14786) (Google, Apache 2.0 licensed) to encode photos and video frames into 768-dimensional embeddings, stores them in SQLite, and searches via cosine similarity. Text queries are encoded directly as raw visual queries, and the closest matches are returned.

**One-time setup:** The app scans your photo library and builds a search index. A fast first pass stores base embeddings so photos become searchable in progressive checkpoints. OCR, blur scoring, scene labels, reverse geocoding, and videos continue in background passes.

**Search pipeline:**
```
Query → Season/Date/Location extraction → Raw SigLIP2 text encoding
     → GPU/CPU dot product → Date/Location/OCR/scene boosting → matching results
```

## Features

- **Natural language search** with raw SigLIP2 query encoding
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
- **Freemium** — 500 indexed photos/videos free, one-time Pro purchase via StoreKit 2 (`com.blockdeep.memorable.pro.v2`)

## Privacy

- All AI processing on-device (Core ML, Neural Engine)
- `isNetworkAccessAllowed = false` on all PHImageManager requests
- Database encrypted at rest (`.completeUnlessOpen`)
- Search history stored in encrypted SQLite, not UserDefaults
- No analytics, no telemetry, no third-party SDKs that collect data
- Indexed media coordinates can be reverse-geocoded via Apple's CLGeocoder; search query location text is matched locally and is not sent off device
- Privacy manifest included (`PrivacyInfo.xcprivacy`)

## Requirements

- iOS 17.0+
- iPhone with A14 chip or later
- Local storage for bundled Core ML model resources

## Build

The project uses [XcodeGen](https://github.com/yonaskolb/XcodeGen). Install it first, then:

```bash
xcodegen generate
open Memorable.xcodeproj
```

For command-line verification, install the iOS Simulator runtime that matches the active Xcode. If `xcodebuild` reports `CoreSimulator is out of date` or `iOS 26.5 is not installed`, update macOS/Xcode components before running the documented simulator build and test commands.

Core ML models are not included in the repository. The active app packaging strategy bundles the compiled `.mlmodelc` folders as app resources via `project.yml`; On Demand Resources or downloaded models are future packaging options, not the current build behavior. For local development, place the compiled `.mlmodelc` bundles in `Memorable/Models/`.

### Dependencies

- [GRDB.swift 7.x](https://github.com/groue/GRDB.swift) — SQLite database
- [SwiftProtobuf 1.28+](https://github.com/apple/swift-protobuf) — SentencePiece tokenizer model deserialization

## Architecture

```
Core/                              Views/
├── AppReadiness.swift             ├── ContentView.swift
├── PerformanceMetrics.swift       ├── MainTabView.swift
├── SemanticSearchRuntime.swift    ├── SearchView.swift (main UI)
├── ModelResourceManager.swift     ├── MoreView.swift
├── Database.swift (protocol+impl) ├── OnThisDayView.swift
├── SearchEngine.swift             ├── FullScreenPhotoViewer.swift
├── IndexingService.swift          ├── SearchResultsViewer.swift
├── ImageEncoder.swift             ├── SourceManagerView.swift
├── TextEncoder.swift              ├── DuplicateFinderView.swift
├── Tokenizer.swift                ├── UpgradeView.swift
├── GPUSimilaritySearch.swift      ├── Theme.swift (Celestial design system)
├── QueryParser.swift              ├── MasonryGrid.swift
├── PhotoLibrary.swift             ├── GlassModifiers.swift
├── DuplicateFinder.swift          └── PhotoThumbnailView.swift
├── SharedUtilities.swift
└── ProFeatures.swift
```

Key design decisions:
- **DatabaseProtocol** for dependency injection and testability
- **Float16 storage** with Float32 compute — halves memory with negligible accuracy loss
- **GPU search** via MPSGraph matrix multiplication with CPU fallback on simulator
- **Progressive indexing** — base embeddings become searchable before slower enrichment completes
- **Deferred enrichment** — OCR, sharpness, and scene labels resume from persisted per-photo state
- **Thread-safe** embedding access via NSLock with snapshot pattern
- **Memory pressure handling** — drops index on memory warning, reloads on next search
- **Timeout wrappers** on all PHImageManager calls to prevent hangs on corrupt assets

## License

All rights reserved.
