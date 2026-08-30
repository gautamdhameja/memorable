import SwiftUI

struct IndexingSlideshowView: View {
    let captionService: PhotoCaptionService
    @Environment(\.database) private var database

    @State private var currentImage: UIImage?
    @State private var currentDate: Date?
    @State private var currentCaption: String?
    @State private var isVisible = false
    @State private var captionVisible = false
    @State private var timerTask: Task<Void, Never>?
    @State private var initialLoadTask: Task<Void, Never>?
    @State private var shownIds: Set<String> = []
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
                                    .font(.system(.subheadline, design: .rounded, weight: .medium))
                                    .italic()
                                    .foregroundStyle(.white)
                                    .multilineTextAlignment(.center)
                                    .shadow(color: .black.opacity(0.5), radius: 4, y: 2)
                            }
                            if let date = currentDate {
                                Text(date.formatted(date: .abbreviated, time: .omitted))
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(.white.opacity(0.8))
                                    .shadow(color: .black.opacity(0.5), radius: 4, y: 2)
                            }
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 16)
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
                    .frame(maxWidth: .infinity, maxHeight: 400)
            } else {
                RoundedRectangle(cornerRadius: 16)
                    .fill(Celestial.Colors.surfaceContainer)
                    .aspectRatio(4.0/3.0, contentMode: .fit)
                    .overlay {
                        VStack(spacing: 8) {
                            ProgressView()
                                .tint(Celestial.Colors.outlineVariant)
                            Text("Relive your memories...")
                                .font(.caption)
                                .foregroundStyle(Celestial.Colors.outline)
                        }
                    }
            }
        }
        .padding(.horizontal, 32)
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
        }
    }

    private func waitForIndexedPhotos() async {
        // Poll until we have at least 5 indexed photos
        while (try? database.indexedCount()) ?? 0 < 5 {
            do {
                try await Task.sleep(nanoseconds: 2_000_000_000)
            } catch {
                return
            }
        }
    }

    private func startCycling() {
        timerTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                if Task.isCancelled { break }
                await showNextPhoto()
            }
        }
    }

    private func showNextPhoto() async {
        imageLoadGeneration &+= 1
        let generation = imageLoadGeneration
        // Get a random indexed photo from the database
        guard let photo = await getRandomIndexedPhoto() else { return }

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

        // Load thumbnail
        guard let loaded = await PhotoLibrary.loadImage(
            for: photo.searchResult,
            targetSize: CGSize(width: 800, height: 800)
        ) else { return }
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

    private func getRandomIndexedPhoto() async -> SlideshowPhoto? {
        let database = database
        let selection = await SlideshowSelectionPolicy.next(
            recentIDs: shownIds,
            historyLimit: 50,
            fetch: {
                try? await CancellableDetachedOperation.run {
                    try database.fetchRandomPhoto(sharp: true)
                }
            },
            identifier: \.id
        )
        guard let selection else { return nil }
        shownIds = selection.recentIDs
        return selection.item
    }
}
