import SwiftUI

struct IndexingBannerView: View {
    @ObservedObject var indexingService: IndexingService

    private var phaseLabel: String {
        switch indexingService.progress.phase {
        case .photos: return "Indexing photos"
        case .videos: return "Indexing videos"
        case .enrichment: return "Improving search"
        case .idle: return "Indexing"
        }
    }

    private var progressDetail: String {
        let progress = indexingService.progress
        var parts = ["\(phaseLabel): \(progress.completed) / \(progress.total)"]
        if let speed = progress.itemsPerSecond {
            parts.append(String(format: "%.1f/sec", speed))
        }
        if let eta = progress.estimatedSecondsRemaining {
            parts.append("~\(formatDuration(eta)) left")
        }
        return parts.joined(separator: " - ")
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
                        Text(progressDetail)
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(Celestial.Colors.onSurfaceVariant)
                        if indexingService.progress.searchableCount > 0 {
                            Text("\(indexingService.progress.searchableCount) media searchable while work continues")
                                .font(.footnote)
                                .foregroundStyle(Celestial.Colors.amber)
                        } else if indexingService.progress.phase == .enrichment {
                            Text("Search is available. Adding text and scene boosts.")
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

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let totalSeconds = max(0, Int(seconds.rounded()))
        if totalSeconds < 60 {
            return "\(totalSeconds)s"
        }
        let minutes = totalSeconds / 60
        if minutes < 60 {
            return "\(minutes)m"
        }
        let hours = minutes / 60
        let remainingMinutes = minutes % 60
        return remainingMinutes == 0 ? "\(hours)h" : "\(hours)h \(remainingMinutes)m"
    }
}
