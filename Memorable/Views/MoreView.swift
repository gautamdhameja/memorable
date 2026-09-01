import SwiftUI

enum MoreNavigationPolicy {
    static func showsReindexShortcut(isReady: Bool, isIndexing: Bool) -> Bool {
        isReady && !isIndexing
    }
}

struct MoreView: View {
    @ObservedObject var indexingService: IndexingService
    let searchEngine: SearchEngine
    let captionService: PhotoCaptionService
    @ObservedObject private var proManager = ProManager.shared
    @Environment(\.database) private var database

    @State private var showSources = false
    @State private var showDuplicates = false
    @State private var showUpgrade = false
    @State private var showReindexConfirm = false
    @State private var reindexError: String?

    private var appVersionString: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "v\(version) (\(build))"
    }

    var body: some View {
        NavigationStack {
            ZStack {
                CelestialBackdrop()

                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        Text("More")
                            .font(Celestial.Typography.screenTitle)
                            .padding(.top, 14)

                        indexStatus
                            .padding(.top, 30)

                        VStack(spacing: 0) {
                            NavigationLink {
                                OnThisDayView(captionService: captionService)
                            } label: {
                                toolRow(
                                    icon: "photo.stack",
                                    title: "Memories",
                                    subtitle: "On this day and slideshows"
                                )
                            }

                            Button(action: { showDuplicates = true }) {
                                toolRow(icon: "square.on.square", title: "Find duplicates", subtitle: "Compare near-identical photos safely")
                            }
                            .disabled(
                                indexingService.progress.isRunning
                                    || !indexingService.isReady
                                    || indexingService.isThermallyPaused
                                    || !database.allowsIndexingWrites
                            )

                            Button(action: { showSources = true }) {
                                toolRow(icon: "photo.stack", title: "Photo sources", subtitle: "Library and custom folders")
                            }
                        }
                        .padding(.horizontal, 14)
                        .modifier(GlassPanelModifier(cornerRadius: 20))
                        .padding(.top, 12)

                        proStatus
                            .padding(.top, 30)

                        VStack(alignment: .leading, spacing: 0) {
                            if MoreNavigationPolicy.showsReindexShortcut(
                                isReady: indexingService.isReady,
                                isIndexing: indexingService.progress.isRunning
                            ) {
                                Button("Re-index library") { showReindexConfirm = true }
                                    .disabled(!database.allowsIndexingWrites)
                                    .frame(minHeight: 44)
                            }

                            HStack(spacing: 20) {
                                NavigationLink("Privacy") { PrivacyPolicyView() }
                                    .frame(minHeight: 44)
                                NavigationLink("Licenses") { LicensesView() }
                                    .frame(minHeight: 44)
                            }

                            Text(appVersionString)
                                .padding(.top, 2)
                        }
                        .font(Celestial.Typography.caption)
                        .foregroundStyle(Celestial.Colors.outline)
                        .padding(.top, 34)

                        Text(AppCopy.aiDisclaimer)
                            .font(Celestial.Typography.micro)
                            .foregroundStyle(Celestial.Colors.outlineVariant)
                            .padding(.top, 18)
                            .padding(.bottom, 32)
                    }
                    .padding(.horizontal, 26)
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .preferredColorScheme(.dark)
            .sheet(isPresented: $showSources) {
                NavigationStack {
                    SourceManagerView(indexingService: indexingService)
                }
            }
            .sheet(isPresented: $showDuplicates) {
                DuplicateFinderView(indexingService: indexingService)
            }
            .sheet(isPresented: $showUpgrade) {
                UpgradeView()
            }
            .alert("Re-index Library", isPresented: $showReindexConfirm) {
                Button("Re-index", role: .destructive) {
                    Task {
                        do {
                            try await indexingService.rebuildLibraryIndex()
                        } catch is CancellationError {
                            return
                        } catch {
                            logger.error("Failed to clear index: \(error.safeDiagnosticCode)")
                            reindexError = "Memorable couldn't clear the current index. Try again."
                        }
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This clears derived search data and rebuilds locally available Apple Photos. Saved folders stay registered and are indexed again when Pro is active. Search is unavailable during indexing.")
            }
            .alert(
                "Couldn't re-index",
                isPresented: Binding(
                    get: { reindexError != nil },
                    set: { if !$0 { reindexError = nil } }
                )
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(reindexError ?? "Try again.")
            }
        }
    }

    private var indexStatus: some View {
        let _ = indexingService.indexVersion
        return VStack(alignment: .leading, spacing: 0) {
            Text(indexStatusTitle)
                .font(Celestial.Typography.bodyEmphasized)
                .foregroundStyle(Celestial.Colors.onSurface)
            Text(indexStatusDetail)
                .font(Celestial.Typography.supporting)
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
                .font(Celestial.Typography.button)
                .foregroundStyle(Celestial.Colors.primaryDim)
                .padding(.top, 14)
                .disabled(!database.allowsIndexingWrites)
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
                        .disabled(!database.allowsIndexingWrites)
                }
                .font(Celestial.Typography.supporting)
                .padding(.top, 14)
            }
        }
        .padding(18)
        .modifier(GlassPanelModifier(cornerRadius: 20))
    }

    private var indexStatusTitle: String {
        if !database.allowsIndexingWrites { return "Indexing unavailable" }
        if indexingService.progress.isRunning { return "Search index updating" }
        if indexingService.isReady { return "Search index up to date" }
        if indexingService.indexRebuildRequired { return "Search index update required" }
        return "Search index not built"
    }

    private var indexStatusDetail: String {
        if !database.allowsIndexingWrites {
            return "Free storage, then close and reopen Memorable"
        }
        let searchableCount = searchEngine.indexSize + searchEngine.videoSize
        if searchableCount > 0 { return "\(searchableCount) items searchable" }
        if indexingService.indexRebuildRequired { return "Rebuild once to keep search results accurate" }
        return "Build the on-device index to start searching"
    }

    private func toolRow(icon: String, title: String, subtitle: String) -> some View {
        HStack(spacing: 14) {
            CelestialGlassIcon(systemName: icon, size: 34)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(Celestial.Typography.bodyEmphasized)
                    .foregroundStyle(Celestial.Colors.onSurface)
                Text(subtitle)
                    .font(Celestial.Typography.caption)
                    .foregroundStyle(Celestial.Colors.outline)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(Celestial.Typography.caption)
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
                            .font(Celestial.Typography.bodyEmphasized)
                            .foregroundStyle(Celestial.Colors.amber)
                        Text("All locally available media can be searched")
                            .font(Celestial.Typography.caption)
                            .foregroundStyle(Celestial.Colors.onSurfaceVariant)
                    }
                    Spacer()
                    Text("ACTIVE")
                        .font(Celestial.Typography.captionStrong)
                        .foregroundStyle(Celestial.Colors.amber)
                }
            } else {
                Button(action: { showUpgrade = true }) {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Memorable Pro")
                                .font(Celestial.Typography.bodyEmphasized)
                                .foregroundStyle(Celestial.Colors.amber)
                            Text("Search all locally available media. One-time purchase.")
                                .font(Celestial.Typography.caption)
                                .foregroundStyle(Celestial.Colors.onSurfaceVariant)
                        }
                        Spacer()
                        Text("Upgrade")
                            .font(Celestial.Typography.button)
                            .foregroundStyle(Celestial.Colors.amber)
                    }
                }
            }
        }
        .padding(18)
        .modifier(
            GlassPanelModifier(
                cornerRadius: 20,
                tint: Celestial.Colors.amber.opacity(0.10),
                interactive: !proManager.isPro
            )
        )
    }
}

struct PrivacyPolicyView: View {
    private static let policyText: String = {
        guard let url = Bundle.main.url(
            forResource: "PRIVACY_POLICY",
            withExtension: "txt"
        ) else {
            logger.error("[PrivacyPolicy] Bundled policy resource is missing")
            return "The privacy policy is unavailable. Close and reopen Memorable, then try again."
        }
        do {
            return try String(contentsOf: url, encoding: .utf8)
        } catch {
            logger.error("[PrivacyPolicy] Could not read bundled policy: \(error.safeDiagnosticCode)")
            return "The privacy policy is unavailable. Close and reopen Memorable, then try again."
        }
    }()

    var body: some View {
        ZStack {
            CelestialBackdrop()
            ScrollView {
                Text(Self.policyText)
                    .font(Celestial.Typography.body)
                    .foregroundStyle(Celestial.Colors.onSurfaceVariant)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(24)
            }
        }
        .celestialNavigationTitle("Privacy")
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
            CelestialBackdrop()

            List {
                ForEach(entries) { entry in
                    NavigationLink {
                        LicenseDetailView(entry: entry)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(entry.name)
                                .font(Celestial.Typography.bodyEmphasized)
                                .foregroundStyle(Celestial.Colors.onSurface)
                            Text(entry.license)
                                .font(Celestial.Typography.footnote)
                                .foregroundStyle(Celestial.Colors.onSurfaceVariant)
                        }
                        .padding(.vertical, 8)
                    }
                    .padding(12)
                    .modifier(GlassPanelModifier(cornerRadius: 16, interactive: true))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                }
            }
            .scrollContentBackground(.hidden)
        }
        .celestialNavigationTitle("Licenses")
    }
}

private struct LicenseDetailView: View {
    let entry: LicenseEntry

    var body: some View {
        ZStack {
            CelestialBackdrop()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(entry.url)
                        .font(Celestial.Typography.footnote)
                        .foregroundStyle(Celestial.Colors.primaryFixedDim)

                    Text(entry.text)
                        .font(Celestial.Typography.technical)
                        .foregroundStyle(Celestial.Colors.onSurfaceVariant)
                }
                .padding()
            }
        }
        .celestialNavigationTitle(entry.name)
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
