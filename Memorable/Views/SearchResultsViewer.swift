import SwiftUI
import Photos

struct SearchResultsViewer: View {
    let initialResult: SearchResult
    let allResults: [SearchResult]
    var searchEngine: SearchEngine? = nil

    @State private var currentIndex: Int = 0
    @State private var displayedResults: [SearchResult] = []
    @State private var showControls: Bool = true
    @State private var showUpgrade = false
    @ObservedObject private var proManager = ProManager.shared
    @Environment(\.dismiss) private var dismiss

    init(
        initialResult: SearchResult,
        allResults: [SearchResult],
        searchEngine: SearchEngine? = nil
    ) {
        self.initialResult = initialResult
        self.allResults = allResults
        self.searchEngine = searchEngine
        _currentIndex = State(initialValue: allResults.firstIndex(where: { $0.id == initialResult.id }) ?? 0)
        _displayedResults = State(initialValue: allResults)
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            TabView(selection: $currentIndex) {
                ForEach(Array(displayedResults.enumerated()), id: \.element.id) { index, result in
                    ZoomableAsyncImage(result: result, isActive: index == currentIndex, onSingleTap: {
                        withAnimation(.easeInOut(duration: 0.2)) { showControls.toggle() }
                    })
                    .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .ignoresSafeArea()

            // Controls overlay
            if showControls {
                LinearGradient(
                    colors: [.black.opacity(0.55), .clear],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 170)
                .frame(maxHeight: .infinity, alignment: .top)
                .ignoresSafeArea()
                .allowsHitTesting(false)

                LinearGradient(
                    colors: [.clear, .black.opacity(0.72)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 240)
                .frame(maxHeight: .infinity, alignment: .bottom)
                .ignoresSafeArea()
                .allowsHitTesting(false)

                VStack(spacing: 0) {
                    HStack {
                        Button(action: { dismiss() }) {
                            Label("Results", systemImage: "chevron.left")
                                .font(.body)
                                .foregroundStyle(.white)
                        }
                        .accessibilityLabel("Back to results")
                        Spacer()
                        if displayedResults.count > 1 {
                            Text("\(currentIndex + 1) of \(displayedResults.count)")
                                .font(.subheadline)
                                .foregroundStyle(.white.opacity(0.82))
                        }
                        Spacer()
                        Button(action: { shareCurrentPhoto() }) {
                            Image(systemName: "ellipsis")
                                .font(.body.weight(.semibold))
                                .foregroundStyle(.white)
                                .frame(width: 44, height: 44)
                        }
                        .accessibilityLabel("Share photo")
                    }
                    .padding(.horizontal, 22)
                    .padding(.top, 6)

                    Spacer()

                    if currentIndex < displayedResults.count {
                        let result = displayedResults[currentIndex]
                        VStack(alignment: .leading, spacing: 0) {
                            if let date = result.creationDate {
                                Text(date.formatted(date: .long, time: .shortened))
                                    .font(.body.weight(.semibold))
                                    .foregroundStyle(.white.opacity(0.94))
                            }

                            HStack {
                                Button(action: { shareCurrentPhoto() }) {
                                    Image(systemName: "square.and.arrow.up")
                                        .font(.title3)
                                        .foregroundStyle(.white)
                                        .frame(width: 44, height: 44)
                                }
                                .accessibilityLabel("Share photo")
                                Spacer()
                                if searchEngine != nil {
                                    Button(action: handleFindSimilar) {
                                        Text(proManager.isPro ? "Find similar" : "Find similar · Pro")
                                            .font(.subheadline.weight(.semibold))
                                            .foregroundStyle(Celestial.Colors.amber)
                                            .frame(minHeight: 44)
                                    }
                                }
                            }
                            .padding(.top, 12)
                        }
                        .padding(.horizontal, 26)
                        .padding(.bottom, 20)
                    }
                }
                .transition(.opacity)
            }
        }
        .statusBar(hidden: true)
        .sheet(isPresented: $showUpgrade) { UpgradeView() }
        .gesture(
            DragGesture(minimumDistance: 80)
                .onEnded { value in
                    if value.translation.height > 100 {
                        dismiss()
                    }
                }
        )
    }

    private func shareCurrentPhoto() {
        guard currentIndex < displayedResults.count else { return }
        let result = displayedResults[currentIndex]
        guard let asset = PhotoLibrary.getAsset(by: result.localIdentifier) else { return }

        Task {
            let item: Any
            if let url = await PhotoLibrary.getQuickLookURL(for: asset) {
                item = url
            } else if let image = await PhotoLibrary.loadImage(
                for: asset,
                targetSize: shareFallbackTargetSize()
            ) {
                item = image
            } else {
                return
            }

            await MainActor.run {
                let activityVC = UIActivityViewController(activityItems: [item], applicationActivities: nil)
                if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                   let rootVC = windowScene.windows.first?.rootViewController {
                    var topVC = rootVC
                    while let presented = topVC.presentedViewController { topVC = presented }
                    activityVC.popoverPresentationController?.sourceView = topVC.view
                    topVC.present(activityVC, animated: true)
                }
            }
        }
    }

    private func handleFindSimilar() {
        guard proManager.isPro else {
            showUpgrade = true
            return
        }
        guard let searchEngine,
              currentIndex < displayedResults.count else { return }
        let similar = searchEngine.findSimilar(photoId: displayedResults[currentIndex].id)
        let photoResults = similar.filter { !$0.isVideo }
        guard !photoResults.isEmpty else { return }
        withAnimation(.easeInOut(duration: 0.2)) {
            displayedResults = photoResults
            currentIndex = 0
        }
    }

    private func shareFallbackTargetSize() -> CGSize {
        let screen = UIScreen.main.bounds.size
        let scale = UIScreen.main.scale
        return CGSize(width: screen.width * scale * 2, height: screen.height * scale * 2)
    }
}
