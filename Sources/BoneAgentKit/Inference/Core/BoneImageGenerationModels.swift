import Foundation

/// 图片输出的像素尺寸。
public struct BoneInferenceImageSize: Codable, Equatable, Sendable {
    /// Task 1 的保守单边上限；Provider 可进一步收紧。
    public static let maximumDimension = 4_096
    /// Task 1 的保守总像素上限，限制解码后的内存压力。
    public static let maximumPixelCount = 16_000_000

    public let width: Int
    public let height: Int
    public let pixelCount: Int
    /// 档位型协议实际提交的 size；nil 表示使用精确像素。
    public let requestSizeValue: String?
    /// 档位型协议实际提交的 ratio；nil 表示使用约分宽高比。
    public let requestRatioValue: String?

    public init(
        width: Int,
        height: Int,
        requestSizeValue: String? = nil,
        requestRatioValue: String? = nil
    ) throws {
        guard (1...Self.maximumDimension).contains(width),
              (1...Self.maximumDimension).contains(height) else {
            throw BoneInferenceError.invalidImageSize
        }
        let (pixelCount, overflow) = width.multipliedReportingOverflow(by: height)
        guard !overflow, pixelCount <= Self.maximumPixelCount else {
            throw BoneInferenceError.invalidImageSize
        }
        self.width = width
        self.height = height
        self.pixelCount = pixelCount
        self.requestSizeValue = requestSizeValue
        self.requestRatioValue = requestRatioValue
    }

    public var openAIValue: String { "\(width)x\(height)" }

    public var aspectRatio: String {
        var lhs = width
        var rhs = height
        while rhs != 0 { (lhs, rhs) = (rhs, lhs % rhs) }
        let divisor = max(lhs, 1)
        return "\(width / divisor):\(height / divisor)"
    }

    private enum CodingKeys: String, CodingKey {
        case width
        case height
        case requestSizeValue
        case requestRatioValue
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let width = try container.decode(Int.self, forKey: .width)
        let height = try container.decode(Int.self, forKey: .height)
        let requestSizeValue = try container.decodeIfPresent(String.self, forKey: .requestSizeValue)
        let requestRatioValue = try container.decodeIfPresent(String.self, forKey: .requestRatioValue)
        do {
            try self.init(
                width: width,
                height: height,
                requestSizeValue: requestSizeValue,
                requestRatioValue: requestRatioValue
            )
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .width,
                in: container,
                debugDescription: "Invalid image dimensions"
            )
        }
    }
}

/// 单次图片请求的输出数量。
public struct BoneInferenceImageCount: Codable, Equatable, Sendable {
    /// Task 1 的保守批量上限，避免一次请求产生无界成本；Provider 可进一步收紧。
    public static let maximum = 8

    public let value: Int

    public init(_ value: Int) throws {
        guard (1...Self.maximum).contains(value) else {
            throw BoneInferenceError.invalidImageCount
        }
        self.value = value
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let value = try container.decode(Int.self, forKey: .value)
        do {
            try self.init(value)
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .value,
                in: container,
                debugDescription: "Invalid image count"
            )
        }
    }
}

/// 受控图片媒体类型；仅接受最长 127 字节的 ASCII type/subtype token。
public struct BoneInferenceImageMediaType: Codable, Equatable, Sendable {
    public static let maximumLength = 127
    public let value: String

    public init(_ value: String) throws {
        guard !value.isEmpty,
              value.utf8.count <= Self.maximumLength,
              value.utf8.allSatisfy({ $0 < 128 }) else {
            throw BoneInferenceError.invalidImageMediaType
        }
        let parts = value.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2,
              parts.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy(Self.isTokenByte) }) else {
            throw BoneInferenceError.invalidImageMediaType
        }
        self.value = value
    }

    private static func isTokenByte(_ byte: UInt8) -> Bool {
        switch byte {
        case 48...57, 65...90, 97...122, 33, 35...39, 42, 43, 45, 46, 94, 95, 96, 124, 126:
            return true
        default:
            return false
        }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        do {
            try self.init(value)
        } catch {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid image media type"
            )
        }
    }
}

/// 临时 Base64 图片正文；只在单次运行内传递，不可 Codable 或写入日志/Checkpoint。
public struct BoneInferenceImageInlineBase64: Equatable, Sendable {
    /// Task 1 的单张解码后数据上限。
    public static let maximumByteCount = 20 * 1_024 * 1_024
    /// 对应最大解码数据的严格 Base64 编码长度；解码前先检查，避免超限分配。
    public static let maximumEncodedCharacterCount = ((maximumByteCount + 2) / 3) * 4

    public let data: String
    public let mimeType: BoneInferenceImageMediaType
    public let decodedByteCount: Int

    public init(data: String, mimeType: BoneInferenceImageMediaType) throws {
        guard data.utf8.count <= Self.maximumEncodedCharacterCount else {
            throw BoneInferenceError.imagePayloadTooLarge
        }
        guard !data.isEmpty,
              data.utf8.allSatisfy(Self.isBase64Byte),
              data.utf8.count.isMultiple(of: 4),
              let estimatedByteCount = Self.estimatedDecodedByteCount(data) else {
            throw BoneInferenceError.invalidImagePayload
        }
        guard estimatedByteCount <= Self.maximumByteCount else {
            throw BoneInferenceError.imagePayloadTooLarge
        }
        guard let decoded = Data(base64Encoded: data),
              decoded.count == estimatedByteCount else {
            throw BoneInferenceError.invalidImagePayload
        }
        self.data = data
        self.mimeType = mimeType
        decodedByteCount = decoded.count
    }

    private static func isBase64Byte(_ byte: UInt8) -> Bool {
        switch byte {
        case 48...57, 65...90, 97...122, 43, 47, 61:
            return true
        default:
            return false
        }
    }

    private static func estimatedDecodedByteCount(_ data: String) -> Int? {
        let bytes = Array(data.utf8)
        let padding: Int
        if bytes.suffix(2) == [61, 61] {
            padding = 2
        } else if bytes.last == 61 {
            padding = 1
        } else {
            padding = 0
        }
        guard !bytes.dropLast(padding).contains(61) else {
            return nil
        }
        let groups = bytes.count / 4
        let (untrimmedCount, overflow) = groups.multipliedReportingOverflow(by: 3)
        guard !overflow, untrimmedCount >= padding else {
            return nil
        }
        return untrimmedCount - padding
    }
}

/// 临时二进制图片正文；只在单次运行内传递，不可 Codable 或写入日志/Checkpoint。
public struct BoneInferenceImageInlineData: Equatable, Sendable {
    /// 与 Base64 payload 相同的单张 20 MiB 保守上限。
    public static let maximumByteCount = BoneInferenceImageInlineBase64.maximumByteCount

    public let data: Data
    public let mimeType: BoneInferenceImageMediaType

    public init(data: Data, mimeType: BoneInferenceImageMediaType) throws {
        guard data.count <= Self.maximumByteCount else {
            throw BoneInferenceError.imagePayloadTooLarge
        }
        self.data = data
        self.mimeType = mimeType
    }
}

/// 图片生成请求；不承担本地资产落库。
public struct BoneInferenceImageGenerationRequest: Codable, Equatable, Sendable {
    public let modelID: String
    public let prompt: String
    public let count: BoneInferenceImageCount
    public let size: BoneInferenceImageSize

    public init(
        modelID: String,
        prompt: String,
        count: BoneInferenceImageCount,
        size: BoneInferenceImageSize
    ) {
        self.modelID = modelID
        self.prompt = prompt
        self.count = count
        self.size = size
    }
}

/// 运行时图片载荷；原始 URL/Base64/Data 不允许直接 Codable。
public enum BoneInferenceImagePayload: Equatable, Sendable {
    case remoteURL(URL)
    case base64(BoneInferenceImageInlineBase64)
    case inlineData(BoneInferenceImageInlineData)

    public var inlineByteCount: Int {
        switch self {
        case .remoteURL:
            return 0
        case .base64(let image):
            return image.decodedByteCount
        case .inlineData(let image):
            return image.data.count
        }
    }

    /// 生成可安全持久化的摘要，不包含 URL 或图片正文。
    public var metadata: BoneInferenceImagePayloadMetadata {
        switch self {
        case .remoteURL:
            return .remoteURL
        case .base64(let image):
            return .inline(byteCount: image.decodedByteCount, mimeType: image.mimeType)
        case .inlineData(let image):
            return .inline(byteCount: image.data.count, mimeType: image.mimeType)
        }
    }
}

/// 可序列化的轻量图片摘要；不构成可恢复原图的引用。
public enum BoneInferenceImagePayloadMetadata: Codable, Equatable, Sendable {
    case remoteURL
    case inline(byteCount: Int, mimeType: BoneInferenceImageMediaType)
}

/// 一次图片生成调用的运行时输出集合。
public struct BoneInferenceImageGenerationResponse: Equatable, Sendable {
    /// 与请求数量上限一致，单次响应最多 8 个 payload。
    public static let maximumPayloadCount = BoneInferenceImageCount.maximum
    /// Task 1 的响应 inline 数据累计上限；远程 URL 不计入。
    public static let maximumInlineByteCount = 40 * 1_024 * 1_024

    public let images: [BoneInferenceImagePayload]

    public init(images: [BoneInferenceImagePayload]) throws {
        try Self.validate(images: images)
        self.images = images
    }

    /// 统一验证 Provider 返回值；即使 Provider 绕过便捷构造，也可在 Engine 出口复验。
    public func validated() throws -> Self {
        try Self.validate(images: images)
        return self
    }

    private static func validate(images: [BoneInferenceImagePayload]) throws {
        guard images.count <= maximumPayloadCount else {
            throw BoneInferenceError.tooManyImagePayloads
        }
        var totalInlineBytes = 0
        for image in images {
            let (nextTotal, overflow) = totalInlineBytes.addingReportingOverflow(image.inlineByteCount)
            guard !overflow, nextTotal <= maximumInlineByteCount else {
                throw BoneInferenceError.imageResponseTooLarge
            }
            totalInlineBytes = nextTotal
        }
    }
}
