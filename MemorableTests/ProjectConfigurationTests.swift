import XCTest
@testable import Memorable

final class MainTabNavigationStateTests: XCTestCase {
    func testDockUsesBalancedNativeIcons() {
        XCTAssertEqual(MainTabDestination.search.systemImage, "magnifyingglass")
        XCTAssertEqual(MainTabDestination.more.systemImage, "ellipsis.circle")
        XCTAssertEqual(PrimaryDockMetrics.iconSize, 20)
        XCTAssertEqual(PrimaryDockMetrics.iconFrame, 30)
    }

    func testDockIsWideWithComfortableVerticalSpaceAndTouchTargets() {
        XCTAssertGreaterThanOrEqual(PrimaryDockMetrics.totalWidth, 320)
        XCTAssertLessThanOrEqual(PrimaryDockMetrics.totalWidth, 340)
        XCTAssertGreaterThanOrEqual(PrimaryDockMetrics.itemWidth, 96)
        XCTAssertEqual(PrimaryDockMetrics.surpriseWidth, PrimaryDockMetrics.itemWidth)
        XCTAssertGreaterThanOrEqual(PrimaryDockMetrics.height, 70)
        XCTAssertEqual(PrimaryDockMetrics.itemSpacing, 0)
        XCTAssertGreaterThanOrEqual(PrimaryDockMetrics.horizontalPadding, 14)
        XCTAssertLessThanOrEqual(PrimaryDockMetrics.outerInset, 6)
        XCTAssertLessThanOrEqual(PrimaryDockMetrics.outerGlassTintOpacity, 0.20)
        XCTAssertLessThanOrEqual(PrimaryDockMetrics.selectionGlassTintOpacity, 0.16)
        XCTAssertLessThanOrEqual(PrimaryDockMetrics.backdropOpacity, 0.60)
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

    func testRetappingSelectedSearchRequestsSearchHome() {
        var navigation = MainTabNavigationState(
            destination: .search,
            searchHomeRequestID: 7
        )

        XCTAssertTrue(navigation.requestSearchHome())
        XCTAssertEqual(navigation.destination, .search)
        XCTAssertEqual(navigation.searchHomeRequestID, 8)
    }

    func testSearchHomeRequestIsIgnoredOutsideSearch() {
        var navigation = MainTabNavigationState(
            destination: .more,
            searchHomeRequestID: 7
        )

        XCTAssertFalse(navigation.requestSearchHome())
        XCTAssertEqual(navigation.destination, .more)
        XCTAssertEqual(navigation.searchHomeRequestID, 7)
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

    func testSigningConfigurationUsesSafeLocalOverridesAndAutomatedGuard() throws {
        let projectYAML = try contents(of: "project.yml")
        let buildConfig = try contents(of: "Config/Build.xcconfig")
        let localConfigExample = try contents(of: "Config/Local.xcconfig.example")
        let gitignore = try contents(of: ".gitignore")
        let premerge = try contents(of: "scripts/premerge.py")
        let signingGuard = try contents(of: "scripts/signing_hygiene.py")
        let credentialPatterns = [
            "*.p12",
            "*.cer",
            "*.certSigningRequest",
            "*.mobileprovision",
            "AuthKey_*.p8",
            "*.p8",
            "ExportOptions.plist",
            ".env",
            "Config/Local.xcconfig",
        ]

        XCTAssertTrue(projectYAML.contains("CODE_SIGN_STYLE: Automatic"))
        XCTAssertTrue(projectYAML.contains("DEVELOPMENT_TEAM:"))
        XCTAssertEqual(
            projectYAML.components(separatedBy: "Config/Build.xcconfig").count - 1,
            3
        )
        XCTAssertEqual(
            buildConfig.trimmingCharacters(in: .whitespacesAndNewlines),
            #"#include? "Local.xcconfig""#
        )
        XCTAssertFalse(buildConfig.contains("CODE_SIGNING_ALLOWED = NO"))
        XCTAssertFalse(buildConfig.contains("CODE_SIGNING_REQUIRED = NO"))
        XCTAssertTrue(localConfigExample.contains("DEVELOPMENT_TEAM = YOUR_TEAM_ID"))
        XCTAssertTrue(localConfigExample.contains("CODE_SIGNING_ALLOWED = YES"))
        for pattern in credentialPatterns {
            XCTAssertTrue(gitignore.contains(pattern), "Missing signing ignore: \(pattern)")
        }
        XCTAssertTrue(premerge.contains("scripts/signing_hygiene.py"))
        XCTAssertTrue(signingGuard.contains("git\", \"ls-files\", \"-z"))
        XCTAssertTrue(signingGuard.contains("git\", \"check-ignore"))
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

    func testInitialIndexingRegistersPermittedProcessingModes() throws {
        let infoPlist = try contents(of: "Memorable/Info.plist")
        let app = try contents(of: "Memorable/MemorableApp.swift")
        let controller = try contents(of: "Memorable/Core/BackgroundIndexingController.swift")
        let appDelegate = try sourceSection(
            in: controller,
            from: "final class MemorableAppDelegate",
            to: "    }\n}"
        )

        XCTAssertTrue(infoPlist.contains("<key>BGTaskSchedulerPermittedIdentifiers</key>"))
        XCTAssertTrue(infoPlist.contains("$(PRODUCT_BUNDLE_IDENTIFIER).indexing.processing"))
        XCTAssertTrue(infoPlist.contains("$(PRODUCT_BUNDLE_IDENTIFIER).indexing.continued.*"))
        XCTAssertTrue(infoPlist.contains("<key>UIBackgroundModes</key>"))
        XCTAssertTrue(infoPlist.contains("<string>processing</string>"))
        XCTAssertTrue(app.contains("@UIApplicationDelegateAdaptor(MemorableAppDelegate.self)"))
        XCTAssertTrue(appDelegate.contains("didFinishLaunchingWithOptions"))
        XCTAssertTrue(appDelegate.contains(
            "BackgroundIndexingController.shared.registerLaunchHandlers()"
        ))
        XCTAssertTrue(controller.contains("BGProcessingTaskRequest"))
        XCTAssertTrue(controller.contains("BGContinuedProcessingTaskRequest"))
        XCTAssertTrue(controller.contains("BackgroundIndexingIdentifiers.continued("))
        XCTAssertTrue(
            controller.contains("ContinuedProcessingRegistration.registerAndSubmit"),
            "Continued-processing registration and submission must use the tested ordering contract"
        )
        XCTAssertFalse(
            controller.contains("forTaskWithIdentifier: continuedWildcardIdentifier"),
            "The continued-processing wildcard is only a plist permission pattern; register a concrete identifier"
        )
    }

    func testReleaseChecklistRequiresPhysicalDeviceBackgroundTaskVerification() throws {
        let checklist = try contents(of: "RELEASE_MANUAL_CHECKLIST.md")

        XCTAssertTrue(checklist.contains("physical device"))
        XCTAssertTrue(checklist.contains("iOS 17"))
        XCTAssertTrue(checklist.contains("iOS 26"))
        XCTAssertTrue(checklist.contains("_simulateLaunchForTaskWithIdentifier"))
        XCTAssertTrue(checklist.contains("_simulateExpirationForTaskWithIdentifier"))
        XCTAssertTrue(checklist.contains("com.blockdeep.memorable.indexing.processing"))
    }

    func testScheduledIndexingLaunchDoesNotHydrateInteractiveSearchStack() throws {
        let app = try contents(of: "Memorable/MemorableApp.swift")
        let indexingService = try contents(of: "Memorable/Core/IndexingService.swift")
        let resume = try sourceSection(
            in: app,
            from: "private func resumeInitialIndexingForSystemTask()",
            to: "private func initialize("
        )
        let preparation = try sourceSection(
            in: app,
            from: "private func prepareIndexingStackForBackground()",
            to: "static func resumeExistingSearchForWarmup"
        )

        XCTAssertTrue(resume.contains("startsSemanticWarmup: false"))
        XCTAssertTrue(resume.contains("prepareIndexingStackForBackground()"))
        XCTAssertTrue(resume.contains("BackgroundIndexingLaunchEligibility.terminalResult"))
        XCTAssertTrue(resume.contains("return .retryableFailure"))
        XCTAssertTrue(preparation.contains("ImageEncoder()"))
        XCTAssertTrue(preparation.contains("SearchEngine(database: database)"))
        XCTAssertFalse(preparation.contains("TextEncoder()"))
        XCTAssertFalse(preparation.contains("checkAndLoadExistingIndex"))
        XCTAssertFalse(preparation.contains("startCaptionPreparation"))
        let workerReload = try sourceSection(
            in: indexingService,
            from: "private func reloadSearchIndexFromLibraryWorker()",
            to: "private func scheduleForegroundInitialIndexingResumeIfNeeded()"
        )
        XCTAssertTrue(workerReload.contains("guard isApplicationActive else"))
        XCTAssertTrue(workerReload.contains("hasDeferredSearchIndexReload = true"))
    }

    func testForegroundingColdBackgroundLaunchStartsSemanticWarmup() throws {
        let app = try contents(of: "Memorable/MemorableApp.swift")
        let lifecycle = try sourceSection(
            in: app,
            from: "func setApplicationActive(_ isActive: Bool)",
            to: "private func resumeInitialIndexingForSystemTask()"
        )

        XCTAssertTrue(lifecycle.contains("ForegroundSemanticWarmupPolicy.shouldStart"))
        XCTAssertTrue(lifecycle.contains("semanticRuntime.startPostPaintWarmup()"))
    }

    func testForegroundWarmupWaitsForSuccessfulBackgroundPreparation() throws {
        let app = try contents(of: "Memorable/MemorableApp.swift")
        let warmup = try sourceSection(
            in: app,
            from: "private func warmCoreSearch(priority:",
            to: "private func prepareIndexingStackForBackground()"
        )
        let preparation = try sourceSection(
            in: app,
            from: "private func prepareIndexingStackForBackground()",
            to: "private func performBackgroundIndexingPreparation()"
        )

        XCTAssertTrue(warmup.contains("waitForBackgroundIndexingPreparationCleanup()"))
        XCTAssertTrue(warmup.contains("while isCoreWarmupRunning"))
        XCTAssertTrue(warmup.contains("try Task.checkCancellation()"))
        XCTAssertTrue(warmup.contains("await Task.yield()"))
        XCTAssertTrue(preparation.contains(
            "restartForegroundWarmupAfterBackgroundPreparationIfNeeded()"
        ))
        XCTAssertTrue(preparation.contains("catch {"))
        XCTAssertFalse(
            preparation.components(separatedBy: "catch {").last?.contains(
                "restartForegroundWarmupAfterBackgroundPreparationIfNeeded()"
            ) ?? true,
            "Failed background preparation must not enter a warmup retry loop"
        )
    }

    func testMemoryWarningCancelsBackgroundIndexingPreparation() throws {
        let app = try contents(of: "Memorable/MemorableApp.swift")
        let memoryWarning = try sourceSection(
            in: app,
            from: "func handleMemoryWarning()",
            to: "func retrySemanticWarmup()"
        )

        XCTAssertTrue(memoryWarning.contains("backgroundIndexingPreparationTask?.cancel()"))
        XCTAssertFalse(memoryWarning.contains("backgroundIndexingPreparationTask = nil"))
        let cleanup = try sourceSection(
            in: app,
            from: "private func waitForBackgroundIndexingPreparationCleanup()",
            to: "private func performBackgroundIndexingPreparation()"
        )
        XCTAssertTrue(cleanup.contains("while let preparationTask"))
        XCTAssertTrue(cleanup.contains("catch is CancellationError"))
        XCTAssertTrue(cleanup.contains("try await preparationTask.value"))
        XCTAssertTrue(cleanup.contains("try Task.checkCancellation()"))
        XCTAssertTrue(cleanup.contains("await Task.yield()"))
    }

    func testOnboardingStartPreservesOnlyTheLiveForegroundGesture() throws {
        let app = try contents(of: "Memorable/MemorableApp.swift")
        let content = try contents(of: "Memorable/Views/ContentView.swift")
        let indexing = try contents(of: "Memorable/Core/IndexingService.swift")

        XCTAssertTrue(content.contains("startIndexAfterCompletion: onboardingIndexRequestBinding"))
        XCTAssertTrue(content.contains("isForeground: scenePhase == .active"))
        XCTAssertTrue(app.contains("foregroundOnboardingIndexIntent.consume()"))
        XCTAssertTrue(app.contains(
            "startInitialIndexingFromOnboarding(isUserInitiated: isUserInitiated)"
        ))
        XCTAssertTrue(indexing.contains(
            "func startInitialIndexingFromOnboarding(isUserInitiated: Bool)"
        ))
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

    func testSharedGlassSurfacesUseThePremiumChromeLayer() throws {
        let glassModifiers = try contents(of: "Memorable/Views/GlassModifiers.swift")
        let searchBar = try sourceSection(
            in: glassModifiers,
            from: "struct GlassSearchBarModifier",
            to: "struct GlassPanelModifier"
        )
        let panel = try sourceSection(
            in: glassModifiers,
            from: "struct GlassPanelModifier",
            to: "struct GlassCircleModifier"
        )
        let circle = try sourceSection(
            in: glassModifiers,
            from: "struct GlassCircleModifier",
            to: "struct CelestialGlassIcon"
        )
        let capsule = try sourceSection(
            in: glassModifiers,
            from: "struct GlassCapsuleModifier",
            to: "private extension View"
        )

        XCTAssertTrue(glassModifiers.contains("enum CelestialGlassTokens"))
        XCTAssertTrue(glassModifiers.contains("func celestialGlassChrome"))
        XCTAssertTrue(searchBar.contains(".celestialGlassChrome("))
        XCTAssertTrue(panel.contains(".celestialGlassChrome("))
        XCTAssertTrue(circle.contains(".celestialGlassChrome("))
        XCTAssertTrue(capsule.contains(".celestialGlassChrome("))
    }

    func testUpgradeViewRequestsDeferredProductLoading() throws {
        let upgradeView = try contents(of: "Memorable/Views/UpgradeView.swift")

        XCTAssertTrue(upgradeView.contains("await proManager.loadProduct()"))
    }

    func testUpgradeKeepsCommerceActionsOutsideScrollableContent() throws {
        let upgradeView = try contents(of: "Memorable/Views/UpgradeView.swift")
        let scrollingContent = try sourceSection(
            in: upgradeView,
            from: "ScrollView {",
            to: ".scrollBounceBehavior(.basedOnSize)"
        )
        let purchaseFooter = try sourceSection(
            in: upgradeView,
            from: "private var purchaseFooter",
            to: "private func proFeature"
        )

        XCTAssertTrue(upgradeView.contains(".safeAreaInset(edge: .bottom"))
        XCTAssertFalse(scrollingContent.contains("await proManager.purchase()"))
        XCTAssertFalse(scrollingContent.contains("await proManager.restorePurchases()"))
        XCTAssertTrue(purchaseFooter.contains("await proManager.purchase()"))
        XCTAssertTrue(purchaseFooter.contains("await proManager.restorePurchases()"))
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

    func testLicensesUsesOneGroupedGlassPanelInsteadOfListStyledCards() throws {
        let moreView = try contents(of: "Memorable/Views/MoreView.swift")
        let licensesView = try sourceSection(
            in: moreView,
            from: "struct LicensesView: View",
            to: "private struct LicenseDetailView"
        )

        XCTAssertTrue(licensesView.contains("ScrollView"))
        XCTAssertTrue(licensesView.contains("GlassPanelModifier(cornerRadius: 20)"))
        XCTAssertTrue(licensesView.contains("CelestialGlassIcon("))
        XCTAssertFalse(licensesView.contains("List {"))
        XCTAssertFalse(licensesView.contains(".celestialGlassCardButtonStyle("))
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

    func testSearchDockReselectReturnsToSearchHistory() throws {
        let mainTabView = try contents(of: "Memorable/Views/MainTabView.swift")
        let searchView = try contents(of: "Memorable/Views/SearchView.swift")

        XCTAssertTrue(mainTabView.contains("navigation.requestSearchHome()"))
        XCTAssertTrue(mainTabView.contains("searchHomeRequestID: navigation.searchHomeRequestID"))
        XCTAssertTrue(searchView.contains(".onChange(of: searchHomeRequestID)"))
        XCTAssertTrue(searchView.contains("viewModel.setQueryText(\"\")"))
    }

    func testDockUsesOneSharedGlyphTreatmentWithoutAlignmentOffsets() throws {
        let mainTabView = try contents(of: "Memorable/Views/MainTabView.swift")

        XCTAssertTrue(mainTabView.contains("private struct PrimaryDockGlyph"))
        XCTAssertTrue(mainTabView.contains("PrimaryDockSelectionPill(isSelected: isSelected)"))
        XCTAssertTrue(mainTabView.contains("private var dockSpecularOutline"))
        XCTAssertTrue(mainTabView.contains("systemName: \"sparkles\""))
        XCTAssertFalse(mainTabView.contains("wand.and.stars"))
        XCTAssertFalse(mainTabView.contains("isHighlighted:"))
        XCTAssertFalse(mainTabView.contains(".offset(y: tab == .more"))
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

    func testPhotoSourcesEmptyFolderStateUsesOneActionableGlassPanel() throws {
        let sourceManager = try contents(of: "Memorable/Views/SourceManagerView.swift")
        let emptyFoldersPanel = try sourceSection(
            in: sourceManager,
            from: "private var emptyFoldersPanel",
            to: "private func requestFolderPicker"
        )

        XCTAssertTrue(emptyFoldersPanel.contains("CelestialGlassIcon("))
        XCTAssertTrue(emptyFoldersPanel.contains("GlassPanelModifier(cornerRadius: 16)"))
        XCTAssertTrue(emptyFoldersPanel.contains("Button(action: requestFolderPicker)"))
        XCTAssertTrue(emptyFoldersPanel.contains("CelestialHairline()"))
    }

    func testPushedScreensCannotBypassTheSharedNavigationPolicy() throws {
        let sources = try allAppSourceText()

        XCTAssertEqual(
            sources.components(separatedBy: ".navigationTitle(").count - 1,
            1,
            "Navigation titles must go through celestialNavigationTitle so a hidden parent bar cannot strand a child screen"
        )
    }

    func testMoreNavigationKeepsBarGeometryStableAcrossPushes() throws {
        let moreView = try contents(of: "Memorable/Views/MoreView.swift")
        let moreRoot = try sourceSection(
            in: moreView,
            from: "struct MoreView: View",
            to: "struct PrivacyPolicyView: View"
        )

        XCTAssertFalse(moreRoot.contains(".toolbar(.hidden, for: .navigationBar)"))
        XCTAssertTrue(moreRoot.contains(".toolbar(.visible, for: .navigationBar)"))
        XCTAssertTrue(moreRoot.contains("ToolbarItem(placement: .principal)"))
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
        XCTAssertEqual(
            searchView.components(
                separatedBy: "IndexingBannerView(indexingService: indexingService)"
            ).count - 1,
            2,
            "Initial and incremental indexing must use the same home-screen progress card"
        )
        XCTAssertTrue(searchView.contains("presentation: .initialIndexing"))
        let indexingBanner = try contents(of: "Memorable/Views/IndexingBannerView.swift")
        let indexingProgress = try sourceSection(
            in: indexingBanner,
            from: "struct IndexingBannerView",
            to: ".accessibilityElement(children: .contain)"
        )
        XCTAssertTrue(indexingProgress.contains("ProgressView("))
        XCTAssertTrue(indexingProgress.contains(".frame(minWidth: 44, minHeight: 44)"))
        XCTAssertFalse(indexingBanner.contains("Circle()"), "The legacy dial must not remain")
        XCTAssertFalse(searchView.contains(
            "else if indexingService.progress.isRunning,\n                                          viewModel.queryText.isEmpty"
        ), "Incremental indexing must keep the normal home content visible")

        let service = try contents(of: "Memorable/Core/IndexingService.swift")
        let searchPrioritySection = try sourceSection(
            in: service,
            from: "func prioritizeUserSearch()",
            to: "func cancelAllWorkForMemoryPressure()"
        )
        XCTAssertFalse(searchPrioritySection.contains("geocodingProgress = nil"))
        XCTAssertTrue(searchPrioritySection.contains("enqueueGeocoding("))

        let sourceManager = try contents(of: "Memorable/Views/SourceManagerView.swift")
        let applePhotosStatus = try sourceSection(
            in: sourceManager,
            from: "if indexingService.progress.isRunning",
            to: "else if !indexingService.isReady"
        )
        XCTAssertFalse(
            applePhotosStatus.contains("ProgressView()"),
            "Secondary screens must not duplicate the retired indexing dial"
        )
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

    func testSearchResultsScrollUsesContentSizedBounceAndInteractiveKeyboardDismissal() throws {
        let searchView = try contents(of: "Memorable/Views/SearchView.swift")
        let resultsScroll = try sourceSection(
            in: searchView,
            from: "ScrollView {",
            to: "} // VStack"
        )

        XCTAssertTrue(resultsScroll.contains(".scrollBounceBehavior(.basedOnSize)"))
        XCTAssertTrue(resultsScroll.contains(".scrollDismissesKeyboard(.interactively)"))
    }

    func testPhotoViewerRequestsAnUncroppedPreviewImage() throws {
        let photoLibrary = try contents(of: "Memorable/Core/PhotoLibrary.swift")
        let previewLoader = try sourceSection(
            in: photoLibrary,
            from: "static func loadPreviewImage(",
            to: "private static func loadImage("
        )
        let zoomableImage = try contents(of: "Memorable/Views/ZoomableAsyncImage.swift")

        XCTAssertTrue(previewLoader.contains("photoContentMode: .aspectFit"))
        XCTAssertTrue(zoomableImage.contains("PhotoLibrary.loadPreviewImage("))
    }

    func testSearchHomeKeepsPreviewCompositionAndUsesInterfaceTypography() throws {
        let searchView = try contents(of: "Memorable/Views/SearchView.swift")
        let memoryCard = try sourceSection(
            in: searchView,
            from: "private func todayMemoryView(",
            to: "private var searchHistoryView: some View"
        )
        let homeImage = try sourceSection(
            in: searchView,
            from: "private struct SearchHomePhotoImage: View",
            to: "private struct RecentSearchPlaceholder: View"
        )
        let recentSearchRow = try sourceSection(
            in: searchView,
            from: "private func recentSearchTimelineRow(",
            to: "private func recentSearchMetadata("
        )

        XCTAssertFalse(memoryCard.contains("Date.now"))
        XCTAssertFalse(memoryCard.contains("Celestial.Typography.memoryCaption"))
        XCTAssertTrue(memoryCard.contains("Celestial.Typography.bodyStrong"))
        XCTAssertTrue(memoryCard.contains("HStack(alignment: .center"))
        XCTAssertTrue(memoryCard.contains(
            ".frame(minHeight: SearchHomeCardMetrics.captionHeight)"
        ))
        XCTAssertTrue(memoryCard.contains(
            ".aspectRatio(SearchHomeCardMetrics.imageAspectRatio, contentMode: .fit)"
        ))
        XCTAssertTrue(searchView.contains("static let imageAspectRatio: CGFloat = 4.0 / 3.0"))
        XCTAssertTrue(searchView.contains("static let recentThumbnailWidth: CGFloat = 64"))
        XCTAssertTrue(searchView.contains("static let recentThumbnailHeight: CGFloat = 48"))
        XCTAssertTrue(recentSearchRow.contains(
            "width: SearchHomeCardMetrics.recentThumbnailWidth * displayScale"
        ))
        XCTAssertTrue(recentSearchRow.contains(
            "height: SearchHomeCardMetrics.recentThumbnailHeight * displayScale"
        ))
        XCTAssertTrue(recentSearchRow.contains(
            "width: SearchHomeCardMetrics.recentThumbnailWidth,"
        ))
        XCTAssertTrue(recentSearchRow.contains(
            "height: SearchHomeCardMetrics.recentThumbnailHeight"
        ))
        XCTAssertTrue(homeImage.contains("PhotoLibrary.loadPreviewImage("))
        XCTAssertTrue(homeImage.contains(".scaledToFit()"))
        XCTAssertFalse(homeImage.contains(".scaledToFill()"))
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
        let contentView = try contents(of: "Memorable/Views/ContentView.swift")
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
        let preparedServiceCondition = "if let indexingService, let searchEngine, !semanticRuntime.isCheckingIndexAvailability"
        XCTAssertEqual(
            mainTabView.components(separatedBy: preparedServiceCondition).count - 1,
            2,
            "Both tabs must keep the same preparation shell until index loading finishes"
        )
        let searchBar = try sourceSection(
            in: searchView,
            from: "private var searchBar: some View",
            to: "private var initialIndexingExperience: some View"
        )
        XCTAssertTrue(searchBar.contains(
            ".disabled(!semanticRuntime.readiness.isSemanticSearchReady)"
        ))
        let searchPlaceholder = try sourceSection(
            in: searchView,
            from: "private var searchPlaceholder: String",
            to: "private var searchPreparationStatusText: String"
        )
        XCTAssertTrue(searchPlaceholder.contains("return Self.placeholders[0]"))
        XCTAssertFalse(searchPlaceholder.contains("Warming search"))
        XCTAssertFalse(searchPlaceholder.contains("Preparing search"))
        let searchPreparationStatus = try sourceSection(
            in: searchView,
            from: "private var searchPreparationStatusText: String",
            to: "// MARK: - Banners"
        )
        XCTAssertTrue(searchPreparationStatus.contains("return \"Preparing search...\""))
        XCTAssertFalse(searchPreparationStatus.contains("Warming search"))
        XCTAssertFalse(searchPreparationStatus.contains("Loading your library"))
        XCTAssertFalse(mainTabView.contains("Ready to index your photos"))
        XCTAssertTrue(contentView.contains("private var launchShell"))
        XCTAssertFalse(contentView.contains("private var loadingView"))
        XCTAssertFalse(contentView.contains("Circle()"), "The retired indexing dial must not appear during launch")
        XCTAssertFalse(contentView.contains("ProgressView()"), "Launch checks must not look like indexing")
        XCTAssertTrue(mainTabView.contains("private struct SearchPreparationShell"))
        XCTAssertFalse(mainTabView.contains("private struct SemanticWarmupView"))
        let searchPreparationShell = try sourceSection(
            in: mainTabView,
            from: "private struct SearchPreparationShell",
            to: "private var statusText: String"
        )
        XCTAssertTrue(searchPreparationShell.contains("Text(\"Search your photos...\")"))
        XCTAssertTrue(searchPreparationShell.contains(".disabled(true)"))

        let failedPreparationState = try sourceSection(
            in: String(searchPreparationShell),
            from: "if case .failed = semanticRuntime.phase",
            to: "} else {"
        )
        XCTAssertTrue(failedPreparationState.contains("Text(statusText)"))
        XCTAssertTrue(failedPreparationState.contains("Button(\"Try Again\", action: retry)"))
        XCTAssertFalse(failedPreparationState.contains("ProgressView()"))

        let warmingPreparationState = try sourceSection(
            in: String(searchPreparationShell),
            from: "} else {",
            to: ".accessibilityElement(children: .combine)"
        )
        XCTAssertTrue(warmingPreparationState.contains("ProgressView()"))
        XCTAssertTrue(warmingPreparationState.contains("Text(statusText)"))
        XCTAssertFalse(warmingPreparationState.contains("Try Again"))
        let preparationStatus = try sourceSection(
            in: mainTabView,
            from: "private var statusText: String",
            to: "    }\n}"
        )
        XCTAssertTrue(preparationStatus.contains("return \"Preparing search...\""))
        XCTAssertFalse(preparationStatus.contains("Warming search"))
        XCTAssertFalse(preparationStatus.contains("Loading your library"))

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

    func testScreensUseSharedLayoutRhythm() throws {
        let sources = try allSourceText(in: "Memorable/Views")

        XCTAssertEqual(Celestial.Spacing.pageHorizontalInset, 24)
        XCTAssertEqual(Celestial.Spacing.surfaceHorizontalInset, 16)
        XCTAssertEqual(Celestial.Spacing.surfaceContentInset, 16)
        XCTAssertEqual(Celestial.Spacing.stackedContainerGap, 12)
        XCTAssertEqual(Celestial.Spacing.contentGap, 16)
        XCTAssertEqual(Celestial.Spacing.sectionGap, 28)
        XCTAssertLessThan(
            Celestial.Spacing.surfaceHorizontalInset,
            Celestial.Spacing.pageHorizontalInset
        )
        XCTAssertLessThan(
            Celestial.Spacing.stackedContainerGap,
            Celestial.Spacing.sectionGap
        )
        XCTAssertFalse(sources.contains(".padding(.horizontal, 22)"))
        XCTAssertFalse(sources.contains(".padding(.horizontal, 26)"))
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
