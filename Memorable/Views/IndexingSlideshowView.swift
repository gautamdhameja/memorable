import SwiftUI

struct IndexingSlideshowView: View {
    enum Presentation {
        case standard
        case initialIndexing

        var horizontalPadding: CGFloat {
            switch self {
            case .standard: return 32
            case .initialIndexing: return 0
            }
        }

        var maximumHeight: CGFloat {
            switch self {
            case .standard: return 400
            case .initialIndexing: return 430
            }
        }

        var placeholderText: String {
            switch self {
            case .standard: return "Relive your memories..."
            case .initialIndexing: return "Finding your first memories..."
            }
        }
    }

    let captionService: PhotoCaptionService
    var presentation: Presentation = .standard
    @Environment(\.database) private var database

    @State private var currentImage: UIImage?
    @State private var currentDate: Date?
    @State private var currentCaption: String?
    @State private var isVisible = false
    @State private var captionVisible = false
    @State private var timerTask: Task<Void, Never>?
    @State private var initialLoadTask: Task<Void, Never>?
    @State private var shownIds: Set<String> = []
    @State private var duplicateFilter = MemoryDuplicateFilter()
    @State private var imageLoadGeneration: UInt = 0

    var body: some View {
        ZStack {
            if let image = currentImage {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .overlay(alignment: .bottom) {
                        VStack(spacing: 6) {
                            if let caption = currentCaption {
                                Text(caption)
                                    .font(Celestial.Typography.compactMemoryCaption)
                                    .italic()
                                    .foregroundStyle(.white)
                                    .multilineTextAlignment(.center)
                                    .shadow(color: .black.opacity(0.5), radius: 4, y: 2)
                            }
                            if let date = currentDate {
                                Text(date.formatted(date: .abbreviated, time: .omitted))
                                    .font(Celestial.Typography.eyebrow)
                                    .foregroundStyle(.white.opacity(0.8))
                                    .shadow(color: .black.opacity(0.5), radius: 4, y: 2)
                            }
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 12)
                        .modifier(
                            GlassPanelModifier(
                                cornerRadius: 16,
                                tint: Color.black.opacity(0.14)
                            )
                        )
                        .padding(.horizontal, 12)
                        .padding(.bottom, 10)
                        .frame(maxWidth: .infinity)
                        .background(
                            LinearGradient(
                                colors: [.clear, .black.opacity(0.6)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .opacity(captionVisible ? 1 : 0)
                        .animation(.easeInOut(duration: 0.6), value: captionVisible)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .frame(maxWidth: .infinity, maxHeight: presentation.maximumHeight)
                    .opacity(isVisible ? 1 : 0)
            } else {
                RoundedRectangle(cornerRadius: 16)
                    .fill(Celestial.Colors.surfaceContainer)
                    .aspectRatio(4.0/3.0, contentMode: .fit)
                    .overlay {
                        VStack(spacing: 8) {
                            ProgressView()
                                .tint(Celestial.Colors.outlineVariant)
                            Text(presentation.placeholderText)
                                .font(Celestial.Typography.caption)
                                .foregroundStyle(Celestial.Colors.outline)
                        }
                    }
            }
        }
        .padding(.horizontal, presentation.horizontalPadding)
        .task {
            let task = Task { @MainActor in
                await waitForIndexedPhotos()
                guard !Task.isCancelled else { return }
                await showNextPhoto()
                guard !Task.isCancelled else { return }
                startCycling()
            }
            initialLoadTask = task
            await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        }
        .onDisappear {
            initialLoadTask?.cancel()
            initialLoadTask = nil
            timerTask?.cancel()
            timerTask = nil
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
            initialLoadTask?.cancel()
            initialLoadTask = nil
            timerTask?.cancel()
            timerTask = nil
            imageLoadGeneration &+= 1
            MemoryPressureReleasePolicy.release(&currentImage)
            currentCaption = nil
            shownIds.removeAll(keepingCapacity: false)
            duplicateFilter.reset()
        }
    }

    private func waitForIndexedPhotos() async {
        // Poll until we have at least 5 indexed photos
        while !Task.isCancelled {
            let count: Int
            do {
                let db = database
                count = try await CancellableDetachedOperation.run(priority: .utility) {
                    try db.indexedCount()
                }
            } catch is CancellationError {
                return
            } catch {
                logger.error("[IndexingSlideshow] Failed to read indexed count: \(error.safeDiagnosticCode)")
                return
            }
            guard count < 5 else { return }
            do {
                try await Task.sleep(nanoseconds: 2_000_000_000)
            } catch is CancellationError {
                return
            } catch {
                logger.error("[IndexingSlideshow] Poll delay failed: \(error.safeDiagnosticCode)")
                return
            }
        }
    }

    private func startCycling() {
        timerTask = Task {
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: 4_000_000_000)
                } catch is CancellationError {
                    break
                } catch {
                    logger.error("[IndexingSlideshow] Cycle delay failed: \(error.safeDiagnosticCode)")
                    break
                }
                if Task.isCancelled { break }
                await showNextPhoto()
            }
        }
    }

    private func showNextPhoto() async {
        imageLoadGeneration &+= 1
        let generation = imageLoadGeneration
        guard let (photo, loaded) = await loadNextEligiblePhoto(generation: generation) else {
            return
        }

        // Fade out current
        withAnimation { captionVisible = false }
        do { try await Task.sleep(nanoseconds: 200_000_000) } catch { return }
        withAnimation { isVisible = false }
        do { try await Task.sleep(nanoseconds: 400_000_000) } catch { return }
        guard ImageLoadGenerationPolicy.acceptsCompletion(
            startedGeneration: generation,
            currentGeneration: imageLoadGeneration,
            isCancelled: Task.isCancelled
        ) else { return }

        currentImage = loaded
        currentDate = photo.creationDate

        // Generate caption from the stored embedding (zero extra encoding!)
        if let embedding = photo.embedding.validatedFloat16Embedding() {
            currentCaption = captionService.caption(for: embedding)
        } else {
            logger.error("Skipped an indexing caption with a malformed embedding")
            currentCaption = nil
        }

        // Fade in photo
        withAnimation { isVisible = true }

        // Caption fades in after delay
        do { try await Task.sleep(nanoseconds: 800_000_000) } catch { return }
        withAnimation { captionVisible = true }
    }

    private func loadNextEligiblePhoto(
        generation: UInt
    ) async -> (photo: SlideshowPhoto, image: UIImage)? {
        for _ in 0..<5 {
            guard let photo = await getRandomIndexedPhoto() else { return nil }
            guard let image = await PhotoLibrary.loadImage(
                for: photo.searchResult,
                targetSize: CGSize(width: 800, height: 800)
            ) else { continue }
            guard ImageLoadGenerationPolicy.acceptsCompletion(
                startedGeneration: generation,
                currentGeneration: imageLoadGeneration,
                isCancelled: Task.isCancelled
            ) else { return nil }
            guard await MemoryPresentationValidator.isEligible(
                image: image,
                requiresValidation: photo.requiresContentValidation
            ) else { continue }
            guard ImageLoadGenerationPolicy.acceptsCompletion(
                startedGeneration: generation,
                currentGeneration: imageLoadGeneration,
                isCancelled: Task.isCancelled
            ) else { return nil }
            return (photo, image)
        }
        return nil
    }

    private func getRandomIndexedPhoto() async -> SlideshowPhoto? {
        let historyLimit = 50
        if shownIds.count >= historyLimit {
            shownIds.removeAll(keepingCapacity: true)
        }
        let database = database
        var candidateFilter = duplicateFilter
        let selection = await SlideshowSelectionPolicy.next(
            recentIDs: shownIds,
            historyLimit: historyLimit,
            maxAttempts: 20,
            fetch: {
                do {
                    return try await CancellableDetachedOperation.run {
                        try database.fetchRandomPhoto(sharp: true)
                    }
                } catch is CancellationError {
                    return nil
                } catch {
                    logger.error(
                        "[IndexingSlideshow] Failed to fetch a photo: \(error.safeDiagnosticCode)"
                    )
                    return nil
                }
            },
            identifier: \.id,
            accepts: { candidateFilter.accepts($0.embedding) }
        )
        guard let selection else { return nil }
        duplicateFilter = candidateFilter
        shownIds = selection.recentIDs
        return selection.item
    }
}
