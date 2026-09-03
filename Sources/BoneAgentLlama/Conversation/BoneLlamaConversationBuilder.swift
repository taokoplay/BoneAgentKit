import BoneAgentKit

/// 将统一推理请求转换为不包含模板标记的纯文本 Conversation。
public enum BoneLlamaConversationBuilder {
    public static func build(request: BoneInferenceRequest) throws -> BoneLlamaConversation {
        guard !request.messages.isEmpty,
              request.availableTools.isEmpty,
              request.responseFormat == .text,
              request.outputConstraint == nil,
              request.providerContinuation == nil,
              request.reasoningDisclosure == .hidden else {
            throw BoneLlamaAdapterError.unsupportedRequest
        }

        let messages = try request.messages.map { message -> BoneLlamaConversationMessage in
            guard let content = message.content,
                  !content.isEmpty,
                  message.assistantTurn == nil,
                  message.toolResult == nil,
                  message.toolResults == nil,
                  message.role != .tool else {
                throw BoneLlamaAdapterError.unsupportedRequest
            }
            let role: BoneLlamaConversationRole
            switch message.role {
            case .system: role = .system
            case .user: role = .user
            case .assistant: role = .assistant
            case .tool: throw BoneLlamaAdapterError.unsupportedRequest
            }
            return try .init(role: role, content: content)
        }
        return try .init(messages: messages)
    }
}
