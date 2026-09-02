import SwiftUI
import UniformTypeIdentifiers

struct SourceManagerView: View {
    @ObservedObject var indexingService: IndexingService
    @Environment(\.database) private var database
    @Environment(\.dismiss) private var dismiss
    @State private var sources: [PhotoSource] = []
    @State private var applePhotosIndexedCount = 0
    @State private var showFolderPicker = false
    @State private var showUpgrade = false
    @State private var deleteError: String?
    @ObservedObject private var proManager = ProManager.shared

    private var folderSources: [PhotoSource] {
        sources.filter { $0.type == PhotoSourceType.folder.rawValue }
    }

    var body: some View {
        ZStack {
            CelestialBackdrop()

            List {
                Section {
                    HStack(spacing: 14) {
                        CelestialGlassIcon(systemName: "photo.on.rectangle", size: 34)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Apple Photos")
                                .font(Celestial.Typography.bodyEmphasized)
                                .foregroundStyle(Celestial.Colors.onSurface)
                            if indexingService.isReady {
                                Text("\(applePhotosIndexedCount) photos indexed")
                                    .font(Celestial.Typography.caption)
                                    .foregroundStyle(Celestial.Colors.onSurfaceVariant)
                            }
                        }
                        Spacer()
                        if indexingService.progress.isRunning {
                            ProgressView()
                                .tint(Celestial.Colors.primaryDim)
                                .controlSize(.small)
                        } else if !indexingService.isReady {
                            Button("Index") {
                                indexingService.startIndexing()
                            }
                            .celestialPrimaryButtonStyle()
                            .disabled(!database.allowsIndexingWrites)
                        } else {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(Celestial.Colors.primaryDim)
                        }
                    }
                    .padding(12)
                    .modifier(GlassPanelModifier(cornerRadius: 16))
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                    .disabled(!database.allowsIndexingWrites)
                } header: {
                    Text("Photo Library")
                        .font(Celestial.Typography.eyebrow)
                        .textCase(nil)
                } footer: {
                    Text("Memorable indexes media that is available on this iPhone. It does not download iCloud-only items.")
                        .font(Celestial.Typography.caption)
                }

                Section {
                    if folderSources.isEmpty {
                        emptyFoldersPanel
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                    } else {
                        ForEach(folderSources) { source in
                            HStack(spacing: 14) {
                                CelestialGlassIcon(
                                    systemName: "folder",
                                    tint: Celestial.Colors.tertiaryDim,
                                    size: 34
                                )
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(source.name)
                                        .font(Celestial.Typography.bodyEmphasized)
                                        .foregroundStyle(Celestial.Colors.onSurface)
                                    Text("\(source.photoCount) photos")
                                        .font(Celestial.Typography.caption)
                                        .foregroundStyle(Celestial.Colors.onSurfaceVariant)
                                }
                                Spacer()
                                Button {
                                    if ProFeatureAccessPolicy(isPro: proManager.isPro)
                                        .allowsFolderRefresh {
                                        indexingService.reindexFolderSource(source)
                                    } else {
                                        showUpgrade = true
                                    }
                                } label: {
                                    Image(
                                        systemName: proManager.isPro
                                            ? "arrow.clockwise.circle"
                                            : "lock.circle"
                                    )
                                    .foregroundStyle(
                                        proManager.isPro
                                            ? Celestial.Colors.primaryDim
                                            : Celestial.Colors.amber
                                    )
                                }
                                .buttonStyle(.plain)
                                .disabled(indexingService.progress.isRunning)
                                .accessibilityLabel(
                                    proManager.isPro
                                        ? "Refresh \(source.name)"
                                        : "Refresh \(source.name), Pro feature"
                                )
                            }
                            .padding(12)
                            .modifier(GlassPanelModifier(cornerRadius: 16))
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                        }
                        .onDelete { offsets in
                            let selectedSources = offsets.map { folderSources[$0] }
                            Task {
                                for source in selectedSources {
                                    do {
                                        try await indexingService.deleteFolderSource(id: source.id)
                                    } catch {
                                        deleteError = "Failed to delete \(source.name): \(error.localizedDescription)"
                                        logger.error("Failed to delete a source: \(error.safeDiagnosticCode)")
                                    }
                                }
                                await loadSources()
                            }
                        }

                        Button(action: requestFolderPicker) {
                            Label(
                                proManager.isPro ? "Add Folder" : "Add Folder (Pro)",
                                systemImage: "plus.circle"
                            )
                        }
                        .celestialSecondaryButtonStyle()
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .disabled(!database.allowsIndexingWrites)
                    }
                } header: {
                    Text("Folders")
                        .font(Celestial.Typography.eyebrow)
                        .textCase(nil)
                }
            }
            .scrollContentBackground(.hidden)
        }
        .preferredColorScheme(.dark)
        .celestialNavigationTitle("Photo Sources")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Done") { dismiss() }
                    .font(Celestial.Typography.button)
                    .foregroundStyle(Celestial.Colors.primaryDim)
            }
        }
        .sheet(isPresented: $showFolderPicker) {
            FolderPickerView { url in
                let name = FolderDisplayNamePolicy.sanitized(url.lastPathComponent)
                indexingService.indexFolder(url: url, name: name)
                showFolderPicker = false
            }
        }
        .task { await loadSources() }
        .onChange(of: indexingService.progress.isRunning) { wasRunning, isRunning in
            guard wasRunning, !isRunning else { return }
            Task { await loadSources() }
        }
        .sheet(isPresented: $showUpgrade) {
            UpgradeView()
        }
        .alert("Error", isPresented: .init(
            get: { deleteError != nil || indexingService.folderIndexingError != nil },
            set: {
                if !$0 {
                    deleteError = nil
                    indexingService.clearFolderIndexingError()
                }
            }
        )) {
            Button("OK") {
                deleteError = nil
                indexingService.clearFolderIndexingError()
            }
        } message: {
            Text(deleteError ?? indexingService.folderIndexingError ?? "")
        }
    }

    private var emptyFoldersPanel: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                CelestialGlassIcon(
                    systemName: "folder",
                    tint: Celestial.Colors.onSurfaceVariant,
                    size: 34
                )
                VStack(alignment: .leading, spacing: 3) {
                    Text("No folders yet")
                        .font(Celestial.Typography.bodyEmphasized)
                        .foregroundStyle(Celestial.Colors.onSurface)
                    Text("Add photos stored outside Apple Photos")
                        .font(Celestial.Typography.caption)
                        .foregroundStyle(Celestial.Colors.onSurfaceVariant)
                }
                Spacer(minLength: 0)
            }
            .frame(minHeight: 68)

            CelestialHairline()
                .padding(.leading, 46)

            Button(action: requestFolderPicker) {
                HStack(spacing: 10) {
                    Image(systemName: proManager.isPro ? "plus" : "lock")
                        .font(Celestial.Typography.captionStrong)
                    Text(proManager.isPro ? "Add Folder" : "Add Folder · Pro")
                        .font(Celestial.Typography.supportingEmphasized)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(Celestial.Typography.captionStrong)
                        .foregroundStyle(Celestial.Colors.outlineVariant)
                }
                .foregroundStyle(
                    proManager.isPro
                        ? Celestial.Colors.primaryDim
                        : Celestial.Colors.amber
                )
                .frame(minHeight: 54)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!database.allowsIndexingWrites)
        }
        .padding(.horizontal, 12)
        .modifier(GlassPanelModifier(cornerRadius: 16))
    }

    private func requestFolderPicker() {
        if proManager.isPro {
            showFolderPicker = true
        } else {
            showUpgrade = true
        }
    }

    private func loadSources() async {
        do {
            let db = database
            let loaded = try await Task.detached(priority: .utility) {
                (
                    sources: try db.listSources(),
                    photoLibraryCounts: try db.photoLibraryIndexedMediaCounts()
                )
            }.value
            sources = loaded.sources
            applePhotosIndexedCount = loaded.photoLibraryCounts.photos
        } catch {
            logger.error("Failed to load sources: \(error.safeDiagnosticCode)")
            sources = []
            applePhotosIndexedCount = 0
        }
    }
}

struct FolderPickerView: UIViewControllerRepresentable {
    var onPick: (URL) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder])
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick)
    }

    class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (URL) -> Void
        init(onPick: @escaping (URL) -> Void) { self.onPick = onPick }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else { return }
            onPick(url)
        }
    }
}
