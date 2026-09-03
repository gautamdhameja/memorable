import SwiftUI

struct IndexingBannerView: View {
    @ObservedObject var indexingService: IndexingService

    private var phaseLabel: String {
        if indexingService.isThermallyPaused {
            return "Paused while this iPhone cools"
        }
        switch indexingService.backgroundExecutionState {
        case .continuingInBackground:
            return "Continuing in background"
        case .pausedAwaitingForeground:
            return "Indexing paused by iOS"
        case .foreground:
            break
        }
        switch indexingService.progress.phase {
        case .photos: return "Building photo search"
        case .videos: return "Adding your videos"
        case .enrichment: return "Finishing your search index"
        case .idle: return "Building search"
        }
    }

    private var detail: String {
        if indexingService.isThermallyPaused {
            return "Indexing resumes automatically when the temperature returns to normal."
        }
        if indexingService.backgroundExecutionState == .pausedAwaitingForeground {
            return "Your progress is saved. Indexing resumes automatically when Memorable is active."
        }
        if indexingService.backgroundExecutionState == .continuingInBackground {
            return "You can return later. iOS may pause this work when background time runs out."
        }

        let progress = indexingService.progress
        var parts: [String] = []
        if progress.searchableCount > 0 {
            let noun = progress.searchableCount == 1 ? "item" : "items"
            parts.append("\(progress.searchableCount.formatted()) \(noun) ready")
        } else {
            parts.append("Finding your first searchable moments")
        }
        if let eta = progress.estimatedSecondsRemaining {
            parts.append("about \(IndexingDurationText.string(for: eta)) left")
        }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(phaseLabel)
                    .font(Celestial.Typography.supportingEmphasized)
                    .foregroundStyle(Celestial.Colors.onSurface)
                Spacer()
                if !indexingService.isThermallyPaused {
                    Text("\(Int(indexingService.progress.percentage))%")
                        .font(Celestial.Typography.supportingEmphasized)
                        .foregroundStyle(Celestial.Colors.amber)
                }
            }

            ProgressView(
                value: indexingService.progress.percentage,
                total: 100
            )
            .tint(isPaused ? Celestial.Colors.amber : Celestial.Colors.primaryDim)

            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(detail)
                    .font(Celestial.Typography.caption)
                    .foregroundStyle(Celestial.Colors.onSurfaceVariant)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 4)

                Button(isPaused ? "Cancel" : "Stop") {
                    indexingService.stopIndexing()
                }
                .font(Celestial.Typography.captionStrong)
                .foregroundStyle(Celestial.Colors.onSurface)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
                .accessibilityLabel(
                    isPaused
                        ? "Cancel automatic indexing resume"
                        : "Stop indexing"
                )
            }
        }
        .padding(Celestial.Spacing.surfaceContentInset)
        .modifier(
            GlassPanelModifier(
                cornerRadius: 18,
                tint: Celestial.Colors.primaryDim.opacity(0.055)
            )
        )
        .accessibilityElement(children: .contain)
    }

    private var isPaused: Bool {
        indexingService.isThermallyPaused
            || indexingService.backgroundExecutionState == .pausedAwaitingForeground
    }
}

private enum IndexingDurationText {
    static func string(for seconds: TimeInterval) -> String {
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
