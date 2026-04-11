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

                List {
                    // New photos available
                    if indexingService.newPhotosAvailable {
                        Section {
                            Button(action: {
                                indexingService.indexNewPhotosOnly()
                            }) {
                                HStack(spacing: 12) {
                                    Image(systemName: "photo.badge.plus")
                                        .foregroundStyle(Celestial.Colors.amber)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("New photos found")
                                            .font(.body.weight(.medium))
                                            .foregroundStyle(Celestial.Colors.onSurface)
                                        Text("Tap to index new photos")
                                            .font(.footnote)
                                            .foregroundStyle(Celestial.Colors.onSurfaceVariant)
                                    }
                                    Spacer()
                                    Image(systemName: "arrow.clockwise")
                                        .foregroundStyle(Celestial.Colors.amber)
                                }
                            }
                            .listRowBackground(Celestial.Colors.amber.opacity(0.1))
                        }
                    }

                    // Smart Albums
                    Section {
                        if smartAlbums.isEmpty {
                            Text("No smart albums yet")
                                .font(.subheadline)
                                .foregroundStyle(Celestial.Colors.outline)
                                .listRowBackground(Celestial.Colors.surfaceContainerHigh)
                        } else {
                            let visibleAlbums = showAllAlbums ? smartAlbums : Array(smartAlbums.prefix(4))
                            ForEach(visibleAlbums) { album in
                                NavigationLink {
                                    SmartAlbumResultsView(album: album, searchEngine: searchEngine)
                                } label: {
                                    HStack(spacing: 12) {
                                        Image(systemName: "rectangle.stack.fill")
                                            .foregroundStyle(Celestial.Colors.primaryDim)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(album.name)
                                                .font(.body.weight(.medium))
                                                .foregroundStyle(Celestial.Colors.onSurface)
                                            Text(album.query)
                                                .font(.footnote)
                                                .foregroundStyle(Celestial.Colors.onSurfaceVariant)
                                        }
                                    }
                                }
                                .listRowBackground(Celestial.Colors.surfaceContainerHigh)
                            }
                            .onDelete { offsets in
                                let visible = showAllAlbums ? smartAlbums : Array(smartAlbums.prefix(4))
                                for offset in offsets {
                                    SmartAlbumStore.delete(id: visible[offset].id)
                                }
                                smartAlbums = SmartAlbumStore.load()
                            }

                            if smartAlbums.count > 4 {
                                Button {
                                    withAnimation { showAllAlbums.toggle() }
                                } label: {
                                    Text(showAllAlbums ? "Show Less" : "Show All (\(smartAlbums.count))")
                                        .font(.footnote.weight(.medium))
                                        .foregroundStyle(Celestial.Colors.primaryFixedDim)
                                }
                                .listRowBackground(Celestial.Colors.surfaceContainerHigh)
                            }
                        }
                    } header: {
                        Text("Smart Albums")
                    }

                    // Discover
                    Section {
                        NavigationLink {
                            SurpriseExploreView(searchEngine: searchEngine)
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "sparkles")
                                    .foregroundStyle(Celestial.Colors.primaryDim)
                                Text("Explore & Discover")
                                    .font(.body.weight(.medium))
                                    .foregroundStyle(Celestial.Colors.onSurface)
                            }
                        }
                        .listRowBackground(Celestial.Colors.surfaceContainerHigh)
                    } header: {
                        Text("Discover")
                    }

                    // Tools
                    Section {
                        Button(action: { showSources = true }) {
                            HStack(spacing: 12) {
                                Image(systemName: "folder.badge.gearshape")
                                    .foregroundStyle(Celestial.Colors.primaryDim)
                                Text("Photo Sources")
                                    .font(.body.weight(.medium))
                                    .foregroundStyle(Celestial.Colors.onSurface)
                            }
                        }
                        .listRowBackground(Celestial.Colors.surfaceContainerHigh)

                        Button(action: { showDuplicates = true }) {
                            HStack(spacing: 12) {
                                Image(systemName: "doc.on.doc")
                                    .foregroundStyle(Celestial.Colors.primaryDim)
                                Text("Find Duplicates")
                                    .font(.body.weight(.medium))
                                    .foregroundStyle(Celestial.Colors.onSurface)
                            }
                        }
                        .listRowBackground(Celestial.Colors.surfaceContainerHigh)
                    } header: {
                        Text("Tools")
                    }

                    // Index Management
                    Section {
                        HStack(spacing: 12) {
                            Image(systemName: "photo.on.rectangle")
                                .foregroundStyle(Celestial.Colors.primaryDim)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Search Index")
                                    .font(.body.weight(.medium))
                                    .foregroundStyle(Celestial.Colors.onSurface)
                                let _ = indexingService.indexVersion // trigger re-render on index reload
                                Text("\(searchEngine.indexSize) photos, \(searchEngine.videoSize) videos indexed")
                                    .font(.footnote)
                                    .foregroundStyle(Celestial.Colors.onSurfaceVariant)
                            }
                        }
                        .listRowBackground(Celestial.Colors.surfaceContainerHigh)

                        Button(action: { showReindexConfirm = true }) {
                            HStack(spacing: 12) {
                                Image(systemName: "arrow.clockwise")
                                    .foregroundStyle(Celestial.Colors.primaryDim)
                                Text("Re-index Library")
                                    .font(.body.weight(.medium))
                                    .foregroundStyle(Celestial.Colors.onSurface)
                            }
                        }
                        .listRowBackground(Celestial.Colors.surfaceContainerHigh)
                    } header: {
                        Text("Index")
                    }

                    // Pro
                    Section {
                        if proManager.isPro {
                            HStack(spacing: 12) {
                                Image(systemName: "sparkles")
                                    .foregroundStyle(Celestial.Colors.primaryDim)
                                Text("Memorable Pro")
                                    .font(.body.weight(.medium))
                                    .foregroundStyle(Celestial.Colors.onSurface)
                                Spacer()
                                Text("ACTIVE")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(Celestial.Colors.onPrimaryContainer)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(Celestial.Colors.primaryContainer)
                                    .clipShape(Capsule())
                            }
                            .listRowBackground(Celestial.Colors.surfaceContainerHigh)
                        } else {
                            Button(action: { showUpgrade = true }) {
                                HStack(spacing: 12) {
                                    Image(systemName: "sparkles")
                                        .foregroundStyle(Celestial.Colors.primaryDim)
                                    Text("Upgrade to Pro")
                                        .font(.body.weight(.medium))
                                        .foregroundStyle(Celestial.Colors.onSurface)
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.footnote)
                                        .foregroundStyle(Celestial.Colors.outlineVariant)
                                }
                            }
                            .listRowBackground(Celestial.Colors.surfaceContainerHigh)
                        }
                    } header: {
                        Text("Pro")
                    }

                    // About
                    Section {
                        HStack(spacing: 12) {
                            Image(systemName: "lock.shield")
                                .foregroundStyle(Celestial.Colors.outlineVariant)
                            Text("Private, on-device processing")
                                .font(.footnote)
                                .foregroundStyle(Celestial.Colors.onSurfaceVariant)
                        }
                        .listRowBackground(Celestial.Colors.surfaceContainerHigh)

                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: "sparkles")
                                .foregroundStyle(Celestial.Colors.outlineVariant)
                            Text(AppCopy.aiDisclaimer)
                                .font(.footnote)
                                .foregroundStyle(Celestial.Colors.onSurfaceVariant)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .listRowBackground(Celestial.Colors.surfaceContainerHigh)

                        HStack(spacing: 12) {
                            Image(systemName: "info.circle")
                                .foregroundStyle(Celestial.Colors.outlineVariant)
                            Text("Memorable \(appVersionString)")
                                .font(.footnote)
                                .foregroundStyle(Celestial.Colors.onSurfaceVariant)
                        }
                        .listRowBackground(Celestial.Colors.surfaceContainerHigh)

                        HStack(spacing: 12) {
                            Image(systemName: "building.2")
                                .foregroundStyle(Celestial.Colors.outlineVariant)
                            Text("Built by BlockDeep Labs")
                                .font(.footnote)
                                .foregroundStyle(Celestial.Colors.onSurfaceVariant)
                        }
                        .listRowBackground(Celestial.Colors.surfaceContainerHigh)
                    } header: {
                        Text("About")
                    }
                }
                .scrollContentBackground(.hidden)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    HStack(spacing: 10) {
                        Image("AppIconTransparent")
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 36, height: 36)
                        Text("More")
                            .font(.system(.title3, design: .rounded, weight: .semibold))
                            .foregroundStyle(Celestial.Colors.onSurface)
                    }
                }
            }
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
