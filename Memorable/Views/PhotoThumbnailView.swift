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

            VStack {
                if result.isVideo {
                    HStack {
                        Image(systemName: "video.fill")
                            .font(.footnote)
                            .foregroundStyle(Celestial.Colors.onSurface)
                            .padding(4)
                            .background(.ultraThinMaterial)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                        Spacer()
                    }
                    .padding(5)
                }

                Spacer()

                HStack {
                    Spacer()
                    Text("\(Int(result.score * 100))%")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Celestial.Colors.amber)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .modifier(GlassBadgeModifier())
                }
                .padding(5)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 16))
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
