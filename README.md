# Memorable: on-device photo search

Memorable searches locally available photos and videos on iPhone with bundled AI models. Describe a memory in natural language, and the app ranks matching media from the local search index.

<p align="center">
  <img src="Memorable/Assets.xcassets/AppIcon.appiconset/icon_180.png" width="90" alt="Memorable app icon" />
</p>

## How search works

Memorable uses [SigLIP2](https://arxiv.org/abs/2502.14786) (Google, Apache 2.0) to encode photos, video frames, and query text as 768-dimensional embeddings. The app stores media embeddings and searchable metadata in a local SQLite database and ranks results with dot-product similarity.

During initial setup, the app indexes photos first so search becomes available at progressive checkpoints. It then indexes video frames and runs deferred OCR, sharpness, scene-label, and place-name enrichment.

```text
Query -> Parse date, location, and exclusions -> Encode visual text locally
      -> Filter local metadata -> Score local embeddings -> Apply local boosts
      -> Merge bounded photo and video results
```

Memorable supports queries such as:

- `sunset at the beach last summer`
- `birthday cake with candles`
- `my dog playing in the snow`
- `that hike with the waterfall`

## Features

The free tier indexes up to 500 photos and videos and provides basic visual-text search, On This Day, Surprise Me, Smart Albums, and local memory slideshows.

The one-time StoreKit 2 product `com.blockdeep.memorable.pro.v2` adds:

- Indexing and search for all locally available photos and videos.
- Date, season, location, time-of-day, and excluded-term query parsing.
- Find Similar and bounded near-duplicate detection.
- Up to 32 newly added folder sources through security-scoped bookmarks.

All tiers can use locally generated OCR and scene labels to improve basic visual ranking.

## Understand the privacy boundary

Memorable has no developer-operated backend and includes no analytics, tracking, advertising, telemetry, or crash-upload service. During indexing and search, photo and video contents, generated embeddings, OCR text, and search query text stay on the device. Technical logs remain on the device because the app has no log-upload path. The developer receives none of this data.

The app uses these Apple-managed service boundaries:

| Boundary | Data sent | Purpose |
|---|---|---|
| Apple MapKit / Core Location reverse geocoding | GPS coordinates stored in indexed media metadata | Resolve coordinates to place names such as city and country |
| Apple StoreKit | Product, entitlement, purchase, restore, and transaction data required by StoreKit | Offer and verify the Pro purchase |

Memorable does not send photo or video contents or search query text through either boundary. The app sets `isNetworkAccessAllowed = false` for PhotoKit requests, so it does not download iCloud-only media while indexing.

When a user taps Share for a photo, Memorable copies the locally available image resource without changing its bytes and provides the copy to the iOS share sheet. The file can include embedded GPS, camera, date, and other metadata from the source. The user chooses the destination; Memorable does not share automatically or send the image to the developer.

AirPlay is available only when the user selects an external playback destination. Picture in Picture uses the local iOS playback session. These playback features do not send data to the developer.

The search database and folder bookmark files use complete-unless-open protection and are excluded from iCloud and device backups.

## Build the app

Memorable requires:

- iOS 17 or later
- An iPhone with an A14 chip or later
- Xcode 16 or later
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)
- Local copies of the compiled Core ML bundles

Generate and open the project:

```bash
xcodegen generate
open Memorable.xcodeproj
```

The repository does not track the compiled `.mlmodelc` directories. Place the image and text model bundles in `Memorable/Models/`. The build packages those directories as app resources; it does not download models at runtime.

## Verify bundled models

The tracked `scripts/model_manifest.json` defines every allowed model file, file size, and SHA-256 digest. Dependency-aware Xcode build phases verify the source artifacts when their inputs change and verify the packaged copies after the resource phase. The build fails closed if a file is missing, changed, symbolically linked, outside the model root, or not listed in the manifest.

Run the same check directly without network access:

```bash
python3 scripts/verify_models.py
```

The manifest pins the upstream model revision, records the conversion environment and tensor contract, and verifies every compiled Core ML file before and after packaging. The file hashes are the release authority for the compiled artifacts.

## Run verification

After changing `project.yml` or adding files, regenerate the project and run the simulator build and tests:

```bash
xcodegen generate
xcodebuild -project Memorable.xcodeproj -scheme Memorable -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -quiet build
xcodebuild -project Memorable.xcodeproj -scheme Memorable -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -quiet test
```

Run the pre-merge gates:

```bash
python3 scripts/premerge.py
```

The pre-merge script verifies bundled model artifacts, checks migration deletion safety, and runs the real-model relevance gate. The relevance gate may need its pinned external dataset when the local cache is incomplete; model verification itself is strictly offline.

Before shipping a release, run the complete automated gate:

```bash
python3 scripts/release_gate.py
```

It runs the repository's Python tests, pre-merge checks, full simulator test suite, Release-only entitlement test, unsigned Release build, and static analysis. Then complete `RELEASE_MANUAL_CHECKLIST.md` with the distribution account and physical devices.

## Memory and cancellation limits

Keep high-cost work bounded and cancellable:

- Query parsing accepts at most 500 characters on every parser path.
- Search retains at most 500 ranked results.
- Duplicate detection performs at most 5,000,000 comparisons and retains at most 2,000 pairs.
- Folder enumeration retains at most 100,000 supported image URLs and checks cancellation during traversal.
- New folder registrations stop at 32 unique canonical paths. Existing installations with more saved folders continue to show every folder and let the user remove them. Each folder image must be 32 MiB or smaller. The app bounds directory traversal, rejects special files and symbolic links, and reads an immutable, size-bounded snapshot before ImageIO parses it.
- Use the Refresh control next to a saved folder to scan it again after its files change. Memorable automatically retries only folders whose earlier scan did not finish; ordinary Apple Photos changes do not rescan saved folders.
- Indexing uses bounded batches and one prefetched image batch.
- Search keeps the newest 8,000 media items in a resident fast window. If the index contains more media, the app searches the remaining rows in bounded 512-media database pages.
- PhotoKit and video loaders use cancellation-aware timeouts.
- A memory warning cancels indexing work, drops the search index, and blocks an in-flight reload from restoring it until explicit work resumes.
- Background-task expiration cancels the active indexing workflow.

Rebuilding the index preserves saved folder registrations and bookmarks. A confirmed Pro downgrade removes derived folder index rows but preserves those registrations. After a rebuild or confirmed Pro restoration, the app automatically schedules saved folders that need indexing.

Add a deterministic limit and a cancellation check before introducing any new operation whose memory or work scales with library size.

## Dependencies

- [GRDB.swift 7.x](https://github.com/groue/GRDB.swift) provides SQLite access.
- [SwiftProtobuf 1.28+](https://github.com/apple/swift-protobuf) reads the SentencePiece tokenizer model.

## Architecture

```text
Core/                              Views/
|- AppReadiness.swift              |- ContentView.swift
|- Database.swift                  |- MainTabView.swift
|- SearchEngine.swift              |- SearchView.swift
|- IndexingService.swift           |- MoreView.swift
|- ImageEncoder.swift              |- OnThisDayView.swift
|- TextEncoder.swift               |- SearchResultsViewer.swift
|- Tokenizer.swift                 |- SourceManagerView.swift
|- GPUSimilaritySearch.swift       |- DuplicateFinderView.swift
|- QueryParser.swift               |- UpgradeView.swift
|- PhotoLibrary.swift              `- PhotoThumbnailView.swift
|- PhotoSharing.swift
|- FolderScanner.swift
|- DuplicateFinder.swift
`- ProFeatures.swift
```

## License

All rights reserved.
