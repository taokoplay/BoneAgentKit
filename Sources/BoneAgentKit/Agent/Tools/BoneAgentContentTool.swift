import Foundation

/// 可选 Tool 契约，用于返回有序文本/图片引用。原 BoneAgentTool 的 JSON 输出行为不变。
/// 实际图片由 Provider 的 Host Resolver 读取；不允许直接把 Base64 塞进结果历史。
public protocol BoneAgentContentTool: Sendable {
    associatedtype Input: Codable & Sendable
    associatedtype Context: BoneAgentToolContext
    static var definition: BoneAgentToolDefinition { get }
    func execute(input: Input, context: Context) async throws -> BoneToolResultContent
}
