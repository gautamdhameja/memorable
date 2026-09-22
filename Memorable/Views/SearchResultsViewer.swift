import SwiftUI
import UIKit

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

private struct PhotoShareSheet: UIViewControllerRepresentable {
    let item: PreparedPhotoShareItem
    let onComplete: @MainActor () -> Void

    @MainActor
    final class Coordinator {
        private let item: PreparedPhotoShareItem
        private let onComplete: @MainActor () -> Void
        private var didFinish = false

        init(item: PreparedPhotoShareItem, onComplete: @escaping @MainActor () -> Void) {
            self.item = item
            self.onComplete = onComplete
        }

        func finish() {
            guard !didFinish else { return }
            didFinish = true
            item.cleanup()
            onComplete()
        }

        func cleanup() {
            item.cleanup()
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(item: item, onComplete: onComplete)
    }

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(
            activityItems: [item.fileURL],
            applicationActivities: nil
        )
        let coordinator = context.coordinator
        controller.completionWithItemsHandler = { [weak coordinator] _, _, _, _ in
            Task { @MainActor in coordinator?.finish() }
        }
        return controller
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}

    static func dismantleUIViewController(
        _ controller: UIActivityViewController,
        coordinator: Coordinator
    ) {
        coordinator.cleanup()
    }
}

@MainActor
final class PhotoShareCoordinator: ObservableObject {
    typealias Preparer = @MainActor @Sendable (SearchResult) async throws -> PreparedPhotoShareItem

    @Published private(set) var isPreparing = false
    @Published var preparedItem: PreparedPhotoShareItem?
    @Published private(set) var errorMessage: String?

    private let preparer: Preparer
    private var preparationTask: Task<Void, Never>?
    private var generation = 0
    private var visibleResultID: String?

    init(
        preparer: @escaping Preparer = { result in
            try await PhotoLibrary.prepareShareItem(for: result)
        }
    ) {
        self.preparer = preparer
    }

    func requestShare(for result: SearchResult) {
        cancelPreparation()
        preparedItem?.cleanup()
        preparedItem = nil
        errorMessage = nil
        visibleResultID = result.id
        generation &+= 1
        let requestGeneration = generation
        isPreparing = true

        preparationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let item = try await preparer(result)
                guard !Task.isCancelled,
                      requestGeneration == generation,
                      visibleResultID == result.id else {
                    item.cleanup()
                    return
                }
                isPreparing = false
                preparationTask = nil
                preparedItem = item
            } catch is CancellationError {
                finishCancelledRequest(generation: requestGeneration)
            } catch let error as PhotoSharePreparationError {
                finishFailedRequest(error, generation: requestGeneration)
            } catch {
                logger.error("[PhotoShareCoordinator] Share preparation failed: \(error.safeDiagnosticCode)")
                finishFailedRequest(.storageUnavailable, generation: requestGeneration)
            }
        }
    }

    func visibleResultDidChange(to resultID: String?) {
        visibleResultID = resultID
        cancelPreparation()
    }

    func cancelPreparation() {
        generation &+= 1
        preparationTask?.cancel()
        preparationTask = nil
        isPreparing = false
    }

    func cancelAll() {
        cancelPreparation()
        preparedItem?.cleanup()
        preparedItem = nil
        errorMessage = nil
    }

    func completePresentation(itemID: UUID) {
        if preparedItem?.id == itemID {
            preparedItem = nil
        }
    }

    func clearError() {
        errorMessage = nil
    }

    private func finishCancelledRequest(generation requestGeneration: Int) {
        guard requestGeneration == generation else { return }
        isPreparing = false
        preparationTask = nil
    }

    private func finishFailedRequest(
        _ error: PhotoSharePreparationError,
        generation requestGeneration: Int
    ) {
        guard !Task.isCancelled, requestGeneration == generation else { return }
        logger.error("[PhotoShareCoordinator] Share preparation failed: \(error.safeDiagnosticCode)")
        isPreparing = false
        preparationTask = nil
        errorMessage = error.userMessage
    }
}

private struct UserSearchActivityKey: EnvironmentKey {
    static let defaultValue: @MainActor @Sendable (Bool, UUID) -> Void = { _, _ in }
}

extension EnvironmentValues {
    var userSearchActivity: @MainActor @Sendable (Bool, UUID) -> Void {
        get { self[UserSearchActivityKey.self] }
        set { self[UserSearchActivityKey.self] = newValue }
    }
}

struct SearchResultsViewer: View {
    let initialResult: SearchResult
    let allResults: [SearchResult]
    var searchEngine: SearchEngine? = nil

    @Environment(\.database) private var database
    @Environment(\.userSearchActivity) private var userSearchActivity
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var nearbyPhoto: SearchResult?
    @State private var recognizedText: String?
    @State private var recognizedTextPhotoID: String?
    @State private var textError: String?
    @State private var copiedText = false
    @State private var currentIndex: Int = 0
    @State private var displayedResults: [SearchResult] = []
    @State private var showControls: Bool = true
    @State private var showUpgrade = false
    @State private var findSimilarTask: Task<Void, Never>?
    @State private var findSimilarGeneration = 0
    @State private var isFindingSimilar = false
    @StateObject private var shareCoordinator = PhotoShareCoordinator()
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
                    ZoomableAsyncImage(
                        result: result,
                        isActive: index == currentIndex,
                        shouldLoad: PhotoViewerPreloadPolicy.shouldLoad(
                            index: index,
                            currentIndex: currentIndex
                        ),
                        onSingleTap: {
                            withAnimation(.easeInOut(duration: 0.2)) { showControls.toggle() }
                        }
                    )
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
                            Group {
                                if dynamicTypeSize.isAccessibilitySize {
                                    Image(systemName: "chevron.left")
                                } else {
                                    Label("Results", systemImage: "chevron.left")
                                }
                            }
                            .font(Celestial.Typography.body)
                        }
                        .celestialGlassCapsuleButtonStyle(
                            tint: Color.black.opacity(0.16),
                            foreground: .white
                        )
                        .accessibilityLabel("Back to results")
                        Spacer()
                        if displayedResults.count > 1 {
                            Text("\(currentIndex + 1) of \(displayedResults.count)")
                                .font(dynamicTypeSize.isAccessibilitySize ? Celestial.Typography.caption : Celestial.Typography.supporting)
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                                .fixedSize(horizontal: true, vertical: false)
                                .foregroundStyle(.white.opacity(0.82))
                                .padding(.horizontal, 11)
                                .frame(minHeight: 34)
                                .modifier(
                                    GlassCapsuleModifier(
                                        tint: Color.black.opacity(0.12)
                                    )
                                )
                        }
                        Spacer()
                        if canShareCurrentPhoto {
                            Button(action: { shareCurrentPhoto() }) {
                                Group {
                                    if shareCoordinator.isPreparing {
                                        ProgressView()
                                            .controlSize(.small)
                                            .tint(.white)
                                    } else {
                                        Image(systemName: "square.and.arrow.up")
                                            .font(Celestial.Typography.bodyStrong)
                                    }
                                }
                            }
                            .celestialGlassCircleButtonStyle(
                                tint: Color.black.opacity(0.16),
                                foreground: .white
                            )
                            .disabled(shareCoordinator.isPreparing || shareCoordinator.preparedItem != nil)
                            .accessibilityLabel("Share photo")
                        } else {
                            Spacer().frame(width: 44)
                        }
                    }
                    .padding(.horizontal, Celestial.Spacing.pageHorizontalInset)
                    .padding(.top, 6)

                    Spacer()

                    if currentIndex < displayedResults.count {
                        let result = displayedResults[currentIndex]
                        let showsFindSimilar = searchEngine != nil && result.supportsFindSimilar
                        if result.creationDate != nil || showsFindSimilar || (recognizedTextPhotoID == result.id && recognizedText?.isEmpty == false) || textError != nil {
                            Group {
                                if dynamicTypeSize.isAccessibilitySize {
                                    ScrollView {
                                        photoDetails(result: result, showsFindSimilar: showsFindSimilar)
                                    }
                                    .frame(height: 300)
                                } else {
                                    photoDetails(result: result, showsFindSimilar: showsFindSimilar)
                                }
                            }
                            .foregroundStyle(.white.opacity(0.94))
                            .frame(minHeight: 44)
                            .padding(.horizontal, Celestial.Spacing.surfaceContentInset)
                            .padding(.vertical, 6)
                            .modifier(
                                GlassPanelModifier(
                                    cornerRadius: 18,
                                    tint: Color.black.opacity(0.16)
                                )
                            )
                            .padding(.horizontal, Celestial.Spacing.surfaceHorizontalInset)
                            .padding(.bottom, Celestial.Spacing.contentGap)
                        }
                    }
                }
                .transition(.opacity)
            }
        }
        .statusBar(hidden: true)
        .sheet(isPresented: $showUpgrade) { UpgradeView() }
        .sheet(item: $nearbyPhoto) { AroundThisTimeView(photo: $0, searchEngine: searchEngine) }
        .task(id: "\(currentResultID ?? ""):\(proManager.isPro)") {
            recognizedText = nil
            recognizedTextPhotoID = nil
            textError = nil
            copiedText = false
            guard currentIndex < displayedResults.count else { return }
            let result = displayedResults[currentIndex]
            guard !result.isVideo else { return }
            do {
                let database = database
                let isPro = proManager.isPro
                let text = try await CancellableDetachedOperation.run {
                    try database.recognizedText(photoID: result.id, isPro: isPro)
                }
                try Task.checkCancellation()
                guard currentResultID == result.id else { return }
                recognizedText = text
                recognizedTextPhotoID = result.id
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, currentResultID == result.id else { return }
                logger.error("Photo text failed: \(error.safeDiagnosticCode)")
                textError = "Text couldn't be loaded."
            }
        }
        .sheet(item: $shareCoordinator.preparedItem) { item in
            PhotoShareSheet(item: item) {
                shareCoordinator.completePresentation(itemID: item.id)
            }
        }
        .alert(
            "Unable to share photo",
            isPresented: Binding(
                get: { shareCoordinator.errorMessage != nil },
                set: { if !$0 { shareCoordinator.clearError() } }
            )
        ) {
            Button("OK") { shareCoordinator.clearError() }
        } message: {
            Text(shareCoordinator.errorMessage ?? "The photo could not be prepared.")
        }
        .gesture(
            DragGesture(minimumDistance: 80)
                .onEnded { value in
                    if value.translation.height > 100 {
                        dismiss()
                    }
                }
        )
        .onDisappear {
            cancelFindSimilar()
            shareCoordinator.cancelAll()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
            cancelFindSimilar()
            shareCoordinator.cancelPreparation()
        }
        .onAppear {
            enforceFolderEntitlement()
            shareCoordinator.visibleResultDidChange(to: currentResultID)
        }
        .onChange(of: currentResultID) {
            shareCoordinator.visibleResultDidChange(to: currentResultID)
        }
        .onChange(of: proManager.isPro) {
            if !proManager.isPro {
                cancelFindSimilar()
            }
            enforceFolderEntitlement()
        }
    }

    private func photoDetails(result: SearchResult, showsFindSimilar: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if recognizedTextPhotoID == result.id, let text = recognizedText, !text.isEmpty,
               FolderResultAccessPolicy.allows(sourceId: result.sourceId, isPro: proManager.isPro) {
                VStack(alignment: .leading, spacing: 6) {
                    if let match = result.textMatch {
                        MatchedTextExcerpt(match: match)
                        if match.kind == .truncatedWord {
                            Text("Partial text match").font(Celestial.Typography.caption)
                        }
                    } else {
                        Text(String(text.prefix(180)))
                            .font(Celestial.Typography.caption)
                            .lineLimit(3)
                    }
                    Button {
                        UIPasteboard.general.setObjects([text as NSString], localOnly: true, expirationDate: nil)
                        copiedText = true
                    } label: {
                        Label(copiedText ? "Copied" : "Copy text",
                              systemImage: copiedText ? "checkmark" : "doc.on.doc")
                    }
                    .font(Celestial.Typography.button)
                    .frame(minHeight: 44)
                }
            } else if let textError {
                Text(textError).font(Celestial.Typography.caption)
            }
            if let date = result.creationDate {
                Text(date.formatted(date: .long, time: .shortened))
                    .font(Celestial.Typography.supporting)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 20) {
                    photoActions(result: result, showsFindSimilar: showsFindSimilar)
                }
                .fixedSize(horizontal: true, vertical: false)
                VStack(alignment: .leading, spacing: 4) {
                    photoActions(result: result, showsFindSimilar: showsFindSimilar)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func photoActions(result: SearchResult, showsFindSimilar: Bool) -> some View {
        if showsFindSimilar {
            Button(action: handleFindSimilar) {
                HStack(spacing: 8) {
                    if isFindingSimilar { ProgressView().tint(Celestial.Colors.amber) }
                    Text(proManager.isPro ? "Find similar" : "Find similar · Pro")
                }
            }
            .disabled(isFindingSimilar)
            .foregroundStyle(Celestial.Colors.amber)
            .frame(minHeight: 44)
        }
        if !result.isVideo, result.creationDate != nil {
            Button { nearbyPhoto = result } label: {
                Label("Around this time", systemImage: "clock.arrow.circlepath")
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(minHeight: 44)
        }
    }

    private var canShareCurrentPhoto: Bool {
        guard currentIndex < displayedResults.count else { return false }
        let result = displayedResults[currentIndex]
        return !result.isVideo
            && FolderResultAccessPolicy.allows(
                sourceId: result.sourceId,
                isPro: proManager.isPro
            ) && (
            result.sourceId == PhotoSourceType.photokit.rawValue || result.filePath != nil
        )
    }

    private var currentResultID: String? {
        guard currentIndex < displayedResults.count else { return nil }
        return displayedResults[currentIndex].id
    }

    private func shareCurrentPhoto() {
        guard currentIndex < displayedResults.count else { return }
        let result = displayedResults[currentIndex]
        guard !result.isVideo else { return }

        shareCoordinator.requestShare(for: result)
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
        let featurePolicy = ProFeatureAccessPolicy(isPro: proManager.isPro)
        let searchActivity = userSearchActivity
        isFindingSimilar = true

        findSimilarTask = Task { @MainActor in
            guard !Task.isCancelled else { return }
            let activityID = UUID()
            searchActivity(true, activityID)
            defer { searchActivity(false, activityID) }
            let similar = await SimilaritySearchOperation.run {
                searchEngine.findSimilar(photoId: photoID, featurePolicy: featurePolicy)
            }
            guard !Task.isCancelled,
                  generation == findSimilarGeneration,
                  proManager.isPro else {
                return
            }

            let photoResults = similar.filter { !$0.isVideo }
            if !photoResults.isEmpty {
                shareCoordinator.visibleResultDidChange(to: photoResults[0].id)
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

    private func enforceFolderEntitlement() {
        guard !proManager.isPro else { return }
        let previouslyVisibleResultID = currentResultID
        let entitledResults = displayedResults.filter {
            FolderResultAccessPolicy.allows(sourceId: $0.sourceId, isPro: false)
        }
        guard entitledResults != displayedResults else { return }

        cancelFindSimilar()
        shareCoordinator.cancelAll()
        guard !entitledResults.isEmpty else {
            dismiss()
            return
        }
        displayedResults = entitledResults
        currentIndex = FilteredResultSelectionPolicy.index(
            preserving: previouslyVisibleResultID,
            previousIndex: currentIndex,
            remainingResultIDs: entitledResults.map(\.id)
        )
    }

}
