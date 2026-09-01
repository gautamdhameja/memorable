import SwiftUI

struct DuplicateFinderView: View {
    @ObservedObject var indexingService: IndexingService
    @ObservedObject private var proManager = ProManager.shared
    @Environment(\.database) private var database
    @State private var duplicates: [DuplicatePair] = []
    @State private var isScanning = false
    @State private var scanComplete = false
    @State private var scanTask: Task<Void, Never>?
    @State private var scanGeneration: UInt = 0
    @State private var deletionAlertTitle = "Couldn't delete photo"
    @State private var deletionAlertMessage: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                CelestialBackdrop()

                Group {
                    if isScanning {
                        VStack(spacing: 16) {
                            ProgressView()
                                .tint(Celestial.Colors.primaryDim)
                            Text("Scanning for duplicates...")
                                .font(Celestial.Typography.supporting)
                                .foregroundStyle(Celestial.Colors.onSurfaceVariant)
                        }
                    } else if duplicates.isEmpty && scanComplete {
                        VStack(spacing: 16) {
                            CelestialGlassIcon(
                                systemName: "checkmark",
                                tint: Celestial.Colors.emerald,
                                size: 64
                            )
                            Text("No duplicates found")
                                .font(Celestial.Typography.supporting)
                                .foregroundStyle(Celestial.Colors.onSurfaceVariant)
                        }
                    } else if !duplicates.isEmpty {
                        List {
                            Section {
                                ForEach(duplicates) { pair in
                                    DuplicatePairRow(
                                        pair: pair,
                                        indexingService: indexingService
                                    ) { deletedIdentifier, result in
                                        handleDeletionResult(
                                            result,
                                            localIdentifier: deletedIdentifier
                                        )
                                    }
                                    .listRowBackground(Color.clear)
                                    .listRowSeparator(.hidden)
                                    .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                                }
                            } header: {
                                HStack {
                                    Text("\(duplicates.count) potential duplicates")
                                    Spacer()
                                    Text("Review before deleting")
                                }
                                .foregroundStyle(Celestial.Colors.onSurfaceVariant)
                            }
                        }
                        .listStyle(.plain)
                        .scrollContentBackground(.hidden)
                    } else {
                        VStack(spacing: 16) {
                            CelestialGlassIcon(
                                systemName: "square.on.square",
                                tint: Celestial.Colors.onSurfaceVariant,
                                size: 64
                            )
                            Text("Find near-identical photos in your library")
                                .font(Celestial.Typography.supporting)
                                .foregroundStyle(Celestial.Colors.onSurfaceVariant)
                            Button("Scan for Duplicates") {
                                Haptics.medium()
                                startScan()
                            }
                            .celestialPrimaryButtonStyle()
                        }
                    }
                }
            }
            .celestialNavigationTitle("Duplicates")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(Celestial.Colors.primaryDim)
                        .disabled(indexingService.isDeletingDuplicatePhoto)
                }
            }
            .preferredColorScheme(.dark)
        }
        .onDisappear {
            cancelScan(clearResults: false)
        }
        .onAppear {
            guard !proManager.isPro else { return }
            dismiss()
        }
        .onChange(of: proManager.isPro) { _, isPro in
            guard !isPro else { return }
            cancelScan(clearResults: true)
            dismiss()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
            cancelScan(clearResults: true)
        }
        .interactiveDismissDisabled(indexingService.isDeletingDuplicatePhoto)
        .alert(
            deletionAlertTitle,
            isPresented: Binding(
                get: { deletionAlertMessage != nil },
                set: { if !$0 { deletionAlertMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(deletionAlertMessage ?? "Try again.")
        }
    }

    private func startScan() {
        guard proManager.isPro else {
            dismiss()
            return
        }
        scanTask?.cancel()
        scanGeneration &+= 1
        let generation = scanGeneration
        isScanning = true
        let db = database
        let featurePolicy = ProFeatureAccessPolicy(isPro: proManager.isPro)
        scanTask = Task.detached(priority: .userInitiated) {
            do {
                let data = try db.loadEmbeddingsForDuplicateScan(
                    limit: IndexingConfig.maxDuplicateScanPhotos
                )
                guard !Task.isCancelled else { return }
                let found = DuplicateFinder.findDuplicates(
                    ids: data.ids,
                    localIdentifiers: data.localIdentifiers,
                    embeddings: data.embeddings,
                    featurePolicy: featurePolicy
                )
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard DuplicateScanGenerationPolicy.acceptsCompletion(
                        startedGeneration: generation,
                        currentGeneration: scanGeneration,
                        isCancelled: Task.isCancelled
                    ), proManager.isPro else { return }
                    duplicates = found
                    isScanning = false
                    scanComplete = true
                    scanTask = nil
                    if !found.isEmpty { Haptics.success() }
                }
            } catch {
                guard !Task.isCancelled else { return }
                logger.error("Duplicate scan failed: \(error.safeDiagnosticCode)")
                await MainActor.run {
                    guard DuplicateScanGenerationPolicy.acceptsCompletion(
                        startedGeneration: generation,
                        currentGeneration: scanGeneration,
                        isCancelled: Task.isCancelled
                    ) else { return }
                    isScanning = false
                    scanComplete = true
                    scanTask = nil
                }
            }
        }
    }

    private func cancelScan(clearResults: Bool) {
        scanGeneration &+= 1
        scanTask?.cancel()
        scanTask = nil
        isScanning = false
        scanComplete = false
        if clearResults {
            duplicates.removeAll(keepingCapacity: false)
        }
    }

    private func handleDeletionResult(
        _ result: Result<DuplicatePhotoDeletionOutcome, Error>,
        localIdentifier: String
    ) {
        switch result {
        case .success(let outcome):
            duplicates.removeAll {
                $0.photo1LocalId == localIdentifier
                    || $0.photo2LocalId == localIdentifier
            }
            if outcome == .indexRefreshPending {
                deletionAlertTitle = "Photo deleted"
                deletionAlertMessage = "Search is refreshing in the background."
            }
        case .failure(let error):
            logger.error("Failed to delete duplicate photo: \(error.safeDiagnosticCode)")
            deletionAlertTitle = "Couldn't delete photo"
            deletionAlertMessage = error.localizedDescription
        }
    }
}

struct DuplicatePairRow: View {
    let pair: DuplicatePair
    @ObservedObject var indexingService: IndexingService
    var onDeletionComplete: ((String, Result<DuplicatePhotoDeletionOutcome, Error>) -> Void)?
    @State private var image1: UIImage?
    @State private var image2: UIImage?
    @State private var imageLoadGeneration: UInt = 0
    @State private var imageLoadTask: Task<Void, Never>?
    @State private var showDeleteConfirm = false
    @State private var deleteTarget: String?
    @State private var isDeleting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 9) {
                Circle()
                    .fill(pair.similarity > 0.98 ? Celestial.Colors.error : Celestial.Colors.amber)
                    .frame(width: 6, height: 6)
                Text("\(matchPercent)% match")
                    .font(Celestial.Typography.supportingEmphasized)
                    .foregroundStyle(pair.similarity > 0.98 ? Celestial.Colors.error : Celestial.Colors.amber)
                Spacer()
            }

            HStack(spacing: 5) {
                thumbnailView(image: image1, label: "LEFT", alignment: .topLeading)
                thumbnailView(image: image2, label: "RIGHT", alignment: .topTrailing)
            }

            HStack(spacing: 5) {
                Button {
                    deleteTarget = pair.photo1LocalId
                    showDeleteConfirm = true
                } label: {
                    Label("Delete Left", systemImage: "trash")
                        .frame(maxWidth: .infinity)
                }
                .celestialSecondaryButtonStyle(tint: Celestial.Colors.error)
                .disabled(
                    isDeleting
                        || indexingService.isDeletingDuplicatePhoto
                        || indexingService.isThermallyPaused
                )

                Button {
                    deleteTarget = pair.photo2LocalId
                    showDeleteConfirm = true
                } label: {
                    Label("Delete Right", systemImage: "trash")
                        .frame(maxWidth: .infinity)
                }
                .celestialSecondaryButtonStyle(tint: Celestial.Colors.error)
                .disabled(
                    isDeleting
                        || indexingService.isDeletingDuplicatePhoto
                        || indexingService.isThermallyPaused
                )
            }
        }
        .padding(14)
        .modifier(GlassPanelModifier(cornerRadius: 18))
        .task {
            imageLoadTask?.cancel()
            let task = Task { @MainActor in
                imageLoadGeneration &+= 1
                let generation = imageLoadGeneration
                await PhotoLibrary.prefetchAssets(localIdentifiers: [
                    pair.photo1LocalId,
                    pair.photo2LocalId,
                ])
                if let asset = await PhotoLibrary.resolveAsset(by: pair.photo1LocalId) {
                    let loaded = await PhotoLibrary.loadThumbnail(for: asset)
                    guard ImageLoadGenerationPolicy.acceptsCompletion(
                        startedGeneration: generation,
                        currentGeneration: imageLoadGeneration,
                        isCancelled: Task.isCancelled
                    ) else { return }
                    image1 = loaded
                }
                if let asset = await PhotoLibrary.resolveAsset(by: pair.photo2LocalId) {
                    let loaded = await PhotoLibrary.loadThumbnail(for: asset)
                    guard ImageLoadGenerationPolicy.acceptsCompletion(
                        startedGeneration: generation,
                        currentGeneration: imageLoadGeneration,
                        isCancelled: Task.isCancelled
                    ) else { return }
                    image2 = loaded
                }
            }
            imageLoadTask = task
            await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
            imageLoadTask?.cancel()
            imageLoadTask = nil
            imageLoadGeneration &+= 1
            MemoryPressureReleasePolicy.release(&image1)
            MemoryPressureReleasePolicy.release(&image2)
        }
        .confirmationDialog("Delete this photo?", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button("Move to Recently Deleted", role: .destructive) {
                guard let localId = deleteTarget else { return }
                deletePhoto(localIdentifier: localId)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The photo will be moved to the Recently Deleted album in Photos.")
        }
    }

    private var matchPercent: Int {
        guard pair.similarity.isFinite else { return 0 }
        return min(100, max(0, Int((pair.similarity * 100).rounded())))
    }

    private func thumbnailView(
        image: UIImage?,
        label: String,
        alignment: Alignment
    ) -> some View {
        Group {
            if let img = image {
                Image(uiImage: img)
                    .resizable()
                    .aspectRatio(1, contentMode: .fill)
                    .clipped()
            } else {
                Rectangle()
                    .fill(Celestial.Colors.surfaceContainer)
            }
        }
        .aspectRatio(1.16, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(alignment: alignment) {
            Text(label)
                .font(Celestial.Typography.microStrong)
                .foregroundStyle(.white)
                .padding(8)
                .shadow(radius: 3)
        }
        .accessibilityLabel("Photo")
    }

    private func deletePhoto(localIdentifier: String) {
        isDeleting = true
        Task { @MainActor in
            defer { isDeleting = false }
            do {
                let outcome = try await indexingService.deleteDuplicatePhoto(
                    localIdentifier: localIdentifier
                )
                onDeletionComplete?(localIdentifier, .success(outcome))
            } catch {
                onDeletionComplete?(localIdentifier, .failure(error))
            }
        }
    }
}
