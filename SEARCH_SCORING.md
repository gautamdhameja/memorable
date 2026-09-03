# Search scoring algorithm

## Process each query locally

Memorable uses SigLIP2 to compare raw query text with photo and video embeddings. The app does not add CLIP-style prompt templates. It parses date and location constraints before ranking so a strong visual match from the wrong time or place does not dominate the result set.

The app caps every query parser path at 500 characters. It processes the bounded query on the device and does not send query text to CLGeocoder or another service.

```text
Query: "sunset in San Diego last summer"
  -> Bound input to 500 characters
  -> Extract visual text, date range, location name, and negative terms
  -> Match location text against local metadata and bundled GPS geometry
  -> Encode raw visual text with the bundled SigLIP2 model
  -> Snapshot the resident photo and video fast window under a lock
  -> Build date and location candidate sets
  -> Score the resident window, then any remaining 512-media database pages
  -> Apply local time, OCR, scene-label, and video adjustments
  -> Penalize negative-term similarity
  -> Remove results below the minimum score
  -> Keep the best frame for each video
  -> Retain at most 500 merged results
```

## Encode raw query text

SigLIP2 uses sigmoid loss over raw web captions. Prompt fusion such as averaging `dog`, `a photo of dog`, and `a picture of dog` can dilute compositional queries. The production path therefore encodes the parser's raw `textQuery`.

## Apply hard filters

Date filters remove media outside the requested range. If the query requires a date, the app also removes media without a creation date because it cannot prove that the media satisfies the constraint.

Location filters first match locally stored city, state, country, or location-name fields. When those labels are not ready yet, the bundled gazetteer resolves unambiguous city names to a conservative radius and state/country names to local Natural Earth polygons, then tests the media's existing GPS coordinate on device. Common full administrative-region names are also mapped locally to the abbreviated values Apple may store (for example, `California` to `CA`). The app never forward-geocodes query text. A separate deferred enrichment path sends only media GPS coordinates to Apple's reverse-geocoding service, caches nearby results persistently, and stores the returned place names locally.

Pure location queries, such as `Paris`, skip visual scoring and return matching metadata sorted by date. The engine caps this path at 500 results.

## Calculate scores

Photo scoring calculates the dot product of normalized embeddings. Devices use the GPU path for the resident fast window when available; database pages use bounded CPU scoring. The simulator uses CPU and vDSP fallbacks.

Video scoring compares the query embedding with each stored frame embedding and keeps the best frame for each video.

Pro search keeps the newest 8,000 media items in the resident fast window. When the persisted index contains additional media, the engine loads 512 media descriptors at a time, applies the same filters and scoring rules to each page, and merges candidates into one bounded global ranking. The 8,000-item value limits resident memory; it does not limit Pro indexing or search coverage.

The app applies these additive values:

| Parameter | Value | Purpose |
|---|---:|---|
| `minimumScoreThreshold` | `0.12` | Include a result in the main response |
| `timeOfDayMatchBoost` | `0.03` | Boost media whose creation hour matches the query |
| `negativeTermWeight` | `0.3` | Subtract weighted negative similarity |
| `ocrBoostPerWord` | `0.08` | Boost matching OCR text |
| `sceneLabelBoostPerMatch` | `0.04` | Boost matching scene labels |
| `videoRelevanceCompensation` | `0.03` | Offset photo-only enrichment boosts |

Newly indexed photos become searchable before enrichment completes. A photo without OCR or scene labels skips those boosts until the deferred enrichment pass updates its row.

## Handle sparse matches

For a query that mixes visual and metadata filters, the app can keep a fallback set when metadata matches but visual scores do not produce enough main results. The UI can then explain that the requested visual content did not match while showing the relevant metadata set separately.

| Parameter | Value | Purpose |
|---|---:|---|
| `locationResultsCap` | `500` | Bound location, fallback, and merged search results |
| `sparseClipMinResults` | `5` | Consider fallback below this main-result count |
| `sparseClipMaxRatio` | `0.1` | Consider fallback below this result-to-candidate ratio |
| `sparseClipMinScore` | `0.07` | Require this top visual score for main-grid confidence |

If hard filters and visual ranking both fail, return an empty local result. Do not call remote processing or silently broaden the query.

## Keep search work bounded

Search scores the local index but retains no more than 500 results in any response path. Whole-library search reads at most 512 media descriptors per database page and checks cancellation between pages. Memory-pressure handling cancels active search work and suspends index reloads until explicit user or app work resumes.

Duplicate search uses separate safety limits: it performs at most 5,000,000 pair comparisons and retains at most 2,000 candidate pairs. Folder enumeration checks cancellation and retains at most 100,000 supported image URLs.

When you add a new scoring or enrichment path, define a deterministic work limit, bound retained output, and propagate task cancellation before integrating it.

## Run the evaluation gate

Run the local relevance harness after changing scoring, preprocessing, model compression, or model artifacts. The gate covers visual queries, date filtering, location metadata, mixed visual and location fallback, negative terms, videos, and empty results.

See `docs/RELEVANCE_EVALUATION.md` for commands and fixture details.
