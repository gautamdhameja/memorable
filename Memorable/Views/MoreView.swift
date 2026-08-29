import SwiftUI

struct MoreView: View {
    @ObservedObject var indexingService: IndexingService
    let searchEngine: SearchEngine
    @ObservedObject private var proManager = ProManager.shared
    @Environment(\.database) private var database

    @State private var smartAlbums: [SmartAlbum] = []
    @State private var showAllAlbums = false
    @State private var showSources = false
    @State private var showDuplicates = false
    @State private var showUpgrade = false
    @State private var showReindexConfirm = false

    private var appVersionString: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "v\(version) (\(build))"
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Celestial.Colors.background.ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        Text("More")
                            .font(.title.bold())
                            .tracking(-0.6)
                            .padding(.top, 14)

                        indexStatus
                            .padding(.top, 30)

                        VStack(spacing: 0) {
                            Button {
                                withAnimation(.easeInOut(duration: 0.2)) { showAllAlbums.toggle() }
                            } label: {
                                toolRow(
                                    icon: "rectangle.stack",
                                    title: "Smart Albums",
                                    subtitle: smartAlbums.isEmpty ? "No saved albums" : "\(smartAlbums.count) self-updating albums"
                                )
                            }

                            if showAllAlbums {
                                ForEach(smartAlbums) { album in
                                    NavigationLink {
                                        SmartAlbumResultsView(album: album, searchEngine: searchEngine)
                                    } label: {
                                        HStack {
                                            VStack(alignment: .leading, spacing: 3) {
                                                Text(album.name)
                                                    .font(.subheadline.weight(.medium))
                                                    .foregroundStyle(Celestial.Colors.onSurface)
                                                Text(album.query)
                                                    .font(.caption)
                                                    .foregroundStyle(Celestial.Colors.outline)
                                                    .lineLimit(1)
                                            }
                                            Spacer()
                                            Image(systemName: "chevron.right")
                                                .font(.caption)
                                                .foregroundStyle(Celestial.Colors.outlineVariant)
                                        }
                                        .padding(.leading, 32)
                                        .padding(.vertical, 12)
                                        .overlay(alignment: .bottom) { CelestialHairline() }
                                    }
                                }
                            }

                            NavigationLink {
                                SurpriseExploreView(searchEngine: searchEngine)
                            } label: {
                                toolRow(icon: "scope", title: "Explore", subtitle: "Places, scenes and text")
                            }

                            Button(action: { showDuplicates = true }) {
                                toolRow(icon: "square.on.square", title: "Find duplicates", subtitle: "Compare near-identical photos safely")
                            }

                            Button(action: { showSources = true }) {
                                toolRow(icon: "photo.stack", title: "Photo sources", subtitle: "Library and custom folders")
                            }
                        }
                        .padding(.top, 8)

                        proStatus
                            .padding(.top, 30)

                        HStack {
                            Button("Re-index library") { showReindexConfirm = true }
                            Spacer()
                            NavigationLink("Privacy · \(appVersionString)") { LicensesView() }
                        }
                        .font(.caption)
                        .foregroundStyle(Celestial.Colors.outline)
                        .padding(.top, 34)

                        Text(AppCopy.aiDisclaimer)
                            .font(.caption2)
                            .foregroundStyle(Celestial.Colors.outlineVariant)
                            .padding(.top, 18)
                            .padding(.bottom, 32)
                    }
                    .padding(.horizontal, 26)
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .preferredColorScheme(.dark)
            .onAppear { smartAlbums = SmartAlbumStore.load() }
            .sheet(isPresented: $showSources) {
                NavigationStack {
                    SourceManagerView(indexingService: indexingService)
                }
            }
            .sheet(isPresented: $showDuplicates) {
                DuplicateFinderView(searchEngine: searchEngine)
            }
            .sheet(isPresented: $showUpgrade) {
                UpgradeView()
            }
            .alert("Re-index Library", isPresented: $showReindexConfirm) {
                Button("Re-index", role: .destructive) {
                    // Stop any active indexing/geocoding before clearing data
                    indexingService.stopIndexing()
                    do {
                        try database.deleteAll()
                        searchEngine.dropIndex()
                        indexingService.isReady = false
                    } catch {
                        logger.error("Failed to clear index: \(error.localizedDescription)")
                    }
                    indexingService.startIndexing()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This will clear the current index and rebuild it from scratch. Search will be unavailable during indexing.")
            }
        }
    }

    private var indexStatus: some View {
        let _ = indexingService.indexVersion
        return VStack(alignment: .leading, spacing: 0) {
            Text(indexStatusTitle)
                .font(.body.weight(.medium))
                .foregroundStyle(Celestial.Colors.onSurface)
            Text(indexStatusDetail)
                .font(.subheadline)
                .foregroundStyle(Celestial.Colors.onSurfaceVariant)
                .padding(.top, 6)

            if !indexingService.progress.isRunning && !indexingService.isReady {
                Button(indexingService.indexRebuildRequired ? "Rebuild index" : "Build index") {
                    if indexingService.indexRebuildRequired {
                        indexingService.rebuildRequiredIndex()
                    } else {
                        indexingService.startIndexing()
                    }
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Celestial.Colors.primaryDim)
                .padding(.top, 14)
            }

            if indexingService.newPhotosAvailable {
                HStack(spacing: 10) {
                    Circle()
                        .fill(Celestial.Colors.amber)
                        .frame(width: 6, height: 6)
                    Text("New photos ready to index")
                        .foregroundStyle(Celestial.Colors.amber)
                    Spacer()
                    Button("Index now") { indexingService.indexNewPhotosOnly() }
                        .fontWeight(.medium)
                        .foregroundStyle(Celestial.Colors.primaryDim)
                }
                .font(.subheadline)
                .padding(.top, 14)
            }
        }
        .padding(.bottom, 20)
        .overlay(alignment: .bottom) { CelestialHairline() }
    }

    private var indexStatusTitle: String {
        if indexingService.progress.isRunning { return "Search index updating" }
        if indexingService.isReady { return "Search index up to date" }
        if indexingService.indexRebuildRequired { return "Search index update required" }
        return "Search index not built"
    }

    private var indexStatusDetail: String {
        let searchableCount = searchEngine.indexSize + searchEngine.videoSize
        if searchableCount > 0 { return "\(searchableCount) items searchable" }
        if indexingService.indexRebuildRequired { return "Rebuild once to keep search results accurate" }
        return "Build the on-device index to start searching"
    }

    private func toolRow(icon: String, title: String, subtitle: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(Celestial.Colors.primaryDim)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.body.weight(.medium))
                    .foregroundStyle(Celestial.Colors.onSurface)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(Celestial.Colors.outline)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(Celestial.Colors.outlineVariant)
        }
        .frame(minHeight: 68)
        .contentShape(Rectangle())
        .overlay(alignment: .bottom) { CelestialHairline() }
    }

    private var proStatus: some View {
        Group {
            if proManager.isPro {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Memorable Pro")
                            .font(.body.weight(.medium))
                            .foregroundStyle(Celestial.Colors.amber)
                        Text("Unlimited indexing is active")
                            .font(.caption)
                            .foregroundStyle(Celestial.Colors.onSurfaceVariant)
                    }
                    Spacer()
                    Text("ACTIVE")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Celestial.Colors.amber)
                }
            } else {
                Button(action: { showUpgrade = true }) {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Memorable Pro")
                                .font(.body.weight(.medium))
                                .foregroundStyle(Celestial.Colors.amber)
                            Text("Unlimited indexing. One-time purchase.")
                                .font(.caption)
                                .foregroundStyle(Celestial.Colors.onSurfaceVariant)
                        }
                        Spacer()
                        Text("Upgrade")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Celestial.Colors.amber)
                    }
                }
            }
        }
        .padding(.vertical, 18)
        .overlay(alignment: .top) {
            Rectangle().fill(Celestial.Colors.amber.opacity(0.35)).frame(height: 1)
        }
        .overlay(alignment: .bottom) {
            Rectangle().fill(Celestial.Colors.amber.opacity(0.35)).frame(height: 1)
        }
    }
}

// MARK: - Smart Album Results

struct SmartAlbumResultsView: View {
    let album: SmartAlbum
    let searchEngine: SearchEngine
    @State private var results: [SearchResult] = []
    @State private var isLoading = true

    var body: some View {
        ZStack {
            Celestial.Colors.background.ignoresSafeArea()

            if isLoading {
                ProgressView()
                    .tint(Celestial.Colors.primaryDim)
            } else if results.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 36, weight: .thin))
                        .foregroundStyle(Celestial.Colors.outlineVariant)
                    Text("No matching photos found")
                        .font(.subheadline)
                        .foregroundStyle(Celestial.Colors.onSurfaceVariant)
                }
            } else {
                ScrollView {
                    SmartAlbumMasonryGrid(results: results)
                        .padding(.horizontal, 6)
                }
            }
        }
        .navigationTitle(album.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .task {
            do {
                results = Array(try await searchEngine.search(query: album.query).results.prefix(50))
            } catch {
                logger.error("Smart album search failed: \(error.localizedDescription)")
            }
            isLoading = false
        }
    }
}

struct SmartAlbumMasonryGrid: View {
    let results: [SearchResult]
    @State private var selectedPhoto: SearchResult?

    var body: some View {
        LazyVStack(spacing: 6) {
            ForEach(results) { result in
                PhotoThumbnailView(result: result)
                    .onTapGesture { selectedPhoto = result }
            }
        }
        .fullScreenCover(item: $selectedPhoto) { result in
            if result.isVideo {
                Color.clear.onAppear {
                    selectedPhoto = nil
                    if let asset = PhotoLibrary.getAsset(by: result.localIdentifier) {
                        presentVideoPlayer(for: asset)
                    }
                }
            } else {
                SearchResultsViewer(
                    initialResult: result,
                    allResults: results.filter { !$0.isVideo }
                )
            }
        }
    }
}

// MARK: - Surprise/Explore View

struct SurpriseExploreView: View {
    let searchEngine: SearchEngine
    @State private var query: String = ""
    @State private var results: [SearchResult] = []
    @State private var isLoading = false
    @State private var selectedPhoto: SearchResult?

    var body: some View {
        ZStack {
            Celestial.Colors.background.ignoresSafeArea()

            VStack(spacing: 16) {
                if results.isEmpty && !isLoading {
                    Spacer()
                    VStack(spacing: 16) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 48, weight: .thin))
                            .foregroundStyle(Celestial.Colors.primaryDim)
                        Text("Tap to discover a random memory")
                            .font(.subheadline)
                            .foregroundStyle(Celestial.Colors.onSurfaceVariant)
                        Button(action: { explore() }) {
                            Label("Surprise Me", systemImage: "sparkles")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Celestial.Colors.onPrimaryContainer)
                                .padding(.horizontal, 28)
                                .padding(.vertical, 14)
                                .background(Celestial.Colors.primaryContainer)
                                .clipShape(Capsule())
                        }
                    }
                    Spacer()
                } else if isLoading {
                    Spacer()
                    ProgressView()
                        .tint(Celestial.Colors.primaryDim)
                    Spacer()
                } else {
                    HStack {
                        Text("\"\(query)\"")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(Celestial.Colors.onSurface)
                        Spacer()
                        Button("Try Another") { explore() }
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(Celestial.Colors.primaryFixedDim)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)

                    ScrollView {
                        LazyVStack(spacing: 6) {
                            ForEach(results) { result in
                                PhotoThumbnailView(result: result)
                                    .onTapGesture { selectedPhoto = result }
                            }
                        }
                        .padding(.horizontal, 6)
                    }
                }
            }
        }
        .navigationTitle("Explore")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .fullScreenCover(item: $selectedPhoto) { result in
            if result.isVideo {
                Color.clear.onAppear {
                    selectedPhoto = nil
                    if let asset = PhotoLibrary.getAsset(by: result.localIdentifier) {
                        presentVideoPlayer(for: asset)
                    }
                }
            } else {
                SearchResultsViewer(
                    initialResult: result,
                    allResults: results.filter { !$0.isVideo }
                )
            }
        }
    }

    private func explore() {
        isLoading = true
        let surprise = SurpriseQueries.random()
        query = surprise
        Task {
            do {
                results = Array(try await searchEngine.search(query: surprise).results.prefix(20))
            } catch {
                logger.error("Explore search failed: \(error.localizedDescription)")
            }
            isLoading = false
        }
    }
}

// MARK: - Licenses View

private struct LicenseEntry: Identifiable {
    let id = UUID()
    let name: String
    let url: String
    let license: String
    let text: String
}

struct LicensesView: View {
    private let entries: [LicenseEntry] = [
        LicenseEntry(
            name: "SigLIP2",
            url: "github.com/google-research/big_vision",
            license: "Apache License 2.0",
            text: apacheLicenseText("Google LLC")
        ),
        LicenseEntry(
            name: "SentencePiece",
            url: "github.com/google/sentencepiece",
            license: "Apache License 2.0",
            text: apacheLicenseText("Google Inc.")
        ),
        LicenseEntry(
            name: "GRDB.swift",
            url: "github.com/groue/GRDB.swift",
            license: "MIT License",
            text: """
            MIT License

            Copyright (C) 2015-2026 Gwendal Roue

            Permission is hereby granted, free of charge, to any person obtaining a \
            copy of this software and associated documentation files (the "Software"), \
            to deal in the Software without restriction, including without limitation \
            the rights to use, copy, modify, merge, publish, distribute, sublicense, \
            and/or sell copies of the Software, and to permit persons to whom the \
            Software is furnished to do so, subject to the following conditions:

            The above copyright notice and this permission notice shall be included in \
            all copies or substantial portions of the Software.

            THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR \
            IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, \
            FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE \
            AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER \
            LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING \
            FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS \
            IN THE SOFTWARE.
            """
        ),
        LicenseEntry(
            name: "Swift Protobuf",
            url: "github.com/apple/swift-protobuf",
            license: "Apache License 2.0",
            text: apacheLicenseText("Apple Inc.")
        ),
    ]

    var body: some View {
        ZStack {
            Celestial.Colors.background.ignoresSafeArea()

            List {
                ForEach(entries) { entry in
                    NavigationLink {
                        LicenseDetailView(entry: entry)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(entry.name)
                                .font(.body.weight(.medium))
                                .foregroundStyle(Celestial.Colors.onSurface)
                            Text(entry.license)
                                .font(.footnote)
                                .foregroundStyle(Celestial.Colors.onSurfaceVariant)
                        }
                    }
                    .listRowBackground(Celestial.Colors.surfaceContainerHigh)
                }
            }
            .scrollContentBackground(.hidden)
        }
        .navigationTitle("Licenses")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
    }
}

private struct LicenseDetailView: View {
    let entry: LicenseEntry

    var body: some View {
        ZStack {
            Celestial.Colors.background.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(entry.url)
                        .font(.footnote)
                        .foregroundStyle(Celestial.Colors.primaryFixedDim)

                    Text(entry.text)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(Celestial.Colors.onSurfaceVariant)
                }
                .padding()
            }
        }
        .navigationTitle(entry.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
    }
}

private func apacheLicenseText(_ copyright: String) -> String {
    """
    Apache License
    Version 2.0, January 2004
    http://www.apache.org/licenses/

    Copyright \(copyright). All Rights Reserved.

    Licensed under the Apache License, Version 2.0 (the "License"); \
    you may not use this file except in compliance with the License. \
    You may obtain a copy of the License at

        http://www.apache.org/licenses/LICENSE-2.0

    Unless required by applicable law or agreed to in writing, software \
    distributed under the License is distributed on an "AS IS" BASIS, \
    WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. \
    See the License for the specific language governing permissions and \
    limitations under the License.
    """
}
