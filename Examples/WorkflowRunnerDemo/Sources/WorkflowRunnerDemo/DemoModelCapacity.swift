import Foundation
import BoneAgentKit

/// Model facts are separate from user budgets. Resolve by exact provider, endpoint and model ID.
struct DemoModelCapacity: Equatable, Sendable {
    static let maximumConfigurableOutputTokens = 1_000_000
    let contextWindowTokens: Int?
    let maximumInputTokens: Int?
    let maximumOutputTokens: Int?
    let recommendedOutputTokens: Int?
    let outputIncludesThinking: Bool
    let sourceTitle: String
    let sourceURL: URL?
    let verifiedAt: String?

    static let unknown = Self(contextWindowTokens: nil, maximumInputTokens: nil, maximumOutputTokens: nil,
        recommendedOutputTokens: nil, outputIncludesThinking: false, sourceTitle: "当前连接与型号的容量未知",
        sourceURL: nil, verifiedAt: nil)

    static func resolve(settings: DemoLiveChatSettings, catalog: BoneInferenceProviderCatalog? = nil) -> Self {
        let modelID = settings.modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !settings.usesFullEndpointURL,
              let connection = DemoLiveChatSettings.connectionURL(settings.baseURL),
              let entry = try? settings.provider.catalogEntry(in: catalog ?? DemoChatProvider.bundledCatalog()),
              let expected = entry.defaultBaseURL,
              normalized(connection) == normalized(expected) else { return .unknown }
        // Official documentation checked for this exact mainland Anthropic endpoint.
        // Do not infer the same capability for gateways, aliases or similarly named models.
        if entry.ident == "MiniMax", connection.host == "api.minimaxi.com",
           connection.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) == "anthropic",
           modelID == "MiniMax-M3.1-Flash" {
            return .init(contextWindowTokens: 1_000_000, maximumInputTokens: nil, maximumOutputTokens: 524_288,
                recommendedOutputTokens: 131_072, outputIncludesThinking: true,
                sourceTitle: "MiniMax 官方文档", sourceURL: URL(string: "https://platform.minimaxi.com/docs/api-reference/text-chat-anthropic"),
                verifiedAt: "2026-11-18")
        }
        guard let model = entry.models.first(where: { $0.id == modelID }) else { return .unknown }
        let declared = model.metadata?.declaration.limits
        func positive(_ value: Int?) -> Int? { value.flatMap { $0 > 0 ? $0 : nil } }
        let context = positive(declared?.context) ?? model.tokenLimits?.contextWindowTokens
        let input = positive(declared?.input) ?? model.tokenLimits?.maximumInputTokens
        let output = positive(declared?.output) ?? model.tokenLimits?.maximumOutputTokens
        guard context != nil || input != nil || output != nil else { return .unknown }
        return .init(contextWindowTokens: context, maximumInputTokens: input, maximumOutputTokens: output,
            recommendedOutputTokens: nil, outputIncludesThinking: false, sourceTitle: "SDK 目录声明",
            sourceURL: model.metadata?.provenance.sourceURL, verifiedAt: model.metadata?.provenance.retrievedAt)
    }

    var selectableOutputMaximum: Int { min(Self.maximumConfigurableOutputTokens, maximumOutputTokens ?? Self.maximumConfigurableOutputTokens) }
    func contextBudget(hostTokens: Int) throws -> BoneContextWindowBudget {
        let window = min(hostTokens, contextWindowTokens ?? hostTokens)
        return try .init(contextWindowTokens: window, maximumInputTokens: maximumInputTokens.map { min($0, window) },
            maximumOutputTokens: maximumOutputTokens.map { min($0, window) }, source: .host)
    }
    private static func normalized(_ url: URL) -> String {
        url.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
}

extension DemoLiveChatSettings {
    var modelCapacity: DemoModelCapacity { .resolve(settings: self) }
    var summaryOutputTokens: Int { contextSummaryOutputTokens ?? 512 }
    var compactsCurrentToolHistory: Bool { managesContext && summarizesContext && contextToolHistoryCompaction == true }
    var effectiveContextWindowTokens: Int { min(contextWindowTokens, modelCapacity.contextWindowTokens ?? contextWindowTokens) }
    var contextSafetyMarginTokens: Int { max(16, effectiveContextWindowTokens / 50) }
    var availableInputTokens: Int? {
        try? modelCapacity.contextBudget(hostTokens: contextWindowTokens).availableInputTokens(
            configuredOutputTokens: maximumOutputTokens, preferredOutputTokens: maximumOutputTokens,
            protocolReserveTokens: 128, safetyMarginTokens: contextSafetyMarginTokens).availableInputTokens
    }
    var replyLimitChoices: [Int] {
        let model = modelCapacity
        let values = [1_024, 2_048, 4_096, 8_192, 16_384, 32_768, 65_536, 131_072, 262_144, 524_288,
                      maximumOutputTokens, model.maximumOutputTokens ?? maximumOutputTokens]
        return Array(Set(values.filter { $0 >= 128 && $0 <= model.selectableOutputMaximum })).sorted()
    }
    var contextWindowChoices: [Int] {
        let values = [8_192, 16_384, 32_768, 65_536, 131_072, 262_144, 1_000_000, 1_048_576,
                      contextWindowTokens, modelCapacity.contextWindowTokens ?? contextWindowTokens]
        return Array(Set(values.filter { (4_096...2_000_000).contains($0) })).sorted()
    }
    mutating func useRecommendedModelCapacity() {
        let capacity = modelCapacity
        guard let output = capacity.recommendedOutputTokens, let context = capacity.contextWindowTokens else { return }
        maximumOutputTokens = output
        contextWindowTokens = context
    }
    mutating func setModelSummaryEnabled(_ enabled: Bool) {
        summarizesContext = enabled
        if enabled && contextSummaryOutputTokens == nil {
            contextSummaryOutputTokens = modelCapacity.outputIncludesThinking ? 8_192 : 2_048
        }
    }
}

extension DemoLiveChatSettings {
    /// Byte budgets remain independent safety boundaries, scaled only by explicit preferences.
    var runInputByteLimit: Int { max(512 * 1_024, min(16 * 1_024 * 1_024, max(0, min(2_000_000, effectiveContextWindowTokens)) * 4)) }
    var runOutputByteLimit: Int {
        let output = max(0, min(DemoModelCapacity.maximumConfigurableOutputTokens, maximumOutputTokens))
        let summary = summarizesContext ? max(0, min(DemoModelCapacity.maximumConfigurableOutputTokens, summaryOutputTokens)) : 0
        return max(256 * 1_024, min(16 * 1_024 * 1_024, (output + summary) * 8))
    }
    var streamByteLimit: Int { max(256 * 1_024, min(32 * 1_024 * 1_024, max(0, min(DemoModelCapacity.maximumConfigurableOutputTokens, maximumOutputTokens)) * 32)) }
}
