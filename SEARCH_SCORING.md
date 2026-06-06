# Search Scoring Algorithm

## Architecture: Parse, Filter, Then Score

Memorable uses SigLIP2 for raw text/image similarity. The text encoder receives
the user's visual query directly; it does not apply CLIP-style prompt templates.
Date and location constraints are parsed first, then applied before ranking so a
strong visual match from the wrong time or place does not dominate the result set.

## Pipeline

```text
Query: "sunset in San Diego last summer"
  -> QueryParser extracts:
     visual text="sunset", date range, location name, negative terms
  -> Location text matches indexed reverse-geocoded metadata locally
  -> TextEncoder encodes the raw visual text with SigLIP2
  -> SearchEngine snapshots photo and video embedding matrices under lock
  -> Date/location filters build candidate sets
  -> Dot products rank photo embeddings and video frame embeddings
  -> Additive boosts adjust location proximity, time of day, available OCR, available scene labels, and video relevance
  -> Negative terms subtract a weighted negative similarity
  -> Results below SearchConfig.minimumScoreThreshold are removed
  -> Best video frame per video is kept
  -> Photo and video results are merged and sorted
```

## Query Encoding

SigLIP2 was trained with sigmoid loss over raw web captions. Prompt fusion such
as averaging `"dog"`, `"a photo of dog"`, and `"a picture of dog"` is intentionally
not used because it dilutes compositional queries. The implemented path encodes
the parser's raw `textQuery`.

## Hard Filters

Date filters remove media outside the requested range. Media without dates is
removed when the user asked for a date because it cannot satisfy the constraint.

Location filters prefer reverse-geocoded string metadata when available:
city, state, country, and full location name are matched against the parsed
location. Query-derived location names are not sent to CLGeocoder. GPS distance
is used only when trusted coordinates are already present in parsed hints.

Pure location queries, such as `"Paris"`, skip visual scoring and return
metadata matches sorted by date.

## Scoring

Photo scoring uses dot product against normalized embeddings. On device, the app
uses the GPU search path when available and CPU/vDSP fallback otherwise.

Video scoring applies the same query embedding to each stored frame embedding,
then keeps the best frame per video.

Boosts are additive and scaled for SigLIP2's lower cosine score range:

| Parameter | Current value | Purpose |
|---|---:|---|
| `minimumScoreThreshold` | `0.12` | Minimum score for main results |
| `locationCloseBoost` | `0.025` | Added within 10% of radius |
| `locationNearBoost` | `0.015` | Added within 30% of radius |
| `timeOfDayMatchBoost` | `0.03` | Added when creation hour matches query |
| `negativeTermWeight` | `0.3` | Subtracts weighted negative similarity |
| `ocrBoostPerWord` | `0.08` | Adds OCR text match strength |
| `sceneLabelBoostPerMatch` | `0.04` | Adds scene label match strength |
| `videoRelevanceCompensation` | `0.03` | Offsets missing photo-only boosts for videos |

OCR and scene-label boosts are enrichment-dependent. Newly indexed base photos
can be searched by embedding before OCR and scene labels are available; those
photos simply skip the unavailable boosts until the background enrichment pass
updates the row.

## Sparse Visual Fallback

For mixed visual/filter queries, the app keeps a fallback set when filters match
but visual scores are too sparse for the main grid. This lets the UI explain
"no dog photos in Berlin" while still showing media from Berlin separately.

Fallback behavior is controlled by:

| Parameter | Current value | Purpose |
|---|---:|---|
| `locationResultsCap` | `500` | Maximum metadata/fallback results |
| `sparseClipMinResults` | `5` | Main-result count below which fallback is considered |
| `sparseClipMaxRatio` | `0.1` | Result/candidate ratio for sparse fallback |
| `sparseClipMinScore` | `0.07` | Minimum top visual score for main-grid confidence |

## Empty Results

If both hard filters and visual ranking fail, the main result set is empty. The
app should show a local empty state instead of falling back to remote processing
or broadening the query silently.

## Evaluation Gate

Scoring changes, model compression, and model replacement must pass the local
search evaluation harness. Coverage includes visual queries, date filtering,
location metadata, mixed visual/location fallback, negative terms, videos, and
empty-result behavior.
