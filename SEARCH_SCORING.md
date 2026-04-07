# Search Scoring Algorithm

## Architecture: Filter First, Then Score

When a user specifies time or location constraints, those are applied as **hard filters** before CLIP scoring. Only photos that pass the filters get scored. This prevents a great sunset from Tokyo outranking a mediocre sunset from Berlin when the user asked for Berlin.

## Pipeline

```
Query: "sunset in San Diego last summer"
  │
  ├─ Parse → textQuery="sunset", dateRange=Jun-Aug 2025, location="San Diego"
  ├─ Geocode → (32.72, -117.16), radius=30km (city-level)
  │
  ├─ PHASE 1: HARD FILTERS
  │   ├─ Date filter: keep only photos from Jun 1 – Aug 31, 2025
  │   ├─ Location filter: keep only photos within 30km of San Diego
  │   └─ Result: 47 of 5267 photos pass → candidateMask
  │
  ├─ PHASE 2: CLIP SCORING
  │   ├─ GPU dot product on ALL 5267 embeddings
  │   └─ Zero out non-candidates (score = -1.0)
  │
  ├─ PHASE 3: SOFT BOOSTS (candidates only)
  │   ├─ Location proximity: +15% within 3km, +8% within 9km
  │   ├─ Time-of-day: "sunset" → 6-10 PM → +30% if match, -30% if not
  │   ├─ Negative terms: -30% per negative similarity
  │   └─ OCR text: +15% per matching word
  │
  ├─ PHASE 4: VIDEO SCORING (same hard filters)
  │
  └─ PHASE 5: RANK AND RETURN
      ├─ Filter: score >= 0.20
      ├─ Sort by score descending
      └─ Return top 50
```

## Phase 1: Hard Filters

### Date Filter

```
IF dateRange is specified:
  FOR each photo:
    IF photo has a date AND date is outside range → ELIMINATE
    IF photo has NO date metadata → ELIMINATE
    (User specified a time — dateless photos are not useful)
```

### Location Filter

```
IF locationCoordinate + locationRadiusKm are specified:
  FOR each photo:
    IF photo has GPS AND distance > radiusKm → ELIMINATE
    IF photo has NO GPS → KEEP (can't determine location, let CLIP decide)
```

### Smart Location Radius

The radius is determined by the **specificity** of the geocoded result:

| Place type | Example | Radius |
|---|---|---|
| Neighborhood | "Berlin Mitte", "Manhattan" | 5 km |
| City | "Berlin", "San Diego", "Paris" | 30 km |
| County/district | "Orange County" | 75 km |
| State/province | "California", "Brandenburg" | 150 km |
| Country | "Italy", "Germany" | 500 km |
| Unknown | fallback | 50 km |

This means "vacation in Italy" uses a 500km radius from Rome (covers the whole country), while "dinner in Berlin Mitte" uses a 5km radius.

## Phase 2: CLIP Scoring

```
1. Encode query with 3-prompt fusion:
   Average("sunset", "a photo of sunset", "a picture of sunset") → L2 normalize

2. GPU matrix multiply: [N, 768] × [768, 1] → N scores

3. Zero out non-candidates: score = -1.0 for filtered photos
```

## Phase 3: Soft Boosts

Applied ONLY to candidates that passed hard filters.

### Location Proximity (within the filtered radius)

```
IF photo is within 10% of radius → score *= 1.15
IF photo is within 30% of radius → score *= 1.08
(No penalty — everything here already passed the hard filter)
```

### Time-of-Day

```
IF "sunset"/"dinner" detected → preferred hours = 18-22
IF photo.hour is in range → score *= 1.3
IF photo.hour is out of range → score *= 0.7
```

### Negative Terms

```
FOR each negative term (e.g., "-cat"):
  Encode "a photo of cat" → negEmbedding
  score -= dot(negEmbedding, photoEmbedding) × 0.3
```

### OCR Text

```
FOR screenshots with OCR text:
  matchCount = query words found in OCR text
  score += 0.15 × matchCount / totalQueryWords
```

## Phase 4: Video Scoring

Videos follow the same pipeline:
1. Hard date filter (same rules as photos)
2. Hard location filter (same rules, using video GPS)
3. CLIP score per frame
4. Negative term penalty
5. Time-of-day boost
6. Best frame per video kept

## Phase 5: Rank and Return

```
1. Sort all candidates by score descending
2. Filter: score >= 0.20 (minimum visual relevance)
3. Take top 50
4. Combine photos + videos, re-sort, return
```

## Queries Without Constraints

When the user types just "dog" (no time, no location):
- candidateMask is all `true` — nothing filtered
- All photos get CLIP scored
- Minimum threshold (0.20) filters visual junk
- Behaves exactly like a simple similarity search

## Empty Results

If hard filters eliminate all photos (e.g., "aurora borealis yesterday in Berlin"):
- Returns empty results immediately
- Does NOT fall back to unfiltered search
- This is correct — showing irrelevant results is worse than showing nothing

## Configuration (AppConstants.swift → SearchConfig)

| Parameter | Value | Purpose |
|---|---|---|
| minimumScoreThreshold | 0.20 | Minimum CLIP score to include |
| locationCloseBoost | 1.15 | Within 10% of location radius |
| locationNearBoost | 1.08 | Within 30% of location radius |
| timeOfDayMatchBoost | 1.3 | Photo taken during expected hours |
| timeOfDayMismatchPenalty | 0.7 | Photo taken at wrong time |
| negativeTermWeight | 0.3 | Negative term penalty multiplier |
| ocrBoostPerWord | 0.15 | OCR text match boost |
