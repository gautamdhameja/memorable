import SwiftUI
import Photos

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
    @State private var shownIds: Set<String> = []
    @State private var photoCount = 0

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
            photoCount = (try? database.indexedCount()) ?? 0
            await showNextPhoto()
            startCycling()
        }
        .onDisappear {
            timerTask?.cancel()
            timerTask = nil
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
        guard let photo = getRandomSharpPhoto() else { return }

        // Fade out
        withAnimation { captionVisible = false }
        try? await Task.sleep(nanoseconds: 300_000_000)
        withAnimation { isVisible = false }
        try? await Task.sleep(nanoseconds: 500_000_000)

        // Load thumbnail
        guard let asset = PhotoLibrary.getAsset(by: photo.localIdentifier) else { return }
        // Load higher res for full-screen
        guard let image = await PhotoLibrary.loadImage(for: asset, targetSize: CGSize(width: 800, height: 800)) else { return }

        currentImage = image
        currentDate = photo.creationDate

        // Caption from stored embedding
        let embeddingFloat16 = photo.embedding.withUnsafeBytes { buf -> [Float16] in
            let ptr = buf.bindMemory(to: Float16.self)
            return Array(UnsafeBufferPointer(start: ptr.baseAddress, count: ptr.count))
        }
        currentCaption = captionService.caption(for: embeddingFloat16)

        // Fade in
        withAnimation { isVisible = true }
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        withAnimation { captionVisible = true }
    }

    private func getRandomSharpPhoto() -> IndexedPhoto? {
        for _ in 0..<5 {
            guard let photo = try? database.fetchRandomPhoto(sharp: true) else {
                return nil
            }
            if !shownIds.contains(photo.id) {
                shownIds.insert(photo.id)
                if shownIds.count > 100 { shownIds.removeAll() }
                return photo
            }
        }
        shownIds.removeAll()
        return try? database.fetchRandomPhoto(sharp: true)
    }
}
