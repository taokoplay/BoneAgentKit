import CryptoKit
import XCTest
@testable import BoneAgentLocalRuntime

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

    func testStoreRejectsUnsafeIDsWithoutTouchingOutsideFiles() throws {
        for id in [".", "..", "", "../escape", "nested/model", ".bone-install-staging", ".BONE-INSTALL-STAGING", ".Bone-Install-Staging", ".bone-download-staging", ".BONE-DOWNLOAD-STAGING"] {
            let root = temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let payload = Data("valid-local-model".utf8)
            let descriptor = try replacing(model(payload: payload), key: "id", value: id)
            let store = try BoneLocalModelStore(rootURL: root.appendingPathComponent("models"))
            let sentinel = root.appendingPathComponent("sentinel")
            try payload.write(to: sentinel)
            XCTAssertThrowsError(try store.modelURL(for: descriptor), id)
            XCTAssertThrowsError(try store.partialURL(for: descriptor), id)
            // Do not exercise destructive APIs against unsafe old code until path rejection works.
            if (try? store.modelURL(for: descriptor)) == nil {
                XCTAssertThrowsError(try store.removeModel(descriptor), id)
                XCTAssertThrowsError(try store.installDownloadedFile(at: sentinel, for: descriptor), id)
            }
            XCTAssertEqual(try Data(contentsOf: sentinel), payload)
        }
    }

    func testStoreRejectsSymlinkedModelDirectoryAndArtifact() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let payload = Data("valid-local-model".utf8)
        let descriptor = try model(payload: payload)
        let store = try BoneLocalModelStore(rootURL: root.appendingPathComponent("models"))
        let outside = root.appendingPathComponent("models-sibling")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let sentinel = outside.appendingPathComponent("model.gguf")
        try payload.write(to: sentinel)
        let directory = store.rootURL.appendingPathComponent(descriptor.id)
        try FileManager.default.createSymbolicLink(at: directory, withDestinationURL: outside)
        XCTAssertThrowsError(try store.modelURL(for: descriptor))
        XCTAssertThrowsError(try store.partialURL(for: descriptor))
        if (try? store.modelURL(for: descriptor)) == nil {
            XCTAssertThrowsError(try store.removeModel(descriptor))
        }
        try FileManager.default.removeItem(at: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("model.gguf"), withDestinationURL: sentinel)
        XCTAssertThrowsError(try store.modelURL(for: descriptor))
        XCTAssertEqual(try Data(contentsOf: sentinel), payload)
    }

    func testStoreRejectsUnsafeArtifactNames() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try BoneLocalModelStore(rootURL: root.appendingPathComponent("models"))
        for name in [".", "..", "", "../model.gguf", "nested/model.gguf", "model.partial", "model.PARTIAL", "model.partial.download", "model.PARTIAL.DOWNLOAD"] {
            let descriptor = try replacing(model(payload: Data("model".utf8)), key: "fileName", value: name)
            XCTAssertThrowsError(try store.modelURL(for: descriptor), name)
            XCTAssertThrowsError(try store.partialURL(for: descriptor), name)
        }
    }

    func testFailedReplacementPreservesOldModelAndCleansStaging() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let old = Data("old-local-model".utf8)
        let new = Data("new-local-model".utf8)
        let descriptor = try model(payload: new)
        let models = root.appendingPathComponent("models")
        let initialStore = try BoneLocalModelStore(rootURL: models)
        let source = root.appendingPathComponent("old.tmp")
        try old.write(to: source)
        let final = try initialStore.installDownloadedFile(at: source, for: model(payload: old))
        let store = try BoneLocalModelStore(rootURL: models, beforeInstallCommit: { _, target in
            XCTAssertEqual(try Data(contentsOf: target), old)
            throw InstallFault.injected
        })
        let replacement = root.appendingPathComponent("new.tmp")
        try new.write(to: replacement)
        XCTAssertThrowsError(try store.installDownloadedFile(at: replacement, for: descriptor))
        XCTAssertEqual(try Data(contentsOf: final), old)
        XCTAssertEqual(try Data(contentsOf: replacement), new)
        let names = try FileManager.default.contentsOfDirectory(atPath: final.deletingLastPathComponent().path)
        XCTAssertEqual(names, ["model.gguf"])
        try assertNoInstallStaging(store)
    }

    func testReplacementPublishesWholeNewFileWithoutRemovingOldBeforeCommit() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let old = Data("old-local-model".utf8)
        let new = Data("new-local-model".utf8)
        let models = root.appendingPathComponent("models")
        let initialStore = try BoneLocalModelStore(rootURL: models)
        let source = root.appendingPathComponent("old.tmp")
        try old.write(to: source)
        let final = try initialStore.installDownloadedFile(at: source, for: model(payload: old))
        let store = try BoneLocalModelStore(rootURL: models, beforeInstallCommit: { staged, target in
            XCTAssertEqual(try Data(contentsOf: target), old)
            XCTAssertEqual(try Data(contentsOf: staged), new)
        })
        let replacement = root.appendingPathComponent("new.tmp")
        try new.write(to: replacement)
        let installed = try store.installDownloadedFile(at: replacement, for: model(payload: new))
        XCTAssertEqual(installed, final)
        XCTAssertEqual(try Data(contentsOf: installed), new)
        XCTAssertFalse(FileManager.default.fileExists(atPath: replacement.path))
    }

    func testFailedFirstInstallLeavesSourceRetryableAndNoStaging() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let payload = Data("valid-local-model".utf8)
        let descriptor = try model(payload: payload)
        let store = try BoneLocalModelStore(rootURL: root.appendingPathComponent("models"), beforeInstallCommit: { _, _ in
            throw InstallFault.injected
        })
        let source = root.appendingPathComponent("download.tmp")
        try payload.write(to: source)
        XCTAssertThrowsError(try store.installDownloadedFile(at: source, for: descriptor))
        XCTAssertEqual(try Data(contentsOf: source), payload)
        XCTAssertEqual(store.installationState(for: descriptor), .notInstalled)
        let directory = try store.modelURL(for: descriptor).deletingLastPathComponent()
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
        try assertNoInstallStaging(store)
    }

    func testRenameFailureDoesNotRemoveExistingDestination() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let payload = Data("valid-local-model".utf8)
        let descriptor = try model(payload: payload)
        let store = try BoneLocalModelStore(rootURL: root.appendingPathComponent("models"))
        let final = try store.modelURL(for: descriptor)
        // A nonempty directory cannot be replaced by rename of a regular file.
        try FileManager.default.createDirectory(at: final, withIntermediateDirectories: true)
        let sentinel = final.appendingPathComponent("sentinel")
        try payload.write(to: sentinel)
        let source = root.appendingPathComponent("download.tmp")
        try payload.write(to: source)
        XCTAssertThrowsError(try store.installDownloadedFile(at: source, for: descriptor))
        XCTAssertEqual(try Data(contentsOf: sentinel), payload)
        XCTAssertEqual(try Data(contentsOf: source), payload)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: final.deletingLastPathComponent().path), ["model.gguf"])
        try assertNoInstallStaging(store)
    }

    func testCleanupRemovesAbandonedInstallStaging() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try BoneLocalModelStore(rootURL: root.appendingPathComponent("models"))
        let staging = store.rootURL.appendingPathComponent(".bone-install-staging")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let abandoned = staging.appendingPathComponent("orphan")
        try Data("stale".utf8).write(to: abandoned)
        try store.cleanIncompleteDownloads()
        XCTAssertFalse(FileManager.default.fileExists(atPath: abandoned.path))
    }

    func testInstallRejectsSymlinkSourceInsteadOfPublishingLink() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let payload = Data("valid-local-model".utf8)
        let descriptor = try model(payload: payload)
        let store = try BoneLocalModelStore(rootURL: root.appendingPathComponent("models"))
        let outside = root.appendingPathComponent("outside.gguf")
        let source = root.appendingPathComponent("download.tmp")
        try payload.write(to: outside)
        try FileManager.default.createSymbolicLink(at: source, withDestinationURL: outside)
        XCTAssertThrowsError(try store.installDownloadedFile(at: source, for: descriptor)) {
            XCTAssertEqual($0 as? BoneLocalModelStoreError, .invalidArtifactFileName)
        }
        XCTAssertEqual(try Data(contentsOf: outside), payload)
    }

    func testCleanupPreservesModelsAndAssetsWithInstallingSuffix() throws {
        for (id, name) in [("foo.installing", "model.gguf"), ("foo.partial", "model.installing")] {
            let root = temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let payload = Data("valid-local-model".utf8)
            var descriptor = try replacing(model(payload: payload), key: "id", value: id)
            descriptor = try replacing(descriptor, key: "fileName", value: name)
            let store = try BoneLocalModelStore(rootURL: root.appendingPathComponent("models"))
            let source = root.appendingPathComponent("download.tmp")
            try payload.write(to: source)
            let final = try store.installDownloadedFile(at: source, for: descriptor)
            try store.cleanIncompleteDownloads()
            XCTAssertEqual(try Data(contentsOf: final), payload)
        }
    }

    func testCleanupReachesHiddenModelsAndPreservesTheirFinalArtifact() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let payload = Data("valid-local-model".utf8)
        let descriptor = try replacing(model(payload: payload), key: "id", value: ".hidden-model")
        let store = try BoneLocalModelStore(rootURL: root.appendingPathComponent("models"))
        let source = root.appendingPathComponent("download.tmp")
        try payload.write(to: source)
        let final = try store.installDownloadedFile(at: source, for: descriptor)
        let partial = try store.partialURL(for: descriptor)
        try payload.write(to: partial)
        try store.cleanIncompleteDownloads()
        XCTAssertFalse(FileManager.default.fileExists(atPath: partial.path))
        XCTAssertEqual(try Data(contentsOf: final), payload)
    }

    func testStartupCleanupRemovesLegacyDownloadButPreservesInstalledModel() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let payload = Data("valid-local-model".utf8)
        let descriptor = try model(payload: payload)
        let store = try BoneLocalModelStore(rootURL: root.appendingPathComponent("models"))
        let source = root.appendingPathComponent("download.tmp")
        try payload.write(to: source)
        let final = try store.installDownloadedFile(at: source, for: descriptor)
        let legacy = try store.partialURL(for: descriptor).appendingPathExtension("download")
        try payload.write(to: legacy)
        try store.cleanIncompleteDownloads()
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path))
        XCTAssertEqual(try Data(contentsOf: final), payload)
    }

    func testDownloadStagingPathsAreUniqueAndStartupCleanupRemovesAbandonedFiles() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try BoneLocalModelStore(rootURL: root.appendingPathComponent("models"))
        let first = try store.downloadStagingURL()
        let second = try store.downloadStagingURL()
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(first.deletingLastPathComponent().lastPathComponent, ".bone-download-staging")
        try Data("first".utf8).write(to: first)
        try Data("second".utf8).write(to: second)
        try store.cleanIncompleteDownloads()
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: second.path))
    }

    func testDownloadStagingRejectsSymlinkedDirectory() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try BoneLocalModelStore(rootURL: root.appendingPathComponent("models"))
        let outside = root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let sentinel = outside.appendingPathComponent("sentinel")
        try Data("keep".utf8).write(to: sentinel)
        try FileManager.default.createSymbolicLink(at: store.rootURL.appendingPathComponent(".bone-download-staging"), withDestinationURL: outside)
        XCTAssertThrowsError(try store.downloadStagingURL())
        XCTAssertThrowsError(try store.cleanIncompleteDownloads())
        XCTAssertEqual(try Data(contentsOf: sentinel), Data("keep".utf8))
    }

    private func assertNoInstallStaging(_ store: BoneLocalModelStore, file: StaticString = #filePath, line: UInt = #line) throws {
        let staging = store.rootURL.appendingPathComponent(".bone-install-staging")
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: staging.path).isEmpty, file: file, line: line)
    }

    private enum InstallFault: Error { case injected }

    private func replacing(_ model: BoneLocalModelDescriptor, key: String, value: String) throws -> BoneLocalModelDescriptor {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(model)) as? [String: Any])
        if key == "fileName" {
            var artifact = try XCTUnwrap(object["artifact"] as? [String: Any])
            artifact[key] = value
            object["artifact"] = artifact
        } else { object[key] = value }
        return try JSONDecoder().decode(BoneLocalModelDescriptor.self, from: JSONSerialization.data(withJSONObject: object))
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
