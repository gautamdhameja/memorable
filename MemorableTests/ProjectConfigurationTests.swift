import XCTest
@testable import Memorable

final class MainTabNavigationStateTests: XCTestCase {
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

    func testPrimaryDockCentersSurpriseAndKeepsMemoriesInMore() throws {
        let mainTabView = try contents(of: "Memorable/Views/MainTabView.swift")
        let searchView = try contents(of: "Memorable/Views/SearchView.swift")
        let moreView = try contents(of: "Memorable/Views/MoreView.swift")
        let searchDock = try XCTUnwrap(mainTabView.range(of: "dockButton(.search)"))
        let surpriseDock = try XCTUnwrap(mainTabView.range(of: "SurpriseDockButton("))
        let moreDock = try XCTUnwrap(mainTabView.range(of: "dockButton(.more)"))

        XCTAssertLessThan(searchDock.lowerBound, surpriseDock.lowerBound)
        XCTAssertLessThan(surpriseDock.lowerBound, moreDock.lowerBound)
        XCTAssertFalse(mainTabView.contains("case memories"))
        XCTAssertTrue(moreView.contains("OnThisDayView(captionService: captionService)"))
        XCTAssertFalse(moreView.contains("SurpriseExploreView"))
        XCTAssertFalse(searchView.contains("Button(action: performSurpriseSearch)"))
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

    private func metadataValue(prefix: String, in metadata: String) throws -> String {
        let line = try XCTUnwrap(metadata.split(separator: "\n").first {
            $0.hasPrefix(prefix)
        })
        return String(line.dropFirst(prefix.count))
    }

    private func allAppSourceText() throws -> String {
        let sourceRoot = repositoryRoot.appendingPathComponent("Memorable")
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
