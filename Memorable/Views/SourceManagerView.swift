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
            Celestial.Colors.background.ignoresSafeArea()

            List {
                Section {
                    HStack(spacing: 14) {
                        Image(systemName: "photo.on.rectangle")
                            .foregroundStyle(Celestial.Colors.primaryDim)
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
                        } else {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(Celestial.Colors.primaryDim)
                        }
                    }
                    .listRowBackground(Celestial.Colors.surfaceContainerHigh)
                } header: {
                    Text("Photo Library")
                }

                Section {
                    if sources.filter({ $0.type == "folder" }).isEmpty {
                        Text("No folders added")
                            .font(.subheadline)
                            .foregroundStyle(Celestial.Colors.outline)
                            .listRowBackground(Celestial.Colors.surfaceContainerHigh)
                    }

                    ForEach(sources.filter { $0.type == "folder" }) { source in
                        HStack(spacing: 14) {
                            Image(systemName: "folder")
                                .foregroundStyle(Celestial.Colors.tertiaryDim)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(source.name)
                                    .font(.body.weight(.medium))
                                    .foregroundStyle(Celestial.Colors.onSurface)
                                Text("\(source.photoCount) photos")
                                    .font(.caption)
                                    .foregroundStyle(Celestial.Colors.onSurfaceVariant)
                            }
                        }
                        .listRowBackground(Celestial.Colors.surfaceContainerHigh)
                    }
                    .onDelete { offsets in
                        let folderSources = sources.filter { $0.type == "folder" }
                        for offset in offsets {
                            let source = folderSources[offset]
                            do {
                                try database.deleteSource(source.id)
                            } catch {
                                deleteError = "Failed to delete \(source.name): \(error.localizedDescription)"
                                logger.error("Failed to delete source \(source.id): \(error.localizedDescription)")
                            }
                        }
                        loadSources()
                    }

                    Button(action: {
                        if proManager.isPro {
                            showFolderPicker = true
                        } else {
                            showUpgrade = true
                        }
                    }) {
                        Label(proManager.isPro ? "Add Folder" : "Add Folder (Pro)", systemImage: "plus.circle")
                            .foregroundStyle(Celestial.Colors.primaryFixedDim)
                    }
                    .listRowBackground(Celestial.Colors.surfaceContainerHigh)
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
                let name = url.lastPathComponent
                    .filter { !$0.isNewline && $0 != "\0" }
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                indexingService.indexFolder(url: url, name: name)
                showFolderPicker = false
            }
        }
        .onAppear { loadSources() }
        .sheet(isPresented: $showUpgrade) {
            UpgradeView()
        }
        .alert("Error", isPresented: .init(
            get: { deleteError != nil },
            set: { if !$0 { deleteError = nil } }
        )) {
            Button("OK") { deleteError = nil }
        } message: {
            Text(deleteError ?? "")
        }
    }

    private func loadSources() {
        do {
            sources = try database.listSources()
        } catch {
            logger.error("Failed to load sources: \(error.localizedDescription)")
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
