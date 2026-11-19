import Foundation
import BoneAgentKit
import CryptoKit
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// 持久化文件资源存储。快照按 SHA-256 去重，元数据可在进程重启后重新加载。
public actor BoneFileResourceStore {
    public static let maximumFileBytes = 100 * 1_048_576
    public static let maximumNameBytes = 256
    public static let maximumChunkBytes = 65_536

    private let root: URL
    private let blobs: URL
    private let metadata: URL
    private let views: URL
    /// 当前进程已经完成完整性校验的 blob；新进程首次恢复仍会重新校验。
    private var verifiedDigests: Set<String> = []

    /// 创建应用私有资源存储；调用方必须传入应用私有且可持久化的目录。
    /// - Parameter directory: 存储根目录，不应是用户可写的共享目录。
    public init(directory: URL) {
        root = directory
        blobs = directory.appendingPathComponent("blobs", isDirectory: true)
        metadata = directory.appendingPathComponent("metadata", isDirectory: true)
        views = directory.appendingPathComponent("views", isDirectory: true)
    }

    /// 导入文件、生成内容寻址原始快照，并在文本场景下生成 UTF-8 派生视图。
    /// - Parameters:
    ///   - source: 已获 Host 授权的本地文件 URL。
    ///   - name: 展示名称，不会作为路径使用。
    ///   - kind: 资源类型；automatic 根据文件头和扩展名做保守识别。
    ///   - encoding: 文本输入编码；非文本资源必须使用 automatic。
    ///   - maximumBytes: 原始文件大小上限。
    /// - Returns: 可跨进程恢复的资源元数据。
    public func importFile(source: URL, name: String? = nil, kind: BoneFileResourceKind? = nil,
                           encoding: BoneFileResourceEncoding = .automatic,
                           maximumBytes: Int = BoneFileResourceStore.maximumFileBytes) throws -> BoneFileResourceMetadata {
        try Task.checkCancellation()
        guard maximumBytes >= 0 else { throw BoneFileResourceError.capacityExceeded }
        guard source.isFileURL, !source.path.utf8.contains(0) else { throw BoneFileResourceError.notRegularFile }
        let input = open(source.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard input >= 0 else { throw BoneFileResourceError.unavailable }
        defer { _ = close(input) }
        var info = stat()
        guard fstat(input, &info) == 0 else { throw BoneFileResourceError.unavailable }
        guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else { throw BoneFileResourceError.notRegularFile }
        guard info.st_size >= 0, info.st_size <= maximumBytes else { throw BoneFileResourceError.capacityExceeded }

        let resolvedKind: BoneFileResourceKind
        if let kind {
            resolvedKind = kind
        } else if encoding != .automatic {
            // 用户显式选择了文本编码时，编码选择本身就是文本类型确认，不再受前缀探测限制。
            resolvedKind = .text
        } else {
            resolvedKind = try Self.detectKind(source: source, fd: input)
        }
        guard resolvedKind == .text || encoding == .automatic else { throw BoneFileResourceError.invalidRequest }
        let displayName = try Self.validatedName(name ?? source.lastPathComponent)
        try prepareDirectories()

        let staging = try Self.makeTemporaryFile(prefix: "bone-resource-")
        defer { _ = close(staging.fd); try? FileManager.default.removeItem(at: staging.url) }
        let digestAndCount = try Self.copyAndHash(input: input, output: staging.fd, limit: maximumBytes)
        let sha256 = digestAndCount.digest
        let blobURL = blobs.appendingPathComponent(sha256 + ".blob", isDirectory: false)
        let blobAlreadyExisted = FileManager.default.fileExists(atPath: blobURL.path)
        if !blobAlreadyExisted {
            try Self.move(staging.url, to: blobURL)
        }

        let id = sha256
        var createdNormalizedViewURL: URL?
        do {
            var originalEncoding: BoneFileResourceEncoding?
            var normalizedCount: Int?
            var normalizedToken: String?
            // 记录实际用于生成规范化视图的编码，非文本资源保持 automatic。
            var resolvedEncoding: BoneFileResourceEncoding = .automatic
            if resolvedKind == .text {
                let normalized = try Self.normalizeText(source: blobURL, requested: encoding, maximumBytes: maximumBytes)
                let token = sha256 + "-" + normalized.encoding.rawValue
                let normalizedURL = views.appendingPathComponent(token + ".utf8", isDirectory: false)
                if !FileManager.default.fileExists(atPath: normalizedURL.path) {
                    try Self.move(normalized.url, to: normalizedURL)
                    createdNormalizedViewURL = normalizedURL
                } else {
                    try? FileManager.default.removeItem(at: normalized.url)
                }
                originalEncoding = normalized.encoding
                normalizedCount = normalized.byteCount
                normalizedToken = token
                resolvedEncoding = normalized.encoding
            }
            let version = Self.resourceVersion(sha256: sha256, kind: resolvedKind, encoding: resolvedEncoding)
            let reference = try BoneFileResourceReference(id: id, version: version, sha256: sha256,
                                                           byteCount: digestAndCount.byteCount, kind: resolvedKind)
            // 先构造完整 metadata，再一次性写入版本绑定的路径。
            let value = try BoneFileResourceMetadata(name: displayName, reference: reference,
                                                     originalEncoding: originalEncoding,
                                                     normalizedUTF8ByteCount: normalizedCount,
                                                     normalizedTextPathToken: normalizedToken)
            _ = try Self.writeMetadata(value, to: metadataURL(for: reference))
            return value
        } catch {
            // 新建 blob 在解析失败且没有其他 metadata 引用时立即回收，避免留下半成品快照。
            if let createdNormalizedViewURL {
                try? FileManager.default.removeItem(at: createdNormalizedViewURL)
            }
            if !blobAlreadyExisted && !hasMetadataReference(sha256) {
                try? FileManager.default.removeItem(at: blobURL)
            }
            throw error
        }
    }

    /// 从持久化元数据恢复资源；不会使用原始路径或重新取得文件授权。
    /// - Parameter reference: 之前签发的资源引用。
    /// - Returns: 当前存储中与引用完全一致的元数据。
    public func restore(_ reference: BoneFileResourceReference) throws -> BoneFileResourceMetadata {
        let data = (try? Data(contentsOf: metadataURL(for: reference), options: [.mappedIfSafe]))
            ?? (try? Data(contentsOf: kindMetadataURL(for: reference), options: [.mappedIfSafe]))
            ?? (try? Data(contentsOf: legacyMetadataURL(for: reference), options: [.mappedIfSafe]))
        guard let data,
              let value = try? JSONDecoder().decode(BoneFileResourceMetadata.self, from: data),
              value.reference == reference,
              FileManager.default.fileExists(atPath: blobURL(for: reference).path) else {
            throw BoneFileResourceError.expired
        }
        if !verifiedDigests.contains(reference.sha256) {
            guard try Self.fileDigest(at: blobURL(for: reference)) == reference.sha256 else {
                throw BoneFileResourceError.expired
            }
            verifiedDigests.insert(reference.sha256)
        }
        if reference.kind == .text, let token = value.normalizedTextPathToken,
           !FileManager.default.fileExists(atPath: views.appendingPathComponent(token + ".utf8").path) {
            throw BoneFileResourceError.expired
        }
        return value
    }

    /// 按范围读取原始快照，不扫描文件前缀。
    /// - Parameter request: 精确资源版本和字节范围。
    /// - Returns: 有界二进制页。
    public func readBytes(_ request: BoneFileResourceByteReadRequest) throws -> BoneFileResourceBytePage {
        let value = try restore(request.reference)
        _ = value
        let fd = open(blobURL(for: request.reference).path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { throw BoneFileResourceError.unavailable }
        defer { _ = close(fd) }
        let count = min(request.maximumBytes, request.reference.byteCount - request.offset)
        var data = Data(count: count)
        var filled = 0
        try data.withUnsafeMutableBytes { buffer in
            while filled < count {
                try Task.checkCancellation()
                let n = pread(fd, buffer.baseAddress!.advanced(by: filled), count - filled,
                               off_t(request.offset + filled))
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { throw BoneFileResourceError.unavailable }
                filled += n
            }
        }
        return try BoneFileResourceBytePage(reference: request.reference, offset: request.offset, data: data)
    }

    /// 检查持久资源并生成对应的结构化派生视图。
    /// - Parameter reference: 精确资源版本引用。
    /// - Returns: 资源元数据及 PDF、Office 或归档目录。
    public func inspect(_ reference: BoneFileResourceReference) throws -> BoneFileResourceInspection {
        let value = try restore(reference)
        let blob = blobURL(for: reference)
        switch reference.kind {
        case .pdf:
            return BoneFileResourceInspection(metadata: value, pdf: try BoneStructuredFileReaders.inspectPDF(at: blob))
        case .officeOpenXML:
            return BoneFileResourceInspection(metadata: value,
                                               office: try BoneStructuredFileReaders.inspectOffice(
                                                at: blob, fileExtension: URL(fileURLWithPath: value.name).pathExtension))
        case .archive:
            return BoneFileResourceInspection(metadata: value, archiveEntries: try BoneFileArchiveReader.listEntries(at: blob))
        case .text, .binary:
            return BoneFileResourceInspection(metadata: value)
        }
    }

    /// 按资源类型读取一个结构化窗口；每次调用都会重新校验持久快照。
    /// - Parameter request: 绑定引用、视图类型和有界定位信息的窗口请求。
    /// - Returns: 文本、PDF 页、Office 投影或归档条目的统一结果。
    public func readWindow(_ request: BoneFileResourceWindowRequest) throws -> BoneFileResourceWindowResult {
        let value = try restore(request.reference)
        let blob = blobURL(for: request.reference)
        switch request.kind {
        case .text:
            let page = try readText(reference: request.reference, offset: request.offset,
                                    maximumBytes: request.maximumBytes)
            return BoneFileResourceWindowResult(reference: request.reference, kind: .text,
                                                text: page.text, nextOffset: page.nextOffset)
        case .pdfPage:
            guard request.reference.kind == .pdf, let pageIndex = request.pageIndex else {
                throw BoneFileResourceError.invalidRequest
            }
            let page = try BoneStructuredFileReaders.readPDFPage(at: blob, pageIndex: pageIndex,
                                                                  maximumBytes: request.maximumBytes)
            return BoneFileResourceWindowResult(reference: request.reference, kind: .pdfPage,
                                                text: page.text, pageIndex: page.pageIndex,
                                                isTruncated: page.isTruncated)
        case .officeText:
            guard request.reference.kind == .officeOpenXML else { throw BoneFileResourceError.invalidRequest }
            let page = try BoneStructuredFileReaders.readOfficeText(at: blob,
                                                                    fileExtension: URL(fileURLWithPath: value.name).pathExtension,
                                                                    offset: request.offset,
                                                                    maximumBytes: request.maximumBytes)
            return BoneFileResourceWindowResult(reference: request.reference, kind: .officeText,
                                                text: page.text, nextOffset: page.nextOffset)
        case .archiveEntry:
            guard request.reference.kind == .archive, let entryName = request.entryName else {
                throw BoneFileResourceError.invalidRequest
            }
            let page = try BoneFileArchiveReader.readEntry(at: blob, name: entryName,
                                                           offset: request.offset,
                                                           maximumBytes: request.maximumBytes)
            return BoneFileResourceWindowResult(reference: request.reference, kind: .archiveEntry,
                                                nextOffset: page.nextOffset, data: page.data,
                                                archiveEntry: page.entry)
        }
    }

    /// 读取 Office 的段落、工作表/单元格或幻灯片结构，并重新校验持久快照。
    /// - Parameter request: 精确 Office 资源引用请求。
    /// - Returns: 带资源引用的结构化 Office 结果。
    public func readOfficeStructure(_ request: BoneFileResourceOfficeStructureRequest) throws
        -> BoneFileResourceOfficeStructureResult {
        let value = try restore(request.reference)
        let fileExtension = URL(fileURLWithPath: value.name).pathExtension
        let structure = try BoneStructuredFileReaders.readOfficeStructure(at: blobURL(for: request.reference),
                                                                            fileExtension: fileExtension)
        return BoneFileResourceOfficeStructureResult(reference: request.reference, structure: structure)
    }

    /// 列出归档条目；普通文本、PDF 和二进制资源不提供虚构目录。
    /// - Parameter reference: 精确归档资源版本引用。
    /// - Returns: 安全过滤后的条目目录。
    public func listEntries(_ reference: BoneFileResourceReference) throws -> [BoneFileArchiveEntry] {
        guard reference.kind == .archive else { throw BoneFileResourceError.unsupportedFormat }
        _ = try restore(reference)
        return try BoneFileArchiveReader.listEntries(at: blobURL(for: reference))
    }

    /// 读取已经规范化的文本页，复用既有 UTF-8 资源协议。
    /// - Parameter request: 现有 UTF-8 文本页请求。
    /// - Returns: 与旧 API 一致的文本页和 nextOffset。
    public func readText(reference: BoneFileResourceReference, offset: Int = 0,
                         maximumBytes: Int = 4_096) throws -> BoneToolTextResourcePage {
        guard reference.kind == .text else { throw BoneFileResourceError.unsupportedFormat }
        guard (4...65_536).contains(maximumBytes) else { throw BoneFileResourceError.invalidRequest }
        let metadata = try restore(reference)
        guard let token = metadata.normalizedTextPathToken, let count = metadata.normalizedUTF8ByteCount else {
            throw BoneFileResourceError.invalidReference
        }
        guard offset >= 0, offset <= count else { throw BoneToolTextResourceError.invalidReadRequest }
        let normalizedReference = try BoneToolTextResourceReference(
            id: reference.id, version: reference.version, utf8ByteCount: count
        )
        let fd = open(views.appendingPathComponent(token + ".utf8").path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { throw BoneFileResourceError.unavailable }
        defer { _ = close(fd) }
        let requested = min(maximumBytes, count - offset)
        var bytes = Data(count: requested)
        var filled = 0
        try bytes.withUnsafeMutableBytes { buffer in
            while filled < requested {
                try Task.checkCancellation()
                let n = pread(fd, buffer.baseAddress!.advanced(by: filled), requested - filled,
                               off_t(offset + filled))
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { throw BoneFileResourceError.unavailable }
                filled += n
            }
        }
        guard bytes.first.map({ $0 & 0xc0 != 0x80 }) ?? true else { throw BoneToolTextResourceError.invalidOffset }
        let end = Self.completeUTF8Prefix(bytes)
        return try .init(reference: normalizedReference, offset: offset,
                         text: String(decoding: bytes.prefix(end), as: UTF8.self))
    }

    /// 删除一个持久资源及其派生文本视图；调用方应先撤销会话引用。
    /// - Parameter reference: 要删除的精确资源版本。
    public func remove(_ reference: BoneFileResourceReference) throws {
        let value = try restore(reference)
        try? FileManager.default.removeItem(at: metadataURL(for: reference))
        removeMetadataIfMatching(kindMetadataURL(for: reference), reference: reference)
        removeMetadataIfMatching(legacyMetadataURL(for: reference), reference: reference)
        if let token = value.normalizedTextPathToken, !isViewReferenced(token, excluding: reference) {
            try? FileManager.default.removeItem(at: views.appendingPathComponent(token + ".utf8"))
        }
        if !isMetadataReferenced(reference.sha256, excluding: reference) {
            try? FileManager.default.removeItem(at: blobURL(for: reference))
        }
        verifiedDigests.remove(reference.sha256)
    }

    /// 返回带资源版本的 metadata 文件位置，确保同一字节的不同解析视图可以共存。
    /// - Parameter reference: 需要定位的资源引用。
    /// - Returns: 当前版本 metadata 的私有文件 URL。
    private func metadataURL(for reference: BoneFileResourceReference) -> URL {
        metadata.appendingPathComponent(reference.sha256 + "-" + reference.kind.rawValue + "-" + reference.version + ".json",
                                         isDirectory: false)
    }

    /// 返回当前版本方案的兼容路径，用于恢复已写入的 kind 隔离 metadata。
    /// - Parameter reference: 需要定位的资源引用。
    /// - Returns: 兼容 metadata 的私有文件 URL。
    private func kindMetadataURL(for reference: BoneFileResourceReference) -> URL {
        metadata.appendingPathComponent(reference.sha256 + "-" + reference.kind.rawValue + ".json",
                                         isDirectory: false)
    }

    /// 返回旧版本 metadata 文件位置，用于兼容已有 v1 资源存档。
    /// - Parameter reference: 需要兼容恢复的资源引用。
    /// - Returns: 旧版 metadata 的私有文件 URL。
    private func legacyMetadataURL(for reference: BoneFileResourceReference) -> URL {
        metadata.appendingPathComponent(reference.sha256 + ".json", isDirectory: false)
    }

    /// 删除兼容路径上的 metadata，仅在其内容仍属于目标引用时执行。
    /// - Parameters:
    ///   - url: 需要检查的 metadata 路径。
    ///   - reference: 要删除的精确资源引用。
    private func removeMetadataIfMatching(_ url: URL, reference: BoneFileResourceReference) {
        guard let data = try? Data(contentsOf: url),
              let value = try? JSONDecoder().decode(BoneFileResourceMetadata.self, from: data),
              value.reference == reference else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// 检查指定原始摘要是否已经被任意 metadata 引用。
    /// - Parameter sha256: 原始 blob 的内容摘要。
    /// - Returns: 至少存在一份有效 metadata 引用时返回 true。
    private func hasMetadataReference(_ sha256: String) -> Bool {
        guard let urls = try? FileManager.default.contentsOfDirectory(at: metadata,
                                                                        includingPropertiesForKeys: nil) else {
            return false
        }
        for url in urls where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url),
                  let metadataValue = try? JSONDecoder().decode(BoneFileResourceMetadata.self, from: data) else { continue }
            if metadataValue.reference.sha256 == sha256 { return true }
        }
        return false
    }

    /// 检查是否仍有其他 metadata 引用同一原始 blob。
    /// - Parameters:
    ///   - sha256: 原始 blob 的内容摘要。
    ///   - reference: 当前准备删除的引用。
    /// - Returns: 仍被其他有效 metadata 引用时返回 true。
    private func isMetadataReferenced(_ sha256: String, excluding reference: BoneFileResourceReference) -> Bool {
        guard let urls = try? FileManager.default.contentsOfDirectory(at: metadata,
                                                                        includingPropertiesForKeys: nil) else {
            return false
        }
        for url in urls where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url),
                  let metadataValue = try? JSONDecoder().decode(BoneFileResourceMetadata.self, from: data),
                  metadataValue.reference.sha256 == sha256,
                  metadataValue.reference != reference else { continue }
            return true
        }
        return false
    }

    /// 检查是否仍有其他文本 metadata 使用同一个规范化视图文件。
    /// - Parameters:
    ///   - token: 规范化视图内部 token。
    ///   - reference: 当前准备删除的引用。
    /// - Returns: 仍有其他引用使用该视图时返回 true。
    private func isViewReferenced(_ token: String, excluding reference: BoneFileResourceReference) -> Bool {
        guard let urls = try? FileManager.default.contentsOfDirectory(at: metadata,
                                                                        includingPropertiesForKeys: nil) else {
            return false
        }
        for url in urls where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url),
                  let metadataValue = try? JSONDecoder().decode(BoneFileResourceMetadata.self, from: data),
                  metadataValue.reference != reference,
                  metadataValue.normalizedTextPathToken == token else { continue }
            return true
        }
        return false
    }

    /// 根据原始摘要、资源类型和实际解析编码生成稳定资源版本。
    /// - Parameters:
    ///   - sha256: 原始快照 SHA-256 摘要。
    ///   - kind: 资源的结构化读取类型。
    ///   - encoding: 文本实际解析编码，非文本资源使用 automatic。
    /// - Returns: 可写入资源引用的 64 个十六进制字符版本摘要。
    private static func resourceVersion(sha256: String, kind: BoneFileResourceKind,
                                        encoding: BoneFileResourceEncoding) -> String {
        let identity = sha256 + "\n" + kind.rawValue + "\n" + encoding.rawValue
        return SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func blobURL(for reference: BoneFileResourceReference) -> URL {
        blobs.appendingPathComponent(reference.sha256 + ".blob", isDirectory: false)
    }

    private func prepareDirectories() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        for directory in [blobs, metadata, views] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                     attributes: [.posixPermissions: 0o700])
        }
    }

    private static func validatedName(_ name: String) throws -> String {
        let value = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.utf8.count <= BoneFileResourceStore.maximumNameBytes, !value.contains("\0") else {
            throw BoneFileResourceError.invalidName
        }
        return value
    }

    private static func detectKind(source: URL, fd: Int32) throws -> BoneFileResourceKind {
        var header = Data(count: 8)
        let n = header.withUnsafeMutableBytes { pread(fd, $0.baseAddress!, $0.count, 0) }
        guard n >= 0 else { throw BoneFileResourceError.unavailable }
        if n >= 5, String(data: header.prefix(5), encoding: .ascii) == "%PDF-" { return .pdf }
        if n >= 2, header[0] == 0x1F, header[1] == 0x8B { return .archive }
        if n >= 2, (header[0] == 0xFF && header[1] == 0xFE) || (header[0] == 0xFE && header[1] == 0xFF) {
            return .text
        }
        if n >= 4, header[0] == 0x50, header[1] == 0x4B {
            let ext = source.pathExtension.lowercased()
            return ["docx", "xlsx", "pptx"].contains(ext) ? .officeOpenXML : .archive
        }
        return canConfirmUTF8(fd: fd) ? .text : .binary
    }

    private static func canConfirmUTF8(fd: Int32) -> Bool {
        var buffer = Data(count: 65_536)
        let n = buffer.withUnsafeMutableBytes { pread(fd, $0.baseAddress!, $0.count, 0) }
        guard n >= 0 else { return false }
        let prefix = buffer.prefix(n)
        let completeCount = completeUTF8Prefix(prefix)
        guard completeCount > 0 || prefix.isEmpty else { return false }
        return String(data: prefix.prefix(completeCount), encoding: .utf8) != nil
    }

    /// 创建应用临时目录内的私有 staging 文件；调用方负责在失败时关闭并删除。
    /// - Parameter prefix: 临时文件名前缀。
    /// - Returns: 已打开的文件描述符和路径。
    private static func makeTemporaryFile(prefix: String) throws -> (fd: Int32, url: URL) {
        let directory = FileManager.default.temporaryDirectory
        var path = Array(directory.appendingPathComponent(prefix + "XXXXXX").path.utf8CString)
        let fd = mkstemp(&path)
        guard fd >= 0 else { throw BoneFileResourceError.unavailable }
        let url = URL(fileURLWithPath: String(cString: path))
        guard fcntl(fd, F_SETFD, FD_CLOEXEC) != -1 else {
            _ = close(fd)
            try? FileManager.default.removeItem(at: url)
            throw BoneFileResourceError.unavailable
        }
        return (fd, url)
    }

    /// 分块复制并计算 SHA-256，避免把整份文件装入内存。
    /// - Parameters:
    ///   - input: 输入文件描述符。
    ///   - output: staging 文件描述符。
    ///   - limit: 原始文件字节上限。
    /// - Returns: 原始字节数和十六进制 SHA-256。
    private static func copyAndHash(input: Int32, output: Int32, limit: Int) throws -> (byteCount: Int, digest: String) {
        var buffer = Data(count: BoneFileResourceStore.maximumChunkBytes)
        var total = 0
        var hasher = SHA256()
        while true {
            try Task.checkCancellation()
            let n = buffer.withUnsafeMutableBytes { pread(input, $0.baseAddress!, $0.count, off_t(total)) }
            if n < 0 && errno == EINTR { continue }
            guard n >= 0 else { throw BoneFileResourceError.unavailable }
            if n == 0 { break }
            guard n <= limit - total else { throw BoneFileResourceError.capacityExceeded }
            hasher.update(data: buffer.prefix(n))
            var written = 0
            try buffer.withUnsafeBytes { raw in
                while written < n {
                    let count = pwrite(output, raw.baseAddress!.advanced(by: written), n - written,
                                       off_t(total + written))
                    if count < 0 && errno == EINTR { try Task.checkCancellation(); continue }
                    guard count > 0 else { throw BoneFileResourceError.unavailable }
                    written += count
                }
            }
            total += n
        }
        return (total, hasher.finalize().map { String(format: "%02x", $0) }.joined())
    }

    /// 按用户选择或 BOM 严格解码文本，并以分块方式写出 UTF-8 派生视图。
    /// - Parameters:
    ///   - source: 已完成内容寻址复制的原始快照。
    ///   - requested: 用户选择的编码。
    ///   - maximumBytes: 规范化后 UTF-8 字节上限。
    /// - Returns: 实际编码和临时 UTF-8 文件信息。
    private static func normalizeText(source: URL, requested: BoneFileResourceEncoding,
                                      maximumBytes: Int) throws -> (encoding: BoneFileResourceEncoding, byteCount: Int, url: URL) {
        let input = open(source.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard input >= 0 else { throw BoneFileResourceError.unavailable }
        defer { _ = close(input) }
        var header = Data(count: 4)
        let headerCount = header.withUnsafeMutableBytes { pread(input, $0.baseAddress!, $0.count, 0) }
        guard headerCount >= 0 else { throw BoneFileResourceError.unavailable }
        let (encoding, skip): (BoneFileResourceEncoding, Int) = {
            let prefix = header.prefix(headerCount)
            switch requested {
            case .automatic:
                if prefix.starts(with: [0xEF, 0xBB, 0xBF]) { return (.utf8, 3) }
                if prefix.starts(with: [0xFF, 0xFE]) { return (.utf16LittleEndian, 2) }
                if prefix.starts(with: [0xFE, 0xFF]) { return (.utf16BigEndian, 2) }
                return (.utf8, 0)
            case .utf8: return (.utf8, prefix.starts(with: [0xEF, 0xBB, 0xBF]) ? 3 : 0)
            case .utf16LittleEndian: return (.utf16LittleEndian, prefix.starts(with: [0xFF, 0xFE]) ? 2 : 0)
            case .utf16BigEndian: return (.utf16BigEndian, prefix.starts(with: [0xFE, 0xFF]) ? 2 : 0)
            case .gbk: return (.gbk, 0)
            case .gb18030: return (.gb18030, 0)
            }
        }()
        let foundationEncoding: String.Encoding
        switch encoding {
        case .utf8: foundationEncoding = .utf8
        case .utf16LittleEndian: foundationEncoding = .utf16LittleEndian
        case .utf16BigEndian: foundationEncoding = .utf16BigEndian
        case .gbk, .gb18030:
            let charsetName = encoding == .gbk ? "GBK" : "GB18030"
            let cfEncoding = CFStringConvertIANACharSetNameToEncoding(charsetName as CFString)
            guard cfEncoding != kCFStringEncodingInvalidId else { throw BoneFileResourceError.unsupportedEncoding }
            foundationEncoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cfEncoding))
        case .automatic: throw BoneFileResourceError.invalidEncoding
        }
        let staging = try makeTemporaryFile(prefix: "bone-text-normalized-")
        do {
            var inputOffset = skip
            var normalizedCount = 0
            var pending = Data()
            var sourceBuffer = Data(count: BoneFileResourceStore.maximumChunkBytes)
            while true {
                try Task.checkCancellation()
                let n = sourceBuffer.withUnsafeMutableBytes {
                    pread(input, $0.baseAddress!, $0.count, off_t(inputOffset))
                }
                if n < 0 && errno == EINTR { continue }
                guard n >= 0 else { throw BoneFileResourceError.unavailable }
                if n == 0 { break }
                inputOffset += n
                pending.append(sourceBuffer.prefix(n))
                let decoded = try decodeCompletePrefix(pending, encoding: foundationEncoding)
                pending = decoded.remainder
                let bytes = Data(decoded.text.utf8)
                guard bytes.count <= maximumBytes - normalizedCount else { throw BoneFileResourceError.capacityExceeded }
                var written = 0
                try bytes.withUnsafeBytes { rawBytes in
                    while written < rawBytes.count {
                        let count = pwrite(staging.fd, rawBytes.baseAddress!.advanced(by: written), rawBytes.count - written,
                                           off_t(normalizedCount + written))
                        if count < 0 && errno == EINTR { try Task.checkCancellation(); continue }
                        guard count > 0 else { throw BoneFileResourceError.unavailable }
                        written += count
                    }
                }
                normalizedCount += bytes.count
            }
            guard pending.isEmpty else { throw BoneFileResourceError.invalidEncoding }
            _ = close(staging.fd)
            return (encoding, normalizedCount, staging.url)
        } catch {
            _ = close(staging.fd)
            try? FileManager.default.removeItem(at: staging.url)
            throw error
        }
    }

    /// 严格解码一个分块的完整前缀，保留最多 8 个可能跨块的编码字节。
    /// - Parameters:
    ///   - data: 上一块尾部与当前块拼接的数据。
    ///   - encoding: 已确定的 Foundation 编码。
    /// - Returns: 可安全输出的文本及下一块继续使用的尾部。
    private static func decodeCompletePrefix(_ data: Data, encoding: String.Encoding) throws -> (text: String, remainder: Data) {
        if data.isEmpty { return ("", Data()) }
        for length in stride(from: data.count, through: max(0, data.count - 8), by: -1) {
            let prefix = data.prefix(length)
            if let text = String(data: prefix, encoding: encoding) {
                let remainder = Data(data.dropFirst(length))
                guard remainder.count <= 8 || !text.isEmpty else { throw BoneFileResourceError.invalidEncoding }
                return (text, remainder)
            }
        }
        throw BoneFileResourceError.invalidEncoding
    }

    /// 流式计算持久 blob 的 SHA-256，恢复时用于 fail-closed 完整性校验。
    /// - Parameter url: 已存在的私有 blob 路径。
    /// - Returns: 小写十六进制 SHA-256。
    private static func fileDigest(at url: URL) throws -> String {
        let fd = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { throw BoneFileResourceError.unavailable }
        defer { _ = close(fd) }
        var buffer = Data(count: BoneFileResourceStore.maximumChunkBytes)
        var offset = 0
        var hasher = SHA256()
        while true {
            let n = buffer.withUnsafeMutableBytes { pread(fd, $0.baseAddress!, $0.count, off_t(offset)) }
            if n < 0 && errno == EINTR { continue }
            guard n >= 0 else { throw BoneFileResourceError.unavailable }
            if n == 0 { break }
            hasher.update(data: buffer.prefix(n))
            offset += n
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// 原子地把 staging 文件移动到内容寻址目录；目标已存在时保留先到版本。
    /// - Parameters:
    ///   - source: staging 路径。
    ///   - destination: 私有存储目标路径。
    private static func move(_ source: URL, to destination: URL) throws {
        do {
            try FileManager.default.moveItem(at: source, to: destination)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        } catch CocoaError.fileWriteFileExists {
            try? FileManager.default.removeItem(at: source)
        } catch {
            throw BoneFileResourceError.unavailable
        }
    }

    /// 原子写入并限制 metadata 文件权限。
    /// - Parameters:
    ///   - value: 需要保存的 Codable 元数据。
    ///   - destination: 私有 metadata 路径。
    /// - Returns: 写入的稳定 JSON 字节。
    private static func writeMetadata<T: Encodable>(_ value: T, to destination: URL) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        let temporary = destination.deletingLastPathComponent().appendingPathComponent("." + UUID().uuidString + ".tmp")
        do {
            try data.write(to: temporary, options: [.atomic])
            try move(temporary, to: destination)
            return data
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }

    private static func completeUTF8Prefix(_ bytes: Data) -> Int {
        guard !bytes.isEmpty, bytes[bytes.count - 1] >= 0x80 else { return bytes.count }
        var start = bytes.count - 1
        while start > max(0, bytes.count - 4), bytes[start] & 0xC0 == 0x80 { start -= 1 }
        let lead = bytes[start]
        let width = (0xC2...0xDF).contains(lead) ? 2 : (0xE0...0xEF).contains(lead) ? 3 : (0xF0...0xF4).contains(lead) ? 4 : 1
        return bytes.count - start < width ? start : bytes.count
    }
}
