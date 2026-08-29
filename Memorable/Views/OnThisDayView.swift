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
                            ZStack(alignment: .bottomLeading) {
                                MemoryHeroImage(localIdentifier: yearGroups.first?.ids.first)
                                    .frame(height: 400)
                                LinearGradient(
                                    colors: [.black.opacity(0.12), Celestial.Colors.background],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                                .frame(height: 240)

                                VStack(alignment: .leading, spacing: 0) {
                                    Text("ON THIS DAY")
                                        .font(.caption.weight(.medium))
                                        .tracking(1.4)
                                        .foregroundStyle(Celestial.Colors.amber)
                                    Text(Date.now.formatted(.dateTime.month(.wide).day()))
                                        .font(.system(.largeTitle, design: .rounded, weight: .semibold))
                                        .tracking(-1)
                                        .foregroundStyle(Celestial.Colors.onSurface)
                                        .padding(.top, 10)
                                    Text("\(yearGroups.reduce(0) { $0 + $1.ids.count }) photos across \(yearGroups.count) years")
                                        .font(.subheadline)
                                        .foregroundStyle(Celestial.Colors.secondary)
                                        .padding(.top, 8)

                                    Button(action: { showSlideshow = true }) {
                                        Label("Relive your memories", systemImage: "play.fill")
                                            .font(.subheadline.weight(.semibold))
                                            .foregroundStyle(Celestial.Colors.surfaceDim)
                                            .padding(.horizontal, 20)
                                            .frame(height: 46)
                                            .background(Celestial.Colors.onSurface)
                                            .clipShape(Capsule())
                                    }
                                    .padding(.top, 22)
                                }
                                .padding(.horizontal, 26)
                                .padding(.bottom, 24)
                            }

                            LazyVStack(spacing: 28) {
                                ForEach(yearGroups, id: \.year) { group in
                                    VStack(spacing: 12) {
                                        HStack(alignment: .firstTextBaseline) {
                                            Text("\(String(group.year))")
                                                .font(.system(.title2, design: .rounded, weight: .semibold))
                                                .tracking(-0.6)
                                                .foregroundStyle(Celestial.Colors.onSurface)
                                            Spacer()
                                            Text("\(group.ids.count) photos")
                                                .font(.caption)
                                                .foregroundStyle(Celestial.Colors.onSurfaceVariant)
                                        }
                                        .padding(.horizontal, 26)

                                        MasonryGrid(
                                            group.ids.prefix(20).map { IdentifiedString(id: $0) },
                                            spacing: 5
                                        ) { item in
                                            MemoryThumbnail(localIdentifier: item.id, groupIds: group.ids)
                                        }
                                        .padding(.horizontal, 5)
                                    }
                                }
                            }
                            .padding(.top, 28)
                        }
                    }
                    .padding(.bottom, 40)
                }
            }
            .toolbar(.hidden, for: .navigationBar)
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

private struct MemoryHeroImage: View {
    let localIdentifier: String?
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Celestial.memoryGradient
            }
        }
        .clipped()
        .task(id: localIdentifier) {
            guard let localIdentifier,
                  let asset = PhotoLibrary.getAsset(by: localIdentifier) else { return }
            image = await PhotoLibrary.loadThumbnail(for: asset, maxDimension: 1200)
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
        let raw = thumb.size.width / thumb.size.height
        return min(max(raw, 9.0/16.0), 16.0/9.0)
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
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
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
