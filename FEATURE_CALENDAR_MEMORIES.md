# Calendar event memories

**Status:** Planned (not yet implemented)
**Priority:** Future release
**Last updated:** April 2026
**Opt-in:** Yes — user must explicitly enable in More → Settings. Not enabled by default.

## Overview

When the user enables this feature, Memorable reads calendar events, matches them to photos from the same time range, and can use Apple's on-device Foundation Models to generate short summaries.

**Example output:**
> *"Team Offsite at Rishikesh" — June 15-17, 2024*
> *The team traded laptops for paddles that day in Rishikesh. Between the rapids and the dal makhani, it was exactly the reset everyone needed.*
> *23 photos from this event*

## Let users opt in

1. Open **More > Settings**.
2. Turn on **Calendar memories**. The setting is off by default.
3. Respond to the system calendar permission prompt.
4. If access is granted, Memorable loads events and matches them to photos.
5. If access is denied, Memorable turns the setting off and explains why.
6. Turn the feature off to clear calendar data from memory. The initial implementation does not store events in the database.

### Require explicit access
- Request calendar access only after the user enables the feature.
- Keep the feature off by default.
- Explain how Memorable uses calendar events before showing the system prompt.
- Do not request calendar access during first launch.

## Architecture

### Access calendars with EventKit

```swift
import EventKit

class CalendarService {
    private let eventStore = EKEventStore()
    
    func requestAccess() async -> Bool {
        // iOS 17+: must use requestFullAccessToEvents
        do {
            return try await eventStore.requestFullAccessToEvents()
        } catch {
            return false
        }
    }
    
    func loadEvents(from startDate: Date, to endDate: Date) -> [EKEvent] {
        let predicate = eventStore.predicateForEvents(
            withStart: startDate,
            end: endDate,
            calendars: nil // all calendars
        )
        return eventStore.events(matching: predicate)
    }
}
```

**Info.plist key required:**
```xml
<key>NSCalendarsFullAccessUsageDescription</key>
<string>Allow Memorable to match calendar events with photos on this device. Memorable does not send calendar data to the developer.</string>
```

### Match photos to events

```swift
struct EventMemory {
    let event: EKEvent
    let matchedPhotos: [IndexedPhoto]
    let photoCategories: [String]      // from PhotoCaptionService
    let narrative: String?             // from Foundation Models
}

func matchPhotosToEvents(events: [EKEvent]) -> [EventMemory] {
    // For each calendar event, find photos taken during that time window
    // Query: SELECT * FROM indexed_photos 
    //        WHERE creationDate >= event.startDate 
    //        AND creationDate <= event.endDate
    
    // Optional GPS enhancement:
    // If event has a location, boost photos taken near that location
    
    // Filter out noise:
    // - Skip events with < 3 matched photos
    // - Skip events shorter than 30 minutes
    // - Skip recurring events (isRecurring)
    // - Skip all-day events that are just reminders
    // - Skip cancelled events (status == .canceled)
}
```

### Filter events

Not all calendar events make good memories. Filter:

| Rule | Reason |
|------|--------|
| Skip events with fewer than 3 photos | Require enough media for the event card and detail view. |
| Skip events shorter than 30 minutes | Reduce matches from brief calendar entries. |
| Skip recurring events | Reduce repeated work and routine entries. |
| Skip canceled events | Exclude events that did not occur. |
| Skip all-day events without photos | Exclude entries that have no matching media. |
| Keep all-day events with photos | Include birthdays, trips, and other documented events. |

### Generate narratives with Foundation Models

On iOS 26+ devices with Foundation Models available:

```swift
@available(iOS 26.0, *)
func generateNarrative(event: EKEvent, photoCategories: [String]) async -> String? {
    guard SystemLanguageModel.default.isAvailable else { return nil }
    
    let session = LanguageModelSession()
    
    let categories = photoCategories.joined(separator: ", ")
    let duration = event.endDate.timeIntervalSince(event.startDate)
    let durationText = duration > 86400 ? "\(Int(duration / 86400)) days" : "\(Int(duration / 3600)) hours"
    
    let prompt = """
    Write a warm, nostalgic 2-sentence memory summary for this event.
    Event: "\(event.title ?? "Untitled")"
    Location: \(event.location ?? "unknown")
    Duration: \(durationText)
    Photos taken during this event include: \(categories)
    Be personal and emotional. No hashtags or emojis.
    """
    
    do {
        let response = try await session.respond(to: prompt)
        return response.content
    } catch {
        return nil
    }
}
```

**Fallback for devices without Foundation Models:**
Template-based narrative using event title + photo count + date:
```
"Your trip to Rishikesh — 23 photos from June 15-17, 2024"
```

### Provide photo categories as narrative context

Reuse the existing `PhotoCaptionService` to categorize matched photos:
```swift
// For each matched photo, get its CLIP embedding from DB
// Run through PhotoCaptionService.caption() to get the category
// Pass unique categories to the narrative generator
// e.g., ["people", "nature", "food", "sunset"]
```

This provides visual-category context to the on-device model without providing image files to it.

## Data model

**No new database tables.** Calendar events are loaded on-demand from EventKit and matched in memory. Nothing is persisted — when the user disables the feature, there's nothing to delete.

```swift
// In-memory only
struct EventMemory: Identifiable {
    let id: String              // event.eventIdentifier
    let title: String
    let location: String?
    let startDate: Date
    let endDate: Date
    let photoLocalIds: [String]
    let photoCount: Int
    let narrative: String?
    let topCategories: [String]
}
```

### Store settings

```swift
// UserDefaults
UserDefaults.standard.bool(forKey: "calendarMemoriesEnabled") // default: false
```

## UI design

### Choose placement

In the **Memories tab**, as a section between "Relive Your Memories" button and "On This Day":

```
Memories tab:
  ├── Relive Your Memories (slideshow button)
  ├── Event Memories (new, only when enabled)
  │   ├── Horizontal scroll of EventMemoryCard views
  │   └── "See All" link to full list
  └── On This Day
```

### Build `EventMemoryCard`

```
┌─────────────────────────────────┐
│  [Cover Photo - sharpest match] │
│                                 │
│  Team Offsite                   │
│  Rishikesh · Jun 15-17, 2024   │
│  23 photos                      │
│                                 │
│  "The team traded laptops..."   │
└─────────────────────────────────┘
```

### Build the event memory detail view

When tapped:
- Full narrative at the top
- Event details (title, location, date range)
- Masonry grid of all matched photos (reuse existing layout)
- Users can open photos in the app's full-screen viewer.
- "Play as Slideshow" button (reuse MemorySlideshowView, scoped to these photos)

### Add settings to the More tab

```
Section("Features") {
    Toggle("Calendar Memories", isOn: $calendarEnabled)
        .onChange(of: calendarEnabled) { _, enabled in
            if enabled {
                // Request calendar access
                // If denied, revert toggle
            } else {
                // Clear any in-memory calendar data
            }
        }
    
    if calendarEnabled {
            Text("Memorable matches calendar events with photos and generates summaries on this device.")
            .font(.footnote)
            .foregroundStyle(.secondary)
    }
}
```

## Protect calendar data

| Concern | Guidance |
|---------|-----------------|
| Calendar data transfer | Keep calendar data on the device. Do not add remote processing. |
| Database storage | Load events from EventKit on demand and retain them only in memory. |
| Disabled access | Clear in-memory event data immediately. |
| Shared calendars | Read only the user's default calendar in the initial implementation. |
| Foundation Models | Use only the on-device model path. |
| Network access | Do not add network requests for calendar processing. Existing CLGeocoder and StoreKit boundaries remain governed by the privacy policy. |

## Implementation tasks

| Task | Effort | Description |
|------|--------|-------------|
| 1 | Low | Create `CalendarService.swift` — EventKit wrapper, request access, load events |
| 2 | Low | Add `NSCalendarsFullAccessUsageDescription` to Info.plist |
| 3 | Low | Add opt-in toggle in MoreView settings section |
| 4 | Medium | Photo-event matching logic (date range overlap query) |
| 5 | Medium | Event filtering (skip recurring, short, cancelled) |
| 6 | Medium | Foundation Models narrative generation with photo categories |
| 7 | Low | Template fallback for devices without Foundation Models |
| 8 | Medium | EventMemoryCard view (horizontal scroll section) |
| 9 | Medium | Event Memory detail view (narrative + masonry grid) |
| 10 | Low | Integration into Memories tab |
| 11 | Low | Settings toggle with calendar permission flow |
| 12 | Low | Build, test, verify |

## Dependencies

- EventKit framework (system framework, no additional dependency)
- Existing indexed_photos table with creationDate
- Existing PhotoCaptionService for photo categorization
- Existing masonry grid layout for detail view
- Existing MemorySlideshowView for slideshow playback
- Foundation Models framework (iOS 26+) for narrative generation
- Existing `SearchResultsViewer` for local photo viewing

## Consider future enhancements

- Smart event grouping: combine multi-day events that are part of the same trip
- Location-aware matching: boost photos near the event's location
- Shared calendar awareness: "Photos from Sarah's birthday party" using shared calendar events
- Yearly recap: "Your year in events" summary combining all event memories
- Widget: "Today's memory" showing an event memory from this date in previous years
- Calendar heatmap: visual calendar showing which days have the most photos

## Sources

- [EventKit Calendar Access — Apple Developer](https://developer.apple.com/documentation/EventKit/accessing-calendar-using-eventkit-and-eventkitui)
- [Foundation Models Framework — Apple Developer](https://developer.apple.com/documentation/FoundationModels)
- [Deep Dive into Foundation Models — WWDC25](https://developer.apple.com/videos/play/wwdc2025/301/)
- [Apple Foundation Models Research](https://machinelearning.apple.com/research/introducing-apple-foundation-models)
- [Read Calendar Events in SwiftUI](https://nicoladefilippo.com/read-events-from-the-calendar-in-swiftui/)
- [EventKitUI in iOS 17](https://betterprogramming.pub/eventkitui-in-ios-17-c83868464a8f)
