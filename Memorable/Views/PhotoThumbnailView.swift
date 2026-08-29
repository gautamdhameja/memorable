import SwiftUI

struct PhotoThumbnailView: View {
    let result: SearchResult
    @State private var thumbnail: UIImage?

    private var accessibilityDescription: String {
        let type = result.isVideo ? "Video" : "Photo"
        if let date = result.creationDate {
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            return "\(type), from \(formatter.string(from: date))"
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
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.white)
                                .padding(7)
                                .background(.black.opacity(0.58))
                                .clipShape(Circle())
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
            #if DEBUG
            logger.info("[PhotoThumbnailView] start load id=\(result.id) localId=\(result.localIdentifier) isVideo=\(result.isVideo) score=\(String(format: "%.4f", result.score)) frame=\(result.bestFramePosition ?? -1)")
            #endif
            let loaded: UIImage?
            if result.sourceId == PhotoSourceType.photokit.rawValue,
               !result.isVideo,
               let asset = PhotoLibrary.getAsset(by: result.localIdentifier) {
                loaded = await PhotoLibrary.loadThumbnail(for: asset)
            } else {
                loaded = await PhotoLibrary.loadImage(
                    for: result,
                    targetSize: CGSize(width: 400, height: 400)
                )
            }
            if !Task.isCancelled {
                thumbnail = loaded
            }
            if thumbnail != nil {
                #if DEBUG
                if let thumbnail = thumbnail {
                    logger.info("[PhotoThumbnailView] loaded thumbnail id=\(result.id) localId=\(result.localIdentifier) size=\(String(format: "%.0fx%.0f", thumbnail.size.width, thumbnail.size.height))")
                }
                #endif
            } else {
                #if DEBUG
                logger.warning("[PhotoThumbnailView] media load failed id=\(result.id) localId=\(result.localIdentifier) isVideo=\(result.isVideo)")
                #endif
            }
        }
    }
}
