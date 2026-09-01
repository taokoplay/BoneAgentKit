import XCTest
@testable import BoneAgentLocalRuntime

final class BoneLocalModelDownloadSecurityPolicyTests: XCTestCase {
    func testAllowsExactAndWildcardHTTPSHosts() throws {
        let source = BoneLocalModelDownloadSource(
            id: "official",
            url: URL(string: "https://models.example.com/model.gguf")!,
            allowedHosts: ["models.example.com", "*.cdn.example.com"],
            priority: 10
        )

        XCTAssertNoThrow(try BoneLocalModelDownloadSecurityPolicy.validate(
            URL(string: "https://models.example.com/model.gguf")!,
            for: source
        ))
        XCTAssertNoThrow(try BoneLocalModelDownloadSecurityPolicy.validate(
            URL(string: "https://edge.cdn.example.com/model.gguf")!,
            for: source
        ))
    }

    func testRejectsHTTPUnknownAndWildcardApexHosts() {
        let source = BoneLocalModelDownloadSource(
            id: "official",
            url: URL(string: "https://models.example.com/model.gguf")!,
            allowedHosts: ["models.example.com", "*.cdn.example.com"],
            priority: 10
        )
        let rejected = [
            "http://models.example.com/model.gguf",
            "https://evil.example.com/model.gguf",
            "https://cdn.example.com/model.gguf",
        ]
        for value in rejected {
            XCTAssertThrowsError(try BoneLocalModelDownloadSecurityPolicy.validate(
                URL(string: value)!,
                for: source
            )) { error in
                XCTAssertEqual(error as? BoneLocalModelDownloadError, .untrustedURL)
            }
        }
    }

    func testOrdersSourcesByPriorityThenManifestOrder() {
        let sources = [
            source(id: "second", priority: 20),
            source(id: "first-a", priority: 10),
            source(id: "first-b", priority: 10),
        ]

        XCTAssertEqual(
            BoneLocalModelDownloadSecurityPolicy.orderedSources(sources).map(\.id),
            ["first-a", "first-b", "second"]
        )
    }

    private func source(id: String, priority: Int) -> BoneLocalModelDownloadSource {
        BoneLocalModelDownloadSource(
            id: id,
            url: URL(string: "https://models.example.com/\(id).gguf")!,
            allowedHosts: ["models.example.com"],
            priority: priority
        )
    }
}
