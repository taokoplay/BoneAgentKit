import Foundation
import zlib
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// 在已验证的本地压缩快照上提供安全目录和有界条目读取。
public enum BoneFileArchiveReader {
    public static let maximumEntries = 10_000
    public static let maximumExpandedBytes = 100 * 1_048_576
    public static let maximumCompressionRatio = 1_000
    private static let maximumEOCDSearchBytes = 65_557
    private static let maximumChunkBytes = 65_536
    private static let maximumCentralDirectoryBytes = 16 * 1_048_576

    /// 读取 ZIP 或 GZIP 快照的安全条目目录。
    /// - Parameter url: Host 私有存储中的压缩快照路径。
    /// - Returns: 目录条目；GZIP 返回单个 content 虚拟条目。
    public static func listEntries(at url: URL) throws -> [BoneFileArchiveEntry] {
        let descriptor = try openRegularFile(url)
        defer { _ = close(descriptor.fd) }
        let header = try readPrefix(fd: descriptor.fd, count: 2)
        if header == Data([0x1F, 0x8B]) {
            let uncompressedByteCount = try gzipISize(fd: descriptor.fd, byteCount: descriptor.byteCount)
            return [try BoneFileArchiveEntry(name: "content", compressedByteCount: descriptor.byteCount,
                                             uncompressedByteCount: uncompressedByteCount,
                                             isDirectory: false, isSymbolicLink: false, isEncrypted: false)]
        }
        return try parseZIP(fd: descriptor.fd, byteCount: descriptor.byteCount).map(\.entry)
    }

    /// 读取 ZIP/GZIP 条目的一个展开后字节窗口，展开内容只落到临时文件。
    /// - Parameters:
    ///   - url: Host 私有存储中的压缩快照路径。
    ///   - name: 条目名；GZIP 使用 content。
    ///   - offset: 展开内容偏移。
    ///   - maximumBytes: 本次最多返回的字节数。
    /// - Returns: 有界条目页。
    public static func readEntry(at url: URL, name: String, offset: Int = 0,
                                 maximumBytes: Int = 4_096) throws -> BoneFileArchivePage {
        guard (1...BoneFileResourceByteReadRequest.maximumPageBytes).contains(maximumBytes), offset >= 0 else {
            throw BoneFileResourceError.invalidRequest
        }
        let descriptor = try openRegularFile(url)
        defer { _ = close(descriptor.fd) }
        let header = try readPrefix(fd: descriptor.fd, count: 2)
        if header == Data([0x1F, 0x8B]) {
            guard name == "content" else { throw BoneFileResourceError.invalidReference }
            return try readGZIP(fd: descriptor.fd, byteCount: descriptor.byteCount, name: name,
                                offset: offset, maximumBytes: maximumBytes)
        }
        guard name != "" else { throw BoneFileResourceError.invalidReference }
        let parsed = try parseZIP(fd: descriptor.fd, byteCount: descriptor.byteCount)
        guard let item = parsed.first(where: { $0.entry.name == name }) else {
            throw BoneFileResourceError.invalidReference
        }
        guard !item.entry.isDirectory, !item.entry.isSymbolicLink else {
            throw BoneFileResourceError.archiveUnsafe
        }
        guard !item.entry.isEncrypted else {
            throw BoneFileResourceError.protectedContent
        }
        return try readZIPEntry(fd: descriptor.fd, item: item, offset: offset, maximumBytes: maximumBytes)
    }

    private struct OpenFile {
        let fd: Int32
        let byteCount: Int
    }

    private struct ZIPItem {
        let entry: BoneFileArchiveEntry
        let compressionMethod: UInt16
        let flags: UInt16
        let expectedCRC32: UInt32
        let localHeaderOffset: Int
        let dataOffset: Int
    }

    private static func openRegularFile(_ url: URL) throws -> OpenFile {
        guard url.isFileURL else { throw BoneFileResourceError.notRegularFile }
        let fd = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { throw BoneFileResourceError.unavailable }
        var info = stat()
        guard fstat(fd, &info) == 0 else { _ = close(fd); throw BoneFileResourceError.unavailable }
        guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), info.st_size >= 0,
              info.st_size <= Int64(Int.max) else {
            _ = close(fd)
            throw BoneFileResourceError.notRegularFile
        }
        return OpenFile(fd: fd, byteCount: Int(info.st_size))
    }

    private static func readPrefix(fd: Int32, count: Int) throws -> Data {
        var data = Data(count: count)
        let n = data.withUnsafeMutableBytes { pread(fd, $0.baseAddress!, count, 0) }
        guard n >= 0 else { throw BoneFileResourceError.unavailable }
        data.removeSubrange(n..<data.count)
        return data
    }

    private static func readBytes(fd: Int32, offset: Int, count: Int) throws -> Data {
        guard offset >= 0, count >= 0 else { throw BoneFileResourceError.invalidRequest }
        let size = try fileSize(fd)
        guard offset <= size, count <= size - offset else { throw BoneFileResourceError.parseFailed }
        var data = Data(count: count)
        var filled = 0
        try data.withUnsafeMutableBytes { raw in
            while filled < count {
                try Task.checkCancellation()
                let n = pread(fd, raw.baseAddress!.advanced(by: filled), count - filled, off_t(offset + filled))
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { throw BoneFileResourceError.unavailable }
                filled += n
            }
        }
        return data
    }

    private static func littleEndian16(_ data: Data, _ offset: Int) throws -> UInt16 {
        guard offset >= 0, offset + 2 <= data.count else { throw BoneFileResourceError.parseFailed }
        return UInt16(data[offset]) | UInt16(data[offset + 1]) << 8
    }

    private static func littleEndian32(_ data: Data, _ offset: Int) throws -> UInt32 {
        guard offset >= 0, offset + 4 <= data.count else { throw BoneFileResourceError.parseFailed }
        return UInt32(data[offset]) | UInt32(data[offset + 1]) << 8 |
            UInt32(data[offset + 2]) << 16 | UInt32(data[offset + 3]) << 24
    }

    private static func parseZIP(fd: Int32, byteCount: Int) throws -> [ZIPItem] {
        guard byteCount >= 22 else { throw BoneFileResourceError.parseFailed }
        let searchLength = min(byteCount, maximumEOCDSearchBytes)
        let searchOffset = byteCount - searchLength
        let tail = try readBytes(fd: fd, offset: searchOffset, count: searchLength)
        var eocdOffset: Int?
        if searchLength >= 22 {
            for index in stride(from: searchLength - 22, through: 0, by: -1) {
                if try littleEndian32(tail, index) == 0x06054B50 {
                    eocdOffset = searchOffset + index
                    break
                }
            }
        }
        guard let eocdOffset else { throw BoneFileResourceError.parseFailed }
        let eocd = try readBytes(fd: fd, offset: eocdOffset, count: 22)
        let disk = try littleEndian16(eocd, 4)
        let centralDisk = try littleEndian16(eocd, 6)
        let entriesOnDisk = try littleEndian16(eocd, 8)
        let entriesTotal = try littleEndian16(eocd, 10)
        let centralSize = Int(try littleEndian32(eocd, 12))
        let centralOffset = Int(try littleEndian32(eocd, 16))
        guard disk == 0, centralDisk == 0, entriesOnDisk == entriesTotal,
              entriesTotal != UInt16.max, centralSize != Int(UInt32.max), centralOffset != Int(UInt32.max),
              entriesTotal <= maximumEntries, centralOffset >= 0,
              centralSize >= 0, centralSize <= maximumCentralDirectoryBytes,
              centralOffset <= byteCount - centralSize else {
            throw BoneFileResourceError.archiveLimitExceeded
        }
        let central = try readBytes(fd: fd, offset: centralOffset, count: centralSize)
        var result: [ZIPItem] = []
        var cursor = 0
        // 累计中央目录声明的展开大小，防止多条目合计超过资源预算。
        var totalUncompressedBytes = 0
        for _ in 0..<Int(entriesTotal) {
            guard cursor + 46 <= central.count, try littleEndian32(central, cursor) == 0x02014B50 else {
                throw BoneFileResourceError.parseFailed
            }
            let flags = try littleEndian16(central, cursor + 8)
            let method = try littleEndian16(central, cursor + 10)
            let crc32 = try littleEndian32(central, cursor + 16)
            let compressedSize = Int(try littleEndian32(central, cursor + 20))
            let uncompressedSize = Int(try littleEndian32(central, cursor + 24))
            let nameLength = Int(try littleEndian16(central, cursor + 28))
            let extraLength = Int(try littleEndian16(central, cursor + 30))
            let commentLength = Int(try littleEndian16(central, cursor + 32))
            let externalAttributes = try littleEndian32(central, cursor + 38)
            let localOffset = Int(try littleEndian32(central, cursor + 42))
            let end = cursor + 46 + nameLength + extraLength + commentLength
            guard end <= central.count, compressedSize >= 0, uncompressedSize >= 0,
                  uncompressedSize <= maximumExpandedBytes,
                  uncompressedSize <= maximumExpandedBytes - totalUncompressedBytes,
                  (compressedSize > 0 && UInt64(uncompressedSize) <= UInt64(compressedSize) * UInt64(maximumCompressionRatio)) ||
                    (compressedSize == 0 && uncompressedSize == 0) else {
                throw BoneFileResourceError.archiveLimitExceeded
            }
            totalUncompressedBytes += uncompressedSize
            let nameData = central.subdata(in: (cursor + 46)..<(cursor + 46 + nameLength))
            let name: String
            if flags & 0x800 != 0 {
                guard let decoded = String(data: nameData, encoding: .utf8) else { throw BoneFileResourceError.archiveUnsafe }
                name = decoded
            } else if let decoded = String(data: nameData, encoding: .ascii) {
                name = decoded
            } else {
                throw BoneFileResourceError.archiveUnsafe
            }
            guard isSafeEntryName(name) else { throw BoneFileResourceError.archiveUnsafe }
            let isDirectory = name.hasSuffix("/")
            let typeBits = externalAttributes >> 16 & 0xF000
            let isSymbolicLink = typeBits == 0xA000
            let entry = try BoneFileArchiveEntry(name: name, compressedByteCount: compressedSize,
                                                  uncompressedByteCount: uncompressedSize,
                                                  isDirectory: isDirectory, isSymbolicLink: isSymbolicLink,
                                                  isEncrypted: flags & 0x0001 != 0)
            let item = ZIPItem(entry: entry, compressionMethod: method, flags: flags,
                               expectedCRC32: crc32, localHeaderOffset: localOffset, dataOffset: 0)
            let dataOffset = try validateLocalHeader(fd: fd, byteCount: byteCount, item: item)
            result.append(ZIPItem(entry: entry, compressionMethod: method, flags: flags,
                                  expectedCRC32: crc32, localHeaderOffset: localOffset,
                                  dataOffset: dataOffset))
            cursor = end
        }
        return result
    }

    /// 校验 local header 与中央目录的一致性，并确认压缩数据完整落在文件范围内。
    /// - Parameters:
    ///   - fd: ZIP 快照文件描述符。
    ///   - byteCount: ZIP 文件字节数。
    ///   - item: 已解析的中央目录条目。
    /// - Returns: 条目压缩数据的文件偏移。
    private static func validateLocalHeader(fd: Int32, byteCount: Int, item: ZIPItem) throws -> Int {
        guard item.localHeaderOffset >= 0, item.localHeaderOffset <= byteCount - 30 else {
            throw BoneFileResourceError.parseFailed
        }
        let local = try readBytes(fd: fd, offset: item.localHeaderOffset, count: 30)
        guard try littleEndian32(local, 0) == 0x04034B50 else {
            throw BoneFileResourceError.parseFailed
        }
        let localFlags = try littleEndian16(local, 6)
        let localMethod = try littleEndian16(local, 8)
        let localCRC32 = try littleEndian32(local, 14)
        let localCompressedSize = Int(try littleEndian32(local, 18))
        let localUncompressedSize = Int(try littleEndian32(local, 22))
        let nameLength = Int(try littleEndian16(local, 26))
        let extraLength = Int(try littleEndian16(local, 28))
        let headerEnd = item.localHeaderOffset + 30 + nameLength + extraLength
        guard localFlags == item.flags, localMethod == item.compressionMethod,
              headerEnd >= item.localHeaderOffset + 30, headerEnd <= byteCount,
              headerEnd <= Int.max - item.entry.compressedByteCount,
              headerEnd + item.entry.compressedByteCount <= byteCount else {
            throw BoneFileResourceError.parseFailed
        }
        let localName = try readBytes(fd: fd, offset: item.localHeaderOffset + 30, count: nameLength)
        guard localName == Data(item.entry.name.utf8) else { throw BoneFileResourceError.parseFailed }
        let usesDataDescriptor = item.flags & 0x0008 != 0
        if usesDataDescriptor {
            try validateDataDescriptor(fd: fd, byteCount: byteCount, dataOffset: headerEnd, item: item)
        } else {
            guard localCRC32 == item.expectedCRC32,
                  localCompressedSize == item.entry.compressedByteCount,
                  localUncompressedSize == item.entry.uncompressedByteCount else {
                throw BoneFileResourceError.parseFailed
            }
        }
        return headerEnd
    }

    /// 校验 ZIP data descriptor，使中央目录、压缩数据和条目尾部声明保持一致。
    /// - Parameters:
    ///   - fd: ZIP 快照文件描述符。
    ///   - byteCount: ZIP 文件字节数。
    ///   - dataOffset: 条目压缩数据起始偏移。
    ///   - item: 已解析的中央目录条目。
    private static func validateDataDescriptor(fd: Int32, byteCount: Int, dataOffset: Int,
                                               item: ZIPItem) throws {
        guard dataOffset <= Int.max - item.entry.compressedByteCount else {
            throw BoneFileResourceError.parseFailed
        }
        // data descriptor 位于压缩数据之后，兼容带签名和不带签名两种形式。
        let descriptorOffset = dataOffset + item.entry.compressedByteCount
        guard descriptorOffset <= byteCount - 12 else {
            throw BoneFileResourceError.parseFailed
        }
        // 只读取 descriptor 所需的最多 16 个字节，不把后续中央目录载入内存。
        let descriptor = try readBytes(fd: fd, offset: descriptorOffset, count: min(16, byteCount - descriptorOffset))
        let signature = try littleEndian32(descriptor, 0)
        // 记录 CRC、压缩大小和展开大小字段在 descriptor 中的起点。
        let valuesOffset: Int
        if signature == 0x08074B50 {
            guard descriptor.count >= 16 else { throw BoneFileResourceError.parseFailed }
            valuesOffset = 4
        } else {
            valuesOffset = 0
        }
        guard valuesOffset + 12 <= descriptor.count,
              try littleEndian32(descriptor, valuesOffset) == item.expectedCRC32,
              try littleEndian32(descriptor, valuesOffset + 4) == UInt32(item.entry.compressedByteCount),
              try littleEndian32(descriptor, valuesOffset + 8) == UInt32(item.entry.uncompressedByteCount) else {
            throw BoneFileResourceError.parseFailed
        }
    }

    private static func isSafeEntryName(_ name: String) -> Bool {
        guard !name.isEmpty, !name.hasPrefix("/"), !name.contains("\\"), !name.contains("\0") else { return false }
        let components = name.split(separator: "/", omittingEmptySubsequences: true)
        return !components.contains("..")
    }

    private static func readZIPEntry(fd: Int32, item: ZIPItem, offset: Int, maximumBytes: Int) throws -> BoneFileArchivePage {
        let entry = item.entry
        guard offset <= entry.uncompressedByteCount else { throw BoneFileResourceError.invalidRequest }
        let requested = min(maximumBytes, entry.uncompressedByteCount - offset)
        switch item.compressionMethod {
        case 0:
            try validateStoredEntry(fd: fd, item: item)
            let data = requested == 0 ? Data() : try readBytes(fd: fd, offset: item.dataOffset + offset, count: requested)
            return try BoneFileArchivePage(entry: entry, offset: offset, data: data)
        case 8:
            return try inflateEntry(fd: fd, item: item, offset: offset, maximumBytes: maximumBytes)
        default:
            throw BoneFileResourceError.unsupportedFormat
        }
    }

    /// 校验 stored 条目的完整 CRC 和未压缩大小，再返回请求窗口。
    /// - Parameters:
    ///   - fd: ZIP 快照文件描述符。
    ///   - item: 已通过目录和 local header 校验的条目。
    private static func validateStoredEntry(fd: Int32, item: ZIPItem) throws {
        guard item.entry.compressedByteCount == item.entry.uncompressedByteCount else {
            throw BoneFileResourceError.parseFailed
        }
        let checksum = try crc32Range(fd: fd, offset: item.dataOffset, count: item.entry.uncompressedByteCount)
        guard checksum == item.expectedCRC32 else { throw BoneFileResourceError.parseFailed }
    }

    /// 对文件中的连续字节计算 CRC32，避免把完整条目载入内存。
    /// - Parameters:
    ///   - fd: 文件描述符。
    ///   - offset: 起始文件偏移。
    ///   - count: 参与计算的字节数。
    /// - Returns: 计算得到的 CRC32。
    private static func crc32Range(fd: Int32, offset: Int, count: Int) throws -> UInt32 {
        guard offset >= 0, count >= 0 else { throw BoneFileResourceError.parseFailed }
        var checksum = UInt32(0)
        var position = offset
        var remaining = count
        while remaining > 0 {
            let chunk = min(remaining, maximumChunkBytes)
            let data = try readBytes(fd: fd, offset: position, count: chunk)
            checksum = data.withUnsafeBytes { raw in
                UInt32(zlib.crc32(uLong(checksum), raw.bindMemory(to: Bytef.self).baseAddress, uInt(data.count)))
            }
            position += chunk
            remaining -= chunk
        }
        return checksum
    }

    private static func inflateEntry(fd: Int32, item: ZIPItem, offset: Int,
                                     maximumBytes: Int) throws -> BoneFileArchivePage {
        let staging = try makeTemporaryFile()
        defer { _ = close(staging.fd); try? FileManager.default.removeItem(at: staging.url) }
        try inflate(fd: fd, inputOffset: item.dataOffset, inputSize: item.entry.compressedByteCount,
                    outputFD: staging.fd, outputLimit: item.entry.uncompressedByteCount)
        guard try fileSize(staging.fd) == item.entry.uncompressedByteCount,
              try crc32Range(fd: staging.fd, offset: 0, count: item.entry.uncompressedByteCount) == item.expectedCRC32 else {
            throw BoneFileResourceError.parseFailed
        }
        let requested = min(maximumBytes, item.entry.uncompressedByteCount - offset)
        let data = requested == 0 ? Data() : try readBytes(fd: staging.fd, offset: offset, count: requested)
        return try BoneFileArchivePage(entry: item.entry, offset: offset, data: data)
    }

    private static func readGZIP(fd: Int32, byteCount: Int, name: String, offset: Int,
                                 maximumBytes: Int) throws -> BoneFileArchivePage {
        let staging = try makeTemporaryFile()
        defer { _ = close(staging.fd); try? FileManager.default.removeItem(at: staging.url) }
        try inflateGZIP(fd: fd, inputSize: byteCount, outputFD: staging.fd)
        let size = try fileSize(staging.fd)
        let expectedSize = try gzipISize(fd: fd, byteCount: byteCount)
        let expectedCRC = try gzipCRC32(fd: fd, byteCount: byteCount)
        let actualCRC = try crc32Range(fd: staging.fd, offset: 0, count: size)
        guard size == expectedSize, actualCRC == expectedCRC else {
            throw BoneFileResourceError.parseFailed
        }
        let entry = try BoneFileArchiveEntry(name: name, compressedByteCount: byteCount,
                                              uncompressedByteCount: size, isDirectory: false, isSymbolicLink: false)
        guard offset <= size else { throw BoneFileResourceError.invalidRequest }
        let requested = min(maximumBytes, size - offset)
        let data = requested == 0 ? Data() : try readBytes(fd: staging.fd, offset: offset, count: requested)
        return try BoneFileArchivePage(entry: entry, offset: offset, data: data)
    }

    /// 读取 gzip 尾部的 ISIZE 字段；该值用于目录长度提示，真正读取仍由解压结果校验。
    /// - Parameters:
    ///   - fd: gzip 快照文件描述符。
    ///   - byteCount: gzip 原始字节数。
    /// - Returns: 展开后字节数的低 32 位；超过预算时拒绝目录。
    private static func gzipISize(fd: Int32, byteCount: Int) throws -> Int {
        guard byteCount >= 18 else { throw BoneFileResourceError.parseFailed }
        let tail = try readBytes(fd: fd, offset: byteCount - 4, count: 4)
        let value = Int(try littleEndian32(tail, 0))
        guard value <= maximumExpandedBytes else { throw BoneFileResourceError.archiveLimitExceeded }
        return value
    }

    /// 读取 gzip 尾部的 CRC32 字段，用于和真实展开内容比较。
    /// - Parameters:
    ///   - fd: gzip 快照文件描述符。
    ///   - byteCount: gzip 原始字节数。
    /// - Returns: gzip 尾部声明的 CRC32。
    private static func gzipCRC32(fd: Int32, byteCount: Int) throws -> UInt32 {
        guard byteCount >= 18 else { throw BoneFileResourceError.parseFailed }
        let tail = try readBytes(fd: fd, offset: byteCount - 8, count: 4)
        return try littleEndian32(tail, 0)
    }

    private static func inflate(fd: Int32, inputOffset: Int, inputSize: Int, outputFD: Int32,
                                outputLimit: Int) throws {
        try inflateStream(fd: fd, inputOffset: inputOffset, inputSize: inputSize, outputFD: outputFD,
                          outputLimit: outputLimit, windowBits: -15)
    }

    private static func inflateGZIP(fd: Int32, inputSize: Int, outputFD: Int32) throws {
        try inflateStream(fd: fd, inputOffset: 0, inputSize: inputSize, outputFD: outputFD,
                          outputLimit: maximumExpandedBytes, windowBits: 31)
    }

    private static func inflateStream(fd: Int32, inputOffset: Int, inputSize: Int, outputFD: Int32,
                                     outputLimit: Int, windowBits: Int32) throws {
        var stream = z_stream()
        guard inflateInit2_(&stream, windowBits, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw BoneFileResourceError.parseFailed
        }
        defer { inflateEnd(&stream) }

        var input = Data(count: maximumChunkBytes)
        var output = Data(count: maximumChunkBytes)
        let outputCapacity = output.count
        var consumed = 0
        var produced = 0
        var ended = false

        while consumed < inputSize && !ended {
            let readCount = min(input.count, inputSize - consumed)
            input = try readBytes(fd: fd, offset: inputOffset + consumed, count: readCount)
            var consumedInChunk = 0
            try input.withUnsafeBytes { inputRaw in
                let inputBase = inputRaw.bindMemory(to: Bytef.self).baseAddress!
                while consumedInChunk < readCount && !ended {
                    stream.next_in = UnsafeMutablePointer(mutating: inputBase.advanced(by: consumedInChunk))
                    stream.avail_in = uInt(readCount - consumedInChunk)
                    while stream.avail_in > 0 && !ended {
                        let availableInput = Int(stream.avail_in)
                        var result = Z_OK
                        var written = 0
                        try output.withUnsafeMutableBytes { outputRaw in
                            stream.next_out = outputRaw.bindMemory(to: Bytef.self).baseAddress
                            stream.avail_out = uInt(outputCapacity)
                            result = zlib.inflate(&stream, Z_NO_FLUSH)
                            guard result == Z_OK || result == Z_STREAM_END else {
                                throw BoneFileResourceError.parseFailed
                            }
                            written = outputCapacity - Int(stream.avail_out)
                            guard written <= outputLimit - produced else {
                                throw BoneFileResourceError.archiveLimitExceeded
                            }
                            if written > 0 {
                                let bytes = Data(bytes: outputRaw.baseAddress!, count: written)
                                try writeAll(fd: outputFD, data: bytes, offset: produced)
                                produced += written
                            }
                        }
                        consumedInChunk = readCount - Int(stream.avail_in)
                        if result == Z_STREAM_END {
                            ended = true
                        } else if written == 0 && Int(stream.avail_in) == availableInput {
                            throw BoneFileResourceError.parseFailed
                        }
                    }
                }
            }
            guard consumedInChunk == readCount || ended else {
                throw BoneFileResourceError.parseFailed
            }
            consumed += consumedInChunk
        }

        while !ended {
            var result = Z_OK
            var written = 0
            try output.withUnsafeMutableBytes { outputRaw in
                stream.next_in = nil
                stream.avail_in = 0
                stream.next_out = outputRaw.bindMemory(to: Bytef.self).baseAddress
                stream.avail_out = uInt(outputCapacity)
                result = zlib.inflate(&stream, Z_FINISH)
                written = outputCapacity - Int(stream.avail_out)
                guard written <= outputLimit - produced else {
                    throw BoneFileResourceError.archiveLimitExceeded
                }
                if written > 0 {
                    let bytes = Data(bytes: outputRaw.baseAddress!, count: written)
                    try writeAll(fd: outputFD, data: bytes, offset: produced)
                    produced += written
                }
            }
            switch result {
            case Z_STREAM_END:
                ended = true
            case Z_OK:
                guard written > 0 else { throw BoneFileResourceError.parseFailed }
            default:
                throw BoneFileResourceError.parseFailed
            }
        }
    }

    private static func makeTemporaryFile() throws -> (fd: Int32, url: URL) {
        var path = Array(FileManager.default.temporaryDirectory.appendingPathComponent("bone-archive-XXXXXX").path.utf8CString)
        let fd = mkstemp(&path)
        guard fd >= 0 else { throw BoneFileResourceError.unavailable }
        guard fcntl(fd, F_SETFD, FD_CLOEXEC) != -1 else { _ = close(fd); throw BoneFileResourceError.unavailable }
        // 显式使用指针重载，按 mkstemp 保留的 NUL 终止符解码原 UTF-8 路径。
        return (fd, URL(fileURLWithPath: path.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }))
    }

    private static func writeAll(fd: Int32, data: Data, offset: Int) throws {
        var written = 0
        try data.withUnsafeBytes { raw in
            while written < data.count {
                let n = pwrite(fd, raw.baseAddress!.advanced(by: written), data.count - written, off_t(offset + written))
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { throw BoneFileResourceError.unavailable }
                written += n
            }
        }
    }

    private static func fileSize(_ fd: Int32) throws -> Int {
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_size >= 0, info.st_size <= Int64(Int.max) else {
            throw BoneFileResourceError.unavailable
        }
        return Int(info.st_size)
    }
}
