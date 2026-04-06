# Feature: Photo Timeline with Story Clustering

**Status:** Planned (not yet implemented)
**Priority:** Future release
**Last updated:** April 2026

## Overview

Automatically group photos into "stories" or "events" based on time and location proximity. No AI needed — pure metadata analysis on creation dates and GPS coordinates already stored in the database. The app organizes the user's life into browsable events without any manual effort.

**Example output:**
- "Your trip to Barcelona" — June 14-17, 2023 — 47 photos
- "Saturday at the park" — March 8, 2025 — 12 photos
- "Office lunch" — April 2, 2026 — 3 photos

## Clustering Algorithm

### Rules

```
Two consecutive photos belong to the SAME story if:

1. WITH GPS:
   - Taken within 2 hours of each other AND
   - Within 5km of each other

2. WITHOUT GPS:
   - Taken within 1 hour of each other

A new story starts when EITHER:
   - Time gap > 2 hours (with GPS) or > 1 hour (without GPS)
   - Location jump > 5km (when GPS available)
```

### Algorithm (single pass, O(n))

```
1. Load all indexed photos sorted by creationDate ASC
2. Initialize first photo as start of first story
3. For each subsequent photo:
   a. Compare time gap with previous photo
   b. Compare GPS distance with previous photo (if both have GPS)
   c. If within thresholds → add to current story
   d. If exceeds thresholds → close current story, start new one
4. Filter: discard stories with < 2 photos (single shots aren't stories)
5. Save stories to database
```

### Pseudocode

```swift
func clusterStories(photos: [IndexedPhoto]) -> [PhotoStory] {
    let sorted = photos.sorted { ($0.creationDate ?? .distantPast) < ($1.creationDate ?? .distantPast) }
    
    var stories: [PhotoStory] = []
    var currentPhotos: [IndexedPhoto] = []
    
    for photo in sorted {
        guard let date = photo.creationDate else { continue }
        
        if let lastPhoto = currentPhotos.last,
           let lastDate = lastPhoto.creationDate {
            
            let timeDiff = date.timeIntervalSince(lastDate)
            let bothHaveGPS = photo.latitude != nil && lastPhoto.latitude != nil
            
            let sameStory: Bool
            if bothHaveGPS {
                let distance = haversineDistance(
                    lat1: lastPhoto.latitude!, lon1: lastPhoto.longitude!,
                    lat2: photo.latitude!, lon2: photo.longitude!
                )
                sameStory = timeDiff < 7200 && distance < 5000 // 2hrs, 5km
            } else {
                sameStory = timeDiff < 3600 // 1hr without GPS
            }
            
            if sameStory {
                currentPhotos.append(photo)
            } else {
                if currentPhotos.count >= 2 {
                    stories.append(buildStory(from: currentPhotos))
                }
                currentPhotos = [photo]
            }
        } else {
            currentPhotos = [photo]
        }
    }
    
    // Don't forget the last story
    if currentPhotos.count >= 2 {
        stories.append(buildStory(from: currentPhotos))
    }
    
    return stories
}
```

## Data Model

```swift
struct PhotoStory: Codable, FetchableRecord, PersistableRecord, Identifiable {
    var id: String                  // UUID
    var title: String?              // User-editable, auto-generated initially
    var autoTitle: String           // "Trip to Barcelona" or "Saturday afternoon"
    var startDate: Date
    var endDate: Date
    var latitude: Double?           // Center of the story's GPS cluster
    var longitude: Double?
    var locationName: String?       // Reverse-geocoded place name
    var photoCount: Int
    var coverPhotoId: String        // localIdentifier of the sharpest photo
    var createdAt: Date

    static let databaseTableName = "photo_stories"
}

struct StoryPhoto: Codable, FetchableRecord, PersistableRecord {
    var storyId: String
    var photoLocalIdentifier: String
    var position: Int               // Order within the story

    static let databaseTableName = "story_photos"
}
```

## Auto-Title Generation

Titles are generated from metadata, no AI needed:

### With GPS + Reverse Geocoding
```
"Trip to Barcelona" — if spans multiple days
"Evening in Barcelona" — if same day, evening
"Morning at Central Park" — if same day, morning, specific place
```

### Without GPS
```
"Saturday afternoon" — day of week + time of day
"June 14, 2023" — fallback to date
```

### Time-of-day labels
```
00-06: "Late night"
06-09: "Early morning"
09-12: "Morning"
12-14: "Lunchtime"
14-17: "Afternoon"
17-20: "Evening"
20-24: "Night"
```

### Duration labels
```
Same day: "{time_of_day} in {location}"
2-3 days: "Weekend in {location}"
4-7 days: "Trip to {location}"
7+ days: "Week in {location}" or "{location}, {month} {year}"
```

### Without location
```
Same day: "{day_of_week} {time_of_day}"
Multi-day: "{month} {start_day}-{end_day}, {year}"
```

## Database Migration

```swift
migrator.registerMigration("vX_stories") { db in
    try db.create(table: "photo_stories") { t in
        t.column("id", .text).primaryKey()
        t.column("title", .text)
        t.column("autoTitle", .text).notNull()
        t.column("startDate", .datetime).notNull()
        t.column("endDate", .datetime).notNull()
        t.column("latitude", .double)
        t.column("longitude", .double)
        t.column("locationName", .text)
        t.column("photoCount", .integer).notNull()
        t.column("coverPhotoId", .text).notNull()
        t.column("createdAt", .datetime).notNull()
    }

    try db.create(table: "story_photos") { t in
        t.column("storyId", .text).notNull().references("photo_stories", onDelete: .cascade)
        t.column("photoLocalIdentifier", .text).notNull()
        t.column("position", .integer).notNull()
    }

    try db.create(index: "idx_story_photos_storyId", on: "story_photos", columns: ["storyId"])
}
```

## Cover Photo Selection

For each story, pick the cover photo using this priority:
1. Highest `sharpnessScore` (sharpest photo)
2. If tied, prefer photos with faces detected (more interesting)
3. If still tied, pick the middle photo chronologically (representative of the event)

```swift
func selectCoverPhoto(from photos: [IndexedPhoto]) -> String {
    let sorted = photos.sorted { ($0.sharpnessScore ?? 0) > ($1.sharpnessScore ?? 0) }
    return sorted.first?.localIdentifier ?? photos[photos.count / 2].localIdentifier
}
```

## UI Design

### Stories Tab / Section in Memories

```
┌─────────────────────────────────┐
│  ┌───────────────────────────┐  │
│  │   [Cover Photo]           │  │
│  │                           │  │
│  │   Trip to Barcelona       │  │
│  │   June 14-17, 2023        │  │
│  │   47 photos               │  │
│  └───────────────────────────┘  │
│                                 │
│  ┌──────────┐ ┌──────────┐     │
│  │ Saturday │ │ Office   │     │
│  │ at Park  │ │ Lunch    │     │
│  │ 12 photos│ │ 3 photos │     │
│  └──────────┘ └──────────┘     │
└─────────────────────────────────┘
```

### Story Detail View
- Masonry grid of all photos in the story
- Story title (editable) + date range + location
- "Play as Slideshow" button (reuses MemorySlideshowView)
- Photos clickable (full-screen viewer)

### Story Card Component

```swift
struct StoryCardView: View {
    let story: PhotoStory
    @State private var coverImage: UIImage?
    
    var body: some View {
        ZStack(alignment: .bottomLeading) {
            // Cover photo
            if let image = coverImage {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(16/9, contentMode: .fill)
                    .clipped()
            }
            
            // Gradient + text overlay
            VStack(alignment: .leading, spacing: 4) {
                Text(story.title ?? story.autoTitle)
                    .font(.system(.headline, design: .rounded, weight: .semibold))
                    .foregroundStyle(.white)
                Text(story.dateRangeText)
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.8))
                Text("\(story.photoCount) photos")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.6))
            }
            .padding(16)
            .background(LinearGradient(...))
        }
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }
}
```

## Placement Options

### Option A: Section in Memories tab (recommended)
```
Memories tab:
  ├── Relive Your Memories (slideshow button)
  ├── Your Stories (horizontal scroll of story cards)
  ├── Photo Map (future)
  └── On This Day
```

### Option B: Separate tab
Adds a 5th tab — feels crowded.

### Option C: Inside More tab
Too hidden for such a visual feature.

**Recommended: Option A** — stories as a horizontal scrollable section in the Memories tab, between the slideshow button and On This Day.

## When to Run Clustering

- **After indexing completes** (same timing as face clustering and surprise query validation)
- **Incremental**: when new photos are indexed, only re-cluster the affected time ranges
- **On demand**: user can trigger "Refresh Stories" from settings

## Performance

- **O(n)** single-pass algorithm — sorts photos by date, then linear scan
- For 2,900 photos: < 100ms to cluster
- For 50,000 photos: < 1 second
- Reverse geocoding for titles: batch via CLGeocoder, cache results
- Story clustering runs on `Task.detached(priority: .utility)` after indexing

## Reverse Geocoding for Story Titles

```swift
func reverseGeocode(latitude: Double, longitude: Double) async -> String? {
    let location = CLLocation(latitude: latitude, longitude: longitude)
    let geocoder = CLGeocoder()
    
    do {
        let placemarks = try await geocoder.reverseGeocodeLocation(location)
        if let place = placemarks.first {
            // Prefer: city > locality > area > country
            return place.locality ?? place.subAdministrativeArea ?? place.administrativeArea ?? place.country
        }
    } catch { }
    return nil
}
```

**Rate limiting**: CLGeocoder has rate limits. Process stories in batches of 5-10 with 1-second delays between batches.

## Implementation Tasks

| Task | Effort | Description |
|------|--------|-------------|
| 1 | Low | Database migration: photo_stories + story_photos tables |
| 2 | Medium | StoryClusteringService: single-pass algorithm |
| 3 | Low | Auto-title generation (date/time/location based) |
| 4 | Medium | Reverse geocoding for story location names |
| 5 | Low | Cover photo selection (sharpest photo) |
| 6 | Medium | StoryCardView: horizontal scroll card with cover photo |
| 7 | Medium | StoryDetailView: masonry grid + slideshow button |
| 8 | Low | Integration into Memories tab |
| 9 | Low | Trigger clustering after indexing |
| 10 | Low | Build, test, verify |

**Estimated total effort:** 3-4 hours

## Dependencies

- Existing indexed_photos table with creationDate, latitude, longitude, sharpnessScore
- Existing masonry grid layout (MemoryMasonryGrid)
- Existing FullScreenPhotoViewer for photo taps
- Existing MemorySlideshowView for "Play as Slideshow"
- CLGeocoder for reverse geocoding (already imported)

## Future Enhancements

- User-editable story titles
- Merge/split stories manually
- Share a story as a video montage with captions
- "This time last year" featuring stories from the same month
- Story highlights: auto-select the 5 best photos per story using sharpness + CLIP diversity
- Travel journal: connect stories on a map with routes
