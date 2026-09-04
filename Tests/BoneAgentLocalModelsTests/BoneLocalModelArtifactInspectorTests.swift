import CryptoKit
import XCTest
@testable import BoneAgentLocalModels

final class BoneLocalModelArtifactInspectorTests: XCTestCase {
    func testAcceptsGGUFSignatureForInstalledArtifact() throws {
        let context = try makeContext(payload: Data("GGUFpayload".utf8))
        defer { try? FileManager.default.removeItem(at: context.root) }

        let result = BoneLocalModelArtifactInspector.inspect(
            model: context.model,
            store: context.store,
            verifyChecksum: true
        )

        XCTAssertEqual(result.artifactURL, context.installedURL)
        XCTAssertEqual(result.checks, [
            .init(kind: .installation, status: .passed),
            .init(kind: .artifactIntegrity, status: .passed),
            .init(kind: .formatSignature, status: .passed),
        ])
    }

    func testRejectsWrongOrTruncatedGGUFSignature() throws {
        for payload in [Data("BAD!payload".utf8), Data("GG".utf8)] {
            let context = try makeContext(payload: payload)
            defer { try? FileManager.default.removeItem(at: context.root) }

            let result = BoneLocalModelArtifactInspector.inspect(
                model: context.model,
                store: context.store,
                verifyChecksum: true
            )

            XCTAssertNil(result.artifactURL)
            XCTAssertEqual(result.checks.last, .init(kind: .formatSignature, status: .corrupted))
        }
    }

    func testReportsNotInstalledWithoutExposingPath() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let context = try makeDescriptor(payload: Data("GGUFpayload".utf8))
        let store = try BoneLocalModelStore(rootURL: root.appendingPathComponent("models"))

        let result = BoneLocalModelArtifactInspector.inspect(
            model: context,
            store: store,
            verifyChecksum: true
        )

        XCTAssertNil(result.artifactURL)
        XCTAssertEqual(result.checks, [.init(kind: .installation, status: .corrupted)])
    }

    private func makeContext(payload: Data) throws -> (
        root: URL,
        store: BoneLocalModelStore,
        model: BoneLocalModelDescriptor,
        installedURL: URL
    ) {
        let root = temporaryDirectory()
        let model = try makeDescriptor(payload: payload)
        let source = root.appendingPathComponent("source")
        try payload.write(to: source)
        let store = try BoneLocalModelStore(rootURL: root.appendingPathComponent("models"))
        let installedURL = try store.installDownloadedFile(at: source, for: model)
        return (root, store, model, installedURL)
    }

    private func makeDescriptor(payload: Data) throws -> BoneLocalModelDescriptor {
        let hash = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        return .init(
            id: "model",
            displayName: "Model",
            family: "Test",
            format: .gguf,
            parameterCount: 1,
            quantization: "Q4",
            minimumMemoryBytes: 1,
            recommendedContextTokens: 512,
            minimumRuntimeVersion: 1,
            contextLimits: try .init(
                contextWindowTokens: 1_024,
                maximumInputTokens: 768,
                maximumOutputTokens: 256,
                source: .official,
                verifiedAt: "2026-09-01",
                documentationURL: URL(string: "https://example.com/model")!
            ),
            artifact: .init(
                fileName: "model.gguf",
                expectedByteCount: Int64(payload.count),
                sha256: hash,
                sources: [.init(
                    id: "source",
                    url: URL(string: "https://models.example.com/model.gguf")!,
                    allowedHosts: ["models.example.com"],
                    priority: 1
                )]
            ),
            license: .init(
                name: "Test",
                url: URL(string: "https://example.com/license")!,
                modelCardURL: URL(string: "https://example.com/model")!
            )
        )
    }

    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
