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

    private func contents(of relativePath: String) throws -> String {
        try String(
            contentsOf: repositoryRoot.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }
}
