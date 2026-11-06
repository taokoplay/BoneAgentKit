import Foundation

/// 尺寸限制只触发一次等比缩小；编码仍超出字节预算时失败，不继续牺牲分辨率。
/// OCR 等场景可显式提高目标尺寸/像素上限；默认保留无损编码。
public struct BoneInferenceImagePreprocessingPolicy: Equatable, Sendable {
    public let maxSourceBytes: Int
    public let maxSourcePixels: Int
    public let maxWidth: Int
    public let maxHeight: Int
    public let maxPixels: Int
    public let maximumPreparedBytes: Int
    public let allowsLossy: Bool
    public let jpegQuality: Double

    public init() {
        maxSourceBytes = BoneInferenceImageMetadata.maximumBytes
        maxSourcePixels = BoneInferenceImageMetadata.maximumPixels
        maxWidth = 2_048
        maxHeight = 2_048
        maxPixels = 4_000_000
        maximumPreparedBytes = 4 * 1_024 * 1_024
        allowsLossy = false
        jpegQuality = 0.85
    }

    public init(
        maxSourceBytes: Int = BoneInferenceImageMetadata.maximumBytes,
        maxSourcePixels: Int = BoneInferenceImageMetadata.maximumPixels,
        maxWidth: Int = 2_048,
        maxHeight: Int = 2_048,
        maxPixels: Int = 4_000_000,
        maximumPreparedBytes: Int = 4 * 1_024 * 1_024,
        allowsLossy: Bool = false,
        jpegQuality: Double = 0.85
    ) throws {
        guard (1...BoneInferenceImageMetadata.maximumBytes).contains(maxSourceBytes),
              (1...BoneInferenceImageMetadata.maximumPixels).contains(maxSourcePixels),
              (1...BoneInferenceImageMetadata.maximumDimension).contains(maxWidth),
              (1...BoneInferenceImageMetadata.maximumDimension).contains(maxHeight),
              (1...BoneInferenceImageMetadata.maximumPixels).contains(maxPixels),
              (1...BoneInferenceImageMetadata.maximumBytes).contains(maximumPreparedBytes),
              jpegQuality.isFinite, (0...1).contains(jpegQuality) else {
            throw BoneInferenceImageInputError.invalidPolicy
        }
        self.maxSourceBytes = maxSourceBytes
        self.maxSourcePixels = maxSourcePixels
        self.maxWidth = maxWidth
        self.maxHeight = maxHeight
        self.maxPixels = maxPixels
        self.maximumPreparedBytes = maximumPreparedBytes
        self.allowsLossy = allowsLossy
        self.jpegQuality = jpegQuality
    }
}

/// 可注入的内存预处理器，不缓存、落盘或联网。
/// operation 必须在完整解码前验证真实原图像素上限，并负责真实格式、单帧及方向校正。
/// 此包装器复核返回的资源限制；不能凭调用方提供的元数据鉴定图片内容。
public struct BoneInferenceImagePreprocessor: Sendable {
    public typealias Policy = BoneInferenceImagePreprocessingPolicy
    private let operation: @Sendable (Data, Policy) async throws -> BoneInferencePreparedImage

    public init(operation: @escaping @Sendable (Data, Policy) async throws -> BoneInferencePreparedImage) {
        self.operation = operation
    }

    public func prepare(_ data: Data, policy: Policy = .init()) async throws -> BoneInferencePreparedImage {
        try Task.checkCancellation()
        guard !data.isEmpty else { throw BoneInferenceImageInputError.invalidContent }
        guard data.count <= policy.maxSourceBytes else { throw BoneInferenceImageInputError.sourceTooLarge }
        let prepared = try await operation(data, policy)
        try Task.checkCancellation()
        let metadata = prepared.metadata
        guard metadata.byteCount == prepared.data.count else { throw BoneInferenceImageInputError.invalidMetadata }
        // Metadata 的构造器已验证 SDK 硬上限；这里再验证本次调用更严格的限制。
        guard metadata.width <= policy.maxWidth, metadata.height <= policy.maxHeight,
              metadata.width <= policy.maxPixels / metadata.height,
              prepared.data.count <= policy.maximumPreparedBytes else {
            throw BoneInferenceImageInputError.preparedImageTooLarge
        }
        try Task.checkCancellation()
        return prepared
    }
}
