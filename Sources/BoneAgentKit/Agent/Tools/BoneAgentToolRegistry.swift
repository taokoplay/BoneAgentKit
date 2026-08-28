import Foundation

/// Tool Registry 初始化错误。
public enum BoneAgentToolRegistryError: Error, Equatable, Sendable {
    case duplicateToolID(String)
}

/// 按稳定 ID 保存并调用类型擦除 Tool。
public struct BoneAgentToolRegistry: Sendable {
    private let toolsByID: [String: BoneAnyAgentTool]

    public init(tools: [BoneAnyAgentTool]) throws {
        var indexedTools: [String: BoneAnyAgentTool] = [:]
        for tool in tools {
            guard indexedTools[tool.definition.id] == nil else {
                throw BoneAgentToolRegistryError.duplicateToolID(tool.definition.id)
            }
            indexedTools[tool.definition.id] = tool
        }
        toolsByID = indexedTools
    }

    public var definitions: [BoneAgentToolDefinition] {
        toolsByID.values.map(\.definition).sorted { $0.id < $1.id }
    }

    public func tool(id: String) -> BoneAnyAgentTool? {
        toolsByID[id]
    }

    public func execute(
        id: String,
        input: Data,
        context: any BoneAgentToolContext
    ) async throws -> Data {
        guard let tool = toolsByID[id] else {
            throw BoneAgentToolError.toolNotFound(id)
        }
        return try await tool.execute(input: input, context: context)
    }
}
