import Foundation

public enum BoneInferenceMessageRole: String, Codable, Sendable {
    case system, user, assistant, tool
}

/// Tool 结果边界；内容只供下一轮推理使用，不得进入日志或事件。
public struct BoneInferenceToolResult: Codable, Equatable, Sendable {
    public static let maximumResultByteCount = 1_048_576
    public let callID: String
    public let toolID: String
    public let content: BoneToolResultContent
    public let isError: Bool
    public let ordinal: Int

    public init(
        callID: String,
        toolID: String,
        content: BoneToolResultContent,
        isError: Bool,
        ordinal: Int
    ) throws {
        guard !callID.isEmpty,
              !toolID.isEmpty,
              ordinal >= 0 else {
            throw BoneInferenceError.invalidToolResult
        }
        let validated = try content.validated()
        guard validated.byteCount <= Self.maximumResultByteCount else {
            throw BoneInferenceError.toolResultTooLarge
        }
        self.callID = callID
        self.toolID = toolID
        self.content = validated
        self.isError = isError
        self.ordinal = ordinal
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let callID = try container.decode(String.self, forKey: .callID)
        let toolID = try container.decode(String.self, forKey: .toolID)
        if let content = try container.decodeIfPresent(BoneToolResultContent.self, forKey: .content) {
            try self.init(
                callID: callID,
                toolID: toolID,
                content: content,
                isError: try container.decodeIfPresent(Bool.self, forKey: .isError) ?? false,
                ordinal: try container.decodeIfPresent(Int.self, forKey: .ordinal) ?? 0
            )
        } else {
            try self.init(
                callID: callID,
                toolID: toolID,
                content: .json(container.decode(Data.self, forKey: .result)),
                isError: false,
                ordinal: 0
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(callID, forKey: .callID)
        try container.encode(toolID, forKey: .toolID)
        try container.encode(content, forKey: .content)
        try container.encode(isError, forKey: .isError)
        try container.encode(ordinal, forKey: .ordinal)
    }

    public var legacyResult: Data? {
        guard case let .json(data) = content else { return nil }
        return data
    }

    private enum CodingKeys: CodingKey { case callID, toolID, result, content, isError, ordinal }
}

public struct BoneInferenceMessage: Codable, Equatable, Sendable {
    public let role: BoneInferenceMessageRole
    public let content: String?
    public let assistantTurn: BoneInferenceAssistantTurn?
    public let toolResult: BoneInferenceToolResult?
    public let toolResults: BoneInferenceToolResultBatch?

    public init(role: BoneInferenceMessageRole, content: String) {
        self.role = role
        self.content = content
        assistantTurn = nil
        toolResult = nil
        toolResults = nil
    }

    private init(role: BoneInferenceMessageRole, assistantTurn: BoneInferenceAssistantTurn) {
        self.role = role
        content = nil
        self.assistantTurn = assistantTurn
        toolResult = nil
        toolResults = nil
    }

    private init(role: BoneInferenceMessageRole, toolResult: BoneInferenceToolResult) {
        self.role = role
        content = nil
        assistantTurn = nil
        self.toolResult = toolResult
        toolResults = nil
    }

    private init(role: BoneInferenceMessageRole, toolResults: BoneInferenceToolResultBatch) {
        self.role = role
        content = nil
        assistantTurn = nil
        toolResult = nil
        self.toolResults = toolResults
    }

    public static func assistant(_ turn: BoneInferenceAssistantTurn) -> Self {
        Self(role: .assistant, assistantTurn: turn)
    }

    public static func toolResults(_ batch: BoneInferenceToolResultBatch) -> Self {
        Self(role: .tool, toolResults: batch)
    }

    public static func toolResult(callID: String, toolID: String, result: Data) -> Self {
        let value = try! BoneInferenceToolResult(
            callID: callID,
            toolID: toolID,
            content: .json(result),
            isError: false,
            ordinal: 0
        )
        return Self(role: .tool, toolResult: value)
    }

    public func requiredToolResults() throws -> BoneInferenceToolResultBatch {
        if let toolResults { return toolResults }
        if let toolResult { return try .init(results: [toolResult]) }
        throw BoneInferenceError.invalidToolResult
    }
}

/// 供应商无关的文本生成参数；nil 表示使用具体协议默认行为。
public struct BoneInferenceGenerationOptions: Codable, Equatable, Sendable {
    public let temperature: Double?
    public let maximumOutputTokens: Int?

    public init(temperature: Double? = nil, maximumOutputTokens: Int? = nil) {
        self.temperature = temperature
        self.maximumOutputTokens = maximumOutputTokens
    }

    public func validated() throws -> Self {
        if let temperature, !(0...2).contains(temperature) {
            throw BoneInferenceError.invalidGenerationOptions
        }
        if let maximumOutputTokens, maximumOutputTokens <= 0 {
            throw BoneInferenceError.invalidGenerationOptions
        }
        return self
    }
}

public struct BoneInferenceRequest: Codable, Equatable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case modelID, messages, availableTools, generationOptions, providerContinuation
    }
    public let modelID: String
    public let messages: [BoneInferenceMessage]
    public let availableTools: [BoneAgentToolDefinition]
    public let generationOptions: BoneInferenceGenerationOptions
    public let providerContinuation: BoneInferenceProviderContinuation?

    public init(
        modelID: String,
        messages: [BoneInferenceMessage],
        availableTools: [BoneAgentToolDefinition] = [],
        generationOptions: BoneInferenceGenerationOptions = .init(),
        providerContinuation: BoneInferenceProviderContinuation? = nil
    ) {
        self.modelID = modelID
        self.messages = messages
        self.availableTools = availableTools
        self.generationOptions = generationOptions
        self.providerContinuation = providerContinuation
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        modelID = try container.decode(String.self, forKey: .modelID)
        messages = try container.decode([BoneInferenceMessage].self, forKey: .messages)
        availableTools = try container.decodeIfPresent(
            [BoneAgentToolDefinition].self,
            forKey: .availableTools
        ) ?? []
        generationOptions = try container.decodeIfPresent(
            BoneInferenceGenerationOptions.self,
            forKey: .generationOptions
        ) ?? .init()
        providerContinuation = try container.decodeIfPresent(
            BoneInferenceProviderContinuation.self,
            forKey: .providerContinuation
        )
    }
}

public struct BoneInferenceFinish: Codable, Equatable, Sendable {
    public let text: String
    public init(text: String) { self.text = text }
}

/// 强类型结构化 JSON Data 边界；Provider 负责保证其 JSON 语义。
public struct BoneInferenceStructuredResult: Codable, Equatable, Sendable {
    public let data: Data
    public init(data: Data) { self.data = data }
}

public struct BoneInferenceToolCall: Codable, Equatable, Sendable {
    public static let maximumArgumentsByteCount = 1_048_576
    public let id: String
    public let toolID: String
    public let arguments: Data
    /// 同一 Assistant Turn 内的稳定 Provider 顺序；旧构造默认为 0，由 Turn 重建。
    public let ordinal: Int

    public init(id: String, toolID: String, arguments: Data, ordinal: Int = 0) {
        self.id = id
        self.toolID = toolID
        self.arguments = arguments
        self.ordinal = ordinal
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        toolID = try container.decode(String.self, forKey: .toolID)
        arguments = try container.decode(Data.self, forKey: .arguments)
        ordinal = try container.decodeIfPresent(Int.self, forKey: .ordinal) ?? 0
    }

    func withOrdinal(_ ordinal: Int) -> Self {
        Self(id: id, toolID: toolID, arguments: arguments, ordinal: ordinal)
    }

    private enum CodingKeys: CodingKey { case id, toolID, arguments, ordinal }
}

/// 推理响应。旧单结果 case 保持源码兼容；新 Provider Tool Calling 使用完整 `assistantTurn`。
public enum BoneInferenceResponse: Codable, Equatable, Sendable {
    case finish(BoneInferenceFinish)
    case structured(BoneInferenceStructuredResult)
    case toolCall(BoneInferenceToolCall)
    case assistantTurn(
        turn: BoneInferenceAssistantTurn,
        finishReason: BoneInferenceFinishReason,
        usage: BoneInferenceUsage?,
        refusal: BoneInferenceRefusal?,
        providerContinuation: BoneInferenceProviderContinuation?
    )

    public init(text: String) { self = .finish(.init(text: text)) }

    public init(
        assistantTurn: BoneInferenceAssistantTurn,
        finishReason: BoneInferenceFinishReason,
        usage: BoneInferenceUsage?,
        refusal: BoneInferenceRefusal?,
        providerContinuation: BoneInferenceProviderContinuation?
    ) {
        self = .assistantTurn(
            turn: assistantTurn,
            finishReason: finishReason,
            usage: usage,
            refusal: refusal,
            providerContinuation: providerContinuation
        )
    }

    public var terminalAssistantTurn: BoneInferenceAssistantTurn? {
        switch self {
        case let .finish(value):
            return try? BoneInferenceAssistantTurn(content: [.text(value.text)])
        case let .structured(value):
            return try? BoneInferenceAssistantTurn(content: [.structured(value.data)])
        case let .toolCall(value):
            return try? BoneInferenceAssistantTurn(content: [.toolCall(value)])
        case let .assistantTurn(turn, _, _, _, _):
            return turn
        }
    }
}
