import Foundation

/// 文件资源的固定失败分类，不携带路径、正文、凭据或底层错误文本。
public enum BoneFileResourceError: Error, Equatable, Sendable {
    case invalidReference
    case invalidRequest
    case invalidName
    case notRegularFile
    case unavailable
    case capacityExceeded
    case invalidEncoding
    case unsupportedEncoding
    case unsupportedFormat
    case parseFailed
    case archiveUnsafe
    case archiveLimitExceeded
    case referenceMismatch
    case accessDenied
    case expired
}

/// 资源类型；derived view 仍绑定到同一份原始快照。
public enum BoneFileResourceKind: String, Codable, CaseIterable, Sendable {
    case text
    case pdf
    case officeOpenXML
    case archive
    case binary
}

/// 文本导入编码。automatic 只确认 BOM 或严格 UTF-8，不猜测 GBK 或 GB18030。
public enum BoneFileResourceEncoding: String, Codable, CaseIterable, Sendable {
    case automatic
    case utf8
    case utf16LittleEndian
    case utf16BigEndian
    case gbk
    case gb18030
}

/// Host 管理的持久文件快照引用；不包含路径，也不是权限凭据。
public struct BoneFileResourceReference: Codable, Hashable, Sendable {
    public let id: String
    public let version: String
    public let sha256: String
    public let byteCount: Int
    public let kind: BoneFileResourceKind

    /// 创建一个绑定原始快照身份的引用。
    /// - Parameters:
    ///   - id: 不透明资源标识。
    ///   - version: 不透明资源版本。
    ///   - sha256: 原始快照 SHA-256 十六进制摘要。
    ///   - byteCount: 原始快照字节数。
    ///   - kind: Host 选择或识别的资源类型。
    public init(id: String, version: String, sha256: String, byteCount: Int, kind: BoneFileResourceKind) throws {
        guard Self.validToken(id), Self.validToken(version), Self.isSHA256(sha256), byteCount >= 0 else {
            throw BoneFileResourceError.invalidReference
        }
        self.id = id
        self.version = version
        self.sha256 = sha256.lowercased()
        self.byteCount = byteCount
        self.kind = kind
    }

    /// 从不可信 Codable 输入恢复引用，并重新执行全部身份校验。
    /// - Parameter decoder: 外部存档或模型参数解码器。
    /// - Throws: 引用字段不符合资源合同。
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(id: container.decode(String.self, forKey: .id),
                      version: container.decode(String.self, forKey: .version),
                      sha256: container.decode(String.self, forKey: .sha256),
                      byteCount: container.decode(Int.self, forKey: .byteCount),
                      kind: container.decode(BoneFileResourceKind.self, forKey: .kind))
    }

    private enum CodingKeys: String, CodingKey { case id, version, sha256, byteCount, kind }

    private static func validToken(_ value: String) -> Bool {
        (1...128).contains(value.utf8.count) && value.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95
        }
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy {
            (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
        }
    }
}

/// 文件资源的持久化元数据；正文和派生视图仍存放在 Host 的私有存储中。
public struct BoneFileResourceMetadata: Codable, Equatable, Sendable {
    public let name: String
    public let reference: BoneFileResourceReference
    public let originalEncoding: BoneFileResourceEncoding?
    public let normalizedUTF8ByteCount: Int?
    public let normalizedTextPathToken: String?

    /// 创建资源元数据，并验证展示名称与规范化文本信息。
    /// - Parameters:
    ///   - name: 不含路径的展示名称。
    ///   - reference: 原始快照引用。
    ///   - originalEncoding: 文本资源实际使用的输入编码。
    ///   - normalizedUTF8ByteCount: 规范化 UTF-8 视图大小。
    ///   - normalizedTextPathToken: Host 内部派生文件 token，不是外部路径。
    public init(name: String, reference: BoneFileResourceReference,
                originalEncoding: BoneFileResourceEncoding? = nil,
                normalizedUTF8ByteCount: Int? = nil,
                normalizedTextPathToken: String? = nil) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= 256, !trimmed.contains("\0"),
              normalizedUTF8ByteCount.map({ $0 >= 0 }) ?? true,
              normalizedTextPathToken.map(Self.validToken) ?? true else {
            throw BoneFileResourceError.invalidName
        }
        if reference.kind == .text {
            guard originalEncoding != nil, normalizedUTF8ByteCount != nil, normalizedTextPathToken != nil else {
                throw BoneFileResourceError.invalidReference
            }
        }
        self.name = trimmed
        self.reference = reference
        self.originalEncoding = originalEncoding
        self.normalizedUTF8ByteCount = normalizedUTF8ByteCount
        self.normalizedTextPathToken = normalizedTextPathToken
    }

    /// 从不可信 Codable 输入恢复元数据，并重新执行名称、引用和文本视图校验。
    /// - Parameter decoder: 外部存档或模型参数解码器。
    /// - Throws: 元数据字段不符合资源合同。
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(name: container.decode(String.self, forKey: .name),
                      reference: container.decode(BoneFileResourceReference.self, forKey: .reference),
                      originalEncoding: container.decodeIfPresent(BoneFileResourceEncoding.self, forKey: .originalEncoding),
                      normalizedUTF8ByteCount: container.decodeIfPresent(Int.self, forKey: .normalizedUTF8ByteCount),
                      normalizedTextPathToken: container.decodeIfPresent(String.self, forKey: .normalizedTextPathToken))
    }

    private enum CodingKeys: String, CodingKey {
        case name, reference, originalEncoding, normalizedUTF8ByteCount, normalizedTextPathToken
    }

    private static func validToken(_ value: String) -> Bool {
        (1...160).contains(value.utf8.count) && value.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95
        }
    }
}

/// 原始二进制范围读取请求；结果只返回有界字节窗口。
public struct BoneFileResourceByteReadRequest: Codable, Equatable, Sendable {
    public static let maximumPageBytes = 65_536
    public let reference: BoneFileResourceReference
    public let offset: Int
    public let maximumBytes: Int

    /// 创建一个绑定精确资源版本的二进制读取请求。
    /// - Parameters:
    ///   - reference: 原始快照引用。
    ///   - offset: 0 起点的字节偏移。
    ///   - maximumBytes: 本次最多读取的字节数。
    public init(reference: BoneFileResourceReference, offset: Int = 0, maximumBytes: Int = 4_096) throws {
        guard offset >= 0, offset <= reference.byteCount,
              (1...Self.maximumPageBytes).contains(maximumBytes) else {
            throw BoneFileResourceError.invalidRequest
        }
        self.reference = reference
        self.offset = offset
        self.maximumBytes = maximumBytes
    }

    /// 从不可信 Codable 输入恢复二进制窗口，并使用协议默认值补齐可选字段。
    /// - Parameter decoder: 外部工具调用解码器。
    /// - Throws: 引用或范围不符合有界读取合同。
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(reference: container.decode(BoneFileResourceReference.self, forKey: .reference),
                      offset: container.decodeIfPresent(Int.self, forKey: .offset) ?? 0,
                      maximumBytes: container.decodeIfPresent(Int.self, forKey: .maximumBytes) ?? 4_096)
    }

    private enum CodingKeys: String, CodingKey { case reference, offset, maximumBytes }
}

/// 有界二进制读取结果；Data 编码到工具边界时由 Codable 使用 Base64。
public struct BoneFileResourceBytePage: Codable, Equatable, Sendable {
    public let reference: BoneFileResourceReference
    public let offset: Int
    public let data: Data
    public let nextOffset: Int?

    /// 创建二进制页并验证页身份、长度和连续游标。
    /// - Parameters:
    ///   - reference: 原始快照引用。
    ///   - offset: 页实际起点。
    ///   - data: 页正文。
    public init(reference: BoneFileResourceReference, offset: Int, data: Data) throws {
        guard offset >= 0, offset <= reference.byteCount, data.count <= BoneFileResourceByteReadRequest.maximumPageBytes,
              offset <= reference.byteCount - data.count else { throw BoneFileResourceError.invalidRequest }
        self.reference = reference
        self.offset = offset
        self.data = data
        nextOffset = offset + data.count < reference.byteCount ? offset + data.count : nil
    }

    /// 按原始字节读取请求重新校验 Host handler 返回的页。
    /// - Parameter request: 产生该页的原始读取请求。
    /// - Returns: 通过引用、偏移、长度和连续游标校验的页。
    public func validated(for request: BoneFileResourceByteReadRequest) throws -> Self {
        guard reference == request.reference, offset == request.offset,
              data.count <= request.maximumBytes else {
            throw BoneFileResourceError.referenceMismatch
        }
        let expected = offset + data.count < reference.byteCount ? offset + data.count : nil
        guard nextOffset == expected else { throw BoneFileResourceError.invalidRequest }
        return self
    }
}

/// 压缩包中的安全条目目录项；条目名只用于选择内容，不会成为本地路径。
public struct BoneFileArchiveEntry: Codable, Equatable, Hashable, Sendable {
    public let name: String
    public let compressedByteCount: Int
    public let uncompressedByteCount: Int
    public let isDirectory: Bool
    public let isSymbolicLink: Bool

    /// 创建一个压缩包条目描述。
    /// - Parameters:
    ///   - name: 压缩包内的规范化条目名。
    ///   - compressedByteCount: 压缩后字节数。
    ///   - uncompressedByteCount: 展开后字节数。
    ///   - isDirectory: 是否为目录条目。
    ///   - isSymbolicLink: 是否声明为符号链接。
    public init(name: String, compressedByteCount: Int, uncompressedByteCount: Int,
                isDirectory: Bool, isSymbolicLink: Bool) throws {
        guard !name.isEmpty, compressedByteCount >= 0, uncompressedByteCount >= 0 else {
            throw BoneFileResourceError.archiveUnsafe
        }
        self.name = name
        self.compressedByteCount = compressedByteCount
        self.uncompressedByteCount = uncompressedByteCount
        self.isDirectory = isDirectory
        self.isSymbolicLink = isSymbolicLink
    }
}

/// 压缩包条目的有界读取页；offset 和 nextOffset 以展开后字节计。
public struct BoneFileArchivePage: Codable, Equatable, Sendable {
    public let entry: BoneFileArchiveEntry
    public let offset: Int
    public let data: Data
    public let nextOffset: Int?

    /// 创建压缩包条目读取页并校验连续游标。
    /// - Parameters:
    ///   - entry: 页所属条目。
    ///   - offset: 展开内容中的字节偏移。
    ///   - data: 本页最多返回的数据。
    public init(entry: BoneFileArchiveEntry, offset: Int, data: Data) throws {
        guard offset >= 0, offset <= entry.uncompressedByteCount,
              data.count <= BoneFileResourceByteReadRequest.maximumPageBytes,
              data.count <= entry.uncompressedByteCount - offset else {
            throw BoneFileResourceError.invalidRequest
        }
        self.entry = entry
        self.offset = offset
        self.data = data
        nextOffset = offset + data.count < entry.uncompressedByteCount ? offset + data.count : nil
    }
}

/// PDF 文档的结构化元数据，不包含整份正文。
public struct BoneFilePDFInspection: Codable, Equatable, Sendable {
    public let pageCount: Int
    public let title: String?
    public let author: String?

    /// 创建 PDF 结构化元数据。
    /// - Parameters:
    ///   - pageCount: PDF 页数。
    ///   - title: 文档标题。
    ///   - author: 文档作者。
    public init(pageCount: Int, title: String?, author: String?) throws {
        guard pageCount >= 0 else { throw BoneFileResourceError.parseFailed }
        self.pageCount = pageCount
        self.title = title
        self.author = author
    }
}

/// PDF 单页文本读取结果；页正文仍受有界 UTF-8 预算限制。
public struct BoneFilePDFPage: Codable, Equatable, Sendable {
    public let pageIndex: Int
    public let text: String
    public let isTruncated: Bool

    /// 创建 PDF 页文本结果。
    /// - Parameters:
    ///   - pageIndex: 从零开始的页索引。
    ///   - text: 页文本。
    ///   - isTruncated: 是否因预算截断。
    public init(pageIndex: Int, text: String, isTruncated: Bool) throws {
        guard pageIndex >= 0 else {
            throw BoneFileResourceError.parseFailed
        }
        self.pageIndex = pageIndex
        self.text = text
        self.isTruncated = isTruncated
    }
}

/// OOXML 文档的结构化元数据，首期支持 DOCX、XLSX 和 PPTX。
public struct BoneFileOfficeInspection: Codable, Equatable, Sendable {
    public let fileExtension: String
    public let entryNames: [String]
    public let textEntryNames: [String]

    /// 创建 Office 包检查结果。
    /// - Parameters:
    ///   - fileExtension: 规范化扩展名。
    ///   - entryNames: 安全包目录。
    ///   - textEntryNames: 参与文本投影的 XML 条目。
    public init(fileExtension: String, entryNames: [String], textEntryNames: [String]) throws {
        let normalized = fileExtension.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard ["docx", "xlsx", "pptx"].contains(normalized), entryNames.count <= 10_000,
              textEntryNames.count <= entryNames.count else {
            throw BoneFileResourceError.unsupportedFormat
        }
        self.fileExtension = normalized
        self.entryNames = entryNames
        self.textEntryNames = textEntryNames
    }
}

/// Office 文本投影的有界读取结果。
public struct BoneFileOfficeTextPage: Codable, Equatable, Sendable {
    public let offset: Int
    public let text: String
    public let nextOffset: Int?

    /// 创建 Office 文本页并推导连续偏移。
    /// - Parameters:
    ///   - offset: 规范化 UTF-8 文本偏移。
    ///   - text: 本页文本。
    ///   - totalByteCount: 投影文本总字节数。
    public init(offset: Int, text: String, totalByteCount: Int) throws {
        guard offset >= 0, totalByteCount >= offset,
              text.utf8.count <= totalByteCount - offset,
              !text.isEmpty || offset == totalByteCount else {
            throw BoneFileResourceError.invalidRequest
        }
        self.offset = offset
        self.text = text
        let end = offset + text.utf8.count
        nextOffset = end < totalByteCount ? end : nil
    }
}

/// DOCX 中的一个段落；段落内多个文本运行已经按文档顺序合并。
public struct BoneFileOfficeParagraph: Codable, Equatable, Sendable {
    public let text: String

    /// 创建一个 DOCX 段落结果。
    /// - Parameter text: 段落文本。
    public init(text: String) throws {
        guard text.utf8.count <= BoneStructuredFileReaders.maximumOfficeTextBytes else {
            throw BoneFileResourceError.capacityExceeded
        }
        self.text = text
    }
}

/// XLSX 中的一个单元格；值已经根据 sharedStrings 或 inlineStr 规则解析为文本。
public struct BoneFileOfficeCell: Codable, Equatable, Sendable {
    public let address: String
    public let value: String

    /// 创建一个 XLSX 单元格结果。
    /// - Parameters:
    ///   - address: Excel 单元格地址，例如 A1。
    ///   - value: 单元格文本值。
    public init(address: String, value: String) throws {
        guard !address.isEmpty, address.utf8.count <= 128,
              value.utf8.count <= BoneStructuredFileReaders.maximumOfficeTextBytes else {
            throw BoneFileResourceError.parseFailed
        }
        self.address = address
        self.value = value
    }
}

/// XLSX 中的一个工作表和它的有界单元格结果。
public struct BoneFileOfficeWorksheet: Codable, Equatable, Sendable {
    public let name: String
    public let cells: [BoneFileOfficeCell]

    /// 创建一个 XLSX 工作表结果。
    /// - Parameters:
    ///   - name: 工作表名称。
    ///   - cells: 按文档顺序排列的单元格。
    public init(name: String, cells: [BoneFileOfficeCell]) throws {
        guard !name.isEmpty, name.utf8.count <= 256, cells.count <= 100_000 else {
            throw BoneFileResourceError.parseFailed
        }
        self.name = name
        self.cells = cells
    }
}

/// PPTX 中的一张幻灯片；文本按 XML 文档顺序合并。
public struct BoneFileOfficeSlide: Codable, Equatable, Sendable {
    public let slideIndex: Int
    public let text: String

    /// 创建一个 PPTX 幻灯片结果。
    /// - Parameters:
    ///   - slideIndex: 从一开始的幻灯片序号。
    ///   - text: 幻灯片文本。
    public init(slideIndex: Int, text: String) throws {
        guard slideIndex > 0, text.utf8.count <= BoneStructuredFileReaders.maximumOfficeTextBytes else {
            throw BoneFileResourceError.parseFailed
        }
        self.slideIndex = slideIndex
        self.text = text
    }
}

/// Office 结构化读取结果，按文件类型提供对应集合。
public struct BoneFileOfficeStructure: Codable, Equatable, Sendable {
    public let fileExtension: String
    public let paragraphs: [BoneFileOfficeParagraph]
    public let worksheets: [BoneFileOfficeWorksheet]
    public let slides: [BoneFileOfficeSlide]

    /// 创建一个 Office 结构化结果。
    /// - Parameters:
    ///   - fileExtension: docx、xlsx 或 pptx。
    ///   - paragraphs: DOCX 段落。
    ///   - worksheets: XLSX 工作表。
    ///   - slides: PPTX 幻灯片。
    public init(fileExtension: String, paragraphs: [BoneFileOfficeParagraph] = [],
                worksheets: [BoneFileOfficeWorksheet] = [], slides: [BoneFileOfficeSlide] = []) throws {
        let normalized = fileExtension.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard ["docx", "xlsx", "pptx"].contains(normalized) else {
            throw BoneFileResourceError.unsupportedFormat
        }
        self.fileExtension = normalized
        self.paragraphs = paragraphs
        self.worksheets = worksheets
        self.slides = slides
    }
}

/// Office 结构化读取请求；文件类型由资源引用和持久 metadata 决定。
public struct BoneFileResourceOfficeStructureRequest: Codable, Equatable, Sendable {
    public let reference: BoneFileResourceReference

    /// 创建一个 Office 结构化读取请求。
    /// - Parameter reference: 精确的 Office 资源引用。
    public init(reference: BoneFileResourceReference) throws {
        guard reference.kind == .officeOpenXML else { throw BoneFileResourceError.invalidRequest }
        self.reference = reference
    }

    /// 从不可信工具输入恢复请求，并确认资源类型是 Office Open XML。
    /// - Parameter decoder: 外部工具调用解码器。
    /// - Throws: 引用无效或资源类型不匹配。
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(reference: container.decode(BoneFileResourceReference.self, forKey: .reference))
    }

    private enum CodingKeys: String, CodingKey { case reference }
}

/// Office 结构化读取结果，带回原始资源引用以便模型继续定位。
public struct BoneFileResourceOfficeStructureResult: Codable, Equatable, Sendable {
    public let reference: BoneFileResourceReference
    public let structure: BoneFileOfficeStructure

    /// 创建带资源引用的 Office 结构化结果。
    /// - Parameters:
    ///   - reference: 原始 Office 资源引用。
    ///   - structure: 结构化 Office 内容。
    public init(reference: BoneFileResourceReference, structure: BoneFileOfficeStructure) {
        self.reference = reference
        self.structure = structure
    }

    /// 按 Office 读取请求重新校验 Host handler 返回的结构。
    /// - Parameter request: 产生该结构的原始请求。
    /// - Returns: 通过资源引用和 Office 类型校验的结果。
    public func validated(for request: BoneFileResourceOfficeStructureRequest) throws -> Self {
        guard reference == request.reference,
              ["docx", "xlsx", "pptx"].contains(structure.fileExtension.lowercased()) else {
            throw BoneFileResourceError.referenceMismatch
        }
        return self
    }
}

/// 资源窗口读取模式；每种模式对应一个明确的解析视图。
public enum BoneFileResourceWindowKind: String, Codable, CaseIterable, Sendable {
    case text
    case pdfPage
    case officeText
    case archiveEntry
}

/// 资源窗口读取请求；引用、模式和可选定位字段均由 Host 重新校验。
public struct BoneFileResourceWindowRequest: Codable, Equatable, Sendable {
    public let reference: BoneFileResourceReference
    public let kind: BoneFileResourceWindowKind
    public let offset: Int
    public let maximumBytes: Int
    public let pageIndex: Int?
    public let entryName: String?

    /// 创建一个结构化资源窗口请求。
    /// - Parameters:
    ///   - reference: 精确资源版本引用。
    ///   - kind: 读取的派生视图类型。
    ///   - offset: 文本、Office 或归档展开字节偏移。
    ///   - maximumBytes: 本次最多返回的 UTF-8/展开字节数。
    ///   - pageIndex: PDF 页索引。
    ///   - entryName: 压缩包条目名。
    public init(reference: BoneFileResourceReference, kind: BoneFileResourceWindowKind,
                offset: Int = 0, maximumBytes: Int = 4_096,
                pageIndex: Int? = nil, entryName: String? = nil) throws {
        guard offset >= 0, (1...BoneFileResourceByteReadRequest.maximumPageBytes).contains(maximumBytes),
              pageIndex.map({ $0 >= 0 }) ?? true,
              entryName.map({ !$0.isEmpty && $0.utf8.count <= 1_024 && !$0.contains("\0") }) ?? true else {
            throw BoneFileResourceError.invalidRequest
        }

        // 在请求创建阶段绑定资源类型和窗口类型，避免 Host 收到互相矛盾的定位字段。
        let hasPageIndex = pageIndex != nil
        let hasEntryName = entryName != nil
        let matchesResourceKind: Bool
        switch kind {
        case .text:
            matchesResourceKind = reference.kind == .text && !hasPageIndex && !hasEntryName
        case .pdfPage:
            matchesResourceKind = reference.kind == .pdf && hasPageIndex && !hasEntryName && offset == 0
        case .officeText:
            matchesResourceKind = reference.kind == .officeOpenXML && !hasPageIndex && !hasEntryName
        case .archiveEntry:
            matchesResourceKind = reference.kind == .archive && !hasPageIndex && hasEntryName
        }
        guard matchesResourceKind else { throw BoneFileResourceError.invalidRequest }

        self.reference = reference
        self.kind = kind
        self.offset = offset
        self.maximumBytes = maximumBytes
        self.pageIndex = pageIndex
        self.entryName = entryName
    }

    /// 从不可信 Codable 输入恢复窗口请求并重新执行所有边界校验。
    /// - Parameter decoder: 外部工具调用解码器。
    /// - Throws: 请求字段无效。
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(reference: container.decode(BoneFileResourceReference.self, forKey: .reference),
                      kind: container.decode(BoneFileResourceWindowKind.self, forKey: .kind),
                      offset: container.decodeIfPresent(Int.self, forKey: .offset) ?? 0,
                      maximumBytes: container.decodeIfPresent(Int.self, forKey: .maximumBytes) ?? 4_096,
                      pageIndex: container.decodeIfPresent(Int.self, forKey: .pageIndex),
                      entryName: container.decodeIfPresent(String.self, forKey: .entryName))
    }

    private enum CodingKeys: String, CodingKey {
        case reference, kind, offset, maximumBytes, pageIndex, entryName
    }
}

/// 结构化资源窗口的统一输出；未使用的字段保持 nil。
public struct BoneFileResourceWindowResult: Codable, Equatable, Sendable {
    public let reference: BoneFileResourceReference
    public let kind: BoneFileResourceWindowKind
    public let text: String?
    public let nextOffset: Int?
    public let pageIndex: Int?
    public let isTruncated: Bool?
    public let data: Data?
    public let archiveEntry: BoneFileArchiveEntry?

    /// 创建结构化窗口结果。
    /// - Parameters: 各字段按 `kind` 选择性提供，未使用字段必须为 nil。
    public init(reference: BoneFileResourceReference, kind: BoneFileResourceWindowKind,
                text: String? = nil, nextOffset: Int? = nil, pageIndex: Int? = nil,
                isTruncated: Bool? = nil, data: Data? = nil,
                archiveEntry: BoneFileArchiveEntry? = nil) {
        self.reference = reference
        self.kind = kind
        self.text = text
        self.nextOffset = nextOffset
        self.pageIndex = pageIndex
        self.isTruncated = isTruncated
        self.data = data
        self.archiveEntry = archiveEntry
    }

    /// 按请求重新校验 Host handler 返回的结构化窗口。
    /// - Parameter request: 产生该结果的原始窗口请求。
    /// - Returns: 通过资源引用、模式、字段和范围校验的结果。
    public func validated(for request: BoneFileResourceWindowRequest) throws -> Self {
        guard reference == request.reference, kind == request.kind else {
            throw BoneFileResourceError.referenceMismatch
        }

        switch kind {
        case .text, .officeText:
            guard let text, text.utf8.count <= request.maximumBytes,
                  data == nil, pageIndex == nil, isTruncated == nil, archiveEntry == nil else {
                throw BoneFileResourceError.invalidRequest
            }
            try Self.validateNextOffset(nextOffset, offset: request.offset, minimum: request.offset + text.utf8.count)
        case .pdfPage:
            guard let requestedPage = request.pageIndex,
                  let text,
                  text.utf8.count <= request.maximumBytes,
                  pageIndex == requestedPage,
                  data == nil,
                  nextOffset == nil,
                  isTruncated != nil,
                  archiveEntry == nil else {
                throw BoneFileResourceError.invalidRequest
            }
        case .archiveEntry:
            guard let entryName = request.entryName,
                  let archiveEntry,
                  archiveEntry.name == entryName,
                  text == nil,
                  pageIndex == nil,
                  isTruncated == nil,
                  let data,
                  data.count <= request.maximumBytes else {
                throw BoneFileResourceError.invalidRequest
            }
            try Self.validateNextOffset(nextOffset, offset: request.offset,
                                        maximum: archiveEntry.uncompressedByteCount)
        }
        return self
    }

    /// 校验一个连续字节窗口的结束游标。
    /// - Parameters:
    ///   - nextOffset: Host 返回的下一次读取位置。
    ///   - offset: 本次请求的起始位置。
    ///   - maximum: 当前视图的总字节数。
    ///   - minimum: 本页正文结束后的最小连续位置。
    private static func validateNextOffset(_ nextOffset: Int?, offset: Int,
                                           minimum: Int? = nil, maximum: Int? = nil) throws {
        guard let nextOffset else { return }
        guard nextOffset > offset,
              minimum.map({ nextOffset >= $0 }) ?? true,
              maximum.map({ nextOffset <= $0 }) ?? true else {
            throw BoneFileResourceError.invalidRequest
        }
    }
}

/// 资源检查结果；只返回结构化元数据，不返回正文。
public struct BoneFileResourceInspection: Codable, Equatable, Sendable {
    public let metadata: BoneFileResourceMetadata
    public let format: BoneFileResourceFormatInspection?
    public let pdf: BoneFilePDFInspection?
    public let office: BoneFileOfficeInspection?
    public let archiveEntries: [BoneFileArchiveEntry]?

    /// 创建资源检查结果。
    /// - Parameters: 按资源类型提供对应派生检查视图。
    public init(metadata: BoneFileResourceMetadata, pdf: BoneFilePDFInspection? = nil,
                office: BoneFileOfficeInspection? = nil,
                archiveEntries: [BoneFileArchiveEntry]? = nil) {
        self.metadata = metadata
        self.format = nil
        self.pdf = pdf
        self.office = office
        self.archiveEntries = archiveEntries
    }

    /// 创建带格式探测结果的资源检查结果。
    /// - Parameters:
    ///   - metadata: 持久资源元数据。
    ///   - format: 资源格式和能力描述。
    ///   - pdf: PDF 结构化信息。
    ///   - office: Office 结构化信息。
    ///   - archiveEntries: 压缩包安全条目。
    public init(metadata: BoneFileResourceMetadata,
                format: BoneFileResourceFormatInspection,
                pdf: BoneFilePDFInspection? = nil,
                office: BoneFileOfficeInspection? = nil,
                archiveEntries: [BoneFileArchiveEntry]? = nil) {
        self.metadata = metadata
        self.format = format
        self.pdf = pdf
        self.office = office
        self.archiveEntries = archiveEntries
    }

    /// 从旧版或新版工具结果恢复检查结果，缺少 format 字段时按旧协议处理。
    /// - Parameter decoder: 外部工具结果解码器。
    /// - Throws: 结果字段不符合资源检查合同。
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let metadata = try container.decode(BoneFileResourceMetadata.self, forKey: .metadata)
        let pdf = try container.decodeIfPresent(BoneFilePDFInspection.self, forKey: .pdf)
        let office = try container.decodeIfPresent(BoneFileOfficeInspection.self, forKey: .office)
        let archiveEntries = try container.decodeIfPresent([BoneFileArchiveEntry].self, forKey: .archiveEntries)
        if let format = try container.decodeIfPresent(BoneFileResourceFormatInspection.self, forKey: .format) {
            self.init(metadata: metadata, format: format, pdf: pdf, office: office, archiveEntries: archiveEntries)
        } else {
            self.init(metadata: metadata, pdf: pdf, office: office, archiveEntries: archiveEntries)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case metadata, format, pdf, office, archiveEntries
    }

    /// 按检查请求校验 Host handler 返回的资源检查结果。
    /// - Parameter request: 原始资源检查请求。
    /// - Returns: 通过资源引用和资源类型校验的结果。
    public func validated(for request: BoneFileResourceReference) throws -> Self {
        guard metadata.reference == request else { throw BoneFileResourceError.referenceMismatch }
        if let format {
            guard format.family.matches(request.kind) else { throw BoneFileResourceError.invalidRequest }
        }
        switch request.kind {
        case .pdf:
            guard pdf != nil, office == nil, archiveEntries == nil else { throw BoneFileResourceError.invalidRequest }
        case .officeOpenXML:
            guard office != nil, pdf == nil, archiveEntries == nil else { throw BoneFileResourceError.invalidRequest }
        case .archive:
            guard archiveEntries != nil, pdf == nil, office == nil else { throw BoneFileResourceError.invalidRequest }
        case .text, .binary:
            guard pdf == nil, office == nil, archiveEntries == nil else { throw BoneFileResourceError.invalidRequest }
        }
        return self
    }
}
