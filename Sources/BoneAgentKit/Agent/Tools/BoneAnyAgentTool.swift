import Foundation

/// Registry 边界使用的类型擦除 Tool；JSON 编解码仅发生在此边界。
public struct BoneAnyAgentTool: Sendable {
    public let definition: BoneAgentToolDefinition
    private let executeClosure: @Sendable (Data, any BoneAgentToolContext) async throws -> Data

    public init<Tool: BoneAgentTool>(_ tool: Tool) {
        definition = Tool.definition
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

    public func execute(
        input: Data,
        context: any BoneAgentToolContext
    ) async throws -> Data {
        try await executeClosure(input, context)
    }
}
