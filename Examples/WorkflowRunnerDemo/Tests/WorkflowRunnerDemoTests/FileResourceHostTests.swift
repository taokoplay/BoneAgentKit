import Foundation
import Testing
import BoneAgentTools
@testable import WorkflowRunnerDemo

struct FileResourceHostTests {
    @Test
    func importsGBKTextAndRestoresItAcrossHostInstances() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let source = root.appendingPathComponent("中文.txt")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data([0xD6, 0xD0, 0xCE, 0xC4]).write(to: source)

        let first = DemoFileResourceStore(directory: root.appendingPathComponent("store", isDirectory: true))
        let imported = try await first.add(importing: source, kind: .text, encoding: .gbk)
        let format = try await first.detectFormat(imported.reference)
        #expect(format.encoding == .gbk)
        #expect(format.subtype == "gbk")

        let request = try BoneFileResourceWindowRequest(reference: imported.reference, kind: .text, maximumBytes: 16)
        let page = try await first.readWindow(request)
        #expect(page.text == "中文")
        #expect(page.nextOffset == nil)

        let state = try await first.exportPrivateState()
        try FileManager.default.removeItem(at: source)
        let restored = try DemoFileResourceStore(privateState: state, directory: root.appendingPathComponent("store", isDirectory: true))
        #expect(await restored.entries() == [imported])
        #expect(try await restored.readWindow(request).text == "中文")
    }

    @Test
    func restoresBinarySnapshotAndReadsBoundedPagesAfterSourceRemoval() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let source = root.appendingPathComponent("payload.bin")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data([0, 1, 2, 3, 4, 5, 6, 7]).write(to: source)

        let directory = root.appendingPathComponent("store", isDirectory: true)
        let first = DemoFileResourceStore(directory: directory)
        let imported = try await first.add(importing: source, kind: .binary)
        let state = try await first.exportPrivateState()
        try FileManager.default.removeItem(at: source)

        let restored = try DemoFileResourceStore(privateState: state, directory: directory)
        let firstPage = try await restored.readBytes(.init(reference: imported.reference, offset: 0, maximumBytes: 3))
        #expect(Array(firstPage.data) == [0, 1, 2])
        #expect(firstPage.nextOffset == 3)
        let secondPage = try await restored.readBytes(.init(reference: imported.reference, offset: firstPage.nextOffset!, maximumBytes: 3))
        #expect(Array(secondPage.data) == [3, 4, 5])
        #expect(secondPage.nextOffset == 6)
    }

    @Test
    func fileAccessRequiresExactReferenceVersion() async throws {
        let access = DemoFileResourceAccess()
        let reference = try BoneFileResourceReference(
            id: "resource-1", version: "version-1",
            sha256: String(repeating: "a", count: 64), byteCount: 4, kind: .binary
        )
        let changed = try BoneFileResourceReference(
            id: reference.id, version: "version-2",
            sha256: reference.sha256, byteCount: reference.byteCount, kind: reference.kind
        )
        await access.allow([reference])
        #expect(await access.permits(reference))
        #expect(!(await access.permits(changed)))
        await access.revoke(id: reference.id)
        #expect(!(await access.permits(reference)))
    }
}
