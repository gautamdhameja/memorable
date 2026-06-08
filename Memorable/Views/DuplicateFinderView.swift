import SwiftUI
import Photos

struct DuplicateFinderView: View {
    let searchEngine: SearchEngine
    @Environment(\.database) private var database
    @State private var duplicates: [DuplicatePair] = []
    @State private var isScanning = false
    @State private var scanComplete = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                Celestial.Colors.background.ignoresSafeArea()

                Group {
                    if isScanning {
                        VStack(spacing: 16) {
                            ProgressView()
                                .tint(Celestial.Colors.primaryDim)
                            Text("Scanning for duplicates...")
                                .font(.subheadline)
                                .foregroundStyle(Celestial.Colors.onSurfaceVariant)
                        }
                    } else if duplicates.isEmpty && scanComplete {
                        VStack(spacing: 16) {
                            Image(systemName: "checkmark.circle")
                                .font(.system(size: 48, weight: .thin))
                                .foregroundStyle(Celestial.Colors.primaryDim)
                            Text("No duplicates found")
                                .font(.subheadline)
                                .foregroundStyle(Celestial.Colors.onSurfaceVariant)
                        }
                    } else if !duplicates.isEmpty {
                        List {
                            Section {
                                ForEach(duplicates) { pair in
                                    DuplicatePairRow(pair: pair, searchEngine: searchEngine) { deletedPair in
                                        duplicates.removeAll { $0.id == deletedPair.id }
                                    }
                                    .listRowBackground(Celestial.Colors.surfaceContainerHigh)
                                }
                            } header: {
                                Text("\(duplicates.count) potential duplicates")
                            }
                        }
                        .scrollContentBackground(.hidden)
                    } else {
                        VStack(spacing: 16) {
                            Image(systemName: "doc.on.doc")
                                .font(.system(size: 48, weight: .thin))
                                .foregroundStyle(Celestial.Colors.outlineVariant)
                            Text("Find near-identical photos in your library")
                                .font(.subheadline)
                                .foregroundStyle(Celestial.Colors.onSurfaceVariant)
                            Button("Scan for Duplicates") {
                                Haptics.medium()
                                startScan()
                            }
                            .buttonStyle(CelestialButtonStyle())
                        }
                    }
                }
            }
            .navigationTitle("Duplicate Finder")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(Celestial.Colors.primaryDim)
                }
            }
            .preferredColorScheme(.dark)
        }
    }

    private func startScan() {
        isScanning = true
        let db = database
        Task.detached(priority: .userInitiated) {
            do {
                let data = try db.loadAllEmbeddings()
                let found = DuplicateFinder.findDuplicates(
                    ids: data.ids,
                    localIdentifiers: data.localIdentifiers,
                    embeddings: data.embeddings
                )
                await MainActor.run {
                    duplicates = found
                    isScanning = false
                    scanComplete = true
                    if !found.isEmpty { Haptics.success() }
                }
            } catch {
                logger.error("Duplicate scan failed: \(error.localizedDescription)")
                await MainActor.run {
                    isScanning = false
                    scanComplete = true
                }
            }
        }
    }
}

struct DuplicatePairRow: View {
    let pair: DuplicatePair
    let searchEngine: SearchEngine
    var onDelete: ((DuplicatePair) -> Void)?
    @Environment(\.database) private var database
    @State private var image1: UIImage?
    @State private var image2: UIImage?
    @State private var showDeleteConfirm = false
    @State private var deleteTarget: String?
    @State private var isDeleting = false

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                thumbnailView(image: image1, localId: pair.photo1LocalId)
                thumbnailView(image: image2, localId: pair.photo2LocalId)

                VStack(alignment: .leading, spacing: 4) {
                    Text("\(Int(pair.similarity * 100))% match")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Celestial.Colors.onSurface)
                }
                Spacer()
            }

            HStack(spacing: 12) {
                Button {
                    deleteTarget = pair.photo1LocalId
                    showDeleteConfirm = true
                } label: {
                    Label("Delete Left", systemImage: "trash")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Celestial.Colors.error)
                }
                .disabled(isDeleting)

                Button {
                    deleteTarget = pair.photo2LocalId
                    showDeleteConfirm = true
                } label: {
                    Label("Delete Right", systemImage: "trash")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Celestial.Colors.error)
                }
                .disabled(isDeleting)

                Spacer()
            }
        }
        .task {
            if let asset = PhotoLibrary.getAsset(by: pair.photo1LocalId) {
                image1 = await PhotoLibrary.loadThumbnail(for: asset)
            }
            if let asset = PhotoLibrary.getAsset(by: pair.photo2LocalId) {
                image2 = await PhotoLibrary.loadThumbnail(for: asset)
            }
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

    private func thumbnailView(image: UIImage?, localId: String) -> some View {
        Group {
            if let img = image {
                Image(uiImage: img)
                    .resizable()
                    .aspectRatio(1, contentMode: .fill)
                    .frame(width: 80, height: 80)
                    .clipped()
            } else {
                Rectangle()
                    .fill(Celestial.Colors.surfaceContainer)
                    .frame(width: 80, height: 80)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .accessibilityLabel("Photo")
    }

    private func deletePhoto(localIdentifier: String) {
        guard let asset = PhotoLibrary.getAsset(by: localIdentifier) else { return }
        isDeleting = true

        PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.deleteAssets([asset] as NSArray)
        } completionHandler: { success, error in
            DispatchQueue.main.async {
                isDeleting = false
                if success {
                    let db = database
                    let engine = searchEngine
                    Task.detached(priority: .userInitiated) {
                        do {
                            try db.deletePhoto(localIdentifier: localIdentifier)
                            try engine.loadIndex()
                            await MainActor.run { onDelete?(pair) }
                        } catch {
                            logger.error("Failed to update duplicate index after deletion: \(error.localizedDescription)")
                            await MainActor.run { onDelete?(pair) }
                        }
                    }
                } else if let error {
                    logger.error("Failed to delete photo: \(error.localizedDescription)")
                }
            }
        }
    }
}
