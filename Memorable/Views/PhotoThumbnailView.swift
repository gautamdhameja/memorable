import SwiftUI

struct PhotoThumbnailView: View {
    let result: SearchResult
    @State private var thumbnail: UIImage?

    private var accessibilityDescription: String {
        let type = result.isVideo ? "Video" : "Photo"
        let score = "\(Int(result.score * 100))% match"
        if let date = result.creationDate {
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            return "\(type), \(score), from \(formatter.string(from: date))"
        }
        return "\(type), \(score)"
    }

    private var relevanceBadgeColor: Color {
        if result.score >= SearchConfig.strongMatchThreshold {
            return Celestial.Colors.emerald
        } else if result.score >= SearchConfig.marginalMatchThreshold {
            return Celestial.Colors.amber
        } else {
            return Celestial.Colors.orange
        }
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
                    .overlay(alignment: .topLeading) {
                        if result.isVideo {
                            Image(systemName: "video.fill")
                                .font(.footnote)
                                .foregroundStyle(Celestial.Colors.onSurface)
                                .padding(4)
                                .background(.ultraThinMaterial)
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                                .padding(5)
                        }
                    }
                    .overlay(alignment: .bottomTrailing) {
                        if result.score < 1.0 {
                            Text("\(Int(result.score * 100))%")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(relevanceBadgeColor)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .modifier(GlassBadgeModifier())
                                .padding(5)
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
        .clipShape(RoundedRectangle(cornerRadius: Celestial.sharedCornerRadius))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityDescription)
        .accessibilityAddTraits(.isImage)
        .task {
            if let asset = PhotoLibrary.getAsset(by: result.localIdentifier) {
                if result.isVideo {
                    thumbnail = await VideoFrameExtractor.thumbnail(
                        from: asset,
                        atPosition: result.bestFramePosition ?? 0.5
                    )
                } else {
                    thumbnail = await PhotoLibrary.loadThumbnail(for: asset)
                }
            }
        }
    }
}
