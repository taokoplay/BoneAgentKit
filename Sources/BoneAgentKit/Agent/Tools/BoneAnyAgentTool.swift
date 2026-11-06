import Foundation

/// Registry 边界使用的类型擦除 Tool；JSON 编解码仅发生在此边界。
public struct BoneAnyAgentTool: Sendable {
    public let definition: BoneAgentToolDefinition
    private let executeClosure: @Sendable (Data, any BoneAgentToolContext) async throws -> Data
    private let returnsContentEnvelope: Bool

    public init<Tool: BoneAgentTool>(_ tool: Tool) {
        definition = Tool.definition
        returnsContentEnvelope = false
        executeClosure = { data, context in
            let input: Tool.Input
            do {
                input = try JSONDecoder().decode(Tool.Input.self, from: data)
            } catch {
                throw BoneAgentToolError.invalidArguments(toolID: Tool.definition.id)
            }

            guard let typedContext = context as? Tool.Context else {
                throw BoneAgentToolError.invalidContext(toolID: Tool.definition.id)
            }

            let output = try await tool.execute(input: input, context: typedContext)
            return try JSONEncoder().encode(output)
        }
    }

    /// 内容 Tool 的内部 Data 是明确标记的信封；Agent 解码后才作为多模态结果进入历史。
    public init<Tool: BoneAgentContentTool>(_ tool: Tool) {
        definition = Tool.definition
        returnsContentEnvelope = true
        executeClosure = { data, context in
            let input: Tool.Input
            do { input = try JSONDecoder().decode(Tool.Input.self, from: data) }
            catch { throw BoneAgentToolError.invalidArguments(toolID: Tool.definition.id) }
            guard let typedContext = context as? Tool.Context else {
                throw BoneAgentToolError.invalidContext(toolID: Tool.definition.id)
            }
            let content = try await tool.execute(input: input, context: typedContext).validated()
            guard content.byteCount <= BoneInferenceToolResult.maximumResultByteCount else {
                throw BoneInferenceError.toolResultTooLarge
            }
            return try JSONEncoder().encode(content)
        }
    }

    func resultContent(_ output: Data) throws -> BoneToolResultContent {
        if returnsContentEnvelope { return try JSONDecoder().decode(BoneToolResultContent.self, from: output).validated() }
        return try BoneToolResultContent.json(output).validated()
    }

    /// Execute with a typed content result. Existing JSON tools remain `.json`.
    public func executeContent(input: Data, context: any BoneAgentToolContext) async throws -> BoneToolResultContent {
        try await resultContent(executeClosure(input, context))
    }

    /// JSON tools return their encoded Output; content tools return a BoneToolResultContent envelope.
    /// Prefer executeContent when consuming a heterogeneous tool registry.

    public func execute(
        input: Data,
        context: any BoneAgentToolContext
    ) async throws -> Data {
        try await executeClosure(input, context)
    }
}
