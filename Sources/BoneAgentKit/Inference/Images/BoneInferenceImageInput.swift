import Foundation

/// 图片输入的固定失败分类，不包含原文、引用、图片字节或凭据。
public enum BoneInferenceImageInputError: Error, Equatable, Sendable {
    case invalidMetadata, invalidReference, invalidContent, invalidPolicy
    case unsupportedFormat, unsupportedAnimation, unsupportedDetail, decodingFailed
    case sourceTooLarge, preparedImageTooLarge, referenceMismatch
    case missingTokenEstimator, invalidTokenEstimate, tokenOverflow
    case tooManyImages, imageBytesExceeded, requestBytesExceeded, inputTokensExceeded
}

public enum BoneInferenceImageFormat: String, Codable, CaseIterable, Sendable {
    case png = "image/png", jpeg = "image/jpeg", webp = "image/webp"
}

/// 最终发送图片的真实编码尺寸；不能填原图尺寸或从文件名猜测。
public struct BoneInferenceImageMetadata: Codable, Hashable, Sendable {
    public static let maximumBytes = 20 * 1_024 * 1_024
    public static let maximumDimension = 32_768
    public static let maximumPixels = 64_000_000
    public let format: BoneInferenceImageFormat
    public let width: Int
    public let height: Int
    public let byteCount: Int

    public init(format: BoneInferenceImageFormat, width: Int, height: Int, byteCount: Int) throws {
        guard (1...Self.maximumDimension).contains(width), (1...Self.maximumDimension).contains(height),
              width <= Self.maximumPixels / height, (1...Self.maximumBytes).contains(byteCount) else {
            throw BoneInferenceImageInputError.invalidMetadata
        }
        self.format = format; self.width = width; self.height = height; self.byteCount = byteCount
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(format: c.decode(BoneInferenceImageFormat.self, forKey: .format),
                      width: c.decode(Int.self, forKey: .width), height: c.decode(Int.self, forKey: .height),
                      byteCount: c.decode(Int.self, forKey: .byteCount))
    }
    private enum CodingKeys: CodingKey { case format, width, height, byteCount }
}

/// 可序列化的私有附件引用；没有 Base64、URL 或本地路径，不是授权许可。
/// Host 每次解析时校验访问范围/有效期；SDK 在发送前匹配 SHA-256 与实际编码元数据。
public struct BoneInferenceImageReference: Codable, Hashable, Sendable {
    public let id: String
    public let version: String
    public let sha256: String
    public let metadata: BoneInferenceImageMetadata

    public init(id: String, version: String, sha256: String, metadata: BoneInferenceImageMetadata) throws {
        guard Self.token(id), Self.token(version), sha256.utf8.count == 64,
              sha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw BoneInferenceImageInputError.invalidReference
        }
        self.id = id; self.version = version; self.sha256 = sha256; self.metadata = metadata
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(id: c.decode(String.self, forKey: .id), version: c.decode(String.self, forKey: .version),
                      sha256: c.decode(String.self, forKey: .sha256), metadata: c.decode(BoneInferenceImageMetadata.self, forKey: .metadata))
    }
    private static func token(_ value: String) -> Bool {
        (1...128).contains(value.utf8.count) && value.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95
        }
    }
    private enum CodingKeys: CodingKey { case id, version, sha256, metadata }
}

/// detail 的含义取决于 Provider。首期 OpenAI 映射三档；其他 Provider 只接受 automatic。
public enum BoneInferenceImageDetail: String, Codable, Sendable { case automatic, low, high }
public struct BoneInferenceImageInput: Codable, Hashable, Sendable {
    public let reference: BoneInferenceImageReference
    public let detail: BoneInferenceImageDetail
    public init(reference: BoneInferenceImageReference, detail: BoneInferenceImageDetail = .automatic) {
        self.reference = reference; self.detail = detail
    }
}

/// 用户及 Tool 的有序多模态内容；图片正文由配置的解析器在请求前读取，不嵌入历史 JSON。
public enum BoneInferenceInputContent: Codable, Equatable, Sendable {
    case text(String)
    case image(BoneInferenceImageInput)

    static func validate(_ parts: [Self]) throws {
        guard !parts.isEmpty, parts.count <= 128 else { throw BoneInferenceImageInputError.invalidContent }
        for part in parts {
            if case .text(let value) = part, value.isEmpty { throw BoneInferenceImageInputError.invalidContent }
        }
    }
}

/// 运行时图片数据，不 Codable，不自动记录。构造器校验字节长度；Inspector 负责真实解码复验。
public struct BoneInferencePreparedImage: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let data: Data
    public let metadata: BoneInferenceImageMetadata
    public init(data: Data, metadata: BoneInferenceImageMetadata) throws {
        guard data.count == metadata.byteCount else { throw BoneInferenceImageInputError.invalidMetadata }
        self.data = data; self.metadata = metadata
    }
    public func reference(id: String, version: String) throws -> BoneInferenceImageReference {
        try .init(id: id, version: version, sha256: BoneSHA256.hexDigest(data), metadata: metadata)
    }
    public var description: String { "BoneInferencePreparedImage(bytes: \(data.count), width: \(metadata.width), height: \(metadata.height))" }
    public var debugDescription: String { description }
}

/// 可信图片解码器契约；必须验证真实格式、完整可解码、单帧、正向像素尺寸及资源上限。
public typealias BoneInferenceImageInspector = @Sendable (Data) throws -> BoneInferenceImageMetadata

/// Host 负责读取授权与有效期；SDK 检查精确内容及 Inspector 返回的实际元数据，不缓存或联网。
public struct BoneInferenceImageResolver: Sendable {
    private let load: @Sendable (BoneInferenceImageReference) async throws -> Data
    private let inspect: BoneInferenceImageInspector
    public init(inspect: @escaping BoneInferenceImageInspector,
                load: @escaping @Sendable (BoneInferenceImageReference) async throws -> Data) {
        self.inspect = inspect; self.load = load
    }
    public func resolve(_ reference: BoneInferenceImageReference) async throws -> BoneInferencePreparedImage {
        try Task.checkCancellation()
        let bytes = try await load(reference)
        try Task.checkCancellation()
        guard bytes.count == reference.metadata.byteCount, bytes.count <= BoneInferenceImageMetadata.maximumBytes,
              BoneSHA256.hexDigest(bytes) == reference.sha256 else { throw BoneInferenceImageInputError.referenceMismatch }
        let metadata = try inspect(bytes)
        guard metadata == reference.metadata else { throw BoneInferenceImageInputError.referenceMismatch }
        try Task.checkCancellation()
        return try .init(data: bytes, metadata: metadata)
    }
}
