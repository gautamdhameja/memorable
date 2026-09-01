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

    private var aspectRatio: CGFloat {
        guard let thumb = thumbnail else { return 4.0/3.0 }
        guard thumb.size.height > 0 else { return 4.0/3.0 }
        let raw = thumb.size.width / thumb.size.height
        // Clamp to avoid extremes: min 9:16 portrait, max 16:9 landscape
        return min(max(raw, 9.0/16.0), 16.0/9.0)
    }

    var body: some View {
        Group {
            if let thumb = thumbnail {
                Image(uiImage: thumb)
                    .resizable()
                    .aspectRatio(aspectRatio, contentMode: .fit)
                    .overlay(alignment: .bottomTrailing) {
                        if result.isVideo {
                            Image(systemName: "play.fill")
                                .font(Celestial.Typography.captionStrong)
                                .foregroundStyle(.white)
                                .frame(width: 28, height: 28)
                                .modifier(
                                    GlassCircleModifier(
                                        tint: Color.black.opacity(0.18)
                                    )
                                )
                                .padding(7)
                        }
                    }
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
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
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
