import Foundation

/// Tool 执行上下文的类型安全标记协议。
public protocol BoneAgentToolContext: Sendable {}

/// 不需要业务上下文的 Tool 可使用该空上下文。
public struct BoneAgentEmptyContext: BoneAgentToolContext {
    public init() {}
}
