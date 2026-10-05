import Foundation

/// 运行时预算与官方模型事实分离；Host 上限不得伪装成官方能力。
public struct BoneContextWindowBudget: Codable, Equatable, Sendable {
    public enum Source: String, Codable, Sendable { case model, runtime, host }
    public let contextWindowTokens: Int
    public let maximumInputTokens: Int?
    public let maximumOutputTokens: Int?
    public let source: Source

    public init(contextWindowTokens: Int, maximumInputTokens: Int? = nil,
                maximumOutputTokens: Int? = nil, source: Source) throws {
        guard contextWindowTokens > 0,
              maximumInputTokens.map({ $0 > 0 && $0 <= contextWindowTokens }) != false,
              maximumOutputTokens.map({ $0 > 0 && $0 <= contextWindowTokens }) != false else {
            throw BoneContextWindowBudgetError.invalidBudget
        }
        self.contextWindowTokens = contextWindowTokens
        self.maximumInputTokens = maximumInputTokens
        self.maximumOutputTokens = maximumOutputTokens
        self.source = source
    }

    public init(modelLimits: BoneModelContextLimits) {
        contextWindowTokens = modelLimits.contextWindowTokens
        maximumInputTokens = modelLimits.maximumInputTokens
        maximumOutputTokens = modelLimits.maximumOutputTokens.map { min($0, modelLimits.contextWindowTokens) }
        source = .model
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(contextWindowTokens: c.decode(Int.self, forKey: .contextWindowTokens),
                      maximumInputTokens: c.decodeIfPresent(Int.self, forKey: .maximumInputTokens),
                      maximumOutputTokens: c.decodeIfPresent(Int.self, forKey: .maximumOutputTokens),
                      source: c.decode(Source.self, forKey: .source))
    }

    public func availableInputTokens(
        configuredOutputTokens: Int?, preferredOutputTokens: Int?,
        protocolReserveTokens: Int = BoneContextWindowPlanner.defaultProtocolReserveTokens,
        safetyMarginTokens: Int? = nil
    ) throws -> (maximumOutputTokens: Int, availableInputTokens: Int) {
        let choices = [configuredOutputTokens, preferredOutputTokens].compactMap { $0 }.filter { $0 > 0 }
        let desired = choices.min() ?? BoneContextWindowPlanner.defaultOutputTokens
        let output = min(desired, maximumOutputTokens ?? desired)
        let margin = max(0, safetyMarginTokens ?? max(BoneContextWindowPlanner.minimumSafetyMarginTokens, contextWindowTokens / 100))
        var remaining = contextWindowTokens
        for reservation in [output, max(0, protocolReserveTokens), margin] {
            guard reservation < remaining else {
                throw BoneContextWindowError.inputBudgetUnavailable(contextWindow: contextWindowTokens, requestedOutput: output)
            }
            remaining -= reservation
        }
        return (output, min(maximumInputTokens ?? remaining, remaining))
    }

    /// Host 可收紧但不能放宽 Engine 已知的硬容量。
    func constrained(by other: BoneContextWindowBudget?) throws -> Self {
        guard let other else { return self }
        let window = min(contextWindowTokens, other.contextWindowTokens)
        return try Self(contextWindowTokens: window,
                        maximumInputTokens: min(maximumInputTokens ?? window, other.maximumInputTokens ?? window, window),
                        maximumOutputTokens: [maximumOutputTokens, other.maximumOutputTokens].compactMap { $0 }.min().map { min($0, window) }, source: source)
    }

    private enum CodingKeys: CodingKey { case contextWindowTokens, maximumInputTokens, maximumOutputTokens, source }
}

public enum BoneContextWindowBudgetError: Error, Equatable, Sendable { case invalidBudget }

public extension BoneModelContextLimits {
    var contextWindowBudget: BoneContextWindowBudget { BoneContextWindowBudget(modelLimits: self) }
}

/// 可选能力，不增加既有自定义 Engine 的必需实现。
public protocol BoneInferenceContextBudgetProviding: Sendable {
    func contextBudget(for modelID: String) throws -> BoneContextWindowBudget?
}

/// 完整渲染后的请求 Token 数；包含模板/工具，不能是字符数估算。
public protocol BoneInferenceContextTokenCounting: Sendable {
    func countContextTokens(request: BoneInferenceRequest) async throws -> Int
}

/// 只有 Provider adapter 有权重绑定其不透明续接信息。
public protocol BoneInferenceContextRebinding: Sendable {
    func rebindContextContinuation(_ continuation: BoneInferenceProviderContinuation,
                                  from original: [BoneInferenceMessage], to compacted: [BoneInferenceMessage]) throws -> BoneInferenceProviderContinuation?
}
