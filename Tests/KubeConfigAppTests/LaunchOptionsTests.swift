import XCTest
@testable import KubeConfig

final class LaunchOptionsTests: XCTestCase {
    func testCaptureRequiresAnExplicitConfigurationPath() {
        for arguments in [
            ["KubeConfig", "--capture-dir", "/tmp/review", "--config"],
            ["KubeConfig", "--capture-dir", "/tmp/review"],
            ["KubeConfig", "--config", "--capture-dir", "/tmp/review"],
            ["KubeConfig", "--config", ""],
            ["KubeConfig", "--config", "/tmp/sample", "--capture-dir"]
        ] {
            XCTAssertThrowsError(try LaunchOptions(arguments: arguments))
        }
    }

    func testValidPathsWithSpacesAreParsedWithoutReadingFiles() throws {
        let options = try LaunchOptions(arguments: ["KubeConfig", "--capture-dir", "/tmp/my review", "--config", "/tmp/sample config"])
        XCTAssertEqual(options.configurationURL?.path, "/tmp/sample config")
        XCTAssertEqual(options.captureDirectory?.path, "/tmp/my review")
    }

    func testNormalLaunchAndExplicitConfigurationRemainSupported() throws {
        XCTAssertNil(try LaunchOptions(arguments: ["KubeConfig"]).configurationURL)
        let options = try LaunchOptions(arguments: ["KubeConfig", "--config", "/tmp/config"])
        XCTAssertEqual(options.configurationURL?.path, "/tmp/config")
        XCTAssertNil(options.captureDirectory)
    }

    func testMalformedArgumentsDoNotLoadAnyConfiguration() async {
        await MainActor.run {
            let suite = "KubeConfigLaunchTests.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let model = AppModel(defaults: defaults, arguments: ["KubeConfig", "--capture-dir", "/tmp/review", "--config"])
            XCTAssertNil(model.snapshot)
            XCTAssertNil(model.document)
            XCTAssertNotNil(model.errorMessage)
        }
    }
}
