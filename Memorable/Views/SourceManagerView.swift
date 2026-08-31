import SwiftUI
import UniformTypeIdentifiers

struct SourceManagerView: View {
    @ObservedObject var indexingService: IndexingService
    @Environment(\.database) private var database
    @State private var sources: [PhotoSource] = []
    @State private var showFolderPicker = false
    @State private var showUpgrade = false
    @State private var deleteError: String?
    @ObservedObject private var proManager = ProManager.shared

    var body: some View {
        ZStack {
            CelestialBackdrop()

            List {
                Section {
                    HStack(spacing: 14) {
                        CelestialGlassIcon(systemName: "photo.on.rectangle", size: 34)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Apple Photos")
                                .font(.body.weight(.medium))
                                .foregroundStyle(Celestial.Colors.onSurface)
                            if indexingService.isReady {
                                Text("\(indexingService.searchEngine.indexSize) photos indexed")
                                    .font(.caption)
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
                            .buttonStyle(CelestialButtonStyle())
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
                } footer: {
                    Text("Memorable indexes media that is available on this iPhone. It does not download iCloud-only items.")
                }

                Section {
                    if sources.filter({ $0.type == PhotoSourceType.folder.rawValue }).isEmpty {
                        Text("No folders added")
                            .font(.subheadline)
                            .foregroundStyle(Celestial.Colors.outline)
                            .padding(12)
                            .modifier(GlassPanelModifier(cornerRadius: 16))
                            .listRowBackground(Color.clear)
                    }

                    ForEach(sources.filter { $0.type == PhotoSourceType.folder.rawValue }) { source in
                        HStack(spacing: 14) {
                            CelestialGlassIcon(
                                systemName: "folder",
                                tint: Celestial.Colors.tertiaryDim,
                                size: 34
                            )
                            VStack(alignment: .leading, spacing: 3) {
                                Text(source.name)
                                    .font(.body.weight(.medium))
                                    .foregroundStyle(Celestial.Colors.onSurface)
                                Text("\(source.photoCount) photos")
                                    .font(.caption)
                                    .foregroundStyle(Celestial.Colors.onSurfaceVariant)
                            }
                            Spacer()
                            Button {
                                indexingService.reindexFolderSource(source)
                            } label: {
                                Image(systemName: "arrow.clockwise.circle")
                                    .foregroundStyle(Celestial.Colors.primaryDim)
                            }
                            .buttonStyle(.plain)
                            .disabled(indexingService.progress.isRunning)
                            .accessibilityLabel("Refresh \(source.name)")
                        }
                        .padding(12)
                        .modifier(GlassPanelModifier(cornerRadius: 16))
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                    }
                    .onDelete { offsets in
                        let folderSources = sources.filter { $0.type == PhotoSourceType.folder.rawValue }
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

                    Button(action: {
                        if proManager.isPro {
                            showFolderPicker = true
                        } else {
                            showUpgrade = true
                        }
                    }) {
                        Label(proManager.isPro ? "Add Folder" : "Add Folder (Pro)", systemImage: "plus.circle")
                    }
                    .buttonStyle(CelestialSecondaryButtonStyle())
                    .listRowBackground(Color.clear)
                    .disabled(!database.allowsIndexingWrites)
                } header: {
                    Text("Folders")
                }
            }
            .scrollContentBackground(.hidden)
        }
        .preferredColorScheme(.dark)
        .navigationTitle("Photo Sources")
        .toolbarColorScheme(.dark, for: .navigationBar)
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

    private func loadSources() async {
        do {
            let db = database
            sources = try await Task.detached(priority: .utility) {
                try db.listSources()
            }.value
        } catch {
            logger.error("Failed to load sources: \(error.safeDiagnosticCode)")
            sources = []
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
