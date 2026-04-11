import SwiftUI

struct IndexingBannerView: View {
    @ObservedObject var indexingService: IndexingService

    private var phaseLabel: String {
        switch indexingService.progress.phase {
        case .photos: return "Indexing photos"
        case .videos: return "Indexing videos"
        case .idle: return "Indexing"
        }
    }

    var body: some View {
        VStack(spacing: 14) {
            if indexingService.progress.isRunning {
                // Percentage number
                Text("\(Int(indexingService.progress.percentage))%")
                    .font(.system(.title, design: .rounded, weight: .semibold))
                    .foregroundStyle(Celestial.Colors.onSurface)

                // Fat progress bar
                ProgressView(value: indexingService.progress.percentage, total: 100)
                    .tint(indexingService.progress.phase == .videos ? Celestial.Colors.tertiaryDim : Celestial.Colors.primaryFixedDim)
                    .scaleEffect(y: 2.5)
                    .clipShape(Capsule())
                    .accessibilityLabel("\(phaseLabel): \(Int(indexingService.progress.percentage)) percent")

                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(phaseLabel): \(indexingService.progress.completed) / \(indexingService.progress.total)")
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(Celestial.Colors.onSurfaceVariant)
                        if indexingService.progress.phase == .videos {
                            Text("Photos ready. You can search now.")
                                .font(.footnote)
                                .foregroundStyle(Celestial.Colors.amber)
                        }
                    }
                    Spacer()
                    Button("Stop") {
                        indexingService.stopIndexing()
                    }
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Celestial.Colors.error)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Celestial.Colors.error.opacity(0.15))
                    .clipShape(Capsule())
                    .accessibilityLabel("Stop indexing")
                }
            } else {
                Button("Build Search Index") {
                    Haptics.medium()
                    indexingService.startIndexing()
                }
                .buttonStyle(CelestialButtonStyle())
                .accessibilityHint("Scans your photo library and builds a searchable index")
            }
        }
        .padding(20)
        .modifier(GlassPanelModifier(cornerRadius: 20))
    }
}
