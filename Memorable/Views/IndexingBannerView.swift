import SwiftUI

struct IndexingBannerView: View {
    @ObservedObject var indexingService: IndexingService
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .largeTitle) private var percentageSize: CGFloat = 56
    @ScaledMetric(relativeTo: .title2) private var percentageSuffixSize: CGFloat = 25

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
        var parts: [String] = []
        if let speed = progress.itemsPerSecond {
            parts.append(String(format: "%.1f/sec", speed))
        }
        if let eta = progress.estimatedSecondsRemaining {
            parts.append("~\(IndexingDurationText.string(for: eta)) left")
        }
        return parts.isEmpty ? "Calculating…" : parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(spacing: 0) {
            if indexingService.isThermallyPaused {
                Text("INDEXING PAUSED")
                    .font(Celestial.Typography.eyebrow)
                    .tracking(1.2)
                    .foregroundStyle(Celestial.Colors.amber)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: "thermometer.medium")
                    .font(.system(size: 42, weight: .light))
                    .foregroundStyle(Celestial.Colors.amber)
                    .padding(.top, 42)

                Text("Let this iPhone cool down")
                    .font(Celestial.Typography.interfaceTitle)
                    .foregroundStyle(Celestial.Colors.onSurface)
                    .padding(.top, 18)

                Text("Memorable stopped background indexing at a serious thermal level. Indexing resumes automatically after the iPhone cools down.")
                    .font(Celestial.Typography.supporting)
                    .foregroundStyle(Celestial.Colors.onSurfaceVariant)
                    .lineSpacing(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 12)

                Button("Cancel automatic resume") {
                    indexingService.stopIndexing()
                }
                .frame(maxWidth: .infinity)
                .celestialSecondaryButtonStyle(tint: Celestial.Colors.onSurface)
                .padding(.top, 26)
            } else if indexingService.progress.isRunning {
                Text("SEARCH INDEX")
                    .font(Celestial.Typography.eyebrow)
                    .tracking(1.2)
                    .foregroundStyle(Celestial.Colors.onSurfaceVariant)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Group {
                    if dynamicTypeSize.isAccessibilitySize {
                        VStack(alignment: .leading, spacing: 14) {
                            Text("\(Int(indexingService.progress.percentage))%")
                                .font(Celestial.Typography.interfaceTitle)
                                .foregroundStyle(Celestial.Colors.onSurface)
                            Text(phaseLabel)
                                .font(Celestial.Typography.supporting)
                                .foregroundStyle(Celestial.Colors.onSurfaceVariant)
                            ProgressView(value: indexingService.progress.percentage, total: 100)
                                .tint(Celestial.Colors.primaryDim)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 28)
                    } else {
                        ZStack {
                            Circle()
                                .stroke(Celestial.Colors.hairline, lineWidth: 3)
                            Circle()
                                .trim(from: 0, to: indexingService.progress.percentage / 100)
                                .stroke(Celestial.Colors.primaryDim, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                                .rotationEffect(.degrees(-90))
                            Circle()
                                .stroke(
                                    Celestial.Colors.amber.opacity(0.28),
                                    style: StrokeStyle(lineWidth: 1, dash: [2, 9])
                                )
                                .padding(16)
                            VStack(spacing: 10) {
                                HStack(alignment: .firstTextBaseline, spacing: 1) {
                                    Text("\(Int(indexingService.progress.percentage))")
                                        .font(.system(size: percentageSize, weight: .medium, design: .default))
                                        .tracking(-2)
                                    Text("%")
                                        .font(.system(size: percentageSuffixSize, weight: .medium, design: .default))
                                }
                                Text(phaseLabel)
                                    .font(Celestial.Typography.supporting)
                                    .foregroundStyle(Celestial.Colors.onSurfaceVariant)
                            }
                        }
                        .frame(width: 206, height: 206)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 42)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(phaseLabel): \(Int(indexingService.progress.percentage)) percent")

                VStack(spacing: 0) {
                    progressRow(
                        label: "Indexed",
                        value: "\(indexingService.progress.completed) / \(indexingService.progress.total)"
                    )
                    if indexingService.progress.searchableCount > 0 {
                        progressRow(
                            label: "Already searchable",
                            value: "\(indexingService.progress.searchableCount) items",
                            accent: true
                        )
                    }
                    progressRow(label: "Progress", value: progressDetail)
                    CelestialHairline()
                }

                Text("Pauses on its own if the iPhone gets warm. You can search what is ready and leave the app.")
                    .font(Celestial.Typography.supporting)
                    .foregroundStyle(Celestial.Colors.onSurfaceVariant)
                    .lineSpacing(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 24)

                Button("Stop indexing") {
                    indexingService.stopIndexing()
                }
                .frame(maxWidth: .infinity)
                .celestialSecondaryButtonStyle(tint: Celestial.Colors.onSurface)
                .padding(.top, 26)
                .accessibilityLabel("Stop indexing")
            } else {
                Button("Build Search Index") {
                    Haptics.medium()
                    indexingService.startIndexing()
                }
                .celestialPrimaryButtonStyle()
                .accessibilityHint("Scans your photo library and builds a searchable index")
            }
        }
        .padding(18)
        .modifier(GlassPanelModifier(cornerRadius: 22))
    }

    private func progressRow(label: String, value: String, accent: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .foregroundStyle(Celestial.Colors.onSurfaceVariant)
            Spacer()
            Text(value)
                .font(Celestial.Typography.supportingEmphasized)
                .foregroundStyle(accent ? Celestial.Colors.amber : Celestial.Colors.onSurface)
                .multilineTextAlignment(.trailing)
        }
        .font(Celestial.Typography.supporting)
        .padding(.vertical, 15)
        .overlay(alignment: .top) { CelestialHairline() }
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

struct InitialIndexingProgressView: View {
    @ObservedObject var indexingService: IndexingService

    private var phaseLabel: String {
        if indexingService.isThermallyPaused {
            return "Paused while this iPhone cools"
        }
        switch indexingService.progress.phase {
        case .photos: return "Building photo search"
        case .videos: return "Adding your videos"
        case .enrichment: return "Adding helpful details"
        case .idle: return "Building search"
        }
    }

    private var detail: String {
        if indexingService.isThermallyPaused {
            return "Indexing resumes automatically when the temperature returns to normal."
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
            .tint(indexingService.isThermallyPaused ? Celestial.Colors.amber : Celestial.Colors.primaryDim)

            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(detail)
                    .font(Celestial.Typography.caption)
                    .foregroundStyle(Celestial.Colors.onSurfaceVariant)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 4)

                Button(indexingService.isThermallyPaused ? "Cancel" : "Stop") {
                    indexingService.stopIndexing()
                }
                .font(Celestial.Typography.captionStrong)
                .foregroundStyle(Celestial.Colors.onSurface)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
                .accessibilityLabel(
                    indexingService.isThermallyPaused
                        ? "Cancel automatic indexing resume"
                        : "Stop indexing"
                )
            }
        }
        .padding(16)
        .modifier(
            GlassPanelModifier(
                cornerRadius: 18,
                tint: Celestial.Colors.primaryDim.opacity(0.055)
            )
        )
        .accessibilityElement(children: .contain)
    }
}
