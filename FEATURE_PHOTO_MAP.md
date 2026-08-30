# Photo map view

**Status:** Planned (not yet implemented)
**Priority:** Future release
**Last updated:** April 2026

## Overview

Display indexed photos with GPS coordinates on Apple Maps. Tapping a cluster or pin shows photos from that area. Zooming changes the cluster detail.

## User experience

1. Open **Memories**, then tap **Photo map**.
2. View a full-screen Apple Maps interface.
3. View bounded photo clusters as pins with a thumbnail and count.
4. Zoom to change cluster granularity.
5. Tap a pin to open a grid of photos from that area.
6. Tap an empty area to search for nearby photos.
7. Photos without GPS coordinates do not appear on the map.

## Architecture

### Choose placement

Button in Memories tab (same style as "Relive Your Memories" slideshow button). Keeps the tab bar at 4 tabs.

### Follow the data flow

```
1. Load indexed photo coordinates from the database in bounded pages.

2. Cluster nearby photos into map pins
   - Group photos using a documented distance and zoom-level policy
   - Pin shows count + thumbnail of best photo
   - Zooming changes the cluster granularity

3. User taps a pin → shows photo grid for that area
   - Same masonry layout as search results
   - Clickable (full-screen viewer / native video player)

4. User taps empty area on map → search photos near that coordinate
   - Reuses GPS proximity logic from SearchEngine
```

### Implement the view with SwiftUI and MapKit

```swift
import MapKit

struct PhotoMapView: View {
    @State private var region = MKCoordinateRegion(...)
    @State private var photoAnnotations: [PhotoAnnotation] = []

    var body: some View {
        Map(coordinateRegion: $region, annotationItems: photoAnnotations) { annotation in
            MapAnnotation(coordinate: annotation.coordinate) {
                PhotoClusterPin(count: annotation.photoCount, thumbnail: annotation.thumbnail)
                    .onTapGesture { showPhotosForCluster(annotation) }
            }
        }
    }
}
```

### Use the data model

```swift
struct PhotoAnnotation: Identifiable {
    let id: String
    let coordinate: CLLocationCoordinate2D
    let photoIds: [String]        // localIdentifiers of photos in this cluster
    let photoCount: Int
    var thumbnail: UIImage?       // loaded lazily
}
```

### Query the database

```swift
// New method in AppDatabase
func loadAllPhotoLocations() throws -> [(localIdentifier: String, latitude: Double, longitude: Double, creationDate: Date?)] {
    try dbQueue.read { db in
        let sql = """
            SELECT localIdentifier, latitude, longitude, creationDate
            FROM indexed_photos
            WHERE latitude IS NOT NULL AND longitude IS NOT NULL
        """
        // ...
    }
}
```

### Cluster map annotations

**Option 1: MapKit's built-in `MKClusterAnnotation`**
- Handles zoom-level clustering automatically
- Apple manages the clustering algorithm
- Requires a UIKit bridge (`MKMapView` through `UIViewRepresentable`)

**Option 2: Grid-based clustering**
- Divide visible map region into grid cells
- Group photos per cell
- Recompute on region change
- Simpler, pure SwiftUI with Map view

Use option 1 for the initial production implementation. Use option 2 only if the UIKit bridge cannot meet the project constraints.

### Bound performance costs

- Load coordinate rows in bounded database pages.
- Create annotations as the visible map region changes.
- Apply a deterministic cap before retaining annotations in memory.
- Load thumbnails only when pins become visible.
- Add an on-device spatial index if profiling shows that page-based clustering does not meet the target on large libraries.

### Handle photos without GPS

- Not shown on the map (map is a GPS-only feature)
- Show a dynamic banner such as "247 of 2,900 indexed photos have location data."
- Future: allow user to manually assign locations to photos

### Add UI components

1. **PhotoMapView** — Main map view with annotations
2. **PhotoClusterPin** — Custom annotation view (circular thumbnail + count badge)
3. **ClusterDetailView** — Grid of photos when a cluster is tapped (reuse masonry layout)
4. **Map button in Memories tab** — Same style as slideshow button

### Implementation tasks

| Task | Effort | Description |
|------|--------|-------------|
| 1 | Low | Add a paged database method to load photos with GPS coordinates |
| 2 | Medium | Create PhotoMapView with MapKit + annotations |
| 3 | Medium | Implement clustering (grid-based MVP or MKClusterAnnotation) |
| 4 | Low | Create cluster detail view (reuse masonry grid + full-screen viewer) |
| 5 | Low | Add "Photo Map" button to Memories tab |
| 6 | Low | Add info banner for GPS coverage stats |
| 7 | Medium | Lazy thumbnail loading for visible annotations |
| 8 | Low | Build, test, verify |

### Dependencies

- MapKit framework (already available, no additional imports needed)
- CoreLocation (already imported for CLGeocoder in SearchEngine)
- Existing GPS data in indexed_photos table (latitude, longitude columns)
- Existing masonry grid layout (MemoryMasonryGrid)
- Existing local result viewer (`SearchResultsViewer`)

MapKit can retrieve Apple map tiles and related map-service data. Do not attach photo contents, search query text, embeddings, or local identifiers to those requests. Document the Apple service boundary before shipping this feature.

### Consider future enhancements

- Heat map overlay showing photo density
- Time slider to filter photos by date range on the map
- "Photos near me" using current location
- Route visualization for travel trips (connect photos chronologically)
