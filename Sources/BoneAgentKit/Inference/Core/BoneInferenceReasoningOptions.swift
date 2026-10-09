import Foundation

/// 生成策略，与 reasoningDisclosure（展示策略）独立。nil 选项保留服务端默认行为。
public struct BoneInferenceReasoningOptions: Codable, Equatable, Sendable {
    public enum Mode: String, Codable, Sendable { case enabled, disabled, adaptive }
    public let mode: Mode?
    public let effort: String?
    /// -1 仅在显式配置允许的 Gemini 动态预算中使用。
    public let budgetTokens: Int?

    public init(mode: Mode? = nil, effort: String? = nil, budgetTokens: Int? = nil) {
        self.mode = mode; self.effort = effort; self.budgetTokens = budgetTokens
    }
    public func validated() throws -> Self {
        guard mode != nil || effort != nil || budgetTokens != nil,
              effort.map({ !$0.isEmpty && $0.count <= 32 && $0.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") } }) != false,
              budgetTokens.map({ $0 >= -1 }) != false,
              mode != .disabled || (effort == nil && budgetTokens == nil) else {
            throw BoneInferenceReasoningConfigurationError.invalidOptions
        }
        return self
    }
}

public enum BoneInferenceReasoningConfigurationError: Error, Equatable, Sendable {
    case invalidOptions
    case missingProfile
    case unsupportedMode
    case unsupportedEffort
    case unsupportedBudget
    case incompatibleProtocol
    case incompatibleOptions
    case temperatureUnsupported
    case conflictingLegacySetting
    case metadataMismatch
}

/// Host 为确切渠道模型显式选择的请求契约；不能直接由 models.dev 的 reasoning=true 推导。
/// 档位、模式与预算范围来自该实际入口文档或 Host 验证，不代表远端一定接受请求。
public struct BoneInferenceReasoningProfile: Equatable, Sendable {
    public enum WireFormat: String, Codable, Sendable {
        case openAIChat
        case thinkingType
        case enableThinking
        case anthropicBudget
        case anthropicAdaptive
        case anthropicCompatible
        case geminiBudget
        case geminiLevel
    }
    public enum Continuation: String, Codable, Sendable {
        case none
        case reasoningContent
        case anthropicThinking
    }
    public let wireFormat: WireFormat
    public let modes: Set<BoneInferenceReasoningOptions.Mode>
    public let effortValues: Set<String>
    public let budgetRange: ClosedRange<Int>?
    public let allowsTemperature: Bool
    public let continuation: Continuation

    public init(wireFormat: WireFormat, modes: Set<BoneInferenceReasoningOptions.Mode> = [],
                effortValues: Set<String> = [], budgetRange: ClosedRange<Int>? = nil,
                allowsTemperature: Bool = false, continuation: Continuation = .none) {
        self.wireFormat = wireFormat; self.modes = modes; self.effortValues = effortValues
        self.budgetRange = budgetRange; self.allowsTemperature = allowsTemperature
        self.continuation = continuation
    }

    func validated(for wire: BoneInferenceReasoningRequestWire) throws {
        guard !effortValues.contains(where: { $0.isEmpty || $0.count > 32 || !$0.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") } }),
              budgetRange.map({ $0.lowerBound >= -1 }) != false else {
            throw BoneInferenceReasoningConfigurationError.invalidOptions
        }
        switch (wireFormat, wire) {
        case (.openAIChat, .openAI), (.thinkingType, .openAI), (.enableThinking, .openAI),
             (.anthropicBudget, .anthropic), (.anthropicAdaptive, .anthropic),
             (.anthropicCompatible, .anthropic), (.geminiBudget, .gemini), (.geminiLevel, .gemini):
            return
        default:
            throw BoneInferenceReasoningConfigurationError.incompatibleProtocol
        }
    }
}

enum BoneInferenceReasoningRequestWire: Sendable {
    case openAI, anthropic, gemini
}
