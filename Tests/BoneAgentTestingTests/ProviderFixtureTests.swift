import XCTest
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import BoneAgentKit
import BoneAgentTesting

final class ProviderFixtureTests: XCTestCase {
    func testSyntheticFixtureRecordsOnlyAllowlistedMetadata() async throws {
        let fixture = try BoneSyntheticProviderFixture(
            httpResponses: [.init(statusCode: 200, data: Data("{\"ok\":true}".utf8))],
            eventStreams: [[.init(event: "message", data: "{\"delta\":\"private\"}")]]
        )
        var request = URLRequest(url: URL(string: "https://synthetic.invalid/v1/chat?secret=query")!)
        request.httpMethod = "POST"
        request.setValue("Bearer top-secret", forHTTPHeaderField: "Authorization")
        request.setValue("trace-1", forHTTPHeaderField: "X-Request-ID")
        request.httpBody = Data("private-body-key".utf8)

        _ = try await fixture.transport.send(request)
        _ = try await fixture.transport.sendEventStream(request, options: .init(
            firstEventTimeout: 1,
            idleTimeout: 1,
            maximumBytes: 1024
        ))
        let snapshots = await fixture.recorder.snapshots()
        XCTAssertEqual(snapshots.count, 2)
        XCTAssertEqual(snapshots[0].scheme, "https")
        XCTAssertEqual(snapshots[0].host, "synthetic.invalid")
        XCTAssertEqual(snapshots[0].path, "/v1/chat")
        XCTAssertEqual(snapshots[0].headerNames, ["x-request-id"])
        let encoded = String(data: try JSONEncoder().encode(snapshots), encoding: .utf8)!
        for forbidden in ["secret=query", "private-body-key", "top-secret", "Authorization", "private"] {
            XCTAssertFalse(encoded.contains(forbidden), "安全快照泄漏：\(forbidden)")
        }
    }

    func testFixtureRejectsNonSyntheticHostAndDoesNotWriteFiles() async throws {
        let fixture = try BoneSyntheticProviderFixture(httpResponses: [.init(statusCode: 200, data: Data())])
        let before = try FileManager.default.contentsOfDirectory(atPath: FileManager.default.currentDirectoryPath)
        do {
            _ = try await fixture.transport.send(URLRequest(url: URL(string: "https://api.openai.com/v1/chat")!))
            XCTFail("真实 Host 必须拒绝")
        } catch let error as BoneSyntheticProviderFixtureError {
            XCTAssertEqual(error, .nonSyntheticEndpoint)
        }
        let after = try FileManager.default.contentsOfDirectory(atPath: FileManager.default.currentDirectoryPath)
        XCTAssertEqual(before.sorted(), after.sorted(), "Fixture 不得自动落盘")
    }

    func testScriptExhaustionIsStable() async throws {
        let fixture = try BoneSyntheticProviderFixture(httpResponses: [])
        do {
            _ = try await fixture.transport.send(URLRequest(url: URL(string: "https://synthetic.invalid/empty")!))
            XCTFail("脚本耗尽必须拒绝")
        } catch let error as BoneSyntheticProviderFixtureError {
            XCTAssertEqual(error, .scriptExhausted)
        }
    }
}
