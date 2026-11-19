import Foundation
import BoneAgentKit
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// 固定错误分类，不暴露用户文件路径或底层错误文本。
public enum BoneDiskTextResourceError: Error, Equatable, Sendable {
    case notRegularFile, invalidEncoding, capacityExceeded, unavailable
}

/// 已获宿主授权的 UTF-8 普通文件的进程内不可变快照；不负责选择文件、授权或跨进程保存。
public final class BoneDiskTextResource: Sendable {
    /// 传给工具的展示名称和不含路径的版本引用。
    public let descriptor: BoneTextResourceDescriptor
    /// 匿名临时文件仅由本对象持有；读操作使用 pread，不共享可变文件位置。
    private let snapshotFD: Int32
    /// 仅测试使用：记录快照实际读取的字节范围，不包含正文或来源路径。
    private let observeRead: (@Sendable (Int, Int) -> Void)?

    /// 将授权的本地文件按块复制并验证 UTF-8，成功后返回固定字节版本；同步 I/O 应在主线程外调用。
    public convenience init(importing source: URL, name: String, maximumBytes: Int = 100 * 1_048_576) throws {
        try self.init(importing: source, name: name, maximumBytes: maximumBytes, observeRead: nil)
    }

    /// 与公开入口使用同一读写路径；测试可在真正完成系统读取后核对偏移和字节数。
    internal init(importing source: URL, name: String, maximumBytes: Int,
                  afterImportBlock: (@Sendable () -> Void)? = nil,
                  observeRead: (@Sendable (Int, Int) -> Void)?) throws {
        try Task.checkCancellation()
        guard maximumBytes >= 0 else { throw BoneDiskTextResourceError.capacityExceeded }
        guard source.isFileURL, !source.path.utf8.contains(0) else { throw BoneDiskTextResourceError.notRegularFile }
        let id = UUID().uuidString, version = UUID().uuidString
        // 在创建临时文件前先校验展示名称。引用永远不使用传入的路径。
        _ = try BoneTextResourceDescriptor(name: name, reference: .init(id: id, version: version, utf8ByteCount: 0))
        let input = open(source.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard input >= 0 else { throw BoneDiskTextResourceError.unavailable }
        defer { _ = close(input) }
        var info = stat()
        guard fstat(input, &info) == 0 else { throw BoneDiskTextResourceError.unavailable }
        guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else { throw BoneDiskTextResourceError.notRegularFile }
        guard info.st_size >= 0, info.st_size <= maximumBytes else { throw BoneDiskTextResourceError.capacityExceeded }

        // mkstemp 独占创建 0600 文件；立即 unlink，取消、对象释放或进程退出都不会留下可重开的正文文件。
        var path = Array(FileManager.default.temporaryDirectory.appendingPathComponent("bone-text-XXXXXX").path.utf8CString)
        let output = mkstemp(&path)
        guard output >= 0 else { throw BoneDiskTextResourceError.unavailable }
        do {
            guard unlink(path) == 0, fcntl(output, F_SETFD, FD_CLOEXEC) != -1 else {
                throw BoneDiskTextResourceError.unavailable
            }
            let count = try Self.copyUTF8(from: input, to: output, limit: maximumBytes, afterBlock: afterImportBlock)
            try Task.checkCancellation()
            descriptor = try .init(name: name, reference: .init(id: id, version: version, utf8ByteCount: count))
        } catch {
            _ = close(output)
            throw error
        }
        snapshotFD = output
        self.observeRead = observeRead
    }

    deinit { _ = close(snapshotFD) }

    /// 读取精确版本的一个 UTF-8 字节窗口；拒绝落在 scalar 内部的起点，返回真实的下一偏移。
    public func read(_ request: BoneToolTextResourceReadRequest) throws -> BoneToolTextResourcePage {
        try Task.checkCancellation()
        let ref = descriptor.reference
        guard request.reference == ref else { throw BoneToolTextResourceError.referenceMismatch }
        let count = min(request.maximumBytes, ref.utf8ByteCount - request.offset)
        var bytes = Data(count: count)
        try bytes.withUnsafeMutableBytes { (buffer: UnsafeMutableRawBufferPointer) in
            var filled = 0
            while filled < count {
                let offset = request.offset + filled
                let n = pread(snapshotFD, buffer.baseAddress!.advanced(by: filled), count - filled, off_t(offset))
                if n < 0 && errno == EINTR { try Task.checkCancellation(); continue }
                guard n > 0 else { throw BoneDiskTextResourceError.unavailable }
                observeRead?(offset, n)
                filled += n
            }
        }
        guard bytes.first.map({ $0 & 0xc0 != 0x80 }) ?? true else { throw BoneToolTextResourceError.invalidOffset }
        let end = Self.completePrefix(bytes)
        try Task.checkCancellation()
        return try .init(reference: ref, offset: request.offset, text: String(decoding: bytes.prefix(end), as: UTF8.self))
    }

    /// 最多查看末尾四个字节，找出需要交给下一块的 UTF-8 scalar 起点。非法编码由严格校验拒绝。
    private static func completePrefix(_ bytes: Data) -> Int {
        guard !bytes.isEmpty, bytes[bytes.count - 1] >= 0x80 else { return bytes.count }
        var start = bytes.count - 1
        while start > max(0, bytes.count - 4), bytes[start] & 0xc0 == 0x80 { start -= 1 }
        let lead = bytes[start]
        let width = (0xc2...0xdf).contains(lead) ? 2 : (0xe0...0xef).contains(lead) ? 3 : (0xf0...0xf4).contains(lead) ? 4 : 1
        return bytes.count - start < width ? start : bytes.count
    }

    /// 在有界缓冲区内验证并复制；原文件增长、短读写和跨块 scalar 均按实际字节处理，返回复制的总长。
    private static func copyUTF8(from input: Int32, to output: Int32, limit: Int,
                                 afterBlock: (@Sendable () -> Void)?) throws -> Int {
        var buffer = Data(count: 65_536), tail = Data(), total = 0
        while true {
            try Task.checkCancellation()
            let n = buffer.withUnsafeMutableBytes { pread(input, $0.baseAddress!, $0.count, off_t(total)) }
            if n < 0 && errno == EINTR { continue }
            guard n >= 0 else { throw BoneDiskTextResourceError.unavailable }
            if n == 0 { break }
            guard n <= limit - total else { throw BoneDiskTextResourceError.capacityExceeded }
            var block = tail
            block.append(buffer.prefix(n))
            let end = completePrefix(block)
            let prefix = block.prefix(end)
            // round-trip 严格拒绝修复字节；与依赖系统版本的 NSString 解码不同，此处保留块首 BOM。
            guard Data(String(decoding: prefix, as: UTF8.self).utf8) == prefix else { throw BoneDiskTextResourceError.invalidEncoding }
            tail = Data(block.suffix(from: end))
            try buffer.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                var written = 0
                while written < n {
                    let count = pwrite(output, raw.baseAddress!.advanced(by: written), n - written, off_t(total + written))
                    if count < 0 && errno == EINTR { try Task.checkCancellation(); continue }
                    guard count > 0 else { throw BoneDiskTextResourceError.unavailable }
                    written += count
                }
            }
            total += n
            afterBlock?()
        }
        guard tail.isEmpty else { throw BoneDiskTextResourceError.invalidEncoding }
        return total
    }
}
