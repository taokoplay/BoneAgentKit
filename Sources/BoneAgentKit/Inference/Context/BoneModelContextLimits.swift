import Foundation

/// 供应商或实际网关公开声明的模型 Token 能力。
public struct BoneModelContextLimits: Codable, Equatable, Sendable {
    /// 限制数据来源；没有公开证据的模型不应构造本类型。
    public enum Source: String, Codable, Sendable {
        case official
        case gateway
    }

    public let contextWindowTokens: Int
    public let maximumInputTokens: Int?
    public let maximumOutputTokens: Int?
    public let source: Source
    public let verifiedAt: String
    public let documentationURL: URL

    private enum CodingKeys: CodingKey {
        case contextWindowTokens, maximumInputTokens, maximumOutputTokens
        case source, verifiedAt, documentationURL
    }

    public init(
        contextWindowTokens: Int,
        maximumInputTokens: Int?,
        maximumOutputTokens: Int?,
        source: Source,
        verifiedAt: String,
        documentationURL: URL
    ) throws {
        guard contextWindowTokens > 0,
              maximumInputTokens.map({ $0 > 0 && $0 <= contextWindowTokens }) != false,
              maximumOutputTokens.map({ $0 > 0 }) != false,
              !verifiedAt.isEmpty,
              documentationURL.scheme?.lowercased() == "https",
              documentationURL.host != nil else {
            throw BoneModelContextLimitsError.invalidLimits
        }
        self.contextWindowTokens = contextWindowTokens
        self.maximumInputTokens = maximumInputTokens
        self.maximumOutputTokens = maximumOutputTokens
        self.source = source
        self.verifiedAt = verifiedAt
        self.documentationURL = documentationURL
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            contextWindowTokens: container.decode(Int.self, forKey: .contextWindowTokens),
            maximumInputTokens: container.decodeIfPresent(Int.self, forKey: .maximumInputTokens),
            maximumOutputTokens: container.decodeIfPresent(Int.self, forKey: .maximumOutputTokens),
            source: container.decode(Source.self, forKey: .source),
            verifiedAt: container.decode(String.self, forKey: .verifiedAt),
            documentationURL: container.decode(URL.self, forKey: .documentationURL)
        )
    }

    /// 从 App 或其他宿主的扩展 JSON 中读取 `tokenLimits`。
    /// - Parameter value: 包含 `tokenLimits` 的 JSON 字符串。
    /// - Returns: 经统一校验的限制；字段缺失或非法时返回 nil。
    public static func decodeFromExtraConfiguration(_ value: String) -> Self? {
        struct Container: Decodable { let tokenLimits: RawLimits? }
        guard let data = value.data(using: .utf8),
              let raw = try? JSONDecoder().decode(Container.self, from: data).tokenLimits,
              let documentationURL = URL(string: raw.documentationURL) else {
            return nil
        }
        return try? Self(
            contextWindowTokens: raw.contextWindowTokens,
            maximumInputTokens: raw.maximumInputTokens,
            maximumOutputTokens: raw.maximumOutputTokens,
            source: raw.source,
            verifiedAt: raw.verifiedAt,
            documentationURL: documentationURL
        )
    }
}

public enum BoneModelContextLimitsError: Error, Equatable, Sendable {
    case invalidLimits
}

private struct RawLimits: Decodable {
    let contextWindowTokens: Int
    let maximumInputTokens: Int?
    let maximumOutputTokens: Int?
    let source: BoneModelContextLimits.Source
    let verifiedAt: String
    let documentationURL: String
}
