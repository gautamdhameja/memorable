import SwiftUI
import Photos

struct IndexingSlideshowView: View {
    let captionService: PhotoCaptionService
    @Environment(\.database) private var database

    @State private var currentImage: UIImage?
    @State private var currentDate: Date?
    @State private var currentCaption: String?
    @State private var isVisible = false
    @State private var captionVisible = false
    @State private var timerTask: Task<Void, Never>?
    @State private var shownIds: Set<String> = []

    var body: some View {
        ZStack {
            if let image = currentImage {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .opacity(isVisible ? 1 : 0)
                    .animation(.easeInOut(duration: 0.8), value: isVisible)
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
                        .clipShape(
                            UnevenRoundedRectangle(
                                bottomLeadingRadius: 16,
                                bottomTrailingRadius: 16
                            )
                        )
                        .opacity(captionVisible ? 1 : 0)
                        .animation(.easeInOut(duration: 0.6), value: captionVisible)
                    }
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
            // Wait for some photos to be indexed before starting
            await waitForIndexedPhotos()
            await showNextPhoto()
            startCycling()
        }
        .onDisappear {
            timerTask?.cancel()
            timerTask = nil
        }
    }

    private func waitForIndexedPhotos() async {
        // Poll until we have at least 5 indexed photos
        while (try? database.indexedCount()) ?? 0 < 5 {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if Task.isCancelled { return }
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
        // Get a random indexed photo from the database
        guard let photo = getRandomIndexedPhoto() else { return }

        // Fade out current
        withAnimation { captionVisible = false }
        try? await Task.sleep(nanoseconds: 200_000_000)
        withAnimation { isVisible = false }
        try? await Task.sleep(nanoseconds: 400_000_000)

        // Load thumbnail
        guard let asset = PhotoLibrary.getAsset(by: photo.localIdentifier) else { return }
        guard let image = await PhotoLibrary.loadThumbnail(for: asset) else { return }

        currentImage = image
        currentDate = photo.creationDate

        // Generate caption from the stored embedding (zero extra encoding!)
        let embeddingFloat16 = photo.embedding.withUnsafeBytes { buf -> [Float16] in
            let ptr = buf.bindMemory(to: Float16.self)
            return Array(UnsafeBufferPointer(start: ptr.baseAddress, count: ptr.count))
        }
        currentCaption = captionService.caption(for: embeddingFloat16)

        // Fade in photo
        withAnimation { isVisible = true }

        // Caption fades in after delay
        try? await Task.sleep(nanoseconds: 800_000_000)
        withAnimation { captionVisible = true }
    }

    private func getRandomIndexedPhoto() -> IndexedPhoto? {
        // Try up to 5 times to find an unshown photo
        for _ in 0..<5 {
            guard let photo = try? database.fetchRandomPhoto(sharp: true) else {
                return nil
            }
            if !shownIds.contains(photo.id) {
                shownIds.insert(photo.id)
                if shownIds.count > 50 { shownIds.removeAll() }
                return photo
            }
        }
        // All attempts returned already-shown photos. Reset and return whatever we get.
        shownIds.removeAll()
        return try? database.fetchRandomPhoto(sharp: true)
    }
}
