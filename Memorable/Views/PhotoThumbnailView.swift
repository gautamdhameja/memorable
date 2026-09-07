import SwiftUI

struct PhotoThumbnailView: View {
    let result: SearchResult
    @State private var thumbnail: UIImage?
    @State private var imageLoadGeneration: UInt = 0
    @State private var imageLoadTask: Task<Void, Never>?

    private var accessibilityDescription: String {
        let type = result.isVideo ? "Video" : "Photo"
        if let date = result.creationDate {
            return "\(type), from \(date.formatted(date: .abbreviated, time: .omitted))"
        }
        return type
    }

    static func imageContent(thumbnail: UIImage?, isVideo: Bool) -> some View {
        // Reserve the same canvas before and after loading; image dimensions
        // must not change masonry row heights while the user is scrolling.
        Rectangle()
            .fill(Celestial.Colors.surfaceContainer)
            .aspectRatio(4.0 / 3.0, contentMode: .fit)
            .overlay {
                if let thumbnail {
                    Image(uiImage: thumbnail)
                        .resizable()
                        .scaledToFit()
                } else {
                    ProgressView()
                        .tint(Celestial.Colors.outlineVariant)
                        .controlSize(.small)
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
    }

    var body: some View {
        Self.imageContent(thumbnail: thumbnail, isVideo: result.isVideo)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityDescription)
        .accessibilityAddTraits(.isImage)
        .task {
            imageLoadTask?.cancel()
            let task = Task { @MainActor in
                imageLoadGeneration &+= 1
                let generation = imageLoadGeneration
                let loaded: UIImage?
                if result.sourceId == PhotoSourceType.photokit.rawValue,
                   !result.isVideo,
                   let asset = await PhotoLibrary.resolveAsset(by: result.localIdentifier) {
                    loaded = await PhotoLibrary.loadThumbnail(for: asset)
                } else {
                    loaded = await PhotoLibrary.loadImage(
                        for: result,
                        targetSize: CGSize(width: 400, height: 400)
                    )
                }
                if ImageLoadGenerationPolicy.acceptsCompletion(
                    startedGeneration: generation,
                    currentGeneration: imageLoadGeneration,
                    isCancelled: Task.isCancelled
                ) {
                    thumbnail = loaded
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
        }
    }
}
