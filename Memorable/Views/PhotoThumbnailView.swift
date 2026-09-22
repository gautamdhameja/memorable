import SwiftUI

struct PhotoThumbnailView: View {
    let result: SearchResult
    var contentMode: ContentMode = .fill
    @State private var thumbnail: UIImage?
    @State private var isLoading = true
    @State private var imageLoadGeneration: UInt = 0
    @State private var imageLoadTask: Task<Void, Never>?
    @State private var tileSize: CGSize = .zero
    @State private var loadedMaxDimension: CGFloat?
    @Environment(\.displayScale) private var displayScale

    private var requestedMaxDimension: CGFloat? {
        TileImagePixelSizePolicy.maxDimension(for: tileSize, displayScale: displayScale)
    }

    private var accessibilityDescription: String {
        let type = result.isVideo ? "Video" : "Photo"
        if let date = result.creationDate {
            return "\(type), from \(date.formatted(date: .abbreviated, time: .omitted))"
        }
        return type
    }

    static func imageContent(
        thumbnail: UIImage?, isVideo: Bool, contentMode: ContentMode = .fill,
        isLoading: Bool = true,
        aspectRatio: CGFloat = MediaTileAspectRatio.fallback
    ) -> some View {
        // The indexed pixel dimensions decide the canvas, so the tile already
        // has the photo's real shape before the image arrives and its height
        // never changes while the user is scrolling.
        Rectangle()
            .fill(Celestial.Colors.surfaceContainer)
            .aspectRatio(aspectRatio, contentMode: .fit)
            .overlay {
                if let thumbnail {
                    GeometryReader { geometry in
                        Image(uiImage: thumbnail)
                            .resizable()
                            .aspectRatio(contentMode: contentMode)
                            .frame(width: geometry.size.width, height: geometry.size.height)
                            .clipped()
                    }
                } else if isLoading {
                    ProgressView()
                        .tint(Celestial.Colors.outlineVariant)
                        .controlSize(.small)
                } else {
                    Image(systemName: "photo.badge.exclamationmark")
                        .foregroundStyle(Celestial.Colors.onSurfaceVariant)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if thumbnail != nil, isVideo {
                    Image(systemName: "play.fill")
                        .font(Celestial.Typography.captionStrong)
                        .foregroundStyle(.white)
                        .frame(width: 28, height: 28)
                        .modifier(
                            GlassCircleModifier(tint: Color.black.opacity(0.18))
                        )
                        .padding(7)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
    }

    var body: some View {
        Self.imageContent(
            thumbnail: thumbnail, isVideo: result.isVideo,
            contentMode: contentMode, isLoading: isLoading,
            aspectRatio: MediaTileAspectRatio.ratio(for: result)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            !isLoading && thumbnail == nil
                ? "\(accessibilityDescription), preview unavailable"
                : accessibilityDescription
        )
        .accessibilityAddTraits(.isImage)
        .onGeometryChange(for: CGSize.self) { $0.size } action: { tileSize = $0 }
        .task(id: requestedMaxDimension) {
            guard let maxDimension = requestedMaxDimension,
                  thumbnail == nil || TileImagePixelSizePolicy.needsReload(
                      loaded: loadedMaxDimension,
                      requested: maxDimension
                  ) else { return }
            imageLoadTask?.cancel()
            let task = Task { @MainActor in
                guard !Task.isCancelled else { return }
                imageLoadGeneration &+= 1
                let generation = imageLoadGeneration
                isLoading = true
                let loaded: UIImage?
                if result.sourceId == PhotoSourceType.photokit.rawValue,
                   !result.isVideo,
                   let asset = await PhotoLibrary.resolveAsset(by: result.localIdentifier) {
                    loaded = await PhotoLibrary.loadThumbnail(for: asset, maxDimension: maxDimension)
                } else {
                    loaded = await PhotoLibrary.loadImage(
                        for: result,
                        targetSize: CGSize(width: maxDimension, height: maxDimension)
                    )
                }
                if ImageLoadGenerationPolicy.acceptsCompletion(
                    startedGeneration: generation,
                    currentGeneration: imageLoadGeneration,
                    isCancelled: Task.isCancelled
                ) {
                    // Keep a sharper image already on screen if the larger
                    // request fails, rather than blanking the tile.
                    if let loaded {
                        thumbnail = loaded
                        loadedMaxDimension = maxDimension
                    } else if thumbnail == nil {
                        loadedMaxDimension = nil
                    }
                    isLoading = false
                }
            }
            imageLoadTask = task
            await withTaskCancellationHandler {
                await task.value
            } onCancel: {
                task.cancel()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
            imageLoadTask?.cancel()
            imageLoadTask = nil
            imageLoadGeneration &+= 1
            MemoryPressureReleasePolicy.release(&thumbnail)
            loadedMaxDimension = nil
            isLoading = false
        }
    }
}
