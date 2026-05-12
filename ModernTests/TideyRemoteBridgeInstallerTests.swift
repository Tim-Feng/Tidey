import XCTest
@testable import iTerm2SharedARC

final class TideyRemoteBridgeInstallerTests: XCTestCase {
    func testPlistRendererReplacesHomeAndLabel() {
        let template = """
        <string>__HOME__/Library/Application Support/Tidey Remote Bridge/tidey-remote-bridge</string>
        <string>__LABEL__</string>
        """

        let rendered = TideyRemoteBridgePlistRenderer.render(
            template: template,
            homeDirectory: URL(fileURLWithPath: "/Users/tidey-test"),
            label: "com.tidey.remote-bridge.cloudflared"
        )

        XCTAssertTrue(rendered.contains("/Users/tidey-test/Library/Application Support/Tidey Remote Bridge/tidey-remote-bridge"))
        XCTAssertTrue(rendered.contains("com.tidey.remote-bridge.cloudflared"))
        XCTAssertFalse(rendered.contains("__HOME__"))
        XCTAssertFalse(rendered.contains("__LABEL__"))
    }

    func testFileComparatorDetectsSameAndDifferentFiles() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TideyRemoteBridgeInstallerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let bundled = directory.appendingPathComponent("bundled")
        let installed = directory.appendingPathComponent("installed")

        try Data("bridge-v1".utf8).write(to: bundled)
        try Data("bridge-v1".utf8).write(to: installed)
        XCTAssertFalse(try TideyRemoteBridgeFileComparator.filesDiffer(bundled, installed))

        try Data("bridge-v2".utf8).write(to: installed)
        XCTAssertTrue(try TideyRemoteBridgeFileComparator.filesDiffer(bundled, installed))
    }

    func testInstallInspectorClassifiesMissingBinaryAsInstallRequired() {
        let classification = TideyRemoteBridgeInstallInspector.classify(
            installedBinaryExists: false,
            binaryDiffers: false,
            bridgePlistExists: true,
            cloudflaredPlistExists: true,
            launchAgentLoaded: true
        )

        XCTAssertEqual(classification, .missingBinary)
        XCTAssertTrue(classification.needsInstall)
    }

    func testInstallInspectorClassifiesStaleBinaryAsInstallRequired() {
        let classification = TideyRemoteBridgeInstallInspector.classify(
            installedBinaryExists: true,
            binaryDiffers: true,
            bridgePlistExists: true,
            cloudflaredPlistExists: true,
            launchAgentLoaded: true
        )

        XCTAssertEqual(classification, .staleBinary)
        XCTAssertTrue(classification.needsInstall)
    }

    func testInstallInspectorPreservesExistingCredentialsWhenOnlyLaunchAgentMissing() {
        let classification = TideyRemoteBridgeInstallInspector.classify(
            installedBinaryExists: true,
            binaryDiffers: false,
            bridgePlistExists: true,
            cloudflaredPlistExists: true,
            launchAgentLoaded: false
        )

        XCTAssertEqual(classification, .notLoaded)
        XCTAssertFalse(classification.needsInstall)
    }

    func testInstallInspectorRequiresInstallWhenPlistMissing() {
        let classification = TideyRemoteBridgeInstallInspector.classify(
            installedBinaryExists: true,
            binaryDiffers: false,
            bridgePlistExists: false,
            cloudflaredPlistExists: true,
            launchAgentLoaded: true
        )

        XCTAssertEqual(classification, .missingPlist)
        XCTAssertTrue(classification.needsInstall)
    }

    func testLaunchctlFailureMessageIsUserFacing() {
        let error = TideyRemoteBridgeInstallerError.launchctlFailed(
            arguments: ["bootstrap", "gui/501", "/Users/tidey-test/Library/LaunchAgents/com.tidey.remote-bridge.plist"],
            output: "Bootstrap failed: 5"
        )

        XCTAssertTrue(error.localizedDescription.contains("launchctl bootstrap gui/501"))
        XCTAssertTrue(error.localizedDescription.contains("Bootstrap failed: 5"))
    }
}
