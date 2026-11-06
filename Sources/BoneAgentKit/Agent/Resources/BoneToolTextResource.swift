import Foundation

/// 资源边界的固定错误，不携带正文、路径、资源标识或底层错误字符串。
public enum BoneToolTextResourceError: Error, Equatable, Sendable {
    case invalidReference
    case invalidPreview
    case invalidReadRequest
    case invalidPage
    case referenceMismatch
    case invalidOffset
    case pageExceedsRequest
    case accessDenied
    case unavailable
    case expired
}

/// Host 签发的不可变文本版本引用。标识和版本都不是 URL、文件路径或授权凭据。
/// Host 必须将同一 id/version 永久绑定到同一份字节，改变内容时签发新版本。
public struct BoneToolTextResourceReference: Codable, Hashable, Sendable {
    public let id: String
    public let version: String
    public let utf8ByteCount: Int

    public init(id: String, version: String, utf8ByteCount: Int) throws {
        guard Self.validToken(id), Self.validToken(version), utf8ByteCount >= 0 else {
            throw BoneToolTextResourceError.invalidReference
        }
        self.id = id
        self.version = version
        self.utf8ByteCount = utf8ByteCount
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(id: c.decode(String.self, forKey: .id), version: c.decode(String.self, forKey: .version),
                      utf8ByteCount: c.decode(Int.self, forKey: .utf8ByteCount))
    }

    private static func validToken(_ value: String) -> Bool {
        (1...128).contains(value.utf8.count) && value.utf8.allSatisfy {
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95
        }
    }
    private enum CodingKeys: CodingKey { case id, version, utf8ByteCount }
}

/// 原始文本的有界前缀；不是语义摘要。完整内容必须由 Host 保留以供后续回读。
/// Codable 用于模型/私有存储边界，内容不属于安全日志或普通 checkpoint。
public struct BoneToolTextResourcePreview: Codable, Equatable, Sendable {
    public static let maximumTextBytes = 4_096
    public let reference: BoneToolTextResourceReference
    public let text: String
    public var isTruncated: Bool { text.utf8.count < reference.utf8ByteCount }
    /// UTF-8 字节偏移；需要完整重读时使用 0，而不是只读取这个位置之后。
    public var nextOffset: Int? { isTruncated ? text.utf8.count : nil }

    /// Host 提供的 text 必须确为引用版本的前缀；SDK 只能检查长度，不能认证来源。
    public init(reference: BoneToolTextResourceReference, text: String) throws {
        guard text.utf8.count <= Self.maximumTextBytes, text.utf8.count <= reference.utf8ByteCount else {
            throw BoneToolTextResourceError.invalidPreview
        }
        self.reference = reference
        self.text = text
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(reference: c.decode(BoneToolTextResourceReference.self, forKey: .reference),
                      text: c.decode(String.self, forKey: .text))
        guard try c.decode(Bool.self, forKey: .isTruncated) == isTruncated,
              try c.decode(Int?.self, forKey: .nextOffset) == nextOffset else {
            throw BoneToolTextResourceError.invalidPreview
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(reference, forKey: .reference)
        try c.encode(text, forKey: .text)
        try c.encode(isTruncated, forKey: .isTruncated)
        try c.encode(nextOffset, forKey: .nextOffset)
    }
    private enum CodingKeys: CodingKey { case reference, text, isTruncated, nextOffset }
}

/// 精确版本内的文本页请求；offset 和 maximumBytes 都以 UTF-8 字节计。
public struct BoneToolTextResourceReadRequest: Codable, Equatable, Sendable {
    /// 至少容纳一个完整 Unicode scalar；上限保证最坏 JSON 转义后仍小于 Tool Result 门限。
    public static let minimumPageBytes = 4
    public static let maximumPageBytes = 65_536
    public let reference: BoneToolTextResourceReference
    public let offset: Int
    public let maximumBytes: Int

    public init(reference: BoneToolTextResourceReference, offset: Int = 0, maximumBytes: Int = 4_096) throws {
        guard offset >= 0, offset <= reference.utf8ByteCount,
              (Self.minimumPageBytes...Self.maximumPageBytes).contains(maximumBytes) else {
            throw BoneToolTextResourceError.invalidReadRequest
        }
        self.reference = reference
        self.offset = offset
        self.maximumBytes = maximumBytes
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(reference: c.decode(BoneToolTextResourceReference.self, forKey: .reference),
                      offset: c.decode(Int.self, forKey: .offset), maximumBytes: c.decode(Int.self, forKey: .maximumBytes))
    }
    private enum CodingKeys: CodingKey { case reference, offset, maximumBytes }
}

/// 引用版本中的连续文本页。只在 EOF 允许空页，非末页必须前进；nextOffset 由真实页长推导。
/// Host 保证正文确实来自该 offset；不支持静默跳页、归一化或切换到新版本。
public struct BoneToolTextResourcePage: Codable, Equatable, Sendable {
    public let reference: BoneToolTextResourceReference
    public let offset: Int
    public let text: String
    public var nextOffset: Int? {
        let end = offset + text.utf8.count
        return end < reference.utf8ByteCount ? end : nil
    }

    public init(reference: BoneToolTextResourceReference, offset: Int, text: String) throws {
        let size = text.utf8.count
        guard offset >= 0, offset <= reference.utf8ByteCount,
              size <= BoneToolTextResourceReadRequest.maximumPageBytes,
              size <= reference.utf8ByteCount - offset,
              size > 0 || offset == reference.utf8ByteCount else {
            throw BoneToolTextResourceError.invalidPage
        }
        self.reference = reference
        self.offset = offset
        self.text = text
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(reference: c.decode(BoneToolTextResourceReference.self, forKey: .reference),
                      offset: c.decode(Int.self, forKey: .offset), text: c.decode(String.self, forKey: .text))
        guard try c.decode(Int?.self, forKey: .nextOffset) == nextOffset else {
            throw BoneToolTextResourceError.invalidPage
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(reference, forKey: .reference)
        try c.encode(offset, forKey: .offset)
        try c.encode(text, forKey: .text)
        try c.encode(nextOffset, forKey: .nextOffset)
    }
    private enum CodingKeys: CodingKey { case reference, offset, text, nextOffset }
}
