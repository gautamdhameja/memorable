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
    @State private var loadError: String?
    @ObservedObject private var proManager = ProManager.shared

    private var folderSources: [PhotoSource] {
        sources.filter { $0.type == PhotoSourceType.folder.rawValue }
    }

    private var canAddFolder: Bool {
        database.allowsIndexingWrites
            && (!indexingService.progress.isRunning || indexingService.progress.phase == .enrichment)
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
                                Text("\(CountPhrase.string(applePhotosIndexedCount, "photo")) indexed")
                                    .font(Celestial.Typography.caption)
                                    .foregroundStyle(Celestial.Colors.onSurfaceVariant)
                            }
                        }
                        Spacer()
                        if indexingService.progress.isRunning {
                            Text("Updating")
                                .font(Celestial.Typography.captionStrong)
                                .foregroundStyle(Celestial.Colors.primaryDim)
                                .accessibilityLabel("Search index updating on the home screen")
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
                    .padding(Celestial.Spacing.surfaceContentInset)
                    .modifier(GlassPanelModifier(cornerRadius: 16))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(containerRowInsets)
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
                            .listRowInsets(containerRowInsets)
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
                                    Text(CountPhrase.string(source.photoCount, "photo"))
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
                                    .font(Celestial.Typography.bodyStrong)
                                    .foregroundStyle(
                                        proManager.isPro
                                            ? Celestial.Colors.primaryDim
                                            : Celestial.Colors.amber
                                    )
                                    .frame(width: 44, height: 44)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .padding(.vertical, -8)
                                .padding(.trailing, -10)
                                .disabled(indexingService.progress.isRunning)
                                .accessibilityLabel(
                                    proManager.isPro
                                        ? "Refresh \(source.name)"
                                        : "Refresh \(source.name), Pro feature"
                                )
                            }
                            .padding(Celestial.Spacing.surfaceContentInset)
                            .modifier(GlassPanelModifier(cornerRadius: 16))
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                            .listRowInsets(containerRowInsets)
                        }
                        .onDelete { offsets in
                            let selectedSources = offsets.map { folderSources[$0] }
                            Task {
                                for source in selectedSources {
                                    do {
                                        try await indexingService.deleteFolderSource(id: source.id)
                                    } catch {
                                        deleteError = UserFacingErrorMessage.message(
                                            for: error,
                                            fallback: "Couldn't delete \(source.name). Try again."
                                        )
                                        logger.error("Failed to delete a source: \(error.safeDiagnosticCode)")
                                    }
                                }
                                await loadSources()
                            }
                        }

                        Button(action: requestFolderPicker) {
                            Label(
                                proManager.isPro ? "Add Folder" : "Add Folder · Pro",
                                systemImage: "plus.circle"
                            )
                        }
                        .celestialSecondaryButtonStyle()
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .disabled(!canAddFolder)
                    }
                } header: {
                    Text("Folders")
                        .font(Celestial.Typography.eyebrow)
                        .textCase(nil)
                }
            }
            .scrollContentBackground(.hidden)
            // Rows supply their own 16-point inset, matching the other
            // screens. The grouped list otherwise added a second margin.
            .contentMargins(.horizontal, 0, for: .scrollContent)
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
        .alert("Photo sources", isPresented: .init(
            get: { deleteError != nil || loadError != nil || indexingService.folderIndexingError != nil },
            set: {
                if !$0 {
                    deleteError = nil
                    loadError = nil
                    indexingService.clearFolderIndexingError()
                }
            }
        )) {
            Button("OK") {
                deleteError = nil
                loadError = nil
                indexingService.clearFolderIndexingError()
            }
        } message: {
            Text(deleteError ?? loadError ?? indexingService.folderIndexingError ?? "")
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
            .disabled(!canAddFolder)
        }
        .padding(.horizontal, Celestial.Spacing.surfaceContentInset)
        .modifier(GlassPanelModifier(cornerRadius: 16))
    }

    private var containerRowInsets: EdgeInsets {
        let halfGap = Celestial.Spacing.stackedContainerGap / 2
        return EdgeInsets(
            top: halfGap,
            leading: Celestial.Spacing.surfaceHorizontalInset,
            bottom: halfGap,
            trailing: Celestial.Spacing.surfaceHorizontalInset
        )
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
            loadError = nil
        } catch {
            logger.error("Failed to load sources: \(error.safeDiagnosticCode)")
            loadError = "Photo sources couldn’t load. Close and reopen Photo Sources to try again."
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
