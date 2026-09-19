import Foundation

/// 本次 Run 的模型元数据，由构造 Engine 的 Host 按真实来源注入。
///
/// `BoneInferenceEngine` 只暴露能力声明，不暴露 Provider 身份、目录版本或模型限制证据，
/// 因此这些事实不能由 Kit 猜测，也不会从模型名称推断。缺失字段保持 nil 表示未知，
/// 不得用默认值补全；凭据、完整 Provider UUID 和 URL 永远不进入本类型。
public struct BoneAgentModelSnapshotContext: Equatable, Sendable {
    public let providerKind: BoneInferenceProviderKind?
    /// Host 配置的模型显示名；只用于回看，不参与请求。
    public let modelDisplayName: String?
    /// Host 配置的模型别名（显示用短名）；实际请求值是 `BoneInferenceRequest.modelID`。
    public let modelAlias: String?
    /// 本次 Run 实际生效的服务端推理策略；Engine 不通过协议暴露该值。
    public let serverReasoning: BoneInferenceServerReasoning?
    /// 模型级能力声明及其证据来源；与 Engine 实现取交集后的结果才进入快照。
    public let capabilityProfile: BoneModelCapabilityProfile?
    /// 该模型 Token 限制的公开证据；没有公开证据的模型保持 nil。
    public let contextLimits: BoneModelContextLimits?
    /// 本次 Run 使用的 Catalog 版本坐标；Host 混用多份目录时用于定位来源。
    public let catalogVersion: Int?
    public let catalogVerifiedAt: String?

    public init(
        providerKind: BoneInferenceProviderKind? = nil,
        modelDisplayName: String? = nil,
        modelAlias: String? = nil,
        serverReasoning: BoneInferenceServerReasoning? = nil,
        capabilityProfile: BoneModelCapabilityProfile? = nil,
        contextLimits: BoneModelContextLimits? = nil,
        catalogVersion: Int? = nil,
        catalogVerifiedAt: String? = nil
    ) {
        self.providerKind = providerKind
        self.modelDisplayName = modelDisplayName
        self.modelAlias = modelAlias
        self.serverReasoning = serverReasoning
        self.capabilityProfile = capabilityProfile
        self.contextLimits = contextLimits
        self.catalogVersion = catalogVersion
        self.catalogVerifiedAt = catalogVerifiedAt
    }
}

/// 一次 Agent Run 实际使用的模型事实快照。
///
/// 只包含白名单事实：模型身份、解析后的能力与证据来源、上下文限制证据、请求参数回显、
/// 终态与用量计数、产出时间。不得携带 Prompt、模型响应正文、Tool 参数或结果、凭据、
/// 完整 Provider UUID 或敏感 URL；唯一允许出现的 URL 是 `contextLimits.documentationURL`，
/// 它必须是 Host 声明的公开厂商文档地址，不能带签名、Token 或用户资源路径。
///
/// Kit 只交付快照：不落盘、不跨 Run 聚合会话。会话级记录由 Host 把同一次对话的多次
/// Run 快照累加而成，`inferenceResponseCount` 与 `usageByResponse` 是判断覆盖度的依据。
public struct BoneAgentRunModelSnapshot: Codable, Equatable, Sendable {
    /// 实际发出的请求模型 ID，而不是目录显示名或别名。
    public let modelID: String
    /// Host 配置的模型显示名；只允许来自模型目录，不能携带用户内容，不参与请求。
    public let modelDisplayName: String?
    /// Host 配置的模型别名（显示用短名）；`modelID` 才是实际请求值，同样不能携带用户内容。
    public let modelAlias: String?
    public let providerKind: BoneInferenceProviderKind?
    public let invocation: BoneInferenceInvocationMode
    /// 本次 Run 能力门禁通过时解析出的能力；已与 Engine 实现取过交集。
    public let resolvedCapabilities: Set<BoneInferenceCapability>
    public let capabilityProfileSource: BoneModelCapabilityEvidenceSource?
    public let capabilityProfileVerifiedAt: String?
    public let contextLimits: BoneModelContextLimits?
    public let catalogVersion: Int?
    public let catalogVerifiedAt: String?
    /// 本次 Run 使用的文本生成参数回显，用于复现同一次推理的输入侧事实。
    public let generationOptions: BoneInferenceGenerationOptions
    /// 本次 Run 实际生效的服务端推理策略；Engine 未暴露且 Host 未提供时为 nil。
    public let serverReasoning: BoneInferenceServerReasoning?
    /// 是否在本次 Run 中启用了受约束输出；禁用与未验证都不会在此伪造为已启用。
    public let usesOutputConstraint: Bool
    /// Runtime 实际提供的 Tool 数量，不是模型自行声明的能力。
    public let availableToolCount: Int
    public let terminalState: BoneAgentRunTerminalState
    /// 最后一次推理响应的终止原因；该次响应以 legacy 单结果形态交付时为 nil（形态本身不带原因）。
    public let finishReason: BoneInferenceFinishReason?
    /// Engine 已交付的推理响应数，包含随后被取消或未提交 checkpoint 的响应；用量覆盖度以它为准。
    public let inferenceResponseCount: Int
    /// 本次 Run 已受理的 Tool 结果数；副作用不确定（`toolOutcomeUnknown`）时不计入。
    public let toolResultCount: Int
    /// 各次推理响应报告的用量，按发生顺序；未报告用量的响应不产生条目。
    public let usageByResponse: [BoneInferenceUsage]
    /// 已报告用量的合计；可选字段只在其全部报告者都提供时才给出，否则保持未知。
    /// 该值由 `usageByResponse` 推导，不参与编解码，避免出现自相矛盾的记录。
    public let totalUsage: BoneInferenceUsage?
    /// Run 自身耗时；从能力门禁之后开始计，不包含快照投递耗时。
    public let wallClockSeconds: TimeInterval?
    /// ISO 8601 UTC 产出一致时间戳，格式 `yyyy-MM-dd'T'HH:mm:ss.SSS'Z'`。
    public let generatedAt: String

    public init(
        modelID: String,
        modelDisplayName: String? = nil,
        modelAlias: String? = nil,
        providerKind: BoneInferenceProviderKind? = nil,
        invocation: BoneInferenceInvocationMode,
        resolvedCapabilities: Set<BoneInferenceCapability>,
        capabilityProfileSource: BoneModelCapabilityEvidenceSource? = nil,
        capabilityProfileVerifiedAt: String? = nil,
        contextLimits: BoneModelContextLimits? = nil,
        catalogVersion: Int? = nil,
        catalogVerifiedAt: String? = nil,
        generationOptions: BoneInferenceGenerationOptions,
        serverReasoning: BoneInferenceServerReasoning? = nil,
        usesOutputConstraint: Bool,
        availableToolCount: Int,
        terminalState: BoneAgentRunTerminalState,
        finishReason: BoneInferenceFinishReason? = nil,
        inferenceResponseCount: Int,
        toolResultCount: Int,
        usageByResponse: [BoneInferenceUsage],
        wallClockSeconds: TimeInterval? = nil,
        generatedAt: String
    ) {
        self.modelID = modelID
        self.modelDisplayName = Self.normalized(modelDisplayName)
        self.modelAlias = Self.normalized(modelAlias)
        self.providerKind = providerKind
        self.invocation = invocation
        self.resolvedCapabilities = resolvedCapabilities
        self.capabilityProfileSource = capabilityProfileSource
        self.capabilityProfileVerifiedAt = capabilityProfileVerifiedAt
        self.contextLimits = contextLimits
        self.catalogVersion = catalogVersion
        self.catalogVerifiedAt = catalogVerifiedAt
        self.generationOptions = generationOptions
        self.serverReasoning = serverReasoning
        self.usesOutputConstraint = usesOutputConstraint
        self.availableToolCount = availableToolCount
        self.terminalState = terminalState
        self.finishReason = finishReason
        self.inferenceResponseCount = inferenceResponseCount
        self.toolResultCount = toolResultCount
        self.usageByResponse = usageByResponse
        totalUsage = Self.aggregate(usageByResponse)
        self.wallClockSeconds = wallClockSeconds
        self.generatedAt = generatedAt
    }

    /// `totalUsage` 故意不参与编解码：读取时重算，避免持久化记录里出现与明细矛盾的合计。
    private enum CodingKeys: String, CodingKey {
        case modelID, modelDisplayName, modelAlias, providerKind, invocation, resolvedCapabilities
        case capabilityProfileSource, capabilityProfileVerifiedAt
        case contextLimits, catalogVersion, catalogVerifiedAt
        case generationOptions, serverReasoning, usesOutputConstraint, availableToolCount
        case terminalState, finishReason, inferenceResponseCount, toolResultCount
        case usageByResponse, wallClockSeconds, generatedAt
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            modelID: try container.decode(String.self, forKey: .modelID),
            modelDisplayName: try container.decodeIfPresent(String.self, forKey: .modelDisplayName),
            modelAlias: try container.decodeIfPresent(String.self, forKey: .modelAlias),
            providerKind: try container.decodeIfPresent(
                BoneInferenceProviderKind.self,
                forKey: .providerKind
            ),
            invocation: try container.decode(BoneInferenceInvocationMode.self, forKey: .invocation),
            resolvedCapabilities: try container.decode(
                Set<BoneInferenceCapability>.self,
                forKey: .resolvedCapabilities
            ),
            capabilityProfileSource: try container.decodeIfPresent(
                BoneModelCapabilityEvidenceSource.self,
                forKey: .capabilityProfileSource
            ),
            capabilityProfileVerifiedAt: try container.decodeIfPresent(
                String.self,
                forKey: .capabilityProfileVerifiedAt
            ),
            contextLimits: try container.decodeIfPresent(
                BoneModelContextLimits.self,
                forKey: .contextLimits
            ),
            catalogVersion: try container.decodeIfPresent(Int.self, forKey: .catalogVersion),
            catalogVerifiedAt: try container.decodeIfPresent(String.self, forKey: .catalogVerifiedAt),
            generationOptions: try container.decode(
                BoneInferenceGenerationOptions.self,
                forKey: .generationOptions
            ),
            serverReasoning: try container.decodeIfPresent(
                BoneInferenceServerReasoning.self,
                forKey: .serverReasoning
            ),
            usesOutputConstraint: try container.decode(Bool.self, forKey: .usesOutputConstraint),
            availableToolCount: try container.decode(Int.self, forKey: .availableToolCount),
            terminalState: try container.decode(BoneAgentRunTerminalState.self, forKey: .terminalState),
            finishReason: try container.decodeIfPresent(
                BoneInferenceFinishReason.self,
                forKey: .finishReason
            ),
            inferenceResponseCount: try container.decode(Int.self, forKey: .inferenceResponseCount),
            toolResultCount: try container.decode(Int.self, forKey: .toolResultCount),
            usageByResponse: try container.decode([BoneInferenceUsage].self, forKey: .usageByResponse),
            wallClockSeconds: try container.decodeIfPresent(TimeInterval.self, forKey: .wallClockSeconds),
            generatedAt: try container.decode(String.self, forKey: .generatedAt)
        )
    }

    /// 显示名与别名只做空白归一：空串等于未提供，不保存只有空白的标识。
    private static func normalized(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    /// 只聚合实际报告过用量的响应：没有报告用量的响应不产生条目，也不按 0 参与。
    /// 可选字段一旦有报告者缺失，合计保持 nil，而不是把未知当成 0。
    /// 必填字段使用饱和加法：溢出停在 Int 边界，不回绕成看起来合法的负数。
    private static func aggregate(_ usages: [BoneInferenceUsage]) -> BoneInferenceUsage? {
        guard !usages.isEmpty else { return nil }
        var inputTokens = 0
        var outputTokens = 0
        var cachedInputTokens: Int? = 0
        var reasoningTokens: Int? = 0
        for usage in usages {
            inputTokens = saturatedAdd(inputTokens, usage.inputTokens)
            outputTokens = saturatedAdd(outputTokens, usage.outputTokens)
            cachedInputTokens = cachedInputTokens.map { saturatedAdd($0, usage.cachedInputTokens ?? 0) }
            if usage.cachedInputTokens == nil { cachedInputTokens = nil }
            reasoningTokens = reasoningTokens.map { saturatedAdd($0, usage.reasoningTokens ?? 0) }
            if usage.reasoningTokens == nil { reasoningTokens = nil }
        }
        return BoneInferenceUsage(
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            cachedInputTokens: cachedInputTokens,
            reasoningTokens: reasoningTokens
        )
    }

    private static func saturatedAdd(_ lhs: Int, _ rhs: Int) -> Int {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        guard overflow else { return sum }
        return rhs >= 0 ? Int.max : Int.min
    }
}

extension BoneAgentRunModelSnapshot {
    /// Kit 内部统一的 UTC 产出一致时间戳；Host 记录同一次对话时可直接复用。
    static func currentUTCTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .iso8601)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"
        return formatter.string(from: Date())
    }
}
