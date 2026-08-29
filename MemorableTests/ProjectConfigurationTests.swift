import XCTest

final class ProjectConfigurationTests: XCTestCase {
    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    func testSigningIsLocalAndUnsignedByDefault() throws {
        let projectYAML = try contents(of: "project.yml")
        let buildConfig = try contents(of: "Config/Build.xcconfig")
        let gitignore = try contents(of: ".gitignore")

        XCTAssertFalse(projectYAML.contains("DEVELOPMENT_TEAM:"))
        XCTAssertFalse(projectYAML.contains("CODE_SIGN_IDENTITY: Apple Development"))
        XCTAssertTrue(projectYAML.contains("Config/Build.xcconfig"))
        XCTAssertTrue(buildConfig.contains("CODE_SIGNING_ALLOWED = NO"))
        XCTAssertTrue(buildConfig.contains("#include? \"Local.xcconfig\""))
        XCTAssertTrue(gitignore.contains("Config/Local.xcconfig"))
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
        let photoLibrary = try contents(of: "Memorable/Core/PhotoLibrary.swift")
        let privacyPolicy = try contents(of: "PRIVACY_POLICY.txt")

        XCTAssertTrue(viewer.contains("Button(action: { shareCurrentPhoto() })"))
        XCTAssertTrue(viewer.contains("private func shareCurrentPhoto()"))
        XCTAssertTrue(viewer.contains("UIActivityViewController("))
        XCTAssertTrue(viewer.contains("activityItems: [item.fileURL]"))
        XCTAssertTrue(viewer.contains("PhotoLibrary.prepareShareItem(for: result)"))
        XCTAssertTrue(viewer.contains(".sheet(item: $shareCoordinator.preparedItem)"))
        XCTAssertTrue(viewer.contains("shareCoordinator.requestShare(for: result)"))
        XCTAssertTrue(photoLibrary.contains("cancelRequest: { manager.cancelDataRequest($0) }"))
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

        XCTAssertTrue(onboarding.contains("Apple resolves photo coordinates into place names"))
        XCTAssertTrue(onboarding.contains("Photos and search text stay on this iPhone unless you choose Share"))
        XCTAssertFalse(onboarding.contains("nothing is uploaded"))
    }

    func testUpgradeViewRequestsDeferredProductLoading() throws {
        let upgradeView = try contents(of: "Memorable/Views/UpgradeView.swift")

        XCTAssertTrue(upgradeView.contains("await proManager.loadProduct()"))
    }

    private func contents(of relativePath: String) throws -> String {
        try String(
            contentsOf: repositoryRoot.appendingPathComponent(relativePath),
            encoding: .utf8
        )
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
