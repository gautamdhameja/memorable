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
    @State private var shownIds: Set<String> = []
    @State private var photoCount = 0
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
                                    .font(.system(.title3, design: .rounded, weight: .medium))
                                    .italic()
                                    .foregroundStyle(.white)
                                    .multilineTextAlignment(.center)
                                    .shadow(color: .black.opacity(0.6), radius: 6, y: 3)
                            }
                            if let date = currentDate {
                                Text(date.formatted(date: .long, time: .omitted))
                                    .font(.footnote.weight(.medium))
                                    .foregroundStyle(.white.opacity(0.7))
                                    .shadow(color: .black.opacity(0.5), radius: 4, y: 2)
                            }
                        }
                        .padding(.horizontal, 24)
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
                        .font(.subheadline)
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
                                .foregroundStyle(.white)
                                .padding(12)
                                .background(.ultraThinMaterial)
                                .clipShape(Circle())
                        }
                        Spacer()
                        Text("\(photoCount) memories")
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(.white.opacity(0.6))
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
                photoCount = (try? database.indexedCount()) ?? 0
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

    private func startCycling() {
        timerTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000) // 5 seconds for standalone
                if Task.isCancelled { break }
                await showNextPhoto()
            }
        }
    }

    private func showNextPhoto() async {
        imageLoadGeneration &+= 1
        let generation = imageLoadGeneration
        guard let photo = await getRandomSharpPhoto() else { return }

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

    private func getRandomSharpPhoto() async -> SlideshowPhoto? {
        let database = database
        guard let photo = try? await CancellableDetachedOperation.run({
            try database.fetchRandomPhoto(sharp: true)
        }) else { return nil }
        if shownIds.contains(photo.id) {
            shownIds.removeAll(keepingCapacity: true)
        }
        shownIds.insert(photo.id)
        if shownIds.count > 100 { shownIds.removeAll(keepingCapacity: true) }
        return photo
    }
}
