import Foundation

/// 外部目录的可追溯声明，不是运行验证，也不授予 Engine 未实现的能力。
/// 模态、状态和 effort 使用字符串保留新值；nil 为未知，不能当作 false。
public struct BoneModelMetadata: Codable, Equatable, Sendable {
    public struct Provenance: Codable, Equatable, Sendable {
        public enum Source: String, Codable, Sendable { case modelsDev, official, host }
        public let source: Source
        public let providerID: String
        public let retrievedAt: String
        public let sourceURL: URL
        public let sourceRevision: String?

        public init(source: Source, providerID: String, retrievedAt: String,
                    sourceURL: URL, sourceRevision: String? = nil) {
            self.source = source; self.providerID = providerID; self.retrievedAt = retrievedAt
            self.sourceURL = sourceURL; self.sourceRevision = sourceRevision
        }
    }

    public struct ReasoningOption: Codable, Equatable, Sendable {
        public let type: String
        public let values: [String?]?
        public let min: Int?
        public let max: Int?

        public init(type: String, values: [String?]? = nil, min: Int? = nil, max: Int? = nil) {
            self.type = type; self.values = values; self.min = min; self.max = max
        }
    }

    public enum Interleaved: Codable, Equatable, Sendable {
        case supported
        case field(String)

        public init(from decoder: any Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let flag = try? container.decode(Bool.self), flag {
                self = .supported
            } else {
                let value = try container.decode(Field.self)
                guard !value.field.isEmpty else {
                    throw DecodingError.dataCorruptedError(in: container, debugDescription: "Empty interleaved field")
                }
                self = .field(value.field)
            }
        }
        public func encode(to encoder: any Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .supported: try container.encode(true)
            case let .field(value): try container.encode(Field(field: value))
            }
        }
        private struct Field: Codable { let field: String }
    }

    public struct Modalities: Codable, Equatable, Sendable {
        public let input: [String]
        public let output: [String]
        public init(input: [String], output: [String]) { self.input = input; self.output = output }
    }

    /// 保留目录原始数值，含图片模型的 0；不会自动转成可执行上下文预算。
    public struct Limits: Codable, Equatable, Sendable {
        public let context: Int?
        public let input: Int?
        public let output: Int?
        public init(context: Int? = nil, input: Int? = nil, output: Int? = nil) {
            self.context = context; self.input = input; self.output = output
        }
    }

    /// 目录 USD / 百万 token 报价；不是计费承诺或本次调用成本。
    public struct Cost: Codable, Equatable, Sendable {
        public struct Tier: Codable, Equatable, Sendable {
            public struct Threshold: Codable, Equatable, Sendable {
                public let type: String?
                public let size: Int
            }
            public let tier: Threshold
            public let input: Double
            public let output: Double
            public let reasoning: Double?
            public let cacheRead: Double?
            public let cacheWrite: Double?
            public let inputAudio: Double?
            public let outputAudio: Double?
            private enum CodingKeys: String, CodingKey {
                case tier, input, output, reasoning
                case cacheRead = "cache_read", cacheWrite = "cache_write"
                case inputAudio = "input_audio", outputAudio = "output_audio"
            }
        }
        public let input: Double
        public let output: Double
        public let reasoning: Double?
        public let cacheRead: Double?
        public let cacheWrite: Double?
        public let inputAudio: Double?
        public let outputAudio: Double?
        public let tiers: [Tier]?
        private enum CodingKeys: String, CodingKey {
            case input, output, reasoning, tiers
            case cacheRead = "cache_read", cacheWrite = "cache_write"
            case inputAudio = "input_audio", outputAudio = "output_audio"
        }
    }

    /// 对齐发布目录的核心字段。供应商请求 body/header 不在元数据中执行或注入。
    public struct Declaration: Codable, Equatable, Sendable {
        public let id: String
        public let name: String?
        public let description: String?
        public let family: String?
        public let canonicalModelID: String?
        public let reasoning: Bool?
        public let reasoningOptions: [ReasoningOption]?
        public let interleaved: Interleaved?
        public let toolCalling: Bool?
        public let structuredOutput: Bool?
        public let temperature: Bool?
        public let attachment: Bool?
        public let modalities: Modalities?
        public let limits: Limits?
        public let status: String?
        public let cost: Cost?
        public let releaseDate: String?
        public let lastUpdated: String?
        public let knowledge: String?
        public let openWeights: Bool?

        public init(id: String, reasoning: Bool? = nil, reasoningOptions: [ReasoningOption]? = nil,
                    interleaved: Interleaved? = nil, toolCalling: Bool? = nil,
                    structuredOutput: Bool? = nil, temperature: Bool? = nil,
                    attachment: Bool? = nil, modalities: Modalities? = nil, limits: Limits? = nil) {
            self.id = id; self.reasoning = reasoning; self.reasoningOptions = reasoningOptions
            self.interleaved = interleaved; self.toolCalling = toolCalling
            self.structuredOutput = structuredOutput; self.temperature = temperature
            self.attachment = attachment; self.modalities = modalities; self.limits = limits
            name = nil; description = nil; family = nil; canonicalModelID = nil
            status = nil; cost = nil; releaseDate = nil; lastUpdated = nil; knowledge = nil; openWeights = nil
        }
        private enum CodingKeys: String, CodingKey {
            case id, name, description, family, reasoning, interleaved, temperature, attachment
            case modalities, status, cost, knowledge
            case canonicalModelID = "canonical_model_id", reasoningOptions = "reasoning_options"
            case toolCalling = "tool_call", structuredOutput = "structured_output", limits = "limit"
            case releaseDate = "release_date", lastUpdated = "last_updated", openWeights = "open_weights"
        }
    }

    public let provenance: Provenance
    public let declaration: Declaration
    public init(provenance: Provenance, declaration: Declaration) {
        self.provenance = provenance; self.declaration = declaration
    }
}
