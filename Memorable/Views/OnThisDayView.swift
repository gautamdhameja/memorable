import SwiftUI
import Photos
import AVKit

struct OnThisDayView: View {
    let captionService: PhotoCaptionService
    @Environment(\.database) private var database
    @State private var yearGroups: [(year: Int, ids: [String])] = []
    @State private var isLoading = true
    @State private var showSlideshow = false
    @State private var indexedCount = 0

    var body: some View {
        NavigationStack {
            ZStack {
                Celestial.Colors.background.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 0) {
                        // Relive Memories button
                        if indexedCount > 0 {
                            Button(action: { showSlideshow = true }) {
                                HStack(spacing: 14) {
                                    Image(systemName: "play.circle.fill")
                                        .font(.system(size: 36))
                                        .foregroundStyle(Celestial.Colors.amber)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text("Relive Your Memories")
                                            .font(.system(.body, design: .rounded, weight: .semibold))
                                            .foregroundStyle(Celestial.Colors.onSurface)
                                        Text("Watch a slideshow of your photos with captions")
                                            .font(.footnote)
                                            .foregroundStyle(Celestial.Colors.onSurfaceVariant)
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.footnote)
                                        .foregroundStyle(Celestial.Colors.outlineVariant)
                                }
                                .padding(16)
                                .background(Celestial.Colors.surfaceVariant.opacity(0.4))
                                .background(.ultraThinMaterial)
                                .clipShape(RoundedRectangle(cornerRadius: 16))
                            }
                            .padding(.horizontal, 16)
                            .padding(.top, 12)
                            .padding(.bottom, 8)
                        }

                        // On This Day section
                        if isLoading {
                            ProgressView()
                                .tint(Celestial.Colors.primaryDim)
                                .padding(.top, 60)
                        } else if yearGroups.isEmpty {
                            VStack(spacing: 16) {
                                Image(systemName: indexedCount == 0 ? "photo.on.rectangle.angled" : "calendar")
                                    .font(.system(size: 48, weight: .thin))
                                    .foregroundStyle(Celestial.Colors.outlineVariant)
                                if indexedCount == 0 {
                                    Text("Index your photo library to unlock memories")
                                        .font(.subheadline)
                                        .foregroundStyle(Celestial.Colors.onSurfaceVariant)
                                        .multilineTextAlignment(.center)
                                    Text("Go to Search and tap \"Build Search Index\"")
                                        .font(.caption)
                                        .foregroundStyle(Celestial.Colors.outlineVariant)
                                } else {
                                    Text("No memories from this day in previous years")
                                        .font(.subheadline)
                                        .foregroundStyle(Celestial.Colors.onSurfaceVariant)
                                        .multilineTextAlignment(.center)
                                }
                            }
                            .padding(.top, 60)
                            .padding(.horizontal)
                        } else {
                            // Section header
                            HStack {
                                Text("ON THIS DAY")
                                    .font(.caption.weight(.medium))
                                    .tracking(1.5)
                                    .foregroundStyle(Celestial.Colors.amber)
                                Spacer()
                            }
                            .padding(.horizontal, 16)
                            .padding(.top, 20)
                            .padding(.bottom, 8)

                            LazyVStack(spacing: 0) {
                                ForEach(yearGroups, id: \.year) { group in
                                    HStack {
                                        Text("\(String(group.year))")
                                            .font(.system(.title3, design: .rounded, weight: .semibold))
                                            .foregroundStyle(Celestial.Colors.onSurface)
                                        Text("\(group.ids.count) photos")
                                            .font(.footnote)
                                            .foregroundStyle(Celestial.Colors.onSurfaceVariant)
                                        Spacer()
                                    }
                                    .padding(.horizontal, 16)
                                    .padding(.top, 16)
                                    .padding(.bottom, 10)

                                    MasonryGrid(group.ids.prefix(20).map { IdentifiedString(id: $0) }, spacing: 6) { item in
                                        MemoryThumbnail(localIdentifier: item.id, groupIds: group.ids)
                                    }
                                    .padding(.horizontal, 6)
                                }
                            }
                        }
                    }
                    .padding(.bottom, 40)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    HStack(spacing: 10) {
                        Image("AppIconTransparent")
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 36, height: 36)
                        Text("Memories")
                            .font(.system(.title3, design: .rounded, weight: .semibold))
                            .foregroundStyle(Celestial.Colors.onSurface)
                    }
                }
            }
            .preferredColorScheme(.dark)
            .fullScreenCover(isPresented: $showSlideshow) {
                MemorySlideshowView(captionService: captionService)
            }
        }
        .task {
            indexedCount = (try? database.indexedCount()) ?? 0
            do {
                yearGroups = try database.onThisDayPhotos()
            } catch {
                logger.error("On This Day error: \(error.localizedDescription)")
            }
            isLoading = false
        }
    }
}

// MARK: - Memory Thumbnail

struct MemoryThumbnail: View {
    let localIdentifier: String
    var groupIds: [String] = []
    @State private var thumbnail: UIImage?
    @State private var selectedResult: SearchResult?
    @State private var creationDate: Date?

    private var aspectRatio: CGFloat {
        guard let thumb = thumbnail else { return 4.0/3.0 }
        guard thumb.size.height > 0 else { return 4.0/3.0 }
        return thumb.size.width / thumb.size.height
    }

    var body: some View {
        ZStack {
            if let thumb = thumbnail {
                Image(uiImage: thumb)
                    .resizable()
                    .aspectRatio(aspectRatio, contentMode: .fit)
            } else {
                Rectangle()
                    .fill(Celestial.Colors.surfaceContainer)
                    .aspectRatio(4.0/3.0, contentMode: .fit)
                    .overlay {
                        ProgressView()
                            .tint(Celestial.Colors.outlineVariant)
                            .controlSize(.small)
                    }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(creationDate.map { "Memory from \(DateFormatter.mediumDate.string(from: $0))" } ?? "Memory photo")
        .accessibilityAddTraits(.isImage)
        .accessibilityAddTraits(.isButton)
        .onTapGesture { handleTap() }
        .fullScreenCover(item: $selectedResult) { result in
            SearchResultsViewer(
                initialResult: result,
                allResults: groupIds.map { id in
                    SearchResult(id: id, score: 1.0, localIdentifier: id, creationDate: nil, isVideo: false, bestFramePosition: nil)
                }
            )
        }
        .task {
            if let asset = PhotoLibrary.getAsset(by: localIdentifier) {
                thumbnail = await PhotoLibrary.loadThumbnail(for: asset)
                creationDate = asset.creationDate
            }
        }
    }

    private func handleTap() {
        guard let asset = PhotoLibrary.getAsset(by: localIdentifier) else { return }

        if asset.mediaType == .video {
            presentVideoPlayer(for: asset)
        } else {
            selectedResult = SearchResult(
                id: localIdentifier, score: 1.0, localIdentifier: localIdentifier,
                creationDate: creationDate, isVideo: false, bestFramePosition: nil
            )
        }
    }
}
