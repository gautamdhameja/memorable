import SwiftUI

enum SimilaritySearchOperation {
    static func run(
        operation: @escaping @Sendable () async -> [SearchResult]
    ) async -> [SearchResult] {
        let searchTask: Task<[SearchResult], Never> = Task.detached(priority: .userInitiated) {
            guard !Task.isCancelled else { return [] }
            let results = await operation()
            return Task.isCancelled ? [] : results
        }
        return await withTaskCancellationHandler {
            await searchTask.value
        } onCancel: {
            searchTask.cancel()
        }
    }
}

struct SearchResultsViewer: View {
    let initialResult: SearchResult
    let allResults: [SearchResult]
    var searchEngine: SearchEngine? = nil

    @State private var currentIndex: Int = 0
    @State private var displayedResults: [SearchResult] = []
    @State private var showControls: Bool = true
    @State private var showUpgrade = false
    @State private var findSimilarTask: Task<Void, Never>?
    @State private var findSimilarGeneration = 0
    @State private var isFindingSimilar = false
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
                        Spacer().frame(width: 44)
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
                                Spacer()
                                if searchEngine != nil, result.supportsFindSimilar {
                                    Button(action: handleFindSimilar) {
                                        HStack(spacing: 8) {
                                            if isFindingSimilar {
                                                ProgressView()
                                                    .controlSize(.small)
                                                    .tint(Celestial.Colors.amber)
                                            }
                                            Text(proManager.isPro ? "Find similar" : "Find similar · Pro")
                                                .font(.subheadline.weight(.semibold))
                                                .foregroundStyle(Celestial.Colors.amber)
                                        }
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
        .onDisappear(perform: cancelFindSimilar)
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
            cancelFindSimilar()
        }
    }

    private func handleFindSimilar() {
        guard proManager.isPro else {
            showUpgrade = true
            return
        }
        guard let searchEngine,
              currentIndex < displayedResults.count,
              displayedResults[currentIndex].supportsFindSimilar else { return }

        findSimilarTask?.cancel()
        findSimilarGeneration += 1
        let generation = findSimilarGeneration
        let photoID = displayedResults[currentIndex].id
        isFindingSimilar = true

        findSimilarTask = Task { @MainActor in
            let similar = await SimilaritySearchOperation.run {
                searchEngine.findSimilar(photoId: photoID)
            }
            guard !Task.isCancelled,
                  generation == findSimilarGeneration else {
                return
            }

            let photoResults = similar.filter { !$0.isVideo }
            if !photoResults.isEmpty {
                withAnimation(.easeInOut(duration: 0.2)) {
                    displayedResults = photoResults
                    currentIndex = 0
                }
            }
            isFindingSimilar = false
            findSimilarTask = nil
        }
    }

    private func cancelFindSimilar() {
        findSimilarGeneration += 1
        findSimilarTask?.cancel()
        findSimilarTask = nil
        isFindingSimilar = false
    }

}
