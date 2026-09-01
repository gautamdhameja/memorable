import XCTest
@testable import Memorable

final class MainTabNavigationStateTests: XCTestCase {
    func testDockUsesBalancedNativeIcons() {
        XCTAssertEqual(MainTabDestination.search.systemImage, "magnifyingglass")
        XCTAssertEqual(MainTabDestination.more.systemImage, "line.3.horizontal")
        XCTAssertEqual(PrimaryDockMetrics.iconSize, 18)
        XCTAssertEqual(PrimaryDockMetrics.iconFrame, 32)
    }

    func testDockIsCompactWithComfortableVerticalSpaceAndTouchTargets() {
        XCTAssertLessThan(PrimaryDockMetrics.totalWidth, 280)
        XCTAssertGreaterThanOrEqual(PrimaryDockMetrics.itemWidth, 72)
        XCTAssertEqual(PrimaryDockMetrics.surpriseWidth, PrimaryDockMetrics.itemWidth)
        XCTAssertGreaterThan(PrimaryDockMetrics.height, 62)
        XCTAssertLessThanOrEqual(PrimaryDockMetrics.itemSpacing, 4)
        XCTAssertGreaterThanOrEqual(PrimaryDockMetrics.horizontalPadding, 12)
    }

    func testUnavailableSurpriseIsNoOpFromMore() {
        var navigation = MainTabNavigationState(
            destination: .more,
            surpriseRequestID: 4
        )

        XCTAssertFalse(navigation.requestSurprise(isAvailable: false))
        XCTAssertEqual(navigation.destination, .more)
        XCTAssertEqual(navigation.surpriseRequestID, 4)
    }

    func testAvailableSurpriseRoutesFromMoreAndIncrementsOnce() {
        var navigation = MainTabNavigationState(destination: .more)

        XCTAssertTrue(navigation.requestSurprise(isAvailable: true))
        XCTAssertEqual(navigation.destination, .search)
        XCTAssertEqual(navigation.surpriseRequestID, 1)
    }

    func testSubsequentAvailableSurpriseInSearchIncrementsOnceAgain() {
        var navigation = MainTabNavigationState(destination: .more)
        navigation.requestSurprise(isAvailable: true)

        XCTAssertTrue(navigation.requestSurprise(isAvailable: true))
        XCTAssertEqual(navigation.destination, .search)
        XCTAssertEqual(navigation.surpriseRequestID, 2)
    }
}

final class MoreNavigationPolicyTests: XCTestCase {
    func testReindexShortcutAppearsOnlyForAReadyIdleIndex() {
        XCTAssertTrue(MoreNavigationPolicy.showsReindexShortcut(isReady: true, isIndexing: false))
        XCTAssertFalse(MoreNavigationPolicy.showsReindexShortcut(isReady: true, isIndexing: true))
        XCTAssertFalse(MoreNavigationPolicy.showsReindexShortcut(isReady: false, isIndexing: false))
        XCTAssertFalse(MoreNavigationPolicy.showsReindexShortcut(isReady: false, isIndexing: true))
    }

    func testProFeaturePolicyFailsClosedForEveryPaidCapability() {
        XCTAssertFalse(ProFeatureAccessPolicy.free.allowsFindSimilar)
        XCTAssertFalse(ProFeatureAccessPolicy.free.allowsNearDuplicateDetection)
        XCTAssertFalse(ProFeatureAccessPolicy.free.allowsFolderRefresh)
        XCTAssertFalse(SearchFeaturePolicy.basic.allowsFolderResults)

        XCTAssertTrue(ProFeatureAccessPolicy.pro.allowsFindSimilar)
        XCTAssertTrue(ProFeatureAccessPolicy.pro.allowsNearDuplicateDetection)
        XCTAssertTrue(ProFeatureAccessPolicy.pro.allowsFolderRefresh)
        XCTAssertTrue(SearchFeaturePolicy.pro.allowsFolderResults)
    }
}

final class ProjectConfigurationTests: XCTestCase {
    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    func testDeviceSigningUsesOfficialTeamByDefault() throws {
        let projectYAML = try contents(of: "project.yml")
        let buildConfigURL = repositoryRoot.appendingPathComponent("Config/Build.xcconfig")
        let buildConfig = if FileManager.default.fileExists(atPath: buildConfigURL.path) {
            try String(contentsOf: buildConfigURL, encoding: .utf8)
        } else {
            ""
        }

        XCTAssertTrue(projectYAML.contains("CODE_SIGN_STYLE: Automatic"))
        XCTAssertTrue(projectYAML.contains("DEVELOPMENT_TEAM: GHL726VCA6"))
        XCTAssertFalse(projectYAML.contains("Config/Build.xcconfig"))
        XCTAssertFalse(buildConfig.contains("CODE_SIGNING_ALLOWED = NO"))
        XCTAssertFalse(buildConfig.contains("CODE_SIGNING_REQUIRED = NO"))
    }

    func testProjectRemainsIPhoneOnly() throws {
        let projectYAML = try contents(of: "project.yml")

        XCTAssertTrue(projectYAML.contains("TARGETED_DEVICE_FAMILY: \"1\""))
        XCTAssertTrue(projectYAML.contains("SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD: \"NO\""))
    }

    func testGeneratedRunSchemeUsesReleaseConfiguration() throws {
        let projectYAML = try contents(of: "project.yml")
        let generatedScheme = try contents(
            of: "Memorable.xcodeproj/xcshareddata/xcschemes/Memorable.xcscheme"
        )

        XCTAssertTrue(projectYAML.contains("run:\n      config: Release"))
        XCTAssertTrue(
            generatedScheme.contains(
                "<LaunchAction\n      buildConfiguration = \"Release\""
            )
        )
    }

    func testBuildVerifiesBundledModelManifest() throws {
        let projectYAML = try contents(of: "project.yml")
        let premerge = try contents(of: "scripts/premerge.py")
        let manifest = try contents(of: "scripts/model_manifest.json")

        XCTAssertTrue(projectYAML.contains("Verify bundled models"))
        XCTAssertTrue(projectYAML.contains("Verify packaged models"))
        XCTAssertTrue(projectYAML.contains("scripts/verify_models.py"))
        XCTAssertTrue(projectYAML.contains("scripts/model_manifest.json"))
        XCTAssertTrue(projectYAML.contains("inputFiles:"))
        XCTAssertTrue(projectYAML.contains("outputFiles:"))
        XCTAssertTrue(projectYAML.contains("--packaged-models-root"))
        XCTAssertTrue(projectYAML.contains("basedOnDependencyAnalysis: true"))
        XCTAssertFalse(projectYAML.contains("basedOnDependencyAnalysis: false"))
        XCTAssertEqual(projectYAML.components(separatedBy: "set -eu").count - 1, 2)
        XCTAssertTrue(premerge.contains("scripts/verify_models.py"))
        XCTAssertTrue(manifest.contains("google/siglip2-base-patch16-224"))
        XCTAssertTrue(manifest.contains("Apache-2.0"))
    }

    func testPhotoSharingRequiresAnExplicitUserAction() throws {
        let sources = try allAppSourceText()
        let viewer = try contents(of: "Memorable/Views/SearchResultsViewer.swift")
        let photoSharing = try contents(of: "Memorable/Core/PhotoSharing.swift")
        let privacyPolicy = try contents(of: "PRIVACY_POLICY.txt")

        XCTAssertTrue(viewer.contains("Button(action: { shareCurrentPhoto() })"))
        XCTAssertTrue(viewer.contains("private func shareCurrentPhoto()"))
        XCTAssertTrue(viewer.contains("UIActivityViewController("))
        XCTAssertTrue(viewer.contains("activityItems: [item.fileURL]"))
        XCTAssertTrue(viewer.contains("PhotoLibrary.prepareShareItem(for: result)"))
        XCTAssertTrue(viewer.contains(".sheet(item: $shareCoordinator.preparedItem)"))
        XCTAssertTrue(viewer.contains("shareCoordinator.requestShare(for: result)"))
        XCTAssertTrue(photoSharing.contains("cancelRequest: { manager.cancelDataRequest($0) }"))
        XCTAssertEqual(
            viewer.components(separatedBy: "Button(action: { shareCurrentPhoto() })").count - 1,
            1
        )
        XCTAssertFalse(photoSharing.contains("renderMetadataStrippedShareItem"))
        XCTAssertFalse(sources.contains(".quickLookPreview"))
        XCTAssertFalse(sources.contains("UIPasteboard"))
        XCTAssertTrue(privacyPolicy.contains("only after you tap Share"))
        XCTAssertTrue(privacyPolicy.contains("choose a destination"))
        XCTAssertTrue(privacyPolicy.contains("does not choose a destination, start sharing automatically"))
    }

    func testAppSourcesDoNotCreateGeneralNetworkClients() throws {
        let sources = try allAppSourceText()

        XCTAssertFalse(sources.contains("URLSession"))
        XCTAssertFalse(sources.contains("import Network"))
        XCTAssertFalse(sources.contains("import WebKit"))
        XCTAssertFalse(sources.contains("WKWebView"))
        XCTAssertFalse(sources.contains("SFSafariViewController"))
        XCTAssertFalse(sources.contains("NWConnection"))
    }

    func testDiagnosticLogsDoNotUseUserControlledErrorDescriptions() throws {
        let unsafeLines = try allAppSourceText()
            .split(separator: "\n")
            .filter { $0.contains("logger.") && $0.contains("localizedDescription") }

        XCTAssertTrue(unsafeLines.isEmpty, "Unsafe diagnostic log lines: \(unsafeLines)")
    }

    func testAppTransportSecurityDoesNotAllowArbitraryLoads() throws {
        let infoPlist = try contents(of: "Memorable/Info.plist")

        XCTAssertTrue(infoPlist.contains("<key>NSAllowsArbitraryLoads</key>"))
        XCTAssertTrue(infoPlist.contains("<false/>"))
    }

    func testOnboardingDisclosesCoordinateGeocoding() throws {
        let onboarding = try contents(of: "Memorable/Views/OnboardingView.swift")
        let infoPlist = try contents(of: "Memorable/Info.plist")

        XCTAssertTrue(onboarding.contains("Apple resolves photo coordinates into place names"))
        XCTAssertTrue(onboarding.contains("Photos and search text stay on this iPhone unless you choose Share"))
        XCTAssertFalse(onboarding.contains("nothing is uploaded"))
        XCTAssertTrue(infoPlist.contains("GPS coordinates may be sent to Apple for place names"))
        XCTAssertTrue(infoPlist.contains("only when you tap Share"))
        XCTAssertFalse(infoPlist.contains("No photos are uploaded"))
        XCTAssertFalse(infoPlist.contains("NSLocationWhenInUseUsageDescription"))
    }

    func testInteractiveGlassButtonsDelegateToNativeButtonStyles() throws {
        let glassModifiers = try contents(of: "Memorable/Views/GlassModifiers.swift")
        let appSources = try allAppSourceText()
        let primary = try sourceSection(
            in: glassModifiers,
            from: "private struct CelestialPrimaryButtonModifier",
            to: "private struct CelestialSecondaryButtonModifier"
        )
        let secondary = try sourceSection(
            in: glassModifiers,
            from: "private struct CelestialSecondaryButtonModifier",
            to: "private struct CelestialGlassCircleButtonModifier"
        )
        let circle = try sourceSection(
            in: glassModifiers,
            from: "private struct CelestialGlassCircleButtonModifier",
            to: "private struct CelestialGlassCapsuleButtonModifier"
        )
        let capsule = try sourceSection(
            in: glassModifiers,
            from: "private struct CelestialGlassCapsuleButtonModifier",
            to: "private struct CelestialGlassCardButtonModifier"
        )
        let card = try sourceSection(
            in: glassModifiers,
            from: "private struct CelestialGlassCardButtonModifier",
            to: "extension View"
        )

        XCTAssertTrue(glassModifiers.contains("func celestialPrimaryButtonStyle("))
        XCTAssertTrue(glassModifiers.contains("func celestialSecondaryButtonStyle("))
        XCTAssertTrue(glassModifiers.contains("func celestialGlassCardButtonStyle("))
        XCTAssertTrue(primary.contains(".buttonStyle(.glassProminent)"))
        XCTAssertTrue(primary.contains(".buttonBorderShape(.roundedRectangle(radius: 13))"))
        XCTAssertTrue(secondary.contains(".buttonStyle(.glass)"))
        XCTAssertTrue(secondary.contains(".buttonBorderShape(.capsule)"))
        XCTAssertTrue(circle.contains(".buttonStyle(.glass)"))
        XCTAssertTrue(circle.contains(".buttonBorderShape(.circle)"))
        XCTAssertTrue(capsule.contains(".buttonStyle(.glass)"))
        XCTAssertTrue(capsule.contains(".buttonBorderShape(.capsule)"))
        XCTAssertTrue(card.contains(".buttonStyle(.glass)"))
        XCTAssertTrue(card.contains(".buttonBorderShape(.roundedRectangle(radius: cornerRadius))"))
        XCTAssertFalse(glassModifiers.contains("PrimitiveButtonStyle"))
        XCTAssertFalse(appSources.contains("interactive:"))
        XCTAssertFalse(appSources.contains(".interactive("))
    }

    func testUpgradeViewRequestsDeferredProductLoading() throws {
        let upgradeView = try contents(of: "Memorable/Views/UpgradeView.swift")

        XCTAssertTrue(upgradeView.contains("await proManager.loadProduct()"))
    }

    func testPrivacyPolicyIsBundledAndAccessibleSeparatelyFromLicenses() throws {
        let projectYAML = try contents(of: "project.yml")
        let moreView = try contents(of: "Memorable/Views/MoreView.swift")
        let policyURL = try XCTUnwrap(Bundle.main.url(
            forResource: "PRIVACY_POLICY",
            withExtension: "txt"
        ))
        let bundledPolicy = try String(contentsOf: policyURL, encoding: .utf8)

        XCTAssertTrue(projectYAML.contains("path: PRIVACY_POLICY.txt"))
        XCTAssertTrue(moreView.contains("NavigationLink(\"Privacy\")"))
        XCTAssertTrue(moreView.contains("PrivacyPolicyView()"))
        XCTAssertTrue(moreView.contains("NavigationLink(\"Licenses"))
        XCTAssertTrue(moreView.contains("LicensesView()"))
        XCTAssertTrue(moreView.contains("forResource: \"PRIVACY_POLICY\""))
        XCTAssertTrue(bundledPolicy.contains("The developer does not operate a backend"))
        XCTAssertTrue(bundledPolicy.contains("only after you tap Share"))
    }

    func testPrimaryNavigationHasSingleOwnersForSurpriseMemoriesAndSmartAlbums() throws {
        let mainTabView = try contents(of: "Memorable/Views/MainTabView.swift")
        let searchView = try contents(of: "Memorable/Views/SearchView.swift")
        let moreView = try contents(of: "Memorable/Views/MoreView.swift")
        let searchDock = try XCTUnwrap(mainTabView.range(of: "dockButton(.search)"))
        let surpriseDock = try XCTUnwrap(mainTabView.range(of: "SurpriseDockButton("))
        let moreDock = try XCTUnwrap(mainTabView.range(of: "dockButton(.more)"))

        XCTAssertLessThan(searchDock.lowerBound, surpriseDock.lowerBound)
        XCTAssertLessThan(surpriseDock.lowerBound, moreDock.lowerBound)
        XCTAssertTrue(mainTabView.contains("Text(\"Surprise me\")"))
        XCTAssertFalse(mainTabView.contains("case memories"))
        XCTAssertTrue(moreView.contains("OnThisDayView(captionService: captionService)"))
        XCTAssertFalse(moreView.contains("SurpriseExploreView"))
        XCTAssertFalse(moreView.contains("title: \"Smart Albums\""))
        XCTAssertFalse(moreView.contains("SmartAlbumStore"))
        XCTAssertFalse(moreView.contains("SmartAlbumResultsView"))
        XCTAssertFalse(searchView.contains("Button(action: performSurpriseSearch)"))
        XCTAssertTrue(searchView.contains("private var smartAlbumsView"))
        XCTAssertTrue(searchView.contains("ForEach(smartAlbums)"))
        XCTAssertFalse(searchView.contains("smartAlbums.prefix("))
    }

    func testUpgradeUsesOneAccessibleDismissAction() throws {
        let upgradeView = try contents(of: "Memorable/Views/UpgradeView.swift")

        XCTAssertFalse(upgradeView.contains("Button(\"Not now\")"))
        XCTAssertTrue(upgradeView.contains(".accessibilityLabel(\"Close\")"))
    }

    func testPhotoSourcesHasAVisibleExitAndInlineTitle() throws {
        let sourceManager = try contents(of: "Memorable/Views/SourceManagerView.swift")
        let theme = try contents(of: "Memorable/Views/Theme.swift")

        XCTAssertTrue(sourceManager.contains("@Environment(\\.dismiss) private var dismiss"))
        XCTAssertTrue(sourceManager.contains("Button(\"Done\") { dismiss() }"))
        XCTAssertTrue(sourceManager.contains(".celestialNavigationTitle(\"Photo Sources\")"))
        XCTAssertTrue(theme.contains(".navigationBarTitleDisplayMode(.inline)"))
        XCTAssertTrue(theme.contains(".toolbar(.visible, for: .navigationBar)"))
    }

    func testPushedScreensCannotBypassTheSharedNavigationPolicy() throws {
        let sources = try allAppSourceText()

        XCTAssertEqual(
            sources.components(separatedBy: ".navigationTitle(").count - 1,
            1,
            "Navigation titles must go through celestialNavigationTitle so a hidden parent bar cannot strand a child screen"
        )
    }

    func testBrandTypographyOutranksSecondaryScreenTitles() throws {
        let theme = try contents(of: "Memorable/Views/Theme.swift")
        let moreView = try contents(of: "Memorable/Views/MoreView.swift")

        XCTAssertTrue(theme.contains("static let brand = Font.system(.title, design: .serif"))
        XCTAssertTrue(theme.contains("static let screenTitle = Font.system(.title2, design: .default"))
        XCTAssertTrue(moreView.contains(".font(Celestial.Typography.screenTitle)"))
    }

    func testInitialIndexingUsesMemoryFirstHierarchyWithoutSearch() throws {
        let searchView = try contents(of: "Memorable/Views/SearchView.swift")
        let initialVisibilitySection = try sourceSection(
            in: searchView,
            from: "if !indexingService.shouldShowInitialIndexingExperience",
            to: "// Database warning"
        )

        XCTAssertTrue(initialVisibilitySection.contains("searchBar"))
        XCTAssertEqual(searchView.components(separatedBy: "searchBar\n").count - 1, 1)
        XCTAssertTrue(searchView.contains("YOUR LIBRARY IS COMING TO LIFE"))
        XCTAssertTrue(searchView.contains(
            "While we build your search, revisit a few moments."
        ))
        XCTAssertTrue(searchView.contains(
            ".font(Celestial.Typography.compactMemoryCaption)"
        ))
        XCTAssertTrue(searchView.contains(
            "InitialIndexingProgressView(indexingService: indexingService)"
        ))
        XCTAssertTrue(searchView.contains("presentation: .initialIndexing"))
        let indexingBanner = try contents(of: "Memorable/Views/IndexingBannerView.swift")
        let initialProgress = try sourceSection(
            in: indexingBanner,
            from: "struct InitialIndexingProgressView",
            to: ".accessibilityElement(children: .contain)"
        )
        XCTAssertTrue(initialProgress.contains(".frame(minWidth: 44, minHeight: 44)"))
    }

    func testSearchResultsToolbarUsesConciseHierarchy() throws {
        let searchView = try contents(of: "Memorable/Views/SearchView.swift")
        let toolbar = try sourceSection(
            in: searchView,
            from: "private func controlsPanel(filteredCount: Int)",
            to: "private func interpretedQueryFacets"
        )

        XCTAssertFalse(toolbar.contains("Search details understood from your description"))
        XCTAssertFalse(toolbar.contains("structuredQuerySentence"))
        XCTAssertTrue(toolbar.contains("systemImage: \"arrow.up.arrow.down\""))
        XCTAssertTrue(toolbar.contains("Image(systemName: \"bookmark\")"))
        XCTAssertTrue(toolbar.contains("ForEach(SearchMediaFilter.allCases"))
        XCTAssertTrue(toolbar.contains(".frame(minHeight: 44)"))
        XCTAssertTrue(toolbar.contains(".celestialGlassCapsuleButtonStyle("))
        XCTAssertTrue(toolbar.contains(".celestialGlassCircleButtonStyle("))

        let facets = try sourceSection(
            in: searchView,
            from: "private func queryFacet(",
            to: "private func resultsGrid("
        )
        XCTAssertTrue(facets.contains("GlassCapsuleModifier("))
    }

    func testValidatedSuggestionsAreExclusiveWithSearchHistory() throws {
        let searchView = try contents(of: "Memorable/Views/SearchView.swift")
        let homeView = try sourceSection(
            in: searchView,
            from: "private var homeView: some View",
            to: "private var validatedSuggestionsView: some View"
        )

        XCTAssertTrue(homeView.contains(
            "canShowValidatedSuggestions && viewModel.shouldShowDiscoverySuggestions"
        ))
    }

    func testStartupChecksExistingIndexInsideHomeScreen() throws {
        let appState = try contents(of: "Memorable/MemorableApp.swift")
        let searchView = try contents(of: "Memorable/Views/SearchView.swift")
        let mainTabView = try contents(of: "Memorable/Views/MainTabView.swift")
        let warmup = try sourceSection(
            in: appState,
            from: "private func warmCoreSearch(priority:",
            to: "static func resumeExistingSearchForWarmup"
        )

        XCTAssertTrue(appState.contains(
            "@Published private(set) var indexingService: IndexingService?"
        ))
        XCTAssertTrue(searchView.contains("semanticRuntime.isCheckingIndexAvailability"))
        XCTAssertTrue(searchView.contains("Loading your library…"))
        XCTAssertFalse(mainTabView.contains("Ready to index your photos"))

        let markChecking = try XCTUnwrap(warmup.range(of: "semanticRuntime.markIndexWarming"))
        let verifyEntitlement = try XCTUnwrap(warmup.range(of: "await ProManager.shared.verifyEntitlement()"))
        XCTAssertLessThan(markChecking.lowerBound, verifyEntitlement.lowerBound)
    }

    func testViewsUseSemanticTypographyRoles() throws {
        let sources = try allSourceText(in: "Memorable/Views")
        let forbiddenFonts = [
            ".font(.body)",
            ".font(.subheadline)",
            ".font(.caption)",
            ".font(.caption2)",
            ".font(.footnote)",
        ]

        for font in forbiddenFonts {
            XCTAssertFalse(sources.contains(font), "Use a Celestial typography role instead of \(font)")
        }
    }

    func testPhotoControlsUseButtonsAndTextControlsCanGrow() throws {
        let searchView = try contents(of: "Memorable/Views/SearchView.swift")
        let moreView = try contents(of: "Memorable/Views/MoreView.swift")
        let memoriesView = try contents(of: "Memorable/Views/OnThisDayView.swift")

        XCTAssertFalse(searchView.contains("PhotoThumbnailView(result: result)\n            .onTapGesture"))
        XCTAssertFalse(moreView.contains("PhotoThumbnailView(result: result)\n                    .onTapGesture"))
        XCTAssertFalse(memoriesView.contains(".accessibilityAddTraits(.isButton)\n        .onTapGesture"))
        XCTAssertTrue(searchView.contains(".frame(minHeight: 52)"))
        XCTAssertGreaterThanOrEqual(PrimaryDockMetrics.height, 62)
    }

    func testAppStoreTextFieldsMeetCurrentLimitsAndVersion() throws {
        let metadata = try contents(of: "APP_STORE_METADATA.txt")
        let subtitle = try metadataValue(prefix: "Subtitle: ", in: metadata)
        let keywords = try metadataValue(prefix: "Keywords: ", in: metadata)

        XCTAssertLessThanOrEqual(subtitle.lengthOfBytes(using: .utf8), 30)
        XCTAssertLessThanOrEqual(keywords.lengthOfBytes(using: .utf8), 100)
        XCTAssertTrue(metadata.contains("What's new in version 1.0.2"))
    }

    func testPreservedFoldersResumeAfterRebuildAndProRestore() throws {
        let service = try contents(of: "Memorable/Core/IndexingService.swift")
        let worker = try contents(of: "Memorable/Core/FolderIndexingWorker.swift")

        XCTAssertTrue(service.contains("ProManager.shared.$isPro"))
        XCTAssertGreaterThanOrEqual(
            service.components(separatedBy: "enqueueSavedFolderReindexingIfNeeded()").count - 1,
            2,
            "Saved folders must resume both after library rebuilds and after Pro restoration"
        )
        XCTAssertTrue(worker.contains("func reindex("))
        XCTAssertTrue(worker.contains("source: PhotoSource"))
        XCTAssertTrue(service.contains("func reindexFolderSource(_ source: PhotoSource)"))
    }

    private func contents(of relativePath: String) throws -> String {
        try String(
            contentsOf: repositoryRoot.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }

    private func sourceSection(
        in source: String,
        from startMarker: String,
        to endMarker: String
    ) throws -> Substring {
        let start = try XCTUnwrap(source.range(of: startMarker))
        let end = try XCTUnwrap(
            source.range(of: endMarker, range: start.upperBound..<source.endIndex)
        )
        return source[start.lowerBound..<end.lowerBound]
    }

    private func metadataValue(prefix: String, in metadata: String) throws -> String {
        let line = try XCTUnwrap(metadata.split(separator: "\n").first {
            $0.hasPrefix(prefix)
        })
        return String(line.dropFirst(prefix.count))
    }

    private func allAppSourceText() throws -> String {
        try allSourceText(in: "Memorable")
    }

    private func allSourceText(in relativePath: String) throws -> String {
        let sourceRoot = repositoryRoot.appendingPathComponent(relativePath)
        guard let enumerator = FileManager.default.enumerator(
            at: sourceRoot,
            includingPropertiesForKeys: nil
        ) else {
            XCTFail("Unable to enumerate app sources")
            return ""
        }

        return try enumerator
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" }
            .map { try String(contentsOf: $0, encoding: .utf8) }
            .joined(separator: "\n")
    }
}
