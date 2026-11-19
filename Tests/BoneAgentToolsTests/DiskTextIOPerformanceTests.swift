import Foundation
import XCTest
import BoneAgentKit
@testable import BoneAgentTools

/// 默认只生成 1 MiB 文件；设置 BONE_DISK_IO_PERFORMANCE_MIB=20 或 100 可单独验收大尺寸。
final class DiskTextIOPerformanceTests: XCTestCase {
    /// 验证固定偏移随机读和 N 页实际读量；不拼接全文，也不把导入读量计入分页。
    func testFixedOffsetsAndLinearReadVolume() throws {
        // 单进程只选一个尺寸，便于外部独立记录峰值 RSS。
        let rawSize = ProcessInfo.processInfo.environment["BONE_DISK_IO_PERFORMANCE_MIB"] ?? "1"
        let size = try XCTUnwrap(Int(rawSize))
        _ = try XCTUnwrap([1, 20, 100].first { $0 == size })
        // 采用 4 KiB 请求，容许实现为 UTF-8 边界探测多读至多 8 字节。
        let pageBytes = 4_096
        let totalBytes = size * 1_048_576
        // 首中尾标记分别位于独立的页起点，1 MiB 时也不会重叠。
        let offsets = [0, totalBytes / 2, totalBytes - pageBytes]
        let markers = ["BONE-HEAD", "BONE-MIDDLE", "BONE-TAIL"]
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("bone-disk-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: url) }
        try Self.writeFixture(url: url, totalBytes: totalBytes, offsets: offsets, markers: markers)

        // 加锁统计器仅保留累计值，避免随着页数增加保留事件数组。
        let reads = ReadCounter()
        let resource = try BoneDiskTextResource(importing: url, name: "disk-\(size)MiB",
            maximumBytes: 100 * 1_048_576, observeRead: { offset, bytes in
                reads.record(offset: offset, bytes: bytes)
            })
        XCTAssertTrue(resource.descriptor.reference.utf8ByteCount == totalBytes)
        // 导入过程不应触发只用于分页的读取观察器。
        XCTAssertTrue(reads.snapshot().bytes == 0)

        // 第一笔就是直接尾读；先读首部会掩盖实现预先扫描或缓存的缺陷。
        for index in [2, 0, 1] {
            reads.reset()
            let offset = offsets[index]
            let page = try resource.read(.init(reference: resource.descriptor.reference,
                offset: offset, maximumBytes: pageBytes))
            XCTAssertTrue(page.offset == offset)
            XCTAssertTrue(page.text.hasPrefix(markers[index]))
            XCTAssertTrue(page.text.utf8.count == pageBytes)
            XCTAssertTrue(page.nextOffset == (index == 2 ? nil : offset + pageBytes))
            let measured = reads.snapshot()
            XCTAssertTrue(measured.bytes >= pageBytes)
            XCTAssertTrue(measured.bytes <= pageBytes + 8)
            XCTAssertTrue(measured.minimumOffset >= offset - 4)
            print("disk_io size_mib=\(size) marker=\(markers[index]) requested_offset=\(offset) minimum_read_offset=\(measured.minimumOffset) actual_read_bytes=\(measured.bytes)")
        }

        // 分别验证 1、8、32 页；每次从中段直接开始，逐页检查读量与区间。
        for pageCount in [1, 8, 32] {
            var accumulatedBytes = 0
            var offset = totalBytes / 2
            for _ in 0..<pageCount {
                reads.reset()
                let page = try resource.read(.init(reference: resource.descriptor.reference,
                    offset: offset, maximumBytes: pageBytes))
                XCTAssertTrue(page.offset == offset)
                XCTAssertTrue(page.text.utf8.count == pageBytes)
                let measured = reads.snapshot()
                XCTAssertTrue(measured.minimumOffset >= offset - 4)
                XCTAssertTrue(measured.bytes >= pageBytes)
                XCTAssertTrue(measured.bytes <= pageBytes + 8)
                accumulatedBytes += measured.bytes
                offset = try XCTUnwrap(page.nextOffset)
            }
            XCTAssertTrue(accumulatedBytes >= pageCount * pageBytes)
            XCTAssertTrue(accumulatedBytes <= pageCount * (pageBytes + 8))
            print("disk_io size_mib=\(size) pages=\(pageCount) actual_read_bytes=\(accumulatedBytes)")
        }
    }

    /// 以固定 4 KiB 缓冲区写出真实文件；参数为路径、总字节数及标记位置/内容，无返回值。
    private static func writeFixture(url: URL, totalBytes: Int, offsets: [Int], markers: [String]) throws {
        XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: nil))
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        // 仅复用小块数据，不建立整文件 Data 或 String，也不生成稀疏文件。
        let block = Data(repeating: 0x78, count: 4_096)
        for offset in stride(from: 0, to: totalBytes, by: block.count) {
            if let index = offsets.firstIndex(of: offset) {
                var markedBlock = block
                markedBlock.replaceSubrange(0..<markers[index].utf8.count, with: markers[index].utf8)
                try handle.write(contentsOf: markedBlock)
            } else {
                try handle.write(contentsOf: block)
            }
        }
        try handle.synchronize()
    }
}

/// 同步保护观察器的累计值；所有可变状态均在锁内访问，满足 Sendable 回调要求。
private final class ReadCounter: @unchecked Sendable {
    /// 保护字节累计值和最小读取偏移的互斥锁。
    private let lock = NSLock()
    /// 本轮底层实际读取的字节数。
    private var bytes = 0
    /// 本轮非空读取的最小文件偏移。
    private var minimumOffset = Int.max

    /// 接收底层偏移和实际字节数并累计，无返回值。
    func record(offset: Int, bytes: Int) {
        lock.lock()
        defer { lock.unlock() }
        self.bytes += bytes
        if bytes > 0 { minimumOffset = min(minimumOffset, offset) }
    }

    /// 清空本轮统计，无入参和返回值。
    func reset() {
        lock.lock()
        defer { lock.unlock() }
        bytes = 0
        minimumOffset = Int.max
    }

    /// 无入参；返回当前实际读取字节总数与非空读取最小偏移。
    func snapshot() -> (bytes: Int, minimumOffset: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (bytes, minimumOffset)
    }
}
