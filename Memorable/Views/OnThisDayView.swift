import SwiftUI

struct OnThisDayView: View {
    @Environment(\.database) private var database
    @State private var yearGroups: [(year: Int, photos: [IndexedPhotoReference])] = []
    @State private var isLoading = true
    @State private var showSlideshow = false
    @State private var indexedCount = 0

    var body: some View {
        ZStack {
            CelestialBackdrop()

            ScrollView {
                VStack(spacing: 0) {
                    if isLoading {
                        ProgressView()
                            .tint(Celestial.Colors.primaryDim)
                            .padding(.top, 60)
                    } else if yearGroups.isEmpty {
                        VStack(spacing: Celestial.Spacing.contentGap) {
                            CelestialGlassIcon(
                                systemName: indexedCount == 0 ? "photo.on.rectangle.angled" : "calendar",
                                tint: Celestial.Colors.onSurfaceVariant,
                                size: 64
                            )
                            if indexedCount == 0 {
                                Text("Index your photo library to unlock memories")
                                    .font(Celestial.Typography.supporting)
                                    .foregroundStyle(Celestial.Colors.onSurfaceVariant)
                                    .multilineTextAlignment(.center)
                                Text("Go to Search and tap \"Build Search Index\"")
                                    .font(Celestial.Typography.caption)
                                    .foregroundStyle(Celestial.Colors.outlineVariant)
                            } else {
                                Text("No memories from this day in previous years")
                                    .font(Celestial.Typography.supporting)
                                    .foregroundStyle(Celestial.Colors.onSurfaceVariant)
                                    .multilineTextAlignment(.center)
                            }
                        }
                        .padding(.top, 60)
                        .padding(.horizontal, Celestial.Spacing.pageHorizontalInset)
                    } else {
                        VStack(alignment: .leading, spacing: 0) {
                            Text("ON THIS DAY")
                                .font(Celestial.Typography.eyebrow)
                                .tracking(1.4)
                                .foregroundStyle(Celestial.Colors.amber)
                            Text(Date.now.formatted(.dateTime.month(.wide).day()))
                                .font(Celestial.Typography.display)
                                .foregroundStyle(Celestial.Colors.onSurface)
                                .padding(.top, 10)
                            Text("\(yearGroups.reduce(0) { $0 + $1.photos.count }) photos across \(yearGroups.count) years")
                                .font(Celestial.Typography.supporting)
                                .foregroundStyle(Celestial.Colors.secondary)
                                .padding(.top, 8)

                            Button(action: { showSlideshow = true }) {
                                Label("Relive your memories", systemImage: "play.fill")
                            }
                            .celestialPrimaryButtonStyle(
                                tint: Celestial.Colors.onSurface,
                                foreground: Celestial.Colors.surfaceDim
                            )
                            .padding(.top, 22)
                        }
                        .padding(.horizontal, Celestial.Spacing.pageHorizontalInset)
                        .padding(.top, 12)
                        .frame(maxWidth: .infinity, alignment: .leading)

                        LazyVStack(spacing: Celestial.Spacing.sectionGap) {
                            ForEach(yearGroups, id: \.year) { group in
                                VStack(spacing: 12) {
                                    HStack(alignment: .firstTextBaseline) {
                                        Text("\(String(group.year))")
                                            .font(Celestial.Typography.title2)
                                            .foregroundStyle(Celestial.Colors.onSurface)
                                        Spacer()
                                        Text("\(allPhotos(in: group.year).count) photos")
                                            .font(Celestial.Typography.caption)
                                            .foregroundStyle(Celestial.Colors.onSurfaceVariant)
                                    }
                                    .padding(.horizontal, Celestial.Spacing.pageHorizontalInset)

                                    MasonryGrid(
                                        Array(group.photos.prefix(20)),
                                        spacing: 5
                                    ) { photo in
                                        MemoryThumbnail(
                                            photo: photo,
                                            groupPhotos: allPhotos(in: group.year)
                                        )
                                    }
                                    .padding(.horizontal, 5)
                                }
                            }
                        }
                        .padding(.top, Celestial.Spacing.sectionGap)
                    }
                }
                .padding(.bottom, 40)
            }
        }
        .celestialNavigationTitle("Memories")
        .preferredColorScheme(.dark)
        .fullScreenCover(isPresented: $showSlideshow) {
            MemorySlideshowView()
        }
        .task {
            do {
                let database = database
                let snapshot = try await CancellableDetachedOperation.run {
                    (
                        hasIndexedPhotos: try database.hasIndexedPhotos(),
                        yearGroups: try database.onThisDayPhotos()
                    )
                }
                indexedCount = snapshot.hasIndexedPhotos ? 1 : 0
                yearGroups = snapshot.yearGroups
            } catch is CancellationError {
                return
            } catch {
                logger.error("On This Day error: \(error.safeDiagnosticCode)")
            }
            isLoading = false
        }
    }

    private func allPhotos(in year: Int) -> [IndexedPhotoReference] {
        yearGroups.first(where: { $0.year == year })?.photos ?? []
    }
}

/// The foreground preserves the complete photo; the blurred layer fills its backdrop.
struct MemoryPhotoImage: View {
    let image: UIImage
    let backgroundBlurRadius: CGFloat

    var body: some View {
        // Fill and fit layers can exceed their proposed size. An overlay keeps
        // those drawing dimensions out of the scroll view's layout calculation.
        Color.clear.overlay {
            ZStack {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .blur(radius: backgroundBlurRadius)
                    .scaleEffect(1.08)
                    .opacity(0.5)
                    .accessibilityHidden(true)

                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
            }
        }
        .clipped()
    }
}

// MARK: - Memory Thumbnail

private enum MemoryThumbnailRecoveryCoordinator {
    private static let permits = CancellablePermitPool(limit: 2)

    static func load(
        _ operation: @escaping @Sendable () async -> UIImage?
    ) async -> UIImage? {
        guard await permits.acquire() else { return nil }
        if Task.isCancelled {
            await permits.release()
            return nil
        }
        let image = await operation()
        await permits.release()
        return Task.isCancelled ? nil : image
    }
}

struct MemoryThumbnail: View {
    let photo: IndexedPhotoReference
    var groupPhotos: [IndexedPhotoReference] = []
    var searchEngine: SearchEngine? = nil
    var accessibilityTitle: String? = nil
    @State private var thumbnail: UIImage?
    @State private var imageLoadGeneration: UInt = 0
    @State private var imageLoadTask: Task<Void, Never>?
    @State private var selectedResult: SearchResult?
    @State private var creationDate: Date?

    private var aspectRatio: CGFloat {
        MemoryCardLayout.aspectRatio(for: photo)
    }

    var body: some View {
        Button(action: handleTap) {
            ZStack {
                if let thumb = thumbnail {
                    MemoryPhotoImage(image: thumb, backgroundBlurRadius: 12)
                } else {
                    Rectangle()
                        .fill(Celestial.Colors.surfaceContainer)
                        .overlay {
                            ProgressView()
                                .tint(Celestial.Colors.outlineVariant)
                                .controlSize(.small)
                        }
                }
            }
            .aspectRatio(aspectRatio, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityTitle ?? creationDate.map { "Memory from \(DateFormatter.mediumDate.string(from: $0))" } ?? "Memory photo")
        .accessibilityAddTraits(.isImage)
        .fullScreenCover(item: $selectedResult) { result in
            SearchResultsViewer(
                initialResult: result,
                allResults: groupPhotos.map(\.searchResult),
                searchEngine: searchEngine
            )
        }
        .task(id: photo.id) {
            let task = startImageLoad()
            await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
            handleMemoryPressure()
        }
        .onDisappear {
            imageLoadTask?.cancel()
            imageLoadTask = nil
            imageLoadGeneration &+= 1
        }
    }

    private func handleTap() {
        selectedResult = photo.searchResult
    }

    private func startImageLoad(
        delayNanoseconds: UInt64 = 0,
        coordinatesRecovery: Bool = false
    ) -> Task<Void, Never> {
        imageLoadTask?.cancel()
        let task = Task { @MainActor in
            if delayNanoseconds > 0 {
                do {
                    try await Task.sleep(nanoseconds: delayNanoseconds)
                } catch {
                    return
                }
            }
            imageLoadGeneration &+= 1
            let generation = imageLoadGeneration
            let result = photo.searchResult
            let load: @Sendable () async -> UIImage? = {
                await PhotoLibrary.loadPreviewImage(
                    for: result,
                    targetSize: MemoryCardLayout.targetSize(for: photo, width: 400)
                )
            }
            let loaded = if coordinatesRecovery {
                await MemoryThumbnailRecoveryCoordinator.load(load)
            } else {
                await load()
            }
            guard ImageLoadGenerationPolicy.acceptsCompletion(
                startedGeneration: generation,
                currentGeneration: imageLoadGeneration,
                isCancelled: Task.isCancelled
            ) else { return }
            thumbnail = loaded
            creationDate = photo.creationDate
        }
        imageLoadTask = task
        return task
    }

    private func handleMemoryPressure() {
        imageLoadTask?.cancel()
        imageLoadTask = nil
        imageLoadGeneration &+= 1
        MemoryPressureReleasePolicy.release(&thumbnail)
        _ = startImageLoad(
            delayNanoseconds: MemoryPressureImageRecoveryPolicy.retryDelayNanoseconds,
            coordinatesRecovery: true
        )
    }
}
