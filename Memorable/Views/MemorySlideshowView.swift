import SwiftUI

struct MemorySlideshowView: View {
    let captionService: PhotoCaptionService
    @Environment(\.dismiss) private var dismiss
    @Environment(\.database) private var database

    @State private var currentImage: UIImage?
    @State private var currentDate: Date?
    @State private var currentCaption: String?
    @State private var isVisible = false
    @State private var captionVisible = false
    @State private var showControls = true
    @State private var timerTask: Task<Void, Never>?
    @State private var initialLoadTask: Task<Void, Never>?
    @State private var memoryRecoveryTask: Task<Void, Never>?
    @State private var shownIds: Set<String> = []
    @State private var duplicateFilter = MemoryDuplicateFilter()
    @State private var imageLoadGeneration: UInt = 0

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let image = currentImage {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .opacity(isVisible ? 1 : 0)
                    .animation(.easeInOut(duration: 1.0), value: isVisible)
                    .overlay(alignment: .bottom) {
                        VStack(spacing: 8) {
                            if let caption = currentCaption {
                                Text(caption)
                                    .font(Celestial.Typography.memoryCaption)
                                    .italic()
                                    .foregroundStyle(.white)
                                    .multilineTextAlignment(.center)
                                    .shadow(color: .black.opacity(0.6), radius: 6, y: 3)
                            }
                            if let date = currentDate {
                                Text(date.formatted(date: .long, time: .omitted))
                                    .font(Celestial.Typography.footnoteEmphasized)
                                    .foregroundStyle(.white.opacity(0.7))
                                    .shadow(color: .black.opacity(0.5), radius: 4, y: 2)
                            }
                        }
                        .padding(.horizontal, 18)
                        .padding(.vertical, 12)
                        .modifier(
                            GlassPanelModifier(
                                cornerRadius: 18,
                                tint: Color.black.opacity(0.14)
                            )
                        )
                        .padding(.horizontal, Celestial.Spacing.pageHorizontalInset)
                        .padding(.bottom, 40)
                        .frame(maxWidth: .infinity)
                        .background(
                            LinearGradient(
                                colors: [.clear, .clear, .black.opacity(0.7)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .opacity(captionVisible ? 1 : 0)
                        .animation(.easeInOut(duration: 0.8), value: captionVisible)
                    }
            } else {
                VStack(spacing: 12) {
                    ProgressView()
                        .tint(.white)
                    Text("Loading memories...")
                        .font(Celestial.Typography.supporting)
                        .foregroundStyle(.white.opacity(0.6))
                }
            }

            // Controls overlay
            if showControls {
                VStack {
                    HStack {
                        Button(action: { dismiss() }) {
                            Image(systemName: "xmark")
                                .font(.system(size: 16, weight: .semibold))
                        }
                        .celestialGlassCircleButtonStyle(
                            tint: Color.black.opacity(0.16),
                            foreground: .white
                        )
                        .accessibilityLabel("Close memories")
                        Spacer()
                        Text("Memories")
                            .font(Celestial.Typography.footnoteEmphasized)
                            .foregroundStyle(.white.opacity(0.82))
                            .padding(.horizontal, 12)
                            .frame(minHeight: 34)
                            .modifier(
                                GlassCapsuleModifier(
                                    tint: Color.black.opacity(0.12)
                                )
                            )
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    Spacer()
                }
                .transition(.opacity)
            }
        }
        .statusBar(hidden: true)
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.2)) {
                showControls.toggle()
            }
        }
        .task {
            let task = Task { @MainActor in
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
            memoryRecoveryTask?.cancel()
            memoryRecoveryTask = nil
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
            handleMemoryPressure()
        }
    }

    private func startCycling() {
        timerTask?.cancel()
        timerTask = Task {
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: 5_000_000_000)
                } catch {
                    break
                }
                await showNextPhoto()
            }
        }
    }

    private func handleMemoryPressure() {
        initialLoadTask?.cancel()
        initialLoadTask = nil
        timerTask?.cancel()
        timerTask = nil
        memoryRecoveryTask?.cancel()
        memoryRecoveryTask = nil
        imageLoadGeneration &+= 1
        currentCaption = nil
        shownIds.removeAll(keepingCapacity: false)
        duplicateFilter.reset()

        switch MemoryPressureImageRecoveryPolicy.decision(
            hasImage: currentImage != nil,
            isActive: true,
            preserveVisibleImage: true
        ) {
        case .preserve:
            startCycling()
        case .release:
            MemoryPressureReleasePolicy.release(&currentImage)
        case .releaseAndRetry:
            MemoryPressureReleasePolicy.release(&currentImage)
            memoryRecoveryTask = Task { @MainActor in
                do {
                    try await Task.sleep(
                        nanoseconds: MemoryPressureImageRecoveryPolicy.retryDelayNanoseconds
                    )
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                await showNextPhoto()
                guard !Task.isCancelled else { return }
                startCycling()
            }
        }
    }

    private func showNextPhoto() async {
        imageLoadGeneration &+= 1
        let generation = imageLoadGeneration
        guard let (photo, loaded) = await loadNextEligiblePhoto(generation: generation) else {
            return
        }

        // Fade out
        withAnimation { captionVisible = false }
        do { try await Task.sleep(nanoseconds: 300_000_000) } catch { return }
        withAnimation { isVisible = false }
        do { try await Task.sleep(nanoseconds: 500_000_000) } catch { return }
        guard ImageLoadGenerationPolicy.acceptsCompletion(
            startedGeneration: generation,
            currentGeneration: imageLoadGeneration,
            isCancelled: Task.isCancelled
        ) else { return }

        currentImage = loaded
        currentDate = photo.creationDate

        // Caption from stored embedding
        if let embedding = photo.embedding.validatedFloat16Embedding() {
            currentCaption = captionService.caption(for: embedding)
        } else {
            logger.error("Skipped a memory caption with a malformed embedding")
            currentCaption = nil
        }

        // Fade in
        withAnimation { isVisible = true }
        do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { return }
        withAnimation { captionVisible = true }
    }

    private func loadNextEligiblePhoto(
        generation: UInt
    ) async -> (photo: SlideshowPhoto, image: UIImage)? {
        for _ in 0..<5 {
            guard let photo = await getRandomSharpPhoto() else { return nil }
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

    private func getRandomSharpPhoto() async -> SlideshowPhoto? {
        let historyLimit = 100
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
                        "[MemorySlideshow] Failed to fetch a photo: \(error.safeDiagnosticCode)"
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
