import Foundation
import XCTest
import BoneAgentKit
@testable import BoneAgentTools
import zlib

final class FileResourceStoreTests: XCTestCase {
    /// 在测试结束后删除私有资源目录，避免跨用例复用快照。
    private func withStore(_ body: (URL, BoneFileResourceStore) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try await body(root, BoneFileResourceStore(directory: root))
    }

    /// 写入临时来源文件并在回调结束后清理，返回 URL 供导入测试使用。
    private func withSource(_ data: Data, _ body: (URL) async throws -> Void) async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        try await body(url)
    }

    /// 生成一个无压缩 ZIP，测试只依赖标准库，不依赖宿主 zip 命令。
    private func makeStoredZIP(name: String, data: Data) -> Data {
        makeStoredZIP(entries: [(name, data)])
    }

    /// 生成包含多个无压缩条目的 ZIP，供 Office 结构化解析测试使用。
    private func makeStoredZIP(entries: [(String, Data)]) -> Data {
        func append16(_ value: UInt16, to output: inout Data) {
            output.append(UInt8(value & 0xff)); output.append(UInt8(value >> 8))
        }
        func append32(_ value: UInt32, to output: inout Data) {
            append16(UInt16(value & 0xffff), to: &output); append16(UInt16(value >> 16), to: &output)
        }
        var output = Data()
        var centralDirectory = Data()
        for (name, data) in entries {
            let nameData = Data(name.utf8)
            let checksum = data.withUnsafeBytes { raw in
                UInt32(zlib.crc32(0, raw.bindMemory(to: Bytef.self).baseAddress, uInt(data.count)))
            }
            let localOffset = UInt32(output.count)
            append32(0x04034b50, to: &output)
            append16(20, to: &output); append16(0, to: &output); append16(0, to: &output)
            append16(0, to: &output); append16(0, to: &output)
            append32(checksum, to: &output); append32(UInt32(data.count), to: &output); append32(UInt32(data.count), to: &output)
            append16(UInt16(nameData.count), to: &output); append16(0, to: &output)
            output.append(nameData); output.append(data)

            append32(0x02014b50, to: &centralDirectory)
            append16(20, to: &centralDirectory); append16(20, to: &centralDirectory)
            append16(0, to: &centralDirectory); append16(0, to: &centralDirectory)
            append16(0, to: &centralDirectory); append16(0, to: &centralDirectory)
            append32(checksum, to: &centralDirectory)
            append32(UInt32(data.count), to: &centralDirectory); append32(UInt32(data.count), to: &centralDirectory)
            append16(UInt16(nameData.count), to: &centralDirectory); append16(0, to: &centralDirectory); append16(0, to: &centralDirectory)
            append16(0, to: &centralDirectory); append16(0, to: &centralDirectory)
            append32(0, to: &centralDirectory); append32(localOffset, to: &centralDirectory)
            centralDirectory.append(nameData)
        }
        let centralOffset = UInt32(output.count)
        output.append(centralDirectory)
        let centralSize = UInt32(output.count) - centralOffset
        append32(0x06054b50, to: &output)
        append16(0, to: &output); append16(0, to: &output)
        append16(UInt16(entries.count), to: &output); append16(UInt16(entries.count), to: &output)
        append32(centralSize, to: &output); append32(centralOffset, to: &output); append16(0, to: &output)
        return output
    }

    /// 生成一个包含单个 raw deflate 条目的 ZIP，验证流式展开读取路径。
    private func makeDeflatedZIP(name: String, data: Data) -> Data {
        func append16(_ value: UInt16, to output: inout Data) {
            output.append(UInt8(value & 0xff)); output.append(UInt8(value >> 8))
        }
        func append32(_ value: UInt32, to output: inout Data) {
            append16(UInt16(value & 0xffff), to: &output); append16(UInt16(value >> 16), to: &output)
        }
        let nameData = Data(name.utf8)
        let compressed = Data(base64Encoded: "SyxKzsgsS1VIyk+pBAA=")!
        let checksum = data.withUnsafeBytes { raw in
            UInt32(zlib.crc32(0, raw.bindMemory(to: Bytef.self).baseAddress, uInt(data.count)))
        }
        var output = Data()
        append32(0x04034b50, to: &output)
        append16(20, to: &output); append16(0, to: &output); append16(8, to: &output)
        append16(0, to: &output); append16(0, to: &output)
        append32(checksum, to: &output); append32(UInt32(compressed.count), to: &output); append32(UInt32(data.count), to: &output)
        append16(UInt16(nameData.count), to: &output); append16(0, to: &output)
        output.append(nameData); output.append(compressed)
        let centralOffset = UInt32(output.count)
        append32(0x02014b50, to: &output)
        append16(20, to: &output); append16(20, to: &output); append16(0, to: &output); append16(8, to: &output)
        append16(0, to: &output); append16(0, to: &output); append32(checksum, to: &output)
        append32(UInt32(compressed.count), to: &output); append32(UInt32(data.count), to: &output)
        append16(UInt16(nameData.count), to: &output); append16(0, to: &output); append16(0, to: &output)
        append16(0, to: &output); append16(0, to: &output); append32(0, to: &output); append32(0, to: &output)
        output.append(nameData)
        let centralSize = UInt32(output.count) - centralOffset
        append32(0x06054b50, to: &output)
        append16(0, to: &output); append16(0, to: &output); append16(1, to: &output); append16(1, to: &output)
        append32(centralSize, to: &output); append32(centralOffset, to: &output); append16(0, to: &output)
        return output
    }

    /// 生成带 data descriptor 的无压缩 ZIP，覆盖常见流式打包器输出。
    private func makeDataDescriptorZIP(name: String, data: Data, corruptDescriptor: Bool = false) -> Data {
        func append16(_ value: UInt16, to output: inout Data) {
            output.append(UInt8(value & 0xff)); output.append(UInt8(value >> 8))
        }
        func append32(_ value: UInt32, to output: inout Data) {
            append16(UInt16(value & 0xffff), to: &output); append16(UInt16(value >> 16), to: &output)
        }
        let nameData = Data(name.utf8)
        let checksum = data.withUnsafeBytes { raw in
            UInt32(zlib.crc32(0, raw.bindMemory(to: Bytef.self).baseAddress, uInt(data.count)))
        }
        var output = Data()
        append32(0x04034b50, to: &output)
        append16(20, to: &output); append16(0x0008, to: &output); append16(0, to: &output)
        append16(0, to: &output); append16(0, to: &output)
        append32(0, to: &output); append32(0, to: &output); append32(0, to: &output)
        append16(UInt16(nameData.count), to: &output); append16(0, to: &output)
        output.append(nameData); output.append(data)
        append32(0x08074b50, to: &output)
        append32(corruptDescriptor ? checksum ^ 1 : checksum, to: &output)
        append32(UInt32(data.count), to: &output); append32(UInt32(data.count), to: &output)
        let centralOffset = UInt32(output.count)
        append32(0x02014b50, to: &output)
        append16(20, to: &output); append16(20, to: &output); append16(0x0008, to: &output); append16(0, to: &output)
        append16(0, to: &output); append16(0, to: &output); append32(checksum, to: &output)
        append32(UInt32(data.count), to: &output); append32(UInt32(data.count), to: &output)
        append16(UInt16(nameData.count), to: &output); append16(0, to: &output); append16(0, to: &output)
        append16(0, to: &output); append16(0, to: &output); append32(0, to: &output); append32(0, to: &output)
        output.append(nameData)
        let centralSize = UInt32(output.count) - centralOffset
        append32(0x06054b50, to: &output)
        append16(0, to: &output); append16(0, to: &output); append16(1, to: &output); append16(1, to: &output)
        append32(centralSize, to: &output); append32(centralOffset, to: &output); append16(0, to: &output)
        return output
    }

    /// 生成最小可读 PDF，供 PDFKit 页级读取回归使用。
    private func makeMinimalPDF() -> Data {
        let objects = [
            "1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n",
            "2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n",
            "3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>\nendobj\n",
            "4 0 obj\n<< /Length 44 >>\nstream\nBT /F1 24 Tf 72 720 Td (Hello PDF) Tj ET\nendstream\nendobj\n",
            "5 0 obj\n<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>\nendobj\n",
        ]
        var data = Data("%PDF-1.4\n".utf8)
        var offsets = [0]
        for object in objects {
            offsets.append(data.count)
            data.append(contentsOf: object.utf8)
        }
        let xrefOffset = data.count
        data.append(contentsOf: "xref\n0 6\n0000000000 65535 f \n".utf8)
        for offset in offsets.dropFirst() {
            data.append(contentsOf: String(format: "%010d 00000 n \n", offset).utf8)
        }
        data.append(contentsOf: "trailer\n<< /Size 6 /Root 1 0 R >>\nstartxref\n\(xrefOffset)\n%%EOF\n".utf8)
        return data
    }

    /// GB18030 导入后只保留 UTF-8 视图，分页结果不要求调用方理解原始编码。
    func testGB18030NormalizesToUTF8AndRestoresAcrossStoreInstances() async throws {
        try await withStore { root, store in
            let source = Data([0xD6, 0xD0, 0xB9, 0xFA]) // 中国
            try await withSource(source) { url in
                let metadata = try await store.importFile(source: url, name: "legacy.txt", encoding: .gb18030)
                XCTAssertEqual(metadata.originalEncoding, .gb18030)
                XCTAssertEqual(metadata.normalizedUTF8ByteCount, "中国".utf8.count)
                let page = try await store.readText(reference: metadata.reference, maximumBytes: 64)
                XCTAssertEqual(page.text, "中国")

                let restored = try await BoneFileResourceStore(directory: root).restore(metadata.reference)
                XCTAssertEqual(restored, metadata)
            }
        }
    }

    /// 同一原始字节按不同资源类型导入时，两个引用必须拥有独立 metadata 并可分别恢复。
    func testSameBytesDifferentKindsKeepIndependentMetadata() async throws {
        try await withStore { root, store in
            let sourceData = Data("same bytes".utf8)
            try await withSource(sourceData) { url in
                let text = try await store.importFile(source: url, name: "same.txt", kind: .text,
                                                       encoding: .automatic)
                let binary = try await store.importFile(source: url, name: "same.bin", kind: .binary)

                XCTAssertEqual(text.reference.sha256, binary.reference.sha256)
                XCTAssertEqual(text.reference.kind, .text)
                XCTAssertEqual(binary.reference.kind, .binary)

                let restoredText = try await BoneFileResourceStore(directory: root).restore(text.reference)
                let restoredBinary = try await BoneFileResourceStore(directory: root).restore(binary.reference)
                XCTAssertEqual(restoredText.name, "same.txt")
                XCTAssertEqual(restoredBinary.name, "same.bin")

                let page = try await BoneFileResourceStore(directory: root).readText(reference: text.reference,
                                                                                       maximumBytes: 64)
                XCTAssertEqual(page.text, "same bytes")
            }
        }
    }

    /// UTF-16 BOM 会被识别并转换，原始 BOM 不进入规范化正文。
    func testUTF16BOMNormalizesWithoutBOMInOutput() async throws {
        try await withStore { _, store in
            try await withSource(Data([0xFF, 0xFE, 0x0D, 0x54, 0x0A, 0x00])) { url in
                let metadata = try await store.importFile(source: url, encoding: .automatic)
                XCTAssertEqual(metadata.originalEncoding, .utf16LittleEndian)
                let page = try await store.readText(reference: metadata.reference, maximumBytes: 64)
                XCTAssertEqual(page.text, "名\n")
            }
        }
    }

    /// 非文本文件保留原始字节，并支持从中间偏移直接读取。
    func testBinaryResourceReadsBoundedRange() async throws {
        try await withStore { _, store in
            let bytes = Data((0..<100).map(UInt8.init))
            try await withSource(bytes) { url in
                let metadata = try await store.importFile(source: url, kind: .binary)
                let request = try BoneFileResourceByteReadRequest(reference: metadata.reference, offset: 40, maximumBytes: 12)
                let page = try await store.readBytes(request)
                XCTAssertEqual(page.offset, 40)
                XCTAssertEqual(page.data, Data((40..<52).map(UInt8.init)))
                XCTAssertEqual(page.nextOffset, 52)
            }
        }
    }

    /// 持久 blob 被篡改后，新进程模拟实例必须拒绝恢复。
    func testRestoreRejectsTamperedBlob() async throws {
        try await withStore { root, store in
            try await withSource(Data("stable".utf8)) { url in
                let metadata = try await store.importFile(source: url)
                let blob = root.appendingPathComponent("blobs/")
                    .appendingPathComponent(metadata.reference.sha256 + ".blob")
                try Data("changed".utf8).write(to: blob)
                do {
                    _ = try await BoneFileResourceStore(directory: root).restore(metadata.reference)
                    XCTFail("篡改后的 blob 不应恢复")
                } catch let error as BoneFileResourceError {
                    XCTAssertEqual(error, .expired)
                }
            }
        }
    }

    /// 多字节 UTF-8 字符跨固定分块边界时，规范化内容仍必须与原文一致。
    func testUTF8CharactersCrossChunkBoundaryWithoutLoss() async throws {
        try await withStore { _, store in
            let prefix = String(repeating: "a", count: BoneFileResourceStore.maximumChunkBytes - 1)
            try await withSource(Data((prefix + "中\n").utf8)) { url in
                let metadata = try await store.importFile(source: url, encoding: .automatic)
                let page = try await store.readText(reference: metadata.reference, maximumBytes: 65_536)
                XCTAssertTrue(page.text.hasPrefix(prefix))
                XCTAssertEqual(page.nextOffset, page.offset + page.text.utf8.count)
                let tail = try await store.readText(reference: metadata.reference, offset: page.nextOffset ?? 0, maximumBytes: 64)
                XCTAssertEqual(tail.text, "中\n")
            }
        }
    }

    /// UTF-16 的两个字节单元跨分块边界时，规范化视图不能产生替换字符。
    func testUTF16CharactersCrossChunkBoundaryWithoutLoss() async throws {
        try await withStore { _, store in
            let prefix = String(repeating: "a", count: BoneFileResourceStore.maximumChunkBytes / 2 - 1)
            let sourceText = prefix + "名\n"
            var data = Data([0xFF, 0xFE])
            for unit in sourceText.utf16 {
                data.append(UInt8(unit & 0xFF))
                data.append(UInt8(unit >> 8))
            }
            try await withSource(data) { url in
                let metadata = try await store.importFile(source: url, encoding: .automatic)
                let page = try await store.readText(reference: metadata.reference, maximumBytes: 65_536)
                XCTAssertEqual(page.text, sourceText)
                XCTAssertFalse(page.text.contains("�"))
            }
        }
    }

    /// GB18030 的四字节序列跨分块边界时，规范化视图仍必须完整解码。
    func testGB18030CharactersCrossChunkBoundaryWithoutLoss() async throws {
        try await withStore { _, store in
            let prefix = Data(repeating: 0x61, count: BoneFileResourceStore.maximumChunkBytes - 3)
            let source = prefix + Data([0x81, 0x30, 0x81, 0x30]) + Data([0x0A])
            try await withSource(source) { url in
                let metadata = try await store.importFile(source: url, encoding: .gb18030)
                let page = try await store.readText(reference: metadata.reference, maximumBytes: 65_536)
                XCTAssertEqual(page.text.utf8.count, metadata.normalizedUTF8ByteCount)
                XCTAssertFalse(page.text.contains("�"))
            }
        }
    }

    /// 明确选择 GB18030 时，非法字节必须拒绝导入而不能静默替换。
    func testInvalidGB18030IsRejected() async throws {
        try await withStore { _, store in
            try await withSource(Data([0x81, 0x30, 0x20])) { url in
                do {
                    _ = try await store.importFile(source: url, encoding: .gb18030)
                    XCTFail("非法 GB18030 不应被替换后导入")
                } catch let error as BoneFileResourceError {
                    XCTAssertEqual(error, .invalidEncoding)
                }
            }
        }
    }

    /// 显式选择 GBK 时，兼容的中文编码内容必须规范化为 UTF-8。
    func testGBKNormalizesToUTF8() async throws {
        try await withStore { _, store in
            try await withSource(Data([0xD6, 0xD0, 0xB9, 0xFA])) { url in
                let metadata = try await store.importFile(source: url, name: "legacy-gbk.txt", encoding: .gbk)
                XCTAssertEqual(metadata.originalEncoding, .gbk)
                let page = try await store.readText(reference: metadata.reference, maximumBytes: 64)
                XCTAssertEqual(page.text, "中国")
            }
        }
    }

    /// 文本解析失败时不发布没有 metadata 的孤儿原始 blob。
    func testFailedTextImportDoesNotLeaveOrphanBlob() async throws {
        try await withStore { root, store in
            try await withSource(Data([0xFF, 0xFF])) { url in
                do {
                    _ = try await store.importFile(source: url, name: "invalid.txt", encoding: .gb18030)
                    XCTFail("非法编码应该被拒绝")
                } catch {
                    XCTAssertEqual(error as? BoneFileResourceError, .invalidEncoding)
                }
            }
            let blobs = try FileManager.default.contentsOfDirectory(
                at: root.appendingPathComponent("blobs"), includingPropertiesForKeys: nil)
            XCTAssertTrue(blobs.isEmpty)
        }
    }

    /// 同一字节按 GBK 和 GB18030 解释时，资源版本必须区分解析选项并可分别恢复。
    func testTextEncodingIsPartOfResourceVersion() async throws {
        try await withStore { root, store in
            try await withSource(Data([0xD6, 0xD0, 0xB9, 0xFA])) { url in
                let gbk = try await store.importFile(source: url, name: "legacy-gbk.txt", encoding: .gbk)
                let gb18030 = try await store.importFile(source: url, name: "legacy-gb18030.txt", encoding: .gb18030)

                XCTAssertNotEqual(gbk.reference.version, gb18030.reference.version)
                let restoredGBK = try await BoneFileResourceStore(directory: root).restore(gbk.reference)
                let restoredGB18030 = try await BoneFileResourceStore(directory: root).restore(gb18030.reference)
                XCTAssertEqual(restoredGBK.originalEncoding, .gbk)
                XCTAssertEqual(restoredGB18030.originalEncoding, .gb18030)
            }
        }
    }

    /// ZIP 目录和条目窗口读取只返回请求范围，并拒绝路径穿越。
    func testZIPDirectoryAndBoundedEntryRead() async throws {
        try await withSource(makeStoredZIP(name: "folder/item.txt", data: Data("archive body".utf8))) { url in
            let entries = try BoneFileArchiveReader.listEntries(at: url)
            XCTAssertEqual(entries.map(\.name), ["folder/item.txt"])
            let page = try BoneFileArchiveReader.readEntry(at: url, name: "folder/item.txt", offset: 8, maximumBytes: 4)
            XCTAssertEqual(String(decoding: page.data, as: UTF8.self), "body")
            XCTAssertNil(page.nextOffset)

            let unsafe = makeStoredZIP(name: "../escape.txt", data: Data("x".utf8))
            let unsafeURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try unsafe.write(to: unsafeURL)
            defer { try? FileManager.default.removeItem(at: unsafeURL) }
            XCTAssertThrowsError(try BoneFileArchiveReader.listEntries(at: unsafeURL)) { error in
                XCTAssertEqual(error as? BoneFileResourceError, .archiveUnsafe)
            }
        }
    }

    /// ZIP data descriptor 的 CRC 和尺寸必须与中央目录一致。
    func testZIPDataDescriptorIsValidated() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try makeDataDescriptorZIP(name: "item.txt", data: Data("archive body".utf8)).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let page = try BoneFileArchiveReader.readEntry(at: url, name: "item.txt", offset: 8, maximumBytes: 4)
        XCTAssertEqual(String(decoding: page.data, as: UTF8.self), "body")

        let corruptURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try makeDataDescriptorZIP(name: "item.txt", data: Data("archive body".utf8), corruptDescriptor: true).write(to: corruptURL)
        defer { try? FileManager.default.removeItem(at: corruptURL) }
        XCTAssertThrowsError(try BoneFileArchiveReader.readEntry(at: corruptURL, name: "item.txt")) { error in
            XCTAssertEqual(error as? BoneFileResourceError, .parseFailed)
        }
    }

    /// ZIP 条目数据被篡改时必须通过 CRC 校验拒绝读取。
    func testZIPRejectsCorruptCRC() throws {
        var archive = makeStoredZIP(name: "item.txt", data: Data("archive body".utf8))
        archive[30 + "item.txt".utf8.count] ^= 0x01
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try archive.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertThrowsError(try BoneFileArchiveReader.readEntry(at: url, name: "item.txt")) { error in
            XCTAssertEqual(error as? BoneFileResourceError, .parseFailed)
        }
    }

    /// ZIP 中央目录指向文件末尾之外时必须在读取前失败。
    func testZIPRejectsEntryDataOutsideFile() throws {
        var archive = makeStoredZIP(name: "item.txt", data: Data("archive body".utf8))
        let centralOffset = archive.count - 22 - (46 + "item.txt".utf8.count)
        let localOffsetField = centralOffset + 42
        archive[localOffsetField] = 0xFF
        archive[localOffsetField + 1] = 0xFF
        archive[localOffsetField + 2] = 0xFF
        archive[localOffsetField + 3] = 0x7F
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try archive.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertThrowsError(try BoneFileArchiveReader.readEntry(at: url, name: "item.txt")) { error in
            XCTAssertEqual(error as? BoneFileResourceError, .parseFailed)
        }
    }

    /// ZIP 条目加密标志必须暴露，读取时返回稳定的受保护错误。
    func testZIPEncryptedEntryIsDetectedAndRejected() throws {
        var archive = makeStoredZIP(name: "secret.txt", data: Data("secret".utf8))
        let centralOffset = archive.count - 22 - (46 + "secret.txt".utf8.count)
        archive[6] = 0x01
        archive[centralOffset + 8] = 0x01
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try archive.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let entries = try BoneFileArchiveReader.listEntries(at: url)
        XCTAssertEqual(entries.first?.isEncrypted, true)
        XCTAssertThrowsError(try BoneFileArchiveReader.readEntry(at: url, name: "secret.txt")) { error in
            XCTAssertEqual(error as? BoneFileResourceError, .protectedContent)
        }
    }

    /// deflate 条目通过临时文件流式展开后仍返回正确窗口。
    func testZIPDeflateEntryReadsContent() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try makeDeflatedZIP(name: "item.txt", data: Data("archive body".utf8)).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let page = try BoneFileArchiveReader.readEntry(at: url, name: "item.txt", offset: 8, maximumBytes: 4)
        XCTAssertEqual(String(decoding: page.data, as: UTF8.self), "body")
    }

    /// GZIP 作为单条 content 虚拟条目读取，目录长度来自 gzip 尾部校验字段。
    func testGZIPVirtualEntryReadsContent() throws {
        let encoded = "H4sIAAAAAAAAA8tIzcnJV0gsSs7ILEvlAgB1g/EGDgAAAA=="
        let data = try XCTUnwrap(Data(base64Encoded: encoded))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let entries = try BoneFileArchiveReader.listEntries(at: url)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].name, "content")
        XCTAssertEqual(entries[0].uncompressedByteCount, 14)
        let page = try BoneFileArchiveReader.readEntry(at: url, name: "content", offset: 0, maximumBytes: 64)
        XCTAssertEqual(String(decoding: page.data, as: UTF8.self), "hello archive\n")
    }

    /// GZIP 尾部校验被篡改时必须拒绝读取，而不能只相信 ISIZE。
    func testGZIPRejectsCorruptChecksum() throws {
        var data = try XCTUnwrap(Data(base64Encoded: "H4sIAAAAAAAAA8tIzcnJV0gsSs7ILEvlAgB1g/EGDgAAAA=="))
        data[data.count - 5] ^= 0x01
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertThrowsError(try BoneFileArchiveReader.readEntry(at: url, name: "content")) { error in
            XCTAssertEqual(error as? BoneFileResourceError, .parseFailed)
        }
    }

    /// OOXML 包的 XML 条目被投影为有限 UTF-8 文本，且通过持久引用恢复后仍可读取。
    func testOfficeOpenXMLTextProjection() async throws {
        try await withStore { _, store in
            let xml = Data("<document><p>Hello &amp; 世界</p></document>".utf8)
            try await withSource(makeStoredZIP(name: "word/document.xml", data: xml)) { url in
                let metadata = try await store.importFile(source: url, name: "notes.docx", kind: .officeOpenXML)
                let inspection = try await store.inspect(metadata.reference)
                XCTAssertEqual(inspection.office?.fileExtension, "docx")
                XCTAssertEqual(inspection.office?.textEntryNames, ["word/document.xml"])
                let request = try BoneFileResourceWindowRequest(reference: metadata.reference, kind: .officeText,
                                                                 maximumBytes: 64)
                let result = try await store.readWindow(request)
                XCTAssertEqual(result.text, "Hello & 世界\n")

                let structure = try await store.readOfficeStructure(
                    BoneFileResourceOfficeStructureRequest(reference: metadata.reference)
                )
                XCTAssertEqual(structure.structure.paragraphs.map(\.text), ["Hello & 世界"])
            }
        }
    }

    /// DOCX 结构化读取只返回段落文本，不把样式和关系 XML 混入正文。
    func testDOCXStructuredParagraphs() async throws {
        let document = """
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
          <w:body><w:p><w:r><w:t>Hello</w:t></w:r><w:r><w:t> Word</w:t></w:r></w:p>
          <w:p><w:r><w:t>第二段</w:t></w:r></w:p></w:body>
        </w:document>
        """
        try await withSource(makeStoredZIP(name: "word/document.xml", data: Data(document.utf8))) { url in
            let structure = try BoneStructuredFileReaders.readOfficeStructure(at: url, fileExtension: "docx")
            XCTAssertEqual(structure.paragraphs.map(\.text), ["Hello Word", "第二段"])
        }
    }

    /// XLSX 结构化读取解析工作表名称、单元格地址和 shared strings 值。
    func testXLSXStructuredWorksheetsAndCells() async throws {
        let sharedStrings = "<sst xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\"><si><t>产品</t></si></sst>"
        let workbook = """
        <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
          <sheets><sheet name="销售" sheetId="1" r:id="rId1"/></sheets>
        </workbook>
        """
        let relationships = """
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
          <Relationship Id="rId1" Target="worksheets/sheet1.xml" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet"/>
        </Relationships>
        """
        let sheet = """
        <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
          <sheetData><row r="1"><c r="A1" t="s"><v>0</v></c><c r="B1"><v>42</v></c></row></sheetData>
        </worksheet>
        """
        let entries: [(String, Data)] = [
            ("xl/sharedStrings.xml", Data(sharedStrings.utf8)),
            ("xl/workbook.xml", Data(workbook.utf8)),
            ("xl/_rels/workbook.xml.rels", Data(relationships.utf8)),
            ("xl/worksheets/sheet1.xml", Data(sheet.utf8)),
        ]
        try await withSource(makeStoredZIP(entries: entries)) { url in
            let structure = try BoneStructuredFileReaders.readOfficeStructure(at: url, fileExtension: "xlsx")
            XCTAssertEqual(structure.worksheets.count, 1)
            XCTAssertEqual(structure.worksheets[0].name, "销售")
            XCTAssertEqual(structure.worksheets[0].cells.map(\.value), ["产品", "42"])
            XCTAssertEqual(structure.worksheets[0].cells.map(\.address), ["A1", "B1"])
        }
    }

    /// PPTX 结构化读取按幻灯片顺序返回文本。
    func testPPTXStructuredSlides() async throws {
        let slide = """
        <p:sld xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main" xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main">
          <p:cSld><a:t>标题</a:t><a:t>正文</a:t></p:cSld>
        </p:sld>
        """
        try await withSource(makeStoredZIP(name: "ppt/slides/slide1.xml", data: Data(slide.utf8))) { url in
            let structure = try BoneStructuredFileReaders.readOfficeStructure(at: url, fileExtension: "pptx")
            XCTAssertEqual(structure.slides.map(\.text), ["标题正文"])
        }
    }

    /// PDF 布局和 OCR 请求必须只接受 PDF 引用，并拒绝越界预算。
    func testPDFLayoutAndOCRRequestsValidatePDFAndBudgets() throws {
        let textReference = try BoneFileResourceReference(
            id: "resource",
            version: "version",
            sha256: String(repeating: "a", count: 64),
            byteCount: 10,
            kind: .text
        )
        XCTAssertThrowsError(try BoneFileResourcePDFLayoutRequest(reference: textReference))
        XCTAssertThrowsError(try BoneFileResourceOCRRequest(reference: textReference))

        let pdfReference = try BoneFileResourceReference(
            id: "pdf",
            version: "version",
            sha256: String(repeating: "b", count: 64),
            byteCount: 10,
            kind: .pdf
        )
        XCTAssertThrowsError(try BoneFileResourcePDFLayoutRequest(reference: pdfReference, pageCount: 0))
        XCTAssertThrowsError(try BoneFileResourcePDFLayoutRequest(reference: pdfReference, maximumElements: 0))
        XCTAssertThrowsError(try BoneFileResourceOCRRequest(reference: pdfReference, maximumObservations: 0))
        XCTAssertThrowsError(try BoneFileResourceOCRRequest(reference: pdfReference, languages: [String(repeating: "x", count: 33)]))
    }

    /// 布局和 OCR 结果必须保持连续页序、引用和预算，分页游标不能被伪造。
    func testPDFLayoutAndOCRResultValidationRejectsInvalidPagingAndBudget() throws {
        let reference = try BoneFileResourceReference(
            id: "pdf",
            version: "version",
            sha256: String(repeating: "c", count: 64),
            byteCount: 10,
            kind: .pdf
        )
        let layoutRequest = try BoneFileResourcePDFLayoutRequest(reference: reference, pageCount: 2,
                                                                  maximumTextBytes: 4, maximumElements: 1)
        let layoutPage = try BoneFilePDFLayoutPage(
            pageIndex: 0,
            mediaBox: try BoneFilePDFRectangle(x: 0, y: 0, width: 10, height: 10),
            cropBox: try BoneFilePDFRectangle(x: 0, y: 0, width: 10, height: 10),
            rotation: 0,
            text: [],
            annotationBounds: []
        )
        let layout = BoneFileResourcePDFLayoutResult(reference: reference, pages: [layoutPage], nextPage: 2)
        XCTAssertThrowsError(try layout.validated(for: layoutRequest))

        let ocrRequest = try BoneFileResourceOCRRequest(reference: reference, pageCount: 2, maximumBytes: 4,
                                                        maximumObservations: 1)
        let observation = try BoneFilePDFOCRObservation(
            text: "too long",
            bounds: try BoneFilePDFRectangle(x: 0, y: 0, width: 1, height: 1),
            confidence: 0.9
        )
        let ocrPage = try BoneFilePDFOCRPage(pageIndex: 0, observations: [observation], text: "too long")
        let ocr = BoneFileResourceOCRResult(reference: reference, pages: [ocrPage], nextPage: 1)
        XCTAssertThrowsError(try ocr.validated(for: ocrRequest))
    }

    /// 空白 PDF 页仍然是有效页，不能因为没有正文而被判为解析失败。
    func testPDFEmptyPageIsReadable() throws {
        let page = try BoneFilePDFPage(pageIndex: 0, text: "", isTruncated: false)
        XCTAssertEqual(page.pageIndex, 0)
        XCTAssertEqual(page.text, "")
        XCTAssertFalse(page.isTruncated)
    }

    /// PDF 快照可按页检查并读取文本，正文仍以页级预算返回。
    func testPDFInspectionAndPageRead() async throws {
        try await withStore { _, store in
            try await withSource(makeMinimalPDF()) { url in
                let metadata = try await store.importFile(source: url, name: "hello.pdf", kind: .pdf)
                let inspection = try await store.inspect(metadata.reference)
                XCTAssertEqual(inspection.pdf?.pageCount, 1)
                let request = try BoneFileResourceWindowRequest(reference: metadata.reference, kind: .pdfPage,
                                                                 maximumBytes: 64, pageIndex: 0)
                let result = try await store.readWindow(request)
                XCTAssertEqual(result.text, "Hello PDF")
                XCTAssertEqual(result.pageIndex, 0)

                let layoutRequest = try BoneFileResourcePDFLayoutRequest(
                    reference: metadata.reference,
                    maximumTextBytes: 64,
                    maximumElements: 16
                )
                let layout = try BoneStructuredFileReaders.readPDFLayout(at: url, request: layoutRequest)
                XCTAssertEqual(layout.pages.map(\.pageIndex), [0])
                XCTAssertEqual(layout.pages.first?.mediaBox.width, 612)
                XCTAssertEqual(layout.pages.first?.mediaBox.height, 792)
                XCTAssertEqual(layout.pages.first?.text.map(\.text).joined(), "Hello PDF")
                XCTAssertNil(layout.nextPage)
            }
        }
    }

    /// 持久快照格式探测应覆盖常见文本、容器和二进制类型。
    func testStoreDetectsPersistedResourceFormats() async throws {
        try await withStore { _, store in
            let fixtures: [(String, Data, BoneFileResourceKind, BoneFileResourceEncoding, String, String)] = [
                ("utf8.txt", Data("hello".utf8), .text, .automatic, "utf8", "text/plain"),
                ("legacy.txt", Data([0xD6, 0xD0]), .text, .gbk, "gbk", "text/plain"),
                ("document.pdf", makeMinimalPDF(), .pdf, .automatic, "pdf", "application/pdf"),
                ("document.docx", makeStoredZIP(name: "word/document.xml", data: Data("<w:document/>".utf8)), .officeOpenXML, .automatic, "docx", "application/vnd.openxmlformats-officedocument.wordprocessingml.document"),
                ("archive.zip", makeStoredZIP(name: "item.txt", data: Data("item".utf8)), .archive, .automatic, "zip", "application/zip"),
                ("archive.gz", Data([0x1F, 0x8B, 0x08, 0x00]), .archive, .automatic, "gzip", "application/gzip"),
                ("data.bin", Data([0x00, 0xFF, 0x01]), .binary, .automatic, "binary", "application/octet-stream"),
            ]

            for (name, data, kind, encoding, subtype, mimeType) in fixtures {
                try await withSource(data) { url in
                    let metadata = try await store.importFile(source: url, name: name, kind: kind, encoding: encoding)
                    let format = try await store.detectFormat(metadata.reference)
                    XCTAssertEqual(format.subtype, subtype, name)
                    XCTAssertEqual(format.mimeType, mimeType, name)
                    XCTAssertEqual(format.family.matches(kind), true, name)
                    if kind == .pdf {
                        XCTAssertTrue(format.capabilities.contains(.readPDFLayout))
                        XCTAssertTrue(format.capabilities.contains(.ocr))
                    }
                }
            }
        }
    }

    /// 恶意派生 token 不能通过 Codable metadata 解码进入视图目录。
    func testMetadataRejectsUnsafeDerivedViewToken() throws {
        let reference = try BoneFileResourceReference(id: "id", version: "version",
                                                       sha256: String(repeating: "a", count: 64),
                                                       byteCount: 1, kind: .text)
        XCTAssertThrowsError(try BoneFileResourceMetadata(name: "x.txt", reference: reference,
                                                           originalEncoding: .utf8,
                                                           normalizedUTF8ByteCount: 1,
                                                           normalizedTextPathToken: "../escape"))
    }
}

final class FileResourceToolDefinitionTests: XCTestCase {
    /// 所有新增文件工具都必须有完整模型 Schema，且不改变旧工具 ID。
    func testFileResourceToolsExposeValidatedSchemas() throws {
        let definitions: [BoneAgentToolDefinition] = [
            BoneFileResourceInspectTool<BoneAgentEmptyContext>.definition,
            BoneFileResourceDetectFormatTool<BoneAgentEmptyContext>.definition,
            BoneFileResourceReadWindowTool<BoneAgentEmptyContext>.definition,
            BoneFileResourceReadOfficeTool<BoneAgentEmptyContext>.definition,
            BoneFileResourceListEntriesTool<BoneAgentEmptyContext>.definition,
            BoneFileResourceReadBytesTool<BoneAgentEmptyContext>.definition,
            BoneFileResourcePDFLayoutTool<BoneAgentEmptyContext>.definition,
            BoneFileResourceOCRTool<BoneAgentEmptyContext>.definition,
        ]
        XCTAssertEqual(definitions.map(\.id), [
            "resource.inspect", "resource.detectFormat", "resource.readWindow", "resource.readOffice", "resource.listEntries", "resource.readBytes", "resource.readPDFLayout", "resource.ocr"
        ])
        for definition in definitions {
            XCTAssertNoThrow(try definition.validatedForModelExposure())
        }
    }
}

final class FileResourceFormatAndToolContractTests: XCTestCase {
    /// 格式探测结果必须提供稳定的具体格式、MIME、置信度和读取能力。
    func testFormatInspectionExposesConcreteCapabilities() throws {
        let inspection = try BoneFileResourceFormatInspection(
            family: .text,
            subtype: "utf8",
            mimeType: "text/plain",
            confidence: .high,
            encoding: .utf8,
            capabilities: [.readWindow, .search],
            protectionStatus: .none
        )

        XCTAssertEqual(inspection.family, .text)
        XCTAssertEqual(inspection.subtype, "utf8")
        XCTAssertEqual(inspection.mimeType, "text/plain")
        XCTAssertEqual(inspection.capabilities, [.readWindow, .search])
    }

    /// 旧版 inspection JSON 缺少 format 字段时仍可恢复。
    func testInspectionDecodingRemainsCompatibleWithoutFormatField() throws {
        let reference = try BoneFileResourceReference(
            id: "resource",
            version: "version",
            sha256: String(repeating: "a", count: 64),
            byteCount: 1,
            kind: .binary
        )
        let metadata = try BoneFileResourceMetadata(name: "data.bin", reference: reference)
        let data = try JSONEncoder().encode(BoneFileResourceInspection(metadata: metadata))
        let decoded = try JSONDecoder().decode(BoneFileResourceInspection.self, from: data)

        XCTAssertNil(decoded.format)
        XCTAssertEqual(decoded.metadata.reference, reference)
    }

    /// 窗口请求必须只携带当前读取模式需要的定位字段。
    func testWindowRequestRejectsFieldsFromAnotherMode() throws {
        let reference = try BoneFileResourceReference(
            id: "resource",
            version: "version",
            sha256: String(repeating: "a", count: 64),
            byteCount: 10,
            kind: .text
        )

        XCTAssertThrowsError(try BoneFileResourceWindowRequest(
            reference: reference,
            kind: .text,
            pageIndex: 0
        ))
    }

    /// 结构化窗口结果不能携带与请求不同的资源引用或模式字段。
    func testWindowResultValidationRejectsMismatchedReferenceAndKind() throws {
        let reference = try BoneFileResourceReference(
            id: "resource",
            version: "version",
            sha256: String(repeating: "a", count: 64),
            byteCount: 10,
            kind: .text
        )
        let request = try BoneFileResourceWindowRequest(reference: reference, kind: .text, maximumBytes: 4)
        let otherReference = try BoneFileResourceReference(
            id: "other",
            version: "version",
            sha256: String(repeating: "b", count: 64),
            byteCount: 10,
            kind: .text
        )
        let result = BoneFileResourceWindowResult(reference: otherReference, kind: .archiveEntry, text: "data")

        XCTAssertThrowsError(try result.validated(for: request))
    }

    /// PDF 窗口结果的正文不得超过请求的 UTF-8 字节预算。
    func testWindowResultValidationRejectsPDFTextOverBudget() throws {
        let reference = try BoneFileResourceReference(
            id: "resource",
            version: "version",
            sha256: String(repeating: "a", count: 64),
            byteCount: 10,
            kind: .pdf
        )
        let request = try BoneFileResourceWindowRequest(
            reference: reference,
            kind: .pdfPage,
            maximumBytes: 4,
            pageIndex: 0
        )
        let result = BoneFileResourceWindowResult(
            reference: reference,
            kind: .pdfPage,
            text: "超过预算",
            pageIndex: 0,
            isTruncated: true
        )

        XCTAssertThrowsError(try result.validated(for: request))
    }

    /// 授权失败时统一工厂必须在调用 Host handler 前拒绝请求。
    func testResourceToolFactoryDeniesBeforeHandlerExecution() async throws {
        let reference = try BoneFileResourceReference(
            id: "resource",
            version: "version",
            sha256: String(repeating: "a", count: 64),
            byteCount: 10,
            kind: .text
        )
        let request = BoneFileResourceInspectRequest(reference: reference)
        let authorizer = BoneFileResourceAuthorizer<BoneAgentEmptyContext> { _, _ in
            throw BoneFileResourceError.accessDenied
        }
        let handlerCalled = ManagedHandlerCallState()
        let tool = BoneFileResourceToolFactory.makeInspectTool(
            authorizer: authorizer,
            inspect: { (_: BoneFileResourceInspectRequest, _: BoneAgentEmptyContext) in
                handlerCalled.markCalled()
                return BoneFileResourceInspection(metadata: try BoneFileResourceMetadata(name: "a.txt", reference: reference, originalEncoding: .utf8, normalizedUTF8ByteCount: 1, normalizedTextPathToken: "view"))
            }
        )

        do {
            _ = try await tool.execute(input: request, context: BoneAgentEmptyContext())
            XCTFail("expected access denial")
        } catch BoneFileResourceError.accessDenied {
            XCTAssertFalse(handlerCalled.wasCalled)
        }
    }
}

private final class ManagedHandlerCallState: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    /// 记录 Host handler 是否被调用。
    func markCalled() {
        lock.lock()
        value = true
        lock.unlock()
    }

    /// 读取 Host handler 调用状态。
    var wasCalled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}
