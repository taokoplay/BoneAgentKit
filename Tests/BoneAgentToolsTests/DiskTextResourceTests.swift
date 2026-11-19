import Foundation
import XCTest
import BoneAgentKit
@testable import BoneAgentTools

final class DiskTextResourceTests: XCTestCase {
    /// 用独立临时文件运行用例，退出时清理宿主原件。
    private func withSource(_ bytes: Data, _ verify: (URL) throws -> Void) throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try bytes.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        try verify(url)
    }

    /// 同长度覆盖原件也不能改变快照；读页不拆 Unicode scalar，不吞页首 BOM。
    func testSnapshotSurvivesSourceReplacementAndPreservesExactBytes() throws {
        let text = String(repeating: "a", count: 65_535) + "🙂\u{FEFF}e\u{301}\r\n末"
        try withSource(Data(text.utf8)) { url in
            let snapshot = try BoneDiskTextResource(importing: url, name: "笔记")
            let ref = snapshot.descriptor.reference
            try Data(repeating: 98, count: ref.utf8ByteCount).write(to: url)
            let first = try snapshot.read(.init(reference: ref, maximumBytes: 65_536))
            XCTAssertEqual(first.nextOffset, 65_535)
            var joined = Data(first.text.utf8)
            var cursor = first.nextOffset
            while let offset = cursor {
                let page = try snapshot.read(.init(reference: ref, offset: offset, maximumBytes: 4))
                joined.append(contentsOf: page.text.utf8)
                cursor = page.nextOffset
            }
            XCTAssertEqual(joined, Data(text.utf8))
            XCTAssertThrowsError(try snapshot.read(.init(reference: ref, offset: 65_536))) {
                XCTAssertEqual($0 as? BoneToolTextResourceError, .invalidOffset)
            }
            let wrong = try BoneToolTextResourceReference(id: ref.id, version: "other", utf8ByteCount: joined.count)
            XCTAssertThrowsError(try snapshot.read(.init(reference: wrong))) {
                XCTAssertEqual($0 as? BoneToolTextResourceError, .referenceMismatch)
            }
        }
    }

    /// 截断、过长编码、代理区和越界码点都不能被替换字符掩盖。
    func testMalformedUTF8AndInvalidLimitsRejected() throws {
        for suffix: [UInt8] in [[0xF0, 0x9F], [0xE0, 0x80, 0x80], [0xED, 0xA0, 0x80], [0xF4, 0x90, 0x80, 0x80], [0x80]] {
            try withSource(Data(repeating: 97, count: 65_535) + Data(suffix)) { url in
                XCTAssertThrowsError(try BoneDiskTextResource(importing: url, name: "bad")) {
                    XCTAssertEqual($0 as? BoneDiskTextResourceError, .invalidEncoding)
                }
            }
        }
        try withSource(Data("12345".utf8)) { url in
            XCTAssertThrowsError(try BoneDiskTextResource(importing: url, name: "limited", maximumBytes: 4)) {
                XCTAssertEqual($0 as? BoneDiskTextResourceError, .capacityExceeded)
            }
        }
    }

    /// 空文件是合法的完整资源，目录不是文件。
    func testEmptyFileAndDirectory() throws {
        try withSource(Data()) { url in
            let resource = try BoneDiskTextResource(importing: url, name: "empty")
            let page = try resource.read(.init(reference: resource.descriptor.reference))
            XCTAssertEqual(page.text, "")
            XCTAssertNil(page.nextOffset)
            XCTAssertThrowsError(try BoneDiskTextResource(importing: url.deletingLastPathComponent(), name: "dir"))
        }
    }

    /// 在一个真实 I/O 块写入后发出取消；不允许发布已经部分写入的版本。
    func testCancellationDuringImportDoesNotPublishSnapshot() async throws {
        let source = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data(repeating: 65, count: 150_000).write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }
        let importTask = Task {
            try BoneDiskTextResource(importing: source, name: "cancel", maximumBytes: 150_000,
                afterImportBlock: { withUnsafeCurrentTask { $0?.cancel() } }, observeRead: nil)
        }
        do { _ = try await importTask.value; XCTFail("取消的导入不能交付快照") }
        catch is CancellationError { /* 取消保持独立于编码、容量和 I/O 错误。 */ }
    }
}
