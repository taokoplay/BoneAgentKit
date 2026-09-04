import CryptoKit
import XCTest
@testable import BoneAgentLocalModels

final class BoneLocalModelStoreTests: XCTestCase {
    func testInstallVerifiesSizeAndChecksumThenReportsInstalled() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let payload = Data("valid-local-model".utf8)
        let descriptor = try model(payload: payload)
        let source = root.appendingPathComponent("download.tmp")
        try payload.write(to: source)
        let store = try BoneLocalModelStore(rootURL: root.appendingPathComponent("models"))

        let installedURL = try store.installDownloadedFile(at: source, for: descriptor)

        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertEqual(try Data(contentsOf: installedURL), payload)
        XCTAssertEqual(store.installationState(for: descriptor), .installed(installedURL))
    }

    func testInstallRejectsSizeAndChecksumMismatch() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let expected = Data("expected".utf8)
        let store = try BoneLocalModelStore(rootURL: root.appendingPathComponent("models"))

        let wrongSizeModel = try model(payload: expected)
        let wrongSize = root.appendingPathComponent("wrong-size.tmp")
        try Data("x".utf8).write(to: wrongSize)
        XCTAssertThrowsError(try store.installDownloadedFile(at: wrongSize, for: wrongSizeModel)) {
            XCTAssertEqual($0 as? BoneLocalModelStoreError, .sizeMismatch)
        }

        let wrongHashModel = try model(payload: expected, sha256: String(repeating: "f", count: 64))
        let wrongHash = root.appendingPathComponent("wrong-hash.tmp")
        try expected.write(to: wrongHash)
        XCTAssertThrowsError(try store.installDownloadedFile(at: wrongHash, for: wrongHashModel)) {
            XCTAssertEqual($0 as? BoneLocalModelStoreError, .checksumMismatch)
        }
    }

    func testStoreCleansPartialFilesAndRemovesInstalledModel() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let payload = Data("valid-local-model".utf8)
        let descriptor = try model(payload: payload)
        let store = try BoneLocalModelStore(rootURL: root.appendingPathComponent("models"))
        let source = root.appendingPathComponent("download.tmp")
        try payload.write(to: source)
        _ = try store.installDownloadedFile(at: source, for: descriptor)
        let partial = try store.partialURL(for: descriptor)
        try Data("partial".utf8).write(to: partial)

        try store.cleanIncompleteDownloads()
        XCTAssertFalse(FileManager.default.fileExists(atPath: partial.path))
        try store.removeModel(descriptor)
        XCTAssertEqual(store.installationState(for: descriptor), .notInstalled)
    }

    private func model(payload: Data, sha256: String? = nil) throws -> BoneLocalModelDescriptor {
        let hash = sha256 ?? SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        let json = """
        {"schemaVersion":1,"catalogVersion":1,"runtimeVersion":1,"models":[{
          "id":"test-model","displayName":"Test","family":"Test","format":"gguf",
          "parameterCount":1000,"quantization":"Q4","minimumMemoryBytes":1024,
          "recommendedContextTokens":512,"minimumRuntimeVersion":1,
          "contextLimits":{"contextWindowTokens":1024,"maximumInputTokens":768,"maximumOutputTokens":256,"source":"official","verifiedAt":"2026-09-01","documentationURL":"https://example.com/model"},
          "artifact":{"fileName":"model.gguf","expectedByteCount":\(payload.count),"sha256":"\(hash)","sources":[{"id":"official","url":"https://models.example.com/model.gguf","allowedHosts":["models.example.com"],"priority":1}]},
          "license":{"name":"Test","url":"https://example.com/license","modelCardURL":"https://example.com/model"}
        }]}
        """
        return try XCTUnwrap(BoneLocalModelCatalog(data: Data(json.utf8)).models.first)
    }

    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true
        )
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
