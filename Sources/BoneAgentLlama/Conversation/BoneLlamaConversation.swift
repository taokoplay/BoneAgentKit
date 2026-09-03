import Foundation

/// 不包含任何模型模板 Token 的规范化 Llama 会话角色。
public enum BoneLlamaConversationRole: String, Codable, Equatable, Sendable {
    case system, user, assistant, tool
}

/// 模板渲染前的有界规范化消息。
public struct BoneLlamaConversationMessage: Codable, Equatable, Sendable {
    public static let maximumContentByteCount = 1_048_576

    public let role: BoneLlamaConversationRole
    public let content: String

    public init(role: BoneLlamaConversationRole, content: String) throws {
        guard !content.isEmpty,
              content.lengthOfBytes(using: .utf8) <= Self.maximumContentByteCount else {
            throw BoneLlamaAdapterError.unsupportedRequest
        }
        self.role = role
        self.content = content
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            role: container.decode(BoneLlamaConversationRole.self, forKey: .role),
            content: container.decode(String.self, forKey: .content)
        )
    }

    private enum CodingKeys: CodingKey { case role, content }
}

/// 模板无关的有序会话；具体 Renderer 负责且只负责一次模型模板渲染。
public struct BoneLlamaConversation: Codable, Equatable, Sendable {
    public static let maximumMessageCount = 1_024

    public let messages: [BoneLlamaConversationMessage]

    public init(messages: [BoneLlamaConversationMessage]) throws {
        guard !messages.isEmpty, messages.count <= Self.maximumMessageCount else {
            throw BoneLlamaAdapterError.unsupportedRequest
        }
        self.messages = messages
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(messages: container.decode([BoneLlamaConversationMessage].self, forKey: .messages))
    }

    private enum CodingKeys: CodingKey { case messages }
}
