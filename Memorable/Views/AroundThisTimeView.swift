import SwiftUI

struct AroundThisTimeView: View {
    let photo: SearchResult
    var searchEngine: SearchEngine? = nil
    @Environment(\.database) private var database
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var proManager = ProManager.shared
    @State private var photos: [IndexedPhotoReference] = []
    @State private var isLoading = true
    @State private var errorMessage: String?

    private var entitledPhotos: [IndexedPhotoReference] {
        photos.filter { FolderResultAccessPolicy.allows(sourceId: $0.sourceId, isPro: proManager.isPro) }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                CelestialBackdrop()
                if isLoading {
                    ProgressView().tint(Celestial.Colors.primary)
                } else if let errorMessage {
                    ContentUnavailableView("Couldn't load photos", systemImage: "exclamationmark.triangle",
                                           description: Text(errorMessage))
                } else if entitledPhotos.isEmpty {
                    ContentUnavailableView("No nearby photos", systemImage: "clock",
                                           description: Text("No other indexed photos within one hour of this photo."))
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            Text("One hour before and after")
                                .font(Celestial.Typography.supporting)
                                .foregroundStyle(Celestial.Colors.onSurfaceVariant)
                            if let date = photo.creationDate {
                                Text(date.formatted(date: .long, time: .shortened))
                                    .font(Celestial.Typography.bodyStrong)
                            }
                            MasonryGrid(
                                entitledPhotos,
                                spacing: 5,
                                aspectRatio: { MediaTileAspectRatio.ratio(for: $0) }
                            ) { nearby in
                                MemoryThumbnail(photo: nearby, groupPhotos: entitledPhotos,
                                                searchEngine: searchEngine, accessibilityTitle: nearby.creationDate.map {
                                        "Photo taken \($0.formatted(date: .abbreviated, time: .shortened))"
                                    } ?? "Photo",
                                                viewerBackTitle: "Nearby")
                            }
                            if photos.count == 100 {
                                Text("Showing the 100 closest photos.")
                                    .font(Celestial.Typography.caption)
                            }
                        }
                        .padding(Celestial.Spacing.pageHorizontalInset)
                    }
                }
            }
            .celestialNavigationTitle("Around this time")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .task(id: proManager.isPro) {
            isLoading = true
            errorMessage = nil
            do {
                let database = database
                let isPro = proManager.isPro
                let loaded = try await CancellableDetachedOperation.run {
                    try database.photosAround(photo, isPro: isPro)
                }
                try Task.checkCancellation()
                photos = loaded
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                logger.error("Nearby photos failed: \(error.safeDiagnosticCode)")
                errorMessage = "Close this view and try again."
            }
            isLoading = false
        }
    }
}
