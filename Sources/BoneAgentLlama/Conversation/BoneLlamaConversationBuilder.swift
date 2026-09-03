import BoneAgentKit

/// 将统一推理请求转换为不包含模板标记的纯文本 Conversation。
public enum BoneLlamaConversationBuilder {
    public static func build(request: BoneInferenceRequest) throws -> BoneLlamaConversation {
        try build(request: request, toolEnvelope: nil)
    }

    public static func build(
        request: BoneInferenceRequest,
        toolEnvelope: (any BoneLlamaToolEnvelopeCoding)?
    ) throws -> BoneLlamaConversation {
        guard !request.messages.isEmpty,
              request.responseFormat == .text,
              request.outputConstraint == nil,
              request.providerContinuation == nil,
              request.reasoningDisclosure == .hidden,
              request.availableTools.isEmpty == (toolEnvelope == nil) else {
            throw BoneLlamaAdapterError.unsupportedRequest
        }

        var knownCallIDs: [String: String] = [:]
        var messages: [BoneLlamaConversationMessage] = []
        if let toolEnvelope {
            messages.append(try .init(
                role: .system,
                content: toolEnvelope.systemInstructions(tools: request.availableTools)
            ))
        }
        for message in request.messages {
            switch message.role {
            case .system, .user:
                guard let content = message.content, !content.isEmpty else {
                    throw BoneLlamaAdapterError.unsupportedRequest
                }
                messages.append(try .init(
                    role: message.role == .system ? .system : .user,
                    content: content
                ))
            case .assistant:
                if let content = message.content, !content.isEmpty {
                    messages.append(try .init(role: .assistant, content: content))
                } else if let turn = message.assistantTurn, let toolEnvelope {
                    for call in turn.toolCalls {
                        guard knownCallIDs[call.id] == nil else {
                            throw BoneLlamaAdapterError.unsupportedRequest
                        }
                        knownCallIDs[call.id] = call.toolID
                    }
                    messages.append(try .init(
                        role: .assistant,
                        content: toolEnvelope.encodeAssistantTurn(turn, tools: request.availableTools)
                    ))
                } else {
                    throw BoneLlamaAdapterError.unsupportedRequest
                }
            case .tool:
                guard let toolEnvelope else { throw BoneLlamaAdapterError.unsupportedRequest }
                let batch: BoneInferenceToolResultBatch
                do { batch = try message.requiredToolResults() }
                catch { throw BoneLlamaAdapterError.unsupportedRequest }
                guard batch.results.allSatisfy({ knownCallIDs[$0.callID] == $0.toolID }) else {
                    throw BoneLlamaAdapterError.unsupportedRequest
                }
                messages.append(try .init(
                    role: .tool,
                    content: toolEnvelope.encodeToolResults(batch, tools: request.availableTools)
                ))
            }
        }
        return try .init(messages: messages)
    }
}
