import Foundation

/// Tool 的稳定元数据和模型输入 Schema。
///
/// 旧构造器继续支持纯本地 Registry；只有带合法 `inputSchema` 的定义才能通过
/// `validatedForModelExposure()` 暴露给真实 Provider。
public struct BoneAgentToolDefinition: Codable, Equatable, Sendable {
    public let id: String
    public let version: String
    public let title: String
    public let summary: String
    public let wireName: String?
    public let schemaVersion: Int?
    public let inputSchema: BoneToolSchema?
    public let executionPolicy: BoneToolExecutionPolicy?
    public let impact: BoneToolImpact?

    public init(
        id: String,
        version: String,
        title: String,
        summary: String,
        executionPolicy: BoneToolExecutionPolicy? = nil,
        impact: BoneToolImpact? = nil
    ) {
        self.id = id
        self.version = version
        self.title = title
        self.summary = summary
        wireName = nil
        schemaVersion = nil
        inputSchema = nil
        self.executionPolicy = executionPolicy
        self.impact = impact
    }

    public init(
        id: String,
        version: String,
        title: String,
        summary: String,
        wireName: String,
        schemaVersion: Int,
        inputSchema: BoneToolSchema,
        executionPolicy: BoneToolExecutionPolicy? = nil,
        impact: BoneToolImpact? = nil
    ) {
        self.id = id
        self.version = version
        self.title = title
        self.summary = summary
        self.wireName = wireName
        self.schemaVersion = schemaVersion
        self.inputSchema = inputSchema
        self.executionPolicy = executionPolicy
        self.impact = impact
    }

    /// 返回完整影响声明；未声明时 fail-closed。
    public func requiredImpact() throws -> BoneToolImpact {
        guard let impact else { throw BoneToolPolicyError.undeclaredImpact }
        return impact
    }

    /// 验证 Tool 是否可以安全暴露给模型。
    public func validatedForModelExposure() throws -> Self {
        guard Self.isValidStableID(id),
              Self.isValidVersion(version),
              let wireName,
              Self.isValidWireName(wireName),
              let schemaVersion,
              schemaVersion > 0,
              let inputSchema else {
            if self.inputSchema == nil { throw BoneToolSchemaError.missingInputSchema }
            throw BoneToolSchemaError.invalidToolIdentity
        }
        try BoneToolSchemaValidator.validateDefinition(inputSchema)
        return self
    }
}

private extension BoneAgentToolDefinition {
    static func isValidStableID(_ value: String) -> Bool {
        guard (1...128).contains(value.count) else { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        return value.unicodeScalars.allSatisfy(allowed.contains)
    }

    static func isValidVersion(_ value: String) -> Bool {
        guard (1...64).contains(value.count) else { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.+-")
        return value.unicodeScalars.allSatisfy(allowed.contains)
    }

    static func isValidWireName(_ value: String) -> Bool {
        guard let first = value.unicodeScalars.first,
              (1...64).contains(value.count),
              CharacterSet.letters.union(CharacterSet(charactersIn: "_")).contains(first) else {
            return false
        }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_"))
        return value.unicodeScalars.allSatisfy(allowed.contains)
    }
}
