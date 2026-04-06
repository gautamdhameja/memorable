# Feature: Photo Map View

**Status:** Planned (not yet implemented)
**Priority:** Future release
**Last updated:** April 2026

## Overview

A map-based photo browser where users can see their photos plotted on Apple Maps by GPS location. Tapping a cluster/pin shows photos from that area. Zooming in reveals individual photos.

## User Experience

1. User opens Memories tab → taps "Photo Map" button
2. Full-screen Apple Maps view appears
3. Photo clusters shown as pins with thumbnail + count
4. Zooming in splits clusters into individual photos
5. Tapping a pin opens a masonry grid of photos from that area
6. Tapping an empty area searches for nearby photos
7. Photos without GPS are not shown on the map

## Architecture

### Placement

Button in Memories tab (same style as "Relive Your Memories" slideshow button). Keeps the tab bar at 4 tabs.

### Data Flow

```
1. Load all indexed photos with lat/lon from DB
   (~20% of photos have GPS data)

2. Cluster nearby photos into map pins
   - Group photos within ~500m radius
   - Pin shows count + thumbnail of best photo
   - Zooming in reveals individual photos

3. User taps a pin → shows photo grid for that area
   - Same masonry layout as search results
   - Clickable (full-screen viewer / native video player)

4. User taps empty area on map → search photos near that coordinate
   - Reuses GPS proximity logic from SearchEngine
```

### SwiftUI / MapKit Implementation

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

### Data Model

```swift
struct PhotoAnnotation: Identifiable {
    let id: String
    let coordinate: CLLocationCoordinate2D
    let photoIds: [String]        // localIdentifiers of photos in this cluster
    let photoCount: Int
    var thumbnail: UIImage?       // loaded lazily
}
```

### Database Query

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

### Clustering Approach

**Option 1: MapKit's built-in MKClusterAnnotation**
- Handles zoom-level clustering automatically
- Apple manages the clustering algorithm
- Best UX but requires UIKit bridge (MKMapView via UIViewRepresentable)

**Option 2: Grid-based clustering**
- Divide visible map region into grid cells
- Group photos per cell
- Recompute on region change
- Simpler, pure SwiftUI with Map view

**Recommended:** Option 1 for production quality. Option 2 as MVP.

### Performance Considerations

- Load all lat/lon pairs once on view appear (lightweight — two Doubles per photo)
- Annotations created lazily as the map region changes
- Thumbnails loaded on demand when pins become visible
- For 2,900 photos with ~500 having GPS: ~500 annotations max, well within MapKit limits
- For large libraries (50K+ photos with GPS): need spatial indexing or server-side clustering

### Photos Without GPS

- Not shown on the map (map is a GPS-only feature)
- Show info banner: "247 of 2,900 photos have location data"
- Future: allow user to manually assign locations to photos

### UI Components Needed

1. **PhotoMapView** — Main map view with annotations
2. **PhotoClusterPin** — Custom annotation view (circular thumbnail + count badge)
3. **ClusterDetailView** — Grid of photos when a cluster is tapped (reuse masonry layout)
4. **Map button in Memories tab** — Same style as slideshow button

### Implementation Tasks

| Task | Effort | Description |
|------|--------|-------------|
| 1 | Low | Add DB method to load all photos with GPS coordinates |
| 2 | Medium | Create PhotoMapView with MapKit + annotations |
| 3 | Medium | Implement clustering (grid-based MVP or MKClusterAnnotation) |
| 4 | Low | Create cluster detail view (reuse masonry grid + full-screen viewer) |
| 5 | Low | Add "Photo Map" button to Memories tab |
| 6 | Low | Add info banner for GPS coverage stats |
| 7 | Medium | Lazy thumbnail loading for visible annotations |
| 8 | Low | Build, test, verify |

**Estimated total effort:** 2-3 hours

### Dependencies

- MapKit framework (already available, no additional imports needed)
- CoreLocation (already imported for CLGeocoder in SearchEngine)
- Existing GPS data in indexed_photos table (latitude, longitude columns)
- Existing masonry grid layout (MemoryMasonryGrid)
- Existing full-screen photo viewer (FullScreenPhotoViewer)

### Future Enhancements

- Heat map overlay showing photo density
- Time slider to filter photos by date range on the map
- "Photos near me" using current location
- Route visualization for travel trips (connect photos chronologically)
- Share a map view of a trip
