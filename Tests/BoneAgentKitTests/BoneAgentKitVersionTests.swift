import Foundation
import XCTest
@testable import BoneAgentKit

final class BoneAgentKitVersionTests: XCTestCase {
    func testCurrentVersionMatchesStructuredComponentsAndSemVer() {
        let composed = "\(BoneAgentKitVersion.major).\(BoneAgentKitVersion.minor).\(BoneAgentKitVersion.patch)-\(BoneAgentKitVersion.prerelease)"

        XCTAssertEqual(BoneAgentKitVersion.current, composed)
        XCTAssertNotNil(BoneAgentKitVersion.current.range(
            of: #"^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)-[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*$"#,
            options: .regularExpression
        ))
    }

    func testPublishedDocumentationMatchesRuntimeVersion() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let readme = try String(contentsOf: root.appendingPathComponent("README.md"))
        let changelog = try String(contentsOf: root.appendingPathComponent("CHANGELOG.md"))

        XCTAssertTrue(readme.contains("exact: \"\(BoneAgentKitVersion.current)\""))
        XCTAssertTrue(changelog.contains("## [\(BoneAgentKitVersion.current)] - 2026-09-02"))
    }
}
