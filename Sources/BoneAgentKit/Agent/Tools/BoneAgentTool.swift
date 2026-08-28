import Foundation

/// 使用 Codable 输入输出的强类型 Tool 契约。
public protocol BoneAgentTool: Sendable {
    associatedtype Input: Codable & Sendable
    associatedtype Output: Codable & Sendable
    associatedtype Context: BoneAgentToolContext

    static var definition: BoneAgentToolDefinition { get }

    func execute(input: Input, context: Context) async throws -> Output
}

/// 适合日志和指标的 Tool 错误分类，不含参数、Context 或 Tool ID 原值。
public enum BoneAgentToolSafeReason: String, Codable, Equatable, Sendable {
    case invalidArguments
    case invalidContext
    case toolNotFound
}

/// Tool 边界上的稳定错误。
public enum BoneAgentToolError: Error, Equatable, Sendable {
    case invalidArguments(toolID: String)
    case invalidContext(toolID: String)
    case toolNotFound(String)

    public var safeReason: BoneAgentToolSafeReason {
        switch self {
        case .invalidArguments:
            return .invalidArguments
        case .invalidContext:
            return .invalidContext
        case .toolNotFound:
            return .toolNotFound
        }
    }
}
